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

	// Per-target direct cross-project refs (precomputed once). Sources:
	//   - `t.deps` strings (Bazel-style: ":X" same-project, "P:X" cross)
	//   - `t.dockerfile.from.ref` (same syntax)
	// Cross-project refs (no leading `:`) are kept; same-project refs
	// drop. Values come from G.depManifests (injected by the nushell
	// second pass via cross-dep-strings, which collects from BOTH sources
	// too). Visibility gate fires uniformly: a cross-project dep or
	// FROM-ref to an internal target fails CUE evaluation with
	// `conflicting values "internal" and "public"`.
	//
	// Deduped by "<project>-<name>" so the established
	// `deps + dockerfile.from.ref` pattern doesn't double-count.
	_buildCrossEntry: {
		ref: string
		out: {
			_visibility: G.depManifests[ref].visibility & "public"
			name:    G.depManifests[ref].name
			project: G.depManifests[ref].project
			dir:     G.depManifests[ref].dir
			outs: {
				globs:   G.depManifests[ref].outs.globs
				exclude: G.depManifests[ref].outs.exclude
			}
		}
	}
	_targetCrossDeps: {
		for n, t in G.project.targets if t != null {
			let _depEntries = [
				for d in t.deps
				if !strings.HasPrefix(d, ":") {
					(_buildCrossEntry & {ref: d}).out
				},
			]
			let _fromEntries = [
				if t.dockerfile != _|_
					if t.dockerfile.from != null
					if t.dockerfile.from.ref != _|_
					if !strings.HasPrefix(t.dockerfile.from.ref, ":") {
					(_buildCrossEntry & {ref: t.dockerfile.from.ref}).out
				},
			]
			let _all  = list.Concat([_depEntries, _fromEntries])
			let _keys = [for x in _all {"\(x.project)-\(x.name)"}]
			(n): [for i, x in _all if !list.Contains(list.Slice(_keys, 0, i), _keys[i]) {x}]
		}
	}

	// Resolve a same-project ref `:X[:view]` (or `:bayt`) to the
	// synthetic-aware compose service name. Map key for this struct is
	// the ref string itself; the value is the resolved name. Computed
	// once across every same-project ref used in any target's `deps:`,
	// avoiding the template-evaluation pitfalls of a struct-with-args
	// helper.
	//
	//   `:foo`       → "foo"          (today's behavior)
	//   `:foo:srcs`  → "foo_srcs"     (synthetic name)
	//   `:foo:outs`  → "foo_outs"     (synthetic name)
	//   `:bayt`      → "bayt"         (project synthetic)
	// Refs sourced from t.deps (same-project, leading `:`) PLUS
	// t.dockerfile.from.ref when it's same-project. Both surface in
	// `_sameProjectDepNames` below — the FROM-chain version is what
	// drives scaffolding COPY emission for chained-but-not-in-deps
	// targets (e.g. `dockerfile.from.ref: ":setup"`).
	_sameProjectRefs: [
		for n, t in G.project.targets if t != null
		for d in t.deps if strings.HasPrefix(d, ":") {d},
		for n, t in G.project.targets if t != null
		if t.dockerfile != _|_
		if t.dockerfile.from != null
		if t.dockerfile.from.ref != _|_
		if strings.HasPrefix(t.dockerfile.from.ref, ":") {t.dockerfile.from.ref},
	]
	_sameProjectRefName: {
		for d in _sameProjectRefs {
			let _bare = strings.TrimPrefix(d, ":")
			let _parts = strings.Split(_bare, ":")
			// Materialize the view segment to "" when absent, so CUE
			// evaluates conditions on _view without indexing past the
			// list (`&&` doesn't short-circuit).
			let _target = _parts[0]
			let _view = [if len(_parts) >= 2 {_parts[1]}, ""][0]
			(d): [
				if _target == "bayt" {"bayt"},
				if _target != "bayt" && _view == "srcs" {"\(_target)_srcs"},
				if _target != "bayt" && _view == "outs" {"\(_target)_outs"},
				_target,
			][0]
		}
	}

	// Outs (globs + exclude) for each same-project ref. Same keys as
	// _sameProjectRefName. For `:bayt` returns the scaffolding fileset
	// (`.bayt/**`, `Taskfile.yml`, `compose.yaml`); for view-suffix refs
	// returns the corresponding view from the parent target; for plain
	// refs returns the parent target's outs.
	//
	// BRANCH ORDER IS LOAD-BEARING. CUE's `[if c1 {v1}, if c2 {v2}, …][0]`
	// evaluates every branch with a true condition; if `_target == "bayt"`
	// were NOT checked first, the later `if _target != "" {…}` branch
	// would also fire for `:bayt` and try to access
	// `G.project.targets["bayt"]` (which is `_|_` — the reserved-name
	// regex rejects "bayt" as a target name). That contaminates the
	// list with `_|_` and breaks evaluation. Keep `:bayt` first.
	_sameProjectRefOuts: {
		for d in _sameProjectRefs {
			let _bare = strings.TrimPrefix(d, ":")
			let _parts = strings.Split(_bare, ":")
			let _target = _parts[0]
			let _view = [if len(_parts) >= 2 {_parts[1]}, ""][0]
			(d): [
				if _target == "bayt" {{globs: [".bayt/**", "Taskfile.yml", "compose.yaml"], exclude: []}},
				if _target != "bayt" && _view == "srcs" {
					let _t = G.project.targets[_target]
					{
						globs:   list.Concat([(_expandGlobs & {in: _t.srcs.defaultGlobs}).out,   _t.srcs.globs])
						exclude: list.Concat([(_expandGlobs & {in: _t.srcs.defaultExclude}).out, _t.srcs.exclude])
					}
				},
				if _target != "bayt" && _view == "outs" {G.project.targets[_target].outs},
				if _target != "bayt" && _view == "" {G.project.targets[_target].outs},
				{globs: [], exclude: []},
			][0]
		}
	}

	// Same-project dep names per target — refs with the leading `:`
	// stripped and view suffix folded into the synthetic name (so
	// `:foo:srcs` → `foo_srcs`). Plain refs `:foo` produce `foo`,
	// matching today's keying into G.project.targets[name]. Computed
	// once and reused by _transitiveDeps + per-target files emission.
	_sameProjectDepNames: {
		for n, t in G.project.targets if t != null {
			let _fromRef = [
				if t.dockerfile != _|_
					if t.dockerfile.from != null
					if t.dockerfile.from.ref != _|_
					if strings.HasPrefix(t.dockerfile.from.ref, ":") {t.dockerfile.from.ref},
			]
			let _depRefs = [for d in t.deps if strings.HasPrefix(d, ":") {d}]
			let _all = list.Concat([_fromRef, _depRefs])
			(n): [for i, d in _all if !list.Contains(list.Slice(_all, 0, i), d) {_sameProjectRefName[d]}]
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

	// Transitive cross-project deps per target. Two layers:
	//
	//   1. Direct: walk the same-project chain (self + _transitiveDeps[n])
	//      and collect each step's cross-project deps from _targetCrossDeps.
	//
	//   2. Recursive: for each direct cross-project dep, also pull its
	//      OWN transitiveCrossDeps from the dep's manifest. Cross-project
	//      transitivity becomes implicit — a consumer that `deps: [":b"]`
	//      a cross-project :b automatically gets :b's full transitive
	//      closure (libraries_logs, libraries_xproto, etc.) instead of
	//      having to hand-enumerate.
	//
	// Deduped by "<project>-<name>".
	_transitiveCrossDeps: {
		for n, t in G.project.targets if t != null {
			let _selfPlusDeps = list.Concat([[n], _transitiveDeps[n]])
			let _direct = list.Concat([
				for tn in _selfPlusDeps
				if _targetCrossDeps[tn] != _|_ {_targetCrossDeps[tn]}
			])
			let _viaManifests = list.Concat([
				for d in _direct
				let _ref = "\(d.project):\(d.name)"
				if G.depManifests[_ref] != _|_
				if G.depManifests[_ref].transitiveCrossDeps != _|_ {
					G.depManifests[_ref].transitiveCrossDeps
				}
			])
			let _all  = list.Concat([_direct, _viaManifests])
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
				chainedDeps: list.Concat([
					// FROM-chain ref leads when it's same-project (the
					// chain head, conceptually). Cross-project FROM refs
					// flow through _targetCrossDeps, not chainedDeps.
					// Skipped when the user also lists the same ref in
					// t.deps — that entry takes over.
					[
						if t.dockerfile != _|_
						if t.dockerfile.from != null
						if t.dockerfile.from.ref != _|_
						if strings.HasPrefix(t.dockerfile.from.ref, ":")
						if !list.Contains(t.deps, t.dockerfile.from.ref) {{
							name:    _sameProjectRefName[t.dockerfile.from.ref]
							project: G.project.name
							dir:     G.project.dir
							outs:    _sameProjectRefOuts[t.dockerfile.from.ref]
						}},
					],
					[for d in t.deps {
						[
							if strings.HasPrefix(d, ":") {{
								name:    _sameProjectRefName[d]
								project: G.project.name
								dir:     G.project.dir
								outs:    _sameProjectRefOuts[d]
							}},
							{
								name:    G.depManifests[d].name
								project: G.depManifests[d].project
								dir:     G.depManifests[d].dir
								outs:    G.depManifests[d].outs
							},
						][0]
					}],
				])

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
				if t.hmr != _|_ {hmr: t.hmr}
				// cache.nu reads outs from the manifest at runtime; the
				// `cache` block here records the per-target wrap policy
				// (full / similar) that gen_taskfile.cue used when
				// generating the wrapping invocation. Snapshotted for
				// debuggability — the actual --full / --similar flags in
				// the Taskfile are what cache.nu sees.
				cache: t.cache
			}
		}

		// Synthetic-stage manifests — minimum shape needed for downstream
		// emitters (gen_compose._depCopies, gen_bayt._buildCrossEntry) to
		// resolve cross-project refs to `:foo:srcs` / `:foo:outs` /
		// `:bayt` / `<proj>:bayt`. Consumers read {visibility, name,
		// project, dir, outs.{globs, exclude}, transitiveCrossDeps,
		// chainedDeps} from these stubs.
		//
		// Gated on `t.dockerfile != _|_` so synthetics align with the
		// dockerfile/compose emission in gen_compose.cue (`_emit` map).
		// A target without a dockerfile has no compose service for
		// consumers to reference; no synthetic, no manifest.
		//
		// File names: `bayt.<n>_srcs.json`, `bayt.<n>_outs.json`,
		// `bayt.bayt.json`. Nushell's load-dep-manifests joins ref
		// segments after the first with `_` to derive the filename
		// (`proj:foo:srcs` → `bayt.foo_srcs.json`, `proj:bayt` →
		// `bayt.bayt.json`).
		for n, t in G.project.targets if t != null
			if t.dockerfile != _|_ {
			let _srcsGlobs   = list.Concat([(_expandGlobs & {in: t.srcs.defaultGlobs}).out,   t.srcs.globs])
			let _srcsExclude = list.Concat([(_expandGlobs & {in: t.srcs.defaultExclude}).out, t.srcs.exclude])
			if len(_srcsGlobs) > 0 {
				"\(n)_srcs": {
					name:    "\(n)_srcs"
					project: G.project.name
					dir:     G.project.dir
					// Synthetic carries no toolchain; activate empty.
					activate: ""
					// outs == parent srcs so consumer COPYs land the
					// dep's srcs at their natural paths (matches what
					// gen_compose._depCopies builds via `outs.globs`).
					srcs: {globs: [], exclude: []}
					outs: {globs: _srcsGlobs, exclude: _srcsExclude}
					env: {}
					// Synthetic inherits parent visibility. Cross-project
					// consumers of an internal target's _srcs fail the
					// public-visibility unification at _buildCrossEntry.
					visibility:          t.visibility
					deps:                []
					transitiveDeps:      []
					transitiveCrossDeps: []
					chainedDeps:         []
					cmds:                []
					cache: {full: false, similar: false}
				}
			}
			if len(t.outs.globs) > 0 {
				"\(n)_outs": {
					name:    "\(n)_outs"
					project: G.project.name
					dir:     G.project.dir
					activate: ""
					srcs: {globs: [], exclude: []}
					outs: t.outs
					env: {}
					visibility:          t.visibility
					deps:                []
					transitiveDeps:      []
					transitiveCrossDeps: []
					chainedDeps:         []
					cmds:                []
					cache: {full: false, similar: false}
				}
			}
		}

		// Project-bayt synthetic: one per project, gated on at least one
		// dockerfile-emitting target (matches gen_compose's `_bayt` gate).
		// Always public — replaces the user-authored <proj>:ops graph
		// that was always public.
		let _anyDockerfile = len([for n, t in G.project.targets if t != null if t.dockerfile != _|_ {n}]) > 0
		if _anyDockerfile {
			"bayt": {
				name:    "bayt"
				project: G.project.name
				dir:     G.project.dir
				activate: ""
				// Scaffolding scope mirrors gen_compose._renderSyntheticBayt:
				// .bayt/** (bayt-emitted) + Taskfile.yml + compose.yaml
				// (project-root scaffolding).
				srcs: {globs: [".bayt/**", "Taskfile.yml", "compose.yaml"], exclude: []}
				outs: {globs: [".bayt/**", "Taskfile.yml", "compose.yaml"], exclude: []}
				env: {}
				visibility:          "public"
				deps:                []
				transitiveDeps:      []
				transitiveCrossDeps: []
				chainedDeps:         []
				cmds:                []
				cache: {full: false, similar: false}
			}
		}
	}
}
