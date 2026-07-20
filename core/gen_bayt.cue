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

// _expandCopy — flatten a defaultCopy #MapAsList into a list of copy
// entries, dropping the map-key `name` (#MapToList already drops priority)
// so each element is a plain copy entry ready to concat with `copy`.
_expandCopy: {
	in:  null | #MapAsList
	out: [...]
	out: [if in == null {[]}, [for v in (#MapToList & {"in": in}).out {{for k, x in v if k != "name" {(k): x}}}]][0]
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
		// Opt-in flag: does this project emit .bayt/depot.{yaml,hcl}?
		// generate.nu reads it to keep the depot files fresh on a normal
		// regen (no --depot flag needed).
		depot: G.project.depot
		// Targets the project actually emits — null entries (a project
		// opting out of an inherited target via `"<target>": null`) are
		// filtered here so downstream consumers only see live targets.
		targets: [for n, t in G.project.targets if t != null {n}]

		// Cross-project dirs reached via string deps containing ":",
		// transitively. Single source of truth for "which other projects
		// does this project depend on (directly or through a chain of
		// same-project deps)" — derived, not hand-listed. Used by the
		// emitters (compose, taskfile bayt namespace) to wire
		// cross-project includes / requires automatically.
		crossProjectDirs: (_uniqStrings & {in: [
			for n, t in G.project.targets if t != null
			for d in _transitiveCrossDeps[n] {d.dir}
		]}).out

		// Gradle-stack targets pass `--init-script .bayt/init.gradle.kts`
		// (stacks/gradle _initFlag). Emitters gate the file and its COPY
		// on this, so non-gradle projects carry no gradle residue.
		gradleInit: len([
			for n, t in G.project.targets if t != null
			for c in t.cmds if c.do != _|_ if strings.Contains(c.do, "init.gradle.kts") {1},
		]) > 0
	}

	// Builds a structured entry `{name, project, dir, outs}` for a
	// cross-project ref. The visibility gate unifies the dep's visibility
	// with "public", so any cross-project ref to an internal target
	// fails with `conflicting values "internal" and "public"`.
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
			// Absent in manifests from an older bayt → build-class.
			class: [
				if G.depManifests[ref].class != _|_ {G.depManifests[ref].class},
				"build",
			][0]
		}
	}

	// _fromRef — a target's `dockerfile.from.ref`, or "" when it has none.
	// Classify with HasPrefix/Contains, not `== ""`. Input field is `tgt`
	// not `t` so `& {tgt: t}` at a `for _, t in …` site binds the loop var,
	// not this struct's own field.
	_fromRef: {
		tgt: _
		// Chained `if` (not `&&`, which CUE doesn't short-circuit — the
		// later probes would index past an absent dockerfile/from).
		out: [
			if tgt.dockerfile != _|_ if tgt.dockerfile.from != null if tgt.dockerfile.from.ref != _|_ {tgt.dockerfile.from.ref},
			"",
		][0]
	}

	// Per-target direct cross-project deps. Collects from t.deps +
	// t.dockerfile.from.ref (both Bazel-style: ":X" same-project drops;
	// "P:X" cross-project keeps). Deduped by "<project>-<name>".
	_targetCrossDeps: {
		for n, t in G.project.targets if t != null {
			let _fr = (_fromRef & {tgt: t}).out
			let _depEntries = [
				for d in t.deps
				if !strings.HasPrefix(d, ":") {
					(_buildCrossEntry & {ref: d}).out
				},
			]
			let _fromEntries = [
				if strings.Contains(_fr, ":") if !strings.HasPrefix(_fr, ":") {(_buildCrossEntry & {ref: _fr}).out},
			]
			let _all  = list.Concat([_depEntries, _fromEntries])
			let _keys = [for x in _all {"\(x.project)-\(x.name)"}]
			(n): [for i, x in _all if !list.Contains(list.Slice(_keys, 0, i), _keys[i]) {x}]
		}
		// Synthetic `<n>_srcs`: parent's cross-project deps flipped to
		// their `:srcs` siblings. Entries whose name already ends with
		// `_srcs` pass through (the parent already referenced the
		// upstream's `:srcs` variant directly); `_outs` entries are
		// dropped (compiled artifacts don't belong in a srcs closure);
		// plain entries get the `:srcs` variant if it exists in
		// G.depManifests (skip otherwise — parent had no srcs synthetic).
		for n, t in G.project.targets if t != null
			if t.dockerfile != _|_ {
			"\(n)_srcs": list.Concat([
				[for d in _targetCrossDeps[n] if strings.HasSuffix(d.name, "_srcs") {d}],
				[for d in _targetCrossDeps[n]
					if !strings.HasSuffix(d.name, "_srcs")
					if !strings.HasSuffix(d.name, "_outs")
					let _srcsRef = "\(d.project):\(d.name):srcs"
					if G.depManifests[_srcsRef] != _|_ {
						(_buildCrossEntry & {ref: _srcsRef}).out
					}],
			])
		}
	}

	// Resolve a same-project ref `:X[:view]` to the synthetic-aware
	// compose service name. Keyed by ref string, computed once across
	// every same-project ref used in any target's deps or
	// dockerfile.from.ref.
	//
	//   `:foo`       → "foo"
	//   `:foo:srcs`  → "foo_srcs"     (synthetic name)
	//   `:foo:outs`  → "foo_outs"     (synthetic name)
	//   `:foo:bayt`  → "foo_bayt"     (synthetic name)
	//
	// A bare `:bayt` resolves to "bayt", which nothing emits — the
	// outs lookup fails loudly at generate time; scaffolding deps are
	// per-target (`:foo:bayt`).
	_sameProjectRefs: [
		for n, t in G.project.targets if t != null
		for d in t.deps if strings.HasPrefix(d, ":") {d},
		for n, t in G.project.targets if t != null
		let _fr = (_fromRef & {tgt: t}).out
		if strings.HasPrefix(_fr, ":") {_fr},
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
				if _target != "bayt" && _view == "bayt" {"\(_target)_bayt"},
				_target,
			][0]
		}
	}

	// Per-target scaffolding fileset — what the `<n>_bayt` synthetic
	// carries (the canonical list; emitters and stubs point here).
	// Dockerfile.<n> is load-bearing: the in-layer bake builds from it.
	// The go-task roots ride along because every include in them is
	// `optional: true` and their content is membership-stable — so
	// everything here changes only with n's own definition, never a
	// sibling's (the cache-honesty contract, measured in PR #1470).
	//
	// Up targets in overlay projects widen to ALL local .bayt tool
	// files plus the overlay files themselves: their closure file is
	// the union of local targets' closures (see gen_compose), so the
	// layer must carry every local fragment the union references —
	// including runtime-stack targets (launch, release-*) outside the
	// up target's build-dep chain. Local-coarse is the overlay trade;
	// the cross-project scoping (the real cache win) is untouched.
	// Cross fragments still arrive via the `_bayt` dep chain.
	_baytScaffold: B={
		n: _
		t: _
		// Disjunction-default, not `&&` (CUE doesn't short-circuit).
		let _isUp = [if B.t.compose != _|_ {B.t.compose.up}, false][0]
		let _overlay = len(G.project.compose.includes) > 0
		out: list.Concat([
			[".bayt/compose.\(B.n).yaml", ".bayt/Dockerfile.\(B.n)", ".bayt/bayt.\(B.n).json", ".bayt/Taskfile.yml", ".bayt/Taskfile.bayt.yml"],
			[if B.t.taskfile != _|_ {[".bayt/Taskfile.\(B.n).yaml"]}, []][0],
			[if _isUp {[".bayt/compose.\(B.n).closure.yaml"]}, []][0],
			[if _isUp && _overlay {list.Concat([
				[".bayt/compose.*.yaml", ".bayt/Dockerfile.*", ".bayt/bayt.*.json", ".bayt/Taskfile.*.yaml"],
				G.project.compose.includes,
			])}, []][0],
			[if projectManifest.gradleInit {[".bayt/init.gradle.kts"]}, []][0],
		])
	}

	// Outs lookup by resolved same-project name. Callers resolve a ref
	// to a name via `_sameProjectRefName`, then look up outs here.
	//   `<n>`        → target's outs
	//   `<n>_srcs`   → target's expanded srcs (the synthetic's outs)
	//   `<n>_outs`   → target's outs (the synthetic's outs)
	//   `<n>_bayt`   → target's scaffolding fileset
	_sameProjectOutsByName: {
		for n, t in G.project.targets if t != null {
			(n): t.outs
			if t.dockerfile != _|_ {
				"\(n)_srcs": {
					globs:   list.Concat([(_expandGlobs & {in: t.srcs.defaultGlobs}).out,   t.srcs.globs])
					exclude: list.Concat([(_expandGlobs & {in: t.srcs.defaultExclude}).out, t.srcs.exclude])
				}
				"\(n)_outs": t.outs
				"\(n)_bayt": {globs: (_baytScaffold & {"n": n, "t": t}).out, exclude: []}
			}
		}
	}

	// Class lookup by resolved same-project name. Synthetic views are
	// packaging stages, never runtime-class — class dispatch only
	// applies to plain target refs.
	_sameProjectClassByName: {
		for n, t in G.project.targets if t != null {
			(n): t.class
			if t.dockerfile != _|_ {
				"\(n)_srcs": "build"
				"\(n)_outs": "build"
				"\(n)_bayt": "build"
			}
		}
	}

	// Same-project chainedDeps entry from a resolved name. Mirrors
	// _buildCrossEntry's shape so consumers treat same-project and
	// cross-project entries uniformly.
	_sameProjectEntry: N={
		name: string
		out: {
			name:    N.name
			project: G.project.name
			dir:     G.project.dir
			outs:    _sameProjectOutsByName[N.name]
			class:   _sameProjectClassByName[N.name]
		}
	}

	// Same-project dep names per target — refs with the leading `:`
	// stripped and view suffix folded into the synthetic name (so
	// `:foo:srcs` → `foo_srcs`). Plain refs `:foo` produce `foo`, the
	// G.project.targets[name] key. Reused by _transitiveDeps + per-target
	// files emission.
	_sameProjectDepNames: {
		for n, t in G.project.targets if t != null {
			let _fr = (_fromRef & {tgt: t}).out
			let _fromRefs = [if strings.HasPrefix(_fr, ":") {_fr}]
			let _depRefs = [for d in t.deps if strings.HasPrefix(d, ":") {d}]
			let _all = list.Concat([_fromRefs, _depRefs])
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
		// Same-project synthetic `<n>_srcs` participation: a synthetic
		// `:foo:srcs` carries the source closure of its parent target,
		// so its same-project transitive deps mirror the parent's with
		// each name flipped to its `_srcs` synthetic counterpart. Lets
		// a downstream consumer `deps: [":foo:srcs"]` walk through and
		// pick up `:bar:srcs` automatically when the parent foo chains
		// to bar in same-project.
		for n, t in G.project.targets if t != null
			if t.dockerfile != _|_ {
			"\(n)_srcs": (_uniqStrings & {in: [
				for dep in _transitiveDeps[n] {"\(dep)_srcs"}
			]}).out
		}
	}

	// True iff the target has a dockerfile and a non-empty same-project source
	// closure (own srcs, or a direct dep that itself emits a `_srcs`). Surfaced
	// as the `emitsSrcs` manifest field; every srcs gate (_srcsEmit,
	// _depHasSrcs, the synthetic-manifest stub) reads it. Recurse on DIRECT
	// deps, not flat over transitiveDeps: a non-srcs intermediate must still
	// emit a `_srcs` when a deeper dep has srcs, or the COPY chain breaks.
	_emitsSrcs: {
		for n, t in G.project.targets if t != null {
			(n): [
				if t.dockerfile == _|_ {false},
				if len(list.Concat([(_expandGlobs & {in: t.srcs.defaultGlobs}).out, t.srcs.globs])) > 0 {true},
				// `!= _|_` skips dep names that aren't targets (e.g. the `bayt`
				// synthetic from `:bayt`) — never part of the `_srcs` closure.
				if len([for dn in _sameProjectDepNames[n] if _emitsSrcs[dn] != _|_ if _emitsSrcs[dn] {dn}]) > 0 {true},
				false,
			][0]
		}
	}

	// Transitive cross-project closure for a target or synthetic name.
	// Two layers:
	//   1. Direct: walk the same-project chain (self + _transitiveDeps[name])
	//      and collect each step's cross-project deps from _targetCrossDeps.
	//   2. Manifest pull: for each direct cross-project dep, federate its
	//      own transitiveCrossDeps from G.depManifests. Cross-project
	//      transitivity becomes implicit — a consumer that `deps: [":b"]`
	//      a cross-project :b auto-gets :b's full closure.
	// Deduped by "<project>-<name>".
	// Reconstruct the depManifest lookup ref from a chained-dep entry.
	// Plain names go via "<project>:<name>"; synthetic suffix names map
	// back to the 3-segment ref form so they match load-dep-manifests'
	// keying ("foo_srcs" → "<project>:foo:srcs").
	_manifestRef: D={
		d: _
		out: [
			if strings.HasSuffix(D.d.name, "_srcs") {
				"\(D.d.project):\(strings.TrimSuffix(D.d.name, "_srcs")):srcs"
			},
			if strings.HasSuffix(D.d.name, "_outs") {
				"\(D.d.project):\(strings.TrimSuffix(D.d.name, "_outs")):outs"
			},
			"\(D.d.project):\(D.d.name)",
		][0]
	}

	_computeTransitiveCross: N={
		name: string
		_selfPlusDeps: list.Concat([[N.name], _transitiveDeps[N.name]])
		_direct: list.Concat([
			for tn in _selfPlusDeps
			if _targetCrossDeps[tn] != _|_ {_targetCrossDeps[tn]}
		])
		_viaManifests: list.Concat([
			for d in _direct
			let _ref = (_manifestRef & {"d": d}).out
			if G.depManifests[_ref] != _|_
			if G.depManifests[_ref].transitiveCrossDeps != _|_ {
				G.depManifests[_ref].transitiveCrossDeps
			}
		])
		_all:  list.Concat([_direct, _viaManifests])
		_keys: [for x in _all {"\(x.project)-\(x.name)"}]
		out:   [for i, x in _all if !list.Contains(list.Slice(_keys, 0, i), _keys[i]) {x}]
	}

	_transitiveCrossDeps: {
		for n, t in G.project.targets if t != null {
			(n): (_computeTransitiveCross & {name: n}).out
		}
		for n, t in G.project.targets if t != null
			if t.dockerfile != _|_ {
			"\(n)_srcs": (_computeTransitiveCross & {name: "\(n)_srcs"}).out
		}
	}

	// Repo-root-relative compose-fragment path for a dep at (dir, name).
	// Synthetic names map to their parent fragment — the `_srcs`/`_outs`
	// services live there (gen_compose emits no per-synthetic files).
	_fragPath: F={
		dir:  _
		name: _
		let _parent = [
			if strings.HasSuffix(F.name, "_srcs") {strings.TrimSuffix(F.name, "_srcs")},
			if strings.HasSuffix(F.name, "_outs") {strings.TrimSuffix(F.name, "_outs")},
			if strings.HasSuffix(F.name, "_bayt") {strings.TrimSuffix(F.name, "_bayt")},
			F.name,
		][0]
		let _dp = [if F.dir != "" {"\(F.dir)/"}, ""][0]
		out: "\(_dp).bayt/compose.\(_parent).yaml"
	}

	// upClosure — repo-root-relative fragment paths covering the
	// target's full compose graph: own fragment + same-project direct
	// deps' closures (recursive over this map) + cross direct deps'
	// closures from their manifests (already closed by generation
	// order — the staged induction transitiveCrossDeps rides). Entry
	// closure files include this list FLAT; the recursion must stay
	// here at generate time (see gen_compose bayt_root on ApplyInclude
	// cost). Synthetic dep names map to their parent's fragment.
	_upClosure: {
		for n, t in G.project.targets if t != null {
			let _own = [if t.dockerfile != _|_ {(_fragPath & {dir: G.project.dir, name: n}).out}]
			// Recurse via the parent target: synthetic dep names have no
			// map entry, and their graph is a subset of the parent's.
			let _sameProj = list.FlattenN([
				for dn in _sameProjectDepNames[n]
				let _p = [
					if strings.HasSuffix(dn, "_srcs") {strings.TrimSuffix(dn, "_srcs")},
					if strings.HasSuffix(dn, "_outs") {strings.TrimSuffix(dn, "_outs")},
					if strings.HasSuffix(dn, "_bayt") {strings.TrimSuffix(dn, "_bayt")},
					dn,
				][0]
				if _upClosure[_p] != _|_ {_upClosure[_p]},
			], 1)
			let _cross = list.FlattenN([
				for d in _targetCrossDeps[n]
				if d.name != "bayt"
				let _ref = (_manifestRef & {"d": d}).out {
					[
						// Nested guards, not `&&` (CUE doesn't short-circuit).
						if G.depManifests[_ref] != _|_ {[
							if G.depManifests[_ref].upClosure != _|_ {G.depManifests[_ref].upClosure},
							// Dep manifest predates the field (stale regen):
							// its own fragment still anchors the include; a
							// full `generate --all` backfills the rest.
							[(_fragPath & {dir: d.dir, name: d.name}).out],
						][0]},
						[(_fragPath & {dir: d.dir, name: d.name}).out],
					][0]
				},
			], 1)
			(n): (_uniqStrings & {in: list.Concat([_own, _sameProj, _cross])}).out
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
				class:      t.class
				// The one srcs-emission gate (read here, in gen_compose, and by
				// cross-project consumers via G.depManifests). See _emitsSrcs.
				emitsSrcs: _emitsSrcs[n]

				// Deps normalized to name strings (direct only).
				deps: _depNames

				// Direct same-project dep names — the go-task `::bayt:<dep>`
				// edges. Only DIRECT: go-task reaches an indirect dep through
				// the chain, so emitting a transitive edge too (as chainedDeps
				// would) makes go-task's parallel `deps:` double-start it.
				sameProjectDeps: _sameProjectDepNames[n]

				// Transitive same-project dep names (direct ∪ indirect).
				// Emitted so Dockerfile generation can list the exact set
				// of .bayt/Taskfile.<d>.yaml + .bayt/bayt.<d>.json files
				// this target needs inside the container — no more, no less.
				transitiveDeps: _transitiveDeps[n]

				// Transitive cross-project deps. Used by Dockerfile for
				// COPY --from chains so incremental task resolution finds
				// all dep projects' taskfiles + manifests inside the stage.
				transitiveCrossDeps: _transitiveCrossDeps[n]

				// Up flag + flat fragment closure — gen_compose emits
				// compose.<n>.closure.yaml for up targets from these.
				up:             [if t.compose != _|_ {t.compose.up}, false][0]
				upClosure: _upClosure[n]

				// Merkle-chain metadata. One entry per dep in original order:
				// same-project deps (`:X`) use the current project's
				// name+dir; cross-project deps (`proj:X`) resolve through
				// G.depManifests. outs come along on both branches so the
				// Dockerfile emitter's per-glob COPY emission has the
				// producer's declared interface available without a
				// second lookup.
				let _fr = (_fromRef & {tgt: t}).out
				let _directNames = list.Concat([
					[if strings.HasPrefix(_fr, ":") if !list.Contains(t.deps, _fr) {_sameProjectRefName[_fr]}],
					[for d in t.deps if strings.HasPrefix(d, ":") {_sameProjectRefName[d]}],
				])
				chainedDeps: list.Concat([
					// FROM-chain ref leads. A `from.ref` is itself a dep, so it
					// seeds this host fingerprint Merkle chain — a FROM'd
					// upstream's inputs re-key this target (FROM alone only
					// covers container builds). Same-project → _sameProjectEntry;
					// cross-project → _buildCrossEntry (generate.nu federates
					// from.ref refs, so its manifest is resolved). Skipped when
					// t.deps already lists the ref.
					[if strings.HasPrefix(_fr, ":") if !list.Contains(t.deps, _fr) {
						(_sameProjectEntry & {name: _sameProjectRefName[_fr]}).out
					}],
					[if strings.Contains(_fr, ":") if !strings.HasPrefix(_fr, ":") if !list.Contains(t.deps, _fr) {
						(_buildCrossEntry & {ref: _fr}).out
					}],
					[for d in t.deps {
						[
							if strings.HasPrefix(d, ":") {
								(_sameProjectEntry & {name: _sameProjectRefName[d]}).out
							},
							(_buildCrossEntry & {ref: d}).out,
						][0]
					}],
					// Transitive same-project entries reached via the
					// synthetic `:srcs` chain. Lets a consumer `deps:
					// [":foo:srcs"]` pick up the upstream same-project
					// chain (e.g. `:build:srcs` reached transitively from
					// `:integrate:srcs`) without listing each step.
					// Dedup against _directNames so a directly-listed
					// dep keeps its outs unchanged.
					[for tn in _transitiveDeps[n]
						if !list.Contains(_directNames, tn)
						if _sameProjectOutsByName[tn] != _|_ {
							(_sameProjectEntry & {name: tn}).out
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
					let _copyExtras = (_expandCopy & {in: t.dockerfile.defaultCopy}).out
					dockerfile: {
						// One dynamic field per iteration (splitting into two
						// guarded branches, or a static `copy:`, reorders the
						// output) so copy keeps its manifest position; the value
						// is the merged list at copy, else the field verbatim.
						// defaultCopy is dropped.
						for k, v in t.dockerfile if k != "preamble" && k != "defaultPreamble" && k != "defaultCopy" {
							(k): [if k == "copy" {list.Concat([_copyExtras, v])}, v][0]
						}
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
		// `<n>_srcs`/`<n>_outs` nest under the parent as
		// `files.<n>.synthetics.{srcs,outs}`; load-dep-manifests reads a cross
		// ref `proj:foo:srcs` from `bayt.foo.json` `.synthetics.srcs`. `bayt`
		// is top-level → `bayt.bayt.json`.
		for n, t in G.project.targets if t != null
			if t.dockerfile != _|_ {
			// outs = the full transitive source closure the `_srcs` image
			// carries: union own-srcs globs over {self} ∪ same-project
			// transitive deps, so a dep-fed target still reports what it packages.
			let _srcsGlobs = (_uniqStrings & {in: list.FlattenN([
				for x in list.Concat([[n], _transitiveDeps[n]])
				if _sameProjectOutsByName["\(x)_srcs"] != _|_ {_sameProjectOutsByName["\(x)_srcs"].globs}
			], 1)}).out
			let _srcsExclude = list.Concat([(_expandGlobs & {in: t.srcs.defaultExclude}).out, t.srcs.exclude])
			if _emitsSrcs[n] {
				(n): synthetics: srcs: {
					name:    "\(n)_srcs"
					project: G.project.name
					dir:     G.project.dir
					// Synthetic carries no toolchain; activate empty.
					activate: ""
					// Consumer COPYs land every chained dep's srcs at their
					// natural paths via these globs.
					srcs: {globs: [], exclude: []}
					outs: {globs: _srcsGlobs, exclude: _srcsExclude}
					env: {}
					class: "build"
					// Synthetic inherits parent visibility. Cross-project
					// consumers of an internal target's _srcs fail the
					// public-visibility unification at _buildCrossEntry.
					visibility: t.visibility
					deps:       []
					// Synthetic transitive deps mirror the parent's
					// (name suffix added) so a downstream `:foo:srcs`
					// consumer transitively pulls the upstream `:srcs`
					// closure. Cross-project entries are filtered to
					// those whose `:srcs` synthetic exists in
					// G.depManifests; missing ones drop silently.
					transitiveDeps: _transitiveDeps["\(n)_srcs"]
					// transitiveCrossDeps surfaces both the parent's
					// cross-project closure (for downstream cross-project
					// walking) AND the same-project transitive synthetic
					// chain — the latter expressed as cross-project entries
					// (project = this project's name) so a cross-project
					// consumer of `:foo:srcs` pulls e.g. `:setup:srcs` from
					// the same project too. Same-project consumers ignore
					// the latter via in-memory _transitiveDeps walking.
					transitiveCrossDeps: list.Concat([
						_transitiveCrossDeps["\(n)_srcs"],
						[for tn in _transitiveDeps["\(n)_srcs"]
							if _sameProjectOutsByName[tn] != _|_
							if len(_sameProjectOutsByName[tn].globs) > 0 {
								{
									project: G.project.name
									name:    tn
									dir:     G.project.dir
									outs:    _sameProjectOutsByName[tn]
									class:   "build"
								}
							}],
					])
					chainedDeps: []
					cmds:        []
					cache: {full: false, similar: false}
					// A synthetic's compose graph is a subset of its
					// parent's — cross consumers pulling this stub's
					// closure get the parent fragment set.
					upClosure: _upClosure[n]
				}
			}
			if len(t.outs.globs) > 0 {
				(n): synthetics: outs: {
					name:    "\(n)_outs"
					project: G.project.name
					dir:     G.project.dir
					activate: ""
					srcs: {globs: [], exclude: []}
					outs: t.outs
					env: {}
					class: "build"
					visibility:          t.visibility
					deps:                []
					transitiveDeps:      []
					transitiveCrossDeps: []
					chainedDeps:         []
					cmds:                []
					cache: {full: false, similar: false}
					upClosure: _upClosure[n]
				}
			}
			// Scaffolding view — `:foo:bayt`. The `<n>_bayt` stage is
			// self-contained (it chains its deps' `_bayt` synths
			// internally), so consumers need only the direct COPY and
			// the stub carries no dep lists.
			(n): synthetics: bayt: {
				name:    "\(n)_bayt"
				project: G.project.name
				dir:     G.project.dir
				activate: ""
				srcs: {globs: [], exclude: []}
				outs: {globs: (_baytScaffold & {"n": n, "t": t}).out, exclude: []}
				env: {}
				class: "build"
				visibility:          t.visibility
				deps:                []
				transitiveDeps:      []
				transitiveCrossDeps: []
				chainedDeps:         []
				cmds:                []
				cache: {full: false, similar: false}
				upClosure: _upClosure[n]
			}
		}

	}
}
