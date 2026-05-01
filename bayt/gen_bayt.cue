// gen_bayt.cue — canonical per-target manifest emission. Output is
// `bayt.<target>.json` (the same content as bayt.cue's `#target`,
// resolved and normalized): one source of truth that every other
// `gen_*.cue` reads from.
//
// Pure CUE: no file IO, no exec. The nushell runtime
// (generate-bayt.nu) walks the bundle and writes files.
package bayt

import (
	"list"
	"strings"
)

// _expandGlobs / _expandLines — flatten a #MapAsList default into a
// plain list, plucking either `.glob` (for srcs/outs/exclude maps,
// whose elements have `glob: string`) or `.line` (for preamble maps,
// whose elements have `line: string`). Both default to [] when the
// input is null. Saves the same `[if null { [] }, MapToList(in)
// | pluck-field][0]` boilerplate from repeating ~5 times in the
// manifest emission.
_expandGlobs: {
	in:  null | #MapAsList
	out: [...string]
	out: [if in == null {[]}, [for v in (#MapToList & {"in": in}).out {v.glob}]][0]
}
_expandLines: {
	in:  null | #MapAsList
	out: [...string]
	out: [if in == null {[]}, [for v in (#MapToList & {"in": in}).out {v.line}]][0]
}

#manifestGen: G={
	project: #project
	// Flat map of cross-project dep string → pre-computed manifest object.
	// Injected by nushell (second-pass CUE export with stdin JSON).
	// Default {[string]: _} means same-project-only projects work without
	// injection; any string key returns _ (unconstrained) rather than _|_.
	depManifests: {[string]: _}

	// Project depth from monorepo root. dir="" means workspace-root —
	// strings.Split("", "/") returns [""] (len 1), which would emit one
	// spurious `../` hop and double-slash COPY paths. The conditional
	// keeps depth=0 the canonical workspace-root signal so every path
	// helper (relRoot, rootFromBayt, COPY destinations, taskfile cross-
	// includes) lands cleanly without bespoke per-site special-casing.
	_depth: [
		if G.project.dir == "" {0},
		if G.project.dir != "" {len(strings.Split(G.project.dir, "/"))},
	][0]

	// Project dir as a path-prefix segment: "" or "<dir>/". Used wherever
	// emitters concatenate `<prefix><file>` and a workspace-root project
	// (dir="") would otherwise produce a leading `/`.
	_dirPath: [
		if G.project.dir == "" {""},
		if G.project.dir != "" {"\(G.project.dir)/"},
	][0]

	projectManifest: {
		name:     G.project.name
		dir:      G.project.dir
		activate: G.project.activate
		// Targets the project actually emits — null entries (a project
		// opting out of an inherited target via `"<target>": null`) are
		// filtered here so downstream consumers only see live targets.
		targets: [for n, t in G.project.targets if t != null {n}]

		// Cross-project dirs reached via string deps containing ":",
		// transitively. Single source of truth for "which other projects
		// does this project depend on (directly or through a chain of
		// same-project deps)" — derived, not hand-listed. Used by the
		// emitters (compose, taskfile root, skaffold root) to wire
		// cross-project includes / requires automatically.
		crossProjectDirs: (_uniqStrings & {in: [
			for n, t in G.project.targets if t != null
			for d in _transitiveCrossDeps[n] {d.dir}
		]}).out
	}

	// Per-target direct cross-project deps (precomputed once). Bazel-
	// style refs: same-project deps look like ":<target>", cross-project
	// deps look like "<project>:<target>". The cross-project filter is
	// "ref does NOT start with `:`" — i.e. has a non-empty project
	// prefix. Values come from G.depManifests (injected by the nushell
	// second pass), keyed by the full ref string. Produces {name,
	// project, dir} objects matching the shape that Dockerfile/compose/
	// taskfile emitters consume.
	_targetCrossDeps: {
		for n, t in G.project.targets if t != null {
			(n): [
				for d in t.deps
				if !strings.HasPrefix(d, ":") {
					{
						// Visibility gate: cross-project deps may only
						// reference targets marked public. CUE unification
						// fails with `conflicting values "internal" and
						// "public"` when the producer is internal —
						// surfaces at generation time with a clear
						// message including the offending dep path.
						_visibility: G.depManifests[d].visibility & "public"

						name:    G.depManifests[d].name
						project: G.depManifests[d].project
						dir:     G.depManifests[d].dir
						// outs come along so the consumer's Dockerfile can
						// COPY exactly the producer's declared interface
						// (one COPY per glob, restricted to outs.globs and
						// honoring outs.exclude).
						outs: {
							globs:   G.depManifests[d].outs.globs
							exclude: G.depManifests[d].outs.exclude
						}
					}
				}
			]
		}
	}

	// Same-project dep names per target — Bazel `:<target>` refs with
	// leading `:` stripped, so the bare names key directly into
	// G.project.targets[name]. Computed once and reused by
	// _transitiveDeps and the per-target files emission below.
	_sameProjectDepNames: {
		for n, t in G.project.targets if t != null {
			(n): [for d in t.deps if strings.HasPrefix(d, ":") {strings.TrimPrefix(d, ":")}]
		}
	}

	// Transitive same-project dep names per target. Walks
	// _sameProjectDepNames recursively and dedupes; cross-project deps
	// live in _targetCrossDeps. Used to compute _transitiveCrossDeps
	// (a target that chains through same-project steps into a cross-
	// project dep must still federate that cross-project dep).
	_transitiveDeps: {
		for n, t in G.project.targets if t != null {
			let _dn = _sameProjectDepNames[n]
			(n): (_uniqStrings & {in: list.FlattenN([
				_dn,
				[for name in _dn if _transitiveDeps[name] != _|_ {_transitiveDeps[name]}],
			], 2)}).out
		}
	}

	// Transitive cross-project deps per target. Walks the same-project chain
	// (self + _transitiveDeps[n]) and collects each step's cross-project deps
	// from _targetCrossDeps. Deduped by "<project>-<name>".
	_transitiveCrossDeps: {
		for n, t in G.project.targets if t != null {
			let _selfPlusDeps = list.Concat([[n], _transitiveDeps[n]])
			let _all = list.Concat([
				for tn in _selfPlusDeps
				if _targetCrossDeps[tn] != _|_ {_targetCrossDeps[tn]}
			])
			let _keys = [for x in _all {"\(x.project)-\(x.name)"}]
			(n): [for i, x in _all if !list.Contains(list.Slice(_keys, 0, i), _keys[i]) {x}]
		}
	}

	// Per-target manifests. Skip null entries (a project opting out
	// of an inherited target) so we don't emit ghost manifest files.
	files: {
		for n, t in G.project.targets if t != null {
			// All normalized dep names: same-project bare names plus
			// cross-project target names resolved via G.depManifests.
			let _depNames = list.Concat([
				_sameProjectDepNames[n],
				[for d in t.deps if !strings.HasPrefix(d, ":") {G.depManifests[d].name}],
			])
			(n): {
				// Identity triple — `name` is the target, `project` is
				// the project's name, `dir` is its location relative to
				// monorepo root. Same triple is emitted on every
				// chainedDeps entry below.
				name:    t.name
				project: G.project.name
				dir:     G.project.dir
				// Target-level activate overrides project-level when
				// explicitly set (e.g. setup wants `""` so its mise +
				// pnpm cmds control their own prefixes individually);
				// otherwise inherit the project default.
				activate: [if t.activate != _|_ {t.activate}, G.project.activate][0]

				// Portable action.
				// srcs is emitted as the merged list — defaultGlobs
				// (framework MapAsList) values prepended to globs (user
				// list). Same for exclude. Downstream emitters see only
				// the resolved {globs, exclude} shape.
				let _targetSrcs = {
					globs:   list.Concat([(_expandGlobs & {in: t.srcs.defaultGlobs}).out,   t.srcs.globs])
					exclude: list.Concat([(_expandGlobs & {in: t.srcs.defaultExclude}).out, t.srcs.exclude])
				}
				srcs: _targetSrcs
				outs:       t.outs
				env:        t.env
				visibility: t.visibility

				// Deps normalized to name strings (direct only).
				deps: _depNames

				// Transitive same-project dep names (direct ∪ indirect).
				// Emitted so Dockerfile generation can list the exact set
				// of .bayt/Taskfile.<d>.yaml + .bayt/bayt.<d>.json files
				// this target needs inside the container — no more, no less.
				transitiveDeps: _transitiveDeps[n]

				// Transitive cross-project deps. Used by Dockerfile for
				// COPY --from chains so incremental task resolution finds
				// all dep projects' taskfiles + manifests inside the stage.
				transitiveCrossDeps: _transitiveCrossDeps[n]

				// Merkle-chain metadata. One entry per dep in original order:
				// same-project deps (`:X`) use the current project's
				// name+dir; cross-project deps (`proj:X`) resolve through
				// G.depManifests. outs come along on both branches so the
				// Dockerfile emitter's per-glob COPY emission has the
				// producer's declared interface available without a
				// second lookup.
				chainedDeps: [for d in t.deps {
					let _bare = strings.TrimPrefix(d, ":")
					[
						if strings.HasPrefix(d, ":") {{
							name:    _bare
							project: G.project.name
							dir:     G.project.dir
							outs:    G.project.targets[_bare].outs
						}},
						{
							name:    G.depManifests[d].name
							project: G.depManifests[d].project
							dir:     G.depManifests[d].dir
							outs:    G.depManifests[d].outs
						},
					][0]
				}]

				// Priority-sorted commands. Each cmd's `srcs` is its
				// EFFECTIVE input set (target.srcs ∪ cmd.srcs, with
				// defaultGlobs MapAsList expansion on both sides) —
				// what fingerprint.nu hashes for the cmd-task's stamp.
				// Manifest carries the resolved list; downstream
				// emitters / fingerprint.nu read it directly.
				cmds: [for c in t.cmds {
					// Field-copy (not unification) on srcs because list-
					// unification is length-strict. When a stack sets
					// concrete cmd-level srcs (e.g. mise.install pinning
					// `cmd: "builtin": srcs: globs: [.mise.toml, mise.lock]`)
					// unifying that length-2 list with the length-(2+N)
					// concat result fails on length mismatch. Same pattern
					// as t.dockerfile.preamble below.
					let _cmdGlobsExtras   = (_expandGlobs & {in: c.srcs.defaultGlobs}).out
					let _cmdExcludeExtras = (_expandGlobs & {in: c.srcs.defaultExclude}).out
					{
						for k, v in c if k != "srcs" {(k): v}
						srcs: {
							globs:          list.Concat([_targetSrcs.globs, _cmdGlobsExtras, c.srcs.globs])
							exclude:        list.Concat([_targetSrcs.exclude, _cmdExcludeExtras, c.srcs.exclude])
							defaultGlobs:   c.srcs.defaultGlobs
							defaultExclude: c.srcs.defaultExclude
						}
					}
				}]

				// Output blocks (optional — only present if target emits them).
				if t.taskfile != _|_ {taskfile: t.taskfile}
				if t.dockerfile != _|_ {
					// Merge defaultPreamble (framework #MapAsList, keyed)
					// + preamble (project-leaf list) at manifest emit
					// time so downstream emitters see one resolved
					// preamble list. Same shape as the srcs.globs /
					// defaultGlobs merge above. Field-copy (not
					// unification) because list-unification is length-
					// strict — t.dockerfile.preamble (length N) can't
					// unify with the concat result (length N+M).
					let _preambleExtras = (_expandLines & {in: t.dockerfile.defaultPreamble}).out
					dockerfile: {
						for k, v in t.dockerfile if k != "preamble" && k != "defaultPreamble" {(k): v}
						preamble: list.Concat([_preambleExtras, t.dockerfile.preamble])
					}
				}
				if t.compose != _|_ {compose: t.compose}
				if t.skaffold != _|_ {skaffold: t.skaffold}
				if t.vscode != _|_ {vscode: t.vscode}
				if t.bake != _|_ {bake: t.bake}
				// cache.nu reads outs from the manifest at runtime; the
				// `cache` block here records the per-target wrap policy
				// (full / similar) that gen_taskfile.cue used when
				// generating the wrapping invocation. Snapshotted for
				// debuggability — the actual --full / --similar flags in
				// the Taskfile are what cache.nu sees.
				cache: t.cache
			}
		}
	}
}
