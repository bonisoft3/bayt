// gen_compose.cue — Dockerfile + compose.yaml coupled emitter.
//
// Compose `additional_contexts: { <svc>: "service:<svc>" }` lets the
// Dockerfile write `COPY --from=<svc> --link ...` and BuildKit resolves
// through the compose graph at build time.
//
// Service names are qualified as `<project>-<targetName>` so
// composes from multiple projects can be federated via include: without
// colliding on the bare "build" / "release" names.
//
// Output:
//   dockerfiles: map of target-name → full Dockerfile text body.
//   compose:     structure with .bayt/compose.yaml (include-only root)
//                and .bayt/compose.<n>.yaml (one service each).
//
// File layout per project:
//   <dir>/.bayt/compose.yaml            generated root; includes:
//       - per-target local compose files
//       - each cross-project dep's .bayt/compose.yaml (relocatable
//         relative path, not absolute)
//   <dir>/.bayt/compose.<n>.yaml        single service per file
//   <dir>/.bayt/Dockerfile.<n>            per-target Dockerfile (tool-prefixed
//                                         like the other .bayt/ files —
//                                         Taskfile.<n>.yaml, compose.<n>.yaml,
//                                         skaffold.<n>.yaml, bake.<n>.hcl —
//                                         so directory listings sort by tool)
//   <dir>/compose.yaml                  user-authored (not written by bayt)
//
// Pure CUE; generate-bayt.nu writes files to disk.
package bayt

import (
	"list"
	"strings"
)

#dockerComposeGen: G={
	project: #project
	depManifests:   {[string]: _}

	_m: (#manifestGen & {project: G.project, depManifests: G.depManifests})

	// Only targets that declared a dockerfile block.
	_emit: {for n, t in G._m.files if t.dockerfile != _|_ {(n): t}}

	// Depth of project.dir so we can walk back to the monorepo root from
	// inside .bayt/ for cross-project include paths. `.bayt/` depth =
	// project depth + 1; workspace-root (depth 0) → "../" (one level
	// up from /.bayt/ to /).
	_rootFromBayt: strings.Repeat("../", G._m._depth+1)

	// Helper: qualified service name for a target, used in compose
	// service keys and Dockerfile `COPY --from=<svc>` references.
	_svcName: {
		pn: string
		tn: string
		out: "\(pn)-\(tn)"
	}

	// Helper: format one mount directive. Emits
	// "--mount=type=<t>,target=<x>,sharing=<s>" etc. Optional fields are
	// pulled with "" fallbacks so interpolation is concrete-safe, and
	// all pair strings are fused into a single `out` in one pass (no
	// intermediate lists — CUE's lazy eval struggles with conditional
	// list-building through nested helpers).
	// Helper: emittable deps for a target — same-project chainedDeps
	// (gated on dir match + G._emit) plus all cross-project transitive
	// deps. Used by both _depCopies (Dockerfile path) and _depEntries
	// (compose additional_contexts path).
	_targetDeps: T={
		t:   _
		out: [...]
		out: list.Concat([
			[for d in T.t.chainedDeps if d.dir == T.t.dir if G._emit[d.name] != _|_ {d}],
			[for d in T.t.transitiveCrossDeps {d}],
		])
	}

	// Helper: dep keys ("<project>-<name>") that the FROM-chained
	// upstream of a target already provides. Empty when the target's
	// `from` is null (scratch) or resolves to an image (no ref). Both
	// the Dockerfile dep-COPY filter and the compose
	// additional_contexts filter use this to avoid emitting redundant
	// references to content the upstream stage already inherits.
	_inheritedDepKeys: K={
		t:   _
		out: [...string]
		out: [
			if K.t.dockerfile.from == null {[]},
			if K.t.dockerfile.from != null && K.t.dockerfile.from.ref == _|_ {[]},
			if K.t.dockerfile.from != null && K.t.dockerfile.from.ref != _|_ {
				let _ref      = K.t.dockerfile.from.ref
				let _parts    = strings.Split(_ref, ":")
				let _proj     = [if _parts[0] == "" {K.t.project}, _parts[0]][0]
				let _name     = _parts[1]
				let _upstream = [if _parts[0] == "" {G._m.files[_name]}, G.depManifests[_ref]][0]
				// Upstream's self-key joins the dep keys: its filesystem
				// flows through FROM, so an explicit COPY --from=<upstream>
				// would duplicate content the stage already has.
				list.Concat([
					["\(_proj)-\(_name)"],
					[for d in _upstream.chainedDeps {"\(d.project)-\(d.name)"}],
					[for d in _upstream.transitiveCrossDeps {"\(d.project)-\(d.name)"}],
				])
			},
		][0]
	}

	_mount: {
		m:   #dockerfile.#mount
		out: string
		let _t =  m.type
		let _tg = [if m.target != _|_                            {",target=\(m.target)"},   ""][0]
		let _sc = [if m.source != _|_                            {",source=\(m.source)"},   ""][0]
		let _id = [if m.id != _|_                                {",id=\(m.id)"},           ""][0]
		let _sh = [if m.sharing != _|_ && m.type == "cache"      {",sharing=\(m.sharing)"}, ""][0]
		let _rq = [if m.required                                 {",required=true"},        ""][0]
		out: "--mount=type=\(_t)\(_tg)\(_sc)\(_id)\(_sh)\(_rq)"
	}

	// Helper: render one RUN line for a cmd rule.
	//
	// Shell handling:
	//   shell: "exec" (default) → exec form `RUN [<json-tokens>]`; the
	//     wrap+activate+do string is whitespace-tokenized and JSON-
	//     formatted. No shell wraps the cmd; the runtime exec()s argv
	//     directly. Trade: no pipes, redirects, glob expansion, env-var
	//     interpolation, `&&` chains, etc. Most build cmds fit this.
	//   shell: any other value → `RUN ["<shell>", "-c", "<full-cmd>"]`.
	//     The shell wraps and interprets the cmd string. Use when the
	//     cmd has shell features.
	//
	// OS axis: containers are always Linux, so cmd.linux (if set)
	// overrides cmd-level do/shell. cmd.windows / cmd.darwin are
	// irrelevant here and ignored.
	_runLine: {
		t: _
		c: _

		// Each `[if cond { a }, default][0]` picks `a` when cond holds
		// and `default` otherwise. Used throughout for nullable cmd
		// sub-fields and for OS-axis overrides on linux.
		let _cmdMounts = [if c.dockerfile != _|_ && c.dockerfile.mounts != _|_ {c.dockerfile.mounts}, []][0]
		let _mountStrs = [
			for m in t.dockerfile.mounts {(_mount & {"m": m}).out},
			for m in _cmdMounts {(_mount & {"m": m}).out},
		]
		_prefix: [if len(_mountStrs) > 0 {strings.Join(_mountStrs, " ") + " "}, ""][0]
		_wrap:   [if c.dockerfile != _|_ && c.dockerfile.wrap != _|_ {"\(c.dockerfile.wrap) "}, ""][0]

		// OS axis: linux overrides cmd-level for container builds.
		let _do        = [if c.linux != _|_ && c.linux.do != _|_       {c.linux.do},     c.do][0]
		let _shell     = [if c.linux != _|_ && c.linux.shell != _|_    {c.linux.shell},  c.shell][0]
		let _activated = [if len(t.activate) > 0                       {"\(t.activate) \(_do)"}, _do][0]
		let _full      = "\(_wrap)\(_activated)"

		out: string
		out: [
			// shell == "exec" → exec form, whitespace-tokenized argv.
			if _shell == "exec" {
				let _tokens = strings.Split(_full, " ")
				let _quoted = [for tk in _tokens if tk != "" {"\"\(tk)\""}]
				"RUN \(_prefix)[\(strings.Join(_quoted, ", "))]"
			},
			// shell == "sh" → shell form. Dockerfile's default RUN is
			// already `/bin/sh -c <cmd>`, so writing it that way avoids
			// the JSON-escape dance on the cmd string. Cmds with quotes,
			// backslashes, etc. flow through verbatim.
			if _shell == "sh" {
				"RUN \(_prefix)\(_full)"
			},
			// other shells (nu, bash, pwsh, …) → exec form wrapping the
			// cmd in `[<shell>, "-c", <do>]`. The do string is
			// JSON-escaped: backslash first (so the next pass doesn't
			// re-escape), then quote.
			if _shell != "exec" && _shell != "sh" {
				let _esc1 = strings.Replace(_full, "\\", "\\\\", -1)
				let _esc2 = strings.Replace(_esc1, "\"", "\\\"", -1)
				"RUN \(_prefix)[\"\(_shell)\", \"-c\", \"\(_esc2)\"]"
			},
		][0]
	}

	// Helper: render the full Dockerfile body for one target.
	_renderDockerfile: {
		t: _
		// 1.7-labs unlocks COPY --parents (path-preserving structure).
		// Pinned to a manifest-list digest so BuildKit's content-
		// addressable cache services the frontend image without a
		// registry tag→digest roundtrip on each build. Bump as needed:
		//   docker buildx imagetools inspect docker/dockerfile:1.7-labs
		_syntax: "# syntax=docker/dockerfile:1.7-labs@sha256:b99fecfe00268a8b556fad7d9c37ee25d716ae08a5d7320e6d51c4dd83246894"

		// `from: null` → `FROM scratch AS <target>` with no
		// additional_contexts entry (Docker's parser-level keyword).
		// `from != null` → `FROM <name> AS <target>` with the
		// corresponding additional_contexts entry written below in
		// _service.
		_from: [
			if t.dockerfile.from == null {"FROM scratch AS \(t.name)"},
			"FROM \(t.dockerfile.from.name) AS \(t.name)",
		][0]
		_workdir: [
			if t.dockerfile.workdir != _|_  {t.dockerfile.workdir},
			if t.dir == ""                  {"/monorepo"},
			"/monorepo/\(t.dir)",
		][0]

		// Deps: COPY --from=<qualified-svc> --link ... resolves through
		// compose additional_contexts (see _service below). Iterates over
		// t.chainedDeps (structured {name, project, dir}) so
		// we uniformly handle same-project string deps AND cross-project
		// #target refs. Same-project deps need a dockerfile stage on the
		// other end (G._emit gate); cross-project deps assume their
		// service exists in the federated compose graph (bayt's compose
		// includes handle that).
		//
		// Per-glob COPY using the producer's outs.globs/exclude — what
		// flows is the dep's choice. No framework `--exclude`: if a
		// producer wants to expose `.task/bayt/<target>.hash` to
		// short-circuit consumer task chains, they include it in outs;
		// if not, they exclude it. Same model for same-project and
		// cross-project deps.
		//
		// COPY form: `--parents /monorepo/<depDir>/<glob> /`. With
		// --parents and a `/` destination, BuildKit places files at
		// their original absolute paths, so a producer file at
		// `/monorepo/<depDir>/build/libs/foo.jar` lands at the same
		// path in the consumer — a unified coordinate system.
		//
		// Empty outs → no COPY emitted. Producers that want to be
		// consumable cross-project must declare outs (or chain via
		// `dockerfile.from` for whole-state inheritance).
		//
		// Same-project chainedDeps pull only direct deps; cross-project
		// transitiveCrossDeps pulls the transitive set so a build target
		// chaining through same-project setup → workspace-root setup
		// brings the wsroot taskfile + manifest into this stage too
		// (needed for in-container task resolution of
		// `:workspaceroot:setup:setup`).
		//
		// FROM-chain dedup: when this target chains its FROM off another
		// bayt target (`dockerfile.from.ref`), the upstream's filesystem
		// — including its own COPY --from'd dep content — is inherited.
		// Re-COPY'ing those deps here is redundant AND inflates BuildKit's
		// frontend gRPC payload (each dep entry becomes a recursive
		// service: ref expansion in compose's additional_contexts). At
		// ~10 cross-project deps this overflows BuildKit's 4 MB grpc
		// max_recv_msg_size. _inheritedDepKeys is the set of dep keys
		// the upstream already provides; we filter them out of both
		// _depCopies (here) and _depEntries (in _service below).
		// FROM-scratch targets skip auto cross-stage COPYs. By
		// definition, a scratch image is a packaging stage — the
		// runtime artifact has already encoded everything via the
		// upstream chain (build → ... → releaseLayers → release).
		// Auto-COPY'ing transitive cross-deps' source/build trees
		// into a scratch deployable is just bloat. Cross-stage COPYs
		// the leaf actually needs (e.g. layers from a sibling target)
		// go in `dockerfile.epilogue` explicitly. additional_contexts
		// wiring still flows through deps so bake can resolve those
		// epilogue COPYs' --from refs.
		// Per-dep COPY (one per dep), with all of that dep's outs.globs
		// joined into a single --parents argument list. Per-dep
		// splitting is intentional — it keeps cache granularity across
		// deps so editing dep A's outputs doesn't invalidate the layer
		// carrying dep B. Per-glob splitting *within* a dep added no
		// granularity (the --from and --exclude are constant per dep
		// and any glob's content change re-pulls the same dep stage's
		// state anyway), so we emit one line per dep.
		//
		// Same-project chainedDeps and cross-project transitiveCrossDeps
		// have different filter rules (dir match + G._emit gate for
		// same-project) but share the COPY line shape, so a single
		// line-render closure keeps both branches honest.
		let _depCopyLine = {
			d: _
			out: string
			let _dp          = [if d.dir != ""              {"\(d.dir)/"},        ""][0]
			let _excludeTail = strings.Join([for e in d.outs.exclude {"--exclude=\(e)"}], " ")
			let _excludeJ    = [if len(d.outs.exclude) > 0  {" \(_excludeTail)"}, ""][0]
			let _globPaths   = strings.Join([for g in d.outs.globs {"/monorepo/\(_dp)\(g)"}], " ")
			out: "COPY --from=\(d.project)-\(d.name)\(_excludeJ) --link --parents \(_globPaths) /"
		}
		let _emitForDep = {
			d: _
			out: bool
			out: !list.Contains(_inheritedDepKeys, "\(d.project)-\(d.name)") && len(d.outs.globs) > 0
		}
		_depCopies: [
			if t.dockerfile.from != null
			for d in (G._targetDeps & {"t": t}).out
			if (_emitForDep & {"d": d}).out {
				(_depCopyLine & {"d": d}).out
			},
		]

		_inheritedDepKeys: (G._inheritedDepKeys & {"t": t}).out

		_excludeFlags: [
			for e in t.srcs.exclude {"--exclude=\(e)"},
		]
		_excludeJoin: [if len(_excludeFlags) > 0 {strings.Join(_excludeFlags, " ") + " "}, ""][0]

		// `--parents` (Dockerfile syntax 1.7-labs) preserves source path
		// structure in the destination. Without it we'd have to emit
		// `COPY --link src/**/*.kt ./src/**/*.kt` — the glob in the
		// destination breaks BuildKit ("lstat /src: no such file") and
		// even when it doesn't, empty glob matches can fail. With
		// --parents we emit `COPY --link --parents src/**/*.kt ./` and
		// BuildKit places matched files at their original paths while
		// gracefully handling zero-match globs (e.g. libstoml has no
		// *.java files — glob matches nothing, COPY succeeds silently).
		//
		// All target.srcs.globs land in a single COPY: they share the
		// same `--exclude` flags and feed the same downstream RUN(s),
		// so per-glob splitting buys nothing the BuildKit cache cares
		// about — any glob's content change rebuilds the same
		// downstream layer either way. Per-cmd cache reuse comes from
		// cmd-level srcs (interleaved with each cmd's RUN below), not
		// from splitting the target baseline.
		//
		// Srcs must stay inside the project dir (no `../` escapes).
		// Files that live at the monorepo root belong to a workspace-
		// root project — declare it as a target there and add a
		// cross-project dep instead of reaching across with `..`.
		_srcCopies: [
			if len(t.srcs.globs) > 0 {
				"COPY --link --parents \(_excludeJoin)\(strings.Join(t.srcs.globs, " ")) ./"
			},
		]

		_envs: [
			for k, v in t.env {"ENV \(k)=\(v)"},
		]

		// Always-on per-target taskfile+manifest publish: every emitted
		// Dockerfile stage carries its own .bayt/Taskfile.<n>.yaml +
		// .bayt/bayt.<n>.json + the root .bayt/Taskfile.yml index +
		// the project-root Taskfile.yml. Cheap (tiny files, --link),
		// and it's the only way a cross-project incremental consumer
		// can resolve `:<dep-project>:bayt:<n>` when its task chain
		// runs inside the container — the consumer's
		// `COPY --from=<dep>-<n> --link /monorepo/<dep.dir>/. ...`
		// in _depCopies above brings the dep stage's full workdir in,
		// including these files at their canonical paths.
		//
		// Project-root Taskfile.yml is the launch point (`task bayt:<n>`
		// is invoked from WORKDIR with no `-t` flag), so we COPY it
		// here. It only carries one structural include (`bayt:`) plus
		// any cross-project siblings, so it's near-stable and rarely
		// busts cache. The .bayt/* sources land in one COPY: they're
		// emitted together by a single generate-bayt.nu pass, so
		// per-file granularity provides no realistic cache benefit
		// (and the immediately-following RUN layer invalidates on any
		// FS change either way). init.gradle.kts is emitted for every
		// project — non-gradle stages just carry a harmless ~10-line
		// file they never reference.
		//
		// Per-target Taskfile.<n>.yaml is conditional: gen_taskfile only
		// emits it when t.taskfile != _|_ (e.g. sayt.launch defines no
		// taskfile fragment). COPY'ing a missing file would fail the
		// build at the COPY layer.
		_selfTaskfileSources: [
			".bayt/Taskfile.yml",
			if t.taskfile != _|_ {".bayt/Taskfile.\(t.name).yaml"},
			".bayt/bayt.\(t.name).json",
			".bayt/init.gradle.kts",
		]
		_selfTaskfileCopies: [
			"COPY --link Taskfile.yml ./Taskfile.yml",
			"COPY --link \(strings.Join(_selfTaskfileSources, " ")) ./.bayt/",
		]

		// Incremental-only additions: bayt-runtime stub mount (so
		// `nu .../fingerprint.nu` resolves) and same-project transitive
		// deps' taskfile + manifest (cross-project deps' taskfile state
		// arrives via _depCopies + _selfTaskfileCopies on the dep side).
		// Stamps (.task/) cross stage boundaries via the same
		// _depCopies COPY --from=<dep> chain above; this is the only
		// path stamps take between stages.
		// Per-dep COPY (one per transitive dep) keeps cache granularity
		// across deps — touching dep A doesn't invalidate the layer for
		// dep B. Each dep's Taskfile fragment + manifest are emitted
		// together so they share one COPY.
		_incrementalCopies: list.Concat([
			if t.dockerfile.incremental {[
				// bayt-runtime lives outside the project context; it's
				// wired in through the compose service's additional_contexts
				// (see _service below) and COPY'd here to the well-known
				// path the generated Taskfile cmds reference.
				"COPY --from=bayt-runtime --link . /monorepo/plugins/bayt/runtime/",
			]},
			if !t.dockerfile.incremental {[]},
			if t.dockerfile.incremental {[
				for d in t.transitiveDeps if G._m.files[d] != _|_ {
					"COPY --link .bayt/Taskfile.\(d).yaml .bayt/bayt.\(d).json ./.bayt/"
				},
			]},
			if !t.dockerfile.incremental {[]},
		])

		// Mounts collected from target level + every cmd in the rulemap.
		// Incremental mode runs all cmds through `task`, so its single
		// RUN must carry every mount any cmd needs (gradle cache, pnpm
		// store, secret mounts). Direct mode has one RUN per cmd with
		// only that cmd's mounts.
		_targetMountStrs: [for m in t.dockerfile.mounts {(_mount & {"m": m}).out}]
		_cmdMountStrs: [
			for c in t.cmds
			if c.dockerfile != _|_ && c.dockerfile.mounts != _|_
			for m in c.dockerfile.mounts {
				(_mount & {"m": m}).out
			},
		]

		// Incremental: single RUN wrapping `task <n>:<n>`, target mounts
		// + every cmd's mounts unioned (the RUN executes the whole chain
		// inside go-task, so it needs every mount any chained cmd needs).
		// Non-incremental: one COPY+RUN block per cmd, each carrying
		// only that cmd's mounts and its own srcs. Editing cmd B's
		// inputs (e.g. package.json for pnpm install) doesn't bust
		// cmd A's RUN layer (mise install) — the COPY for cmd B
		// lands AFTER cmd A's RUN, so cmd A's input set hasn't moved.
		// Target.srcs is COPY'd upfront in _srcCopies as the shared
		// baseline; cmd-level srcs land per-cmd here.
		// list.Concat with empty-list fallbacks because CUE's
		// `[ if cond { for x in xs { y } } ]` collapses the inner
		// list into a single positional slot, which conflicts on
		// multi-cmd targets. Wrapping each branch in an explicit
		// list keeps the nesting unambiguous.

		// Persistent cache for cache.nu's content-addressable store.
		// Stable id (`bayt-cache`) means every bayt-emitted RUN across
		// every project/stage shares the same backing volume — a cache
		// hit written by libraries_logs:build during stage X is
		// readable by services_tracker:integrate during stage Y.
		// Path matches cache.nu's `local-root` default; if someone
		// overrides BAYT_CACHE_DIR inside a container the writes would
		// land outside this mount and go into the layer cache instead.
		// Only emitted for incremental targets because non-incremental
		// RUNs don't go through the Taskfile and so don't invoke
		// cache.nu.
		_baytCacheMountStr: "--mount=type=cache,id=bayt-cache,target=/root/.cache/bayt,sharing=shared"

		_runs: list.Concat([
			if t.dockerfile.incremental {
				let _allMounts = list.Concat([[_baytCacheMountStr], _targetMountStrs, _cmdMountStrs])
				let _mountStr = [if len(_allMounts) > 0 {strings.Join(_allMounts, " ") + " "}, ""][0]
				// Collect wraps from all cmds (typically just the builtin cmd).
				// Mirrors _cmdMountStrs pattern: iterate t.cmds (priority-
				// sorted list) rather than accessing t.cmd map by key — map
				// key access in CUE conditionals doesn't evaluate concretely
				// for pattern-constrained maps.
				let _wrapCmds = [for c in t.cmds if c.dockerfile != _|_ && c.dockerfile.wrap != _|_ {c.dockerfile.wrap}]
				let _wrapStr = [if len(_wrapCmds) > 0 {"\(_wrapCmds[0]) "}, ""][0]
				// `task bayt:<n>` (no `-t`) — the WORKDIR's Taskfile.yml
				// is the launch root, with `bayt:` resolving the per-
				// target chain through `.bayt/Taskfile.yml`. Single
				// namespace path, same address users invoke on the host.
				// _wrapStr prepends dind.sh (or similar) when any cmd has
				// a dockerfile.wrap set. Exec form: `task` is a single
				// program with two args, no shell needed.
				let _full = "\(_wrapStr)task bayt:\(t.name)"
				let _tokens = strings.Split(_full, " ")
				let _quoted = [for tk in _tokens if tk != "" {"\"\(tk)\""}]
				["RUN \(_mountStr)[\(strings.Join(_quoted, ", "))]"]
			},
			if !t.dockerfile.incremental {[]},
			if !t.dockerfile.incremental {
				// Non-incremental: emit COPY-then-RUN per cmd, with the
				// cmd's own srcs landing just before its RUN. Editing
				// cmd B's srcs (e.g. package.json for pnpm install)
				// leaves cmd A's RUN layer (mise install) cached because
				// cmd B's COPY lands AFTER cmd A's RUN — A's input set
				// hasn't moved. Target.srcs lands earlier in _srcCopies
				// as the shared baseline for all cmds.
				//
				// gen_bayt.cue unions target.srcs into each cmd's
				// srcs.globs for fingerprint.nu's stamp logic. We're
				// here in the Dockerfile path, where target.srcs already
				// landed in _srcCopies — so subtract via list.Contains
				// to recover the cmd's own contribution. Same shape for
				// exclude (cmd-level adds, target-level already on the
				// _srcCopies COPY).
				//
				// Empty cmd-only globs → no COPY emitted, RUN only.
				// list.FlattenN(_, 1) flattens the per-cmd
				// [optional-COPY, RUN] sublists into one flat list.
				list.FlattenN([
					for c in t.cmds {
						let _cmdOnlyGlobs = [for g in c.srcs.globs if !list.Contains(t.srcs.globs, g) {g}]
						let _cmdOnlyExclude = [for e in c.srcs.exclude if !list.Contains(t.srcs.exclude, e) {e}]
						let _cExcludeFlags = [for x in _cmdOnlyExclude {"--exclude=\(x)"}]
						let _cExcludeJ = [if len(_cExcludeFlags) > 0 {strings.Join(_cExcludeFlags, " ") + " "}, ""][0]
						let _cCopy = [
							if len(_cmdOnlyGlobs) > 0 {
								"COPY --link --parents \(_cExcludeJ)\(strings.Join(_cmdOnlyGlobs, " ")) ./"
							},
						]
						list.Concat([_cCopy, [(_runLine & {"t": t, "c": c}).out]])
					},
				], 1)
			},
			if t.dockerfile.incremental {[]},
		])

		_exposes: [
			for p in t.dockerfile.expose {"EXPOSE \(p)"},
		]

		// ENTRYPOINT — three-form schema (null | list | string). Type-
		// discriminate via `& <type>` unification, then narrow into a
		// concrete value with the disjunction-default pattern so `len()`
		// is safe regardless of which branch fires (CUE eager-evaluates
		// the if-body, so naked `len(t.dockerfile.entrypoint)` errors
		// when entrypoint is null even with a guarded if).
		// null / "" / [] all emit no instruction; non-empty string emits
		// shell form, non-empty list emits exec form (naive `"arg"`
		// quoting — see #dockerfile.entrypoint docstring).
		let _ep = t.dockerfile.entrypoint
		let _epStr = [
			if _ep != null && (_ep & string) != _|_ {_ep},
			"",
		][0]
		let _epList = [
			if _ep != null && (_ep & [...string]) != _|_ && (_ep & string) == _|_ {_ep},
			[],
		][0]
		_entrypoint: [
			if len(_epStr) > 0 {
				"ENTRYPOINT \(_epStr)"
			},
			if len(_epList) > 0 {
				let quoted = [for a in _epList {"\"\(a)\""}]
				"ENTRYPOINT [\(strings.Join(quoted, ", "))]"
			},
		]

		// Layer ordering: for incremental targets the RUN is
		// `task -t .bayt/Taskfile.yml <n>:<n>`, which needs .bayt/
		// state + bayt-runtime present BEFORE the RUN to resolve
		// the task graph — so _selfTaskfileCopies + _incrementalCopies
		// go before _runs. For non-incremental targets the RUN only
		// needs srcs (+ upstream deps); the .bayt/ files are
		// published only for cross-project consumers, so emit them
		// AFTER the RUN. Net: .bayt regen (Taskfile/target json
		// rewrites) doesn't invalidate non-incremental install RUNs.
		_preRun:  [if t.dockerfile.incremental  {list.Concat([_selfTaskfileCopies, _incrementalCopies])}, []][0]
		_postRun: [if !t.dockerfile.incremental {_selfTaskfileCopies},                                   []][0]

		_lines: [
			_syntax,
			_from,
			"WORKDIR \(_workdir)",
			for p in t.dockerfile.preamble {p},
			for l in _depCopies {l},
			for l in _srcCopies {l},
			for l in _preRun {l},
			for l in _envs {l},
			for l in _runs {l},
			for l in _postRun {l},
			for l in _exposes {l},
			for l in _entrypoint {l},
			for l in t.dockerfile.epilogue {l},
		]
		out: string
		out: strings.Join(_lines, "\n") + "\n"
	}

	// Per-target Dockerfile bodies.
	dockerfiles: {
		for n, t in _emit {
			(n): (_renderDockerfile & {"t": t}).out
		}
	}

	// Helper: one service entry inside a per-target compose file.
	// Service key = qualified name; Dockerfile stage name stays bare
	// (stage names are local to one Dockerfile).
	_service: {
		n: string
		t: _
		svc: (_svcName & {pn: t.project, tn: n}).out

		out: {
			// Build block: context is one up from .bayt/ (= project root)
			// so `COPY --link src/...` in the Dockerfile reaches real files.
			build: {
				context:    ".."
				dockerfile: ".bayt/Dockerfile.\(n)"
				target:     n

				// Dep services become additional build contexts so the
				// Dockerfile can `COPY --from=<svc>`. Same-project deps
				// use direct chainedDeps (only the next stage hop is
				// physically wired); cross-project deps use the transitive
				// set so an incremental build that chains through a
				// same-project setup into a workspace-root setup carries
				// the workspace-root context too. Same-project gating on
				// G._emit; cross-project assumes the federated compose
				// graph supplies the dep service via the includes derived
				// from _m.projectManifest.crossProjectDirs at the root.
				// Same dedup as _depCopies: drop entries the FROM-chained
				// upstream already provides. Keeps additional_contexts
				// flat — the recursive `service:X` resolution that fills
				// the gRPC frontend message only fires for entries we
				// actually emit, so dropping these directly shrinks the
				// payload (and lets us keep cross-project FROM-chains
				// without overflowing 4 MB).
				let _inheritedKeys = (G._inheritedDepKeys & {"t": t}).out
				let _depEntries = [
					for d in (G._targetDeps & {"t": t}).out
					if !list.Contains(_inheritedKeys, "\(d.project)-\(d.name)") {
						"\(d.project)-\(d.name)"
					},
				]
				// from-ref: present a single additional_contexts entry so
				// the Dockerfile can FROM the named alias. Keeps every
				// FROM source uniform (image / sibling stage / bake target
				// / ...) without forcing the user to remember which
				// schemes need additional_contexts and which don't.
				// `from: null` (scratch) skips the entry entirely —
				// Docker's parser handles `FROM scratch` directly.
				// bayt-runtime: when incremental, the emitted Dockerfile
				// RUN uses `task <n>:<n>` whose cmds reference
				// `../../plugins/bayt/runtime/fingerprint.nu`. That path
				// lives outside the project context. We can't reach it
				// via additional_contexts: path: (compose restricts
				// `..` escapes there), so we route through service: form
				// pointing at the bayt-runtime-stub service emitted into
				// the project's compose root (see _runtimeStub below).
				// `build.context:` in the stub IS allowed to escape
				// upward, so the stub publishes plugins/bayt/runtime as
				// a buildable context and incremental stages COPY from
				// service:bayt-runtime-stub.
				if t.dockerfile.incremental || len(_depEntries) > 0 || t.dockerfile.from != null {
					additional_contexts: {
						for e in _depEntries {
							(e): "service:\(e)"
						}
						if t.dockerfile.incremental {
							"bayt-runtime": "service:bayt-runtime-stub"
						}
						if t.dockerfile.from != null {
							(t.dockerfile.from.name): t.dockerfile.from.context
						}
					}
				}

				if len(t.dockerfile.secrets) > 0 {
					secrets: t.dockerfile.secrets
				}
			}

			if len(t.dockerfile.secrets) > 0 {
				secrets: t.dockerfile.secrets
			}

			if t.compose != _|_ && t.compose.runtime != _|_ {
				let r = t.compose.runtime
				if r.image != _|_ {image:   r.image}
				if r.command != _|_ {command: r.command}
				if r.entrypoint != _|_ {entrypoint: r.entrypoint}
				if len(r.environment) > 0 {environment: r.environment}
				if len(r.ports) > 0 {ports: r.ports}
				if len(r.volumes) > 0 {volumes: r.volumes}
				if len(r.depends_on) > 0 {depends_on: r.depends_on}
				if r.network_mode != _|_ {network_mode: r.network_mode}
				// healthcheck is open-struct ({...}) in #compose so users
				// pass compose-spec values verbatim — bayt doesn't
				// re-validate compose's own schema for this.
				if r.healthcheck != _|_ {healthcheck: r.healthcheck}
			}

			if t.compose != _|_ && t.compose.develop != _|_ {
				develop: t.compose.develop
			}
		}
	}

	// Compose graph: per-target service files + a federated root that
	// includes them all. Cross-project includes come from
	// _m.projectManifest.crossProjectDirs — derived from each target's
	// #target ref deps (single source of truth, no manual sync).
	compose: {
		files: {
			for n, t in _emit {
				(n): {
					let svc = (_svcName & {pn: t.project, tn: n}).out
					services: (svc): (_service & {"n": n, "t": t}).out

					if len(t.dockerfile.secrets) > 0 {
						secrets: {
							for s in t.dockerfile.secrets {
								// BAYT_<SECRET>_FILE: path to a temp file that dind-vrun
								// creates so Docker Compose can mount the secret at both
								// build time (BuildKit) and runtime. Hand-maintained
								// project compose.yaml files MUST declare the same secret
								// the same way (file: ${BAYT_<SECRET>_FILE}) — declaring
								// it differently (e.g. environment:) collides with this
								// per-target declaration since compose merges all top-level
								// secrets blocks across includes.
								(s): {file: "${BAYT_\(strings.ToUpper(strings.Replace(s, ".", "_", -1)))_FILE}"}
							}
						}
					}
				}
			}
		}

		// Two emitted roots, layered the same way as the Taskfile pair:
		//
		//   - `.bayt/compose.bayt.yaml` is the FEDERATION root. Per-target
		//     includes + cross-project sibling includes + bayt-runtime-stub.
		//     Service names are fully qualified `<project>-<target>` here
		//     so two projects' federations can coexist in one compose graph
		//     without collision. Other projects' bayt files include this
		//     file via cross-project deps.
		//
		//   - `.bayt/compose.yaml` is the USER root — what `<project>/compose.yaml`
		//     `include`s to get short, local-friendly service names
		//     (`setup`, `build`, `integrate`, ...). It includes the
		//     federation file and adds one `extends:` alias service per
		//     local target. Cross-project federation never reaches this
		//     file (other projects only include compose.bayt.yaml), so
		//     the short aliases stay collision-free.
		//
		// Each include is marked `required: false` (compose v2.20+) so
		// missing files don't abort load. Matches go-task's optional
		// includes: inside a Docker build context where only some
		// per-target files are COPY'd, compose still loads what's there.
		// Critical for per-target layer cache isolation.
		bayt_root: {
			let _localIncludes = [
				for n, _ in _emit {
					{path: "./compose.\(n).yaml", required: false}
				},
			]
			let _crossIncludes = [
				for dep in G._m.projectManifest.crossProjectDirs {
					let _dp = [if dep != "" {"\(dep)/"}, ""][0]
					// Cross-project deps target the OTHER project's
					// federation root (compose.bayt.yaml), never its
					// user root (compose.yaml) — that's what keeps
					// alias services from colliding when projects
					// federate.
					{path: "\(G._rootFromBayt)\(_dp).bayt/compose.bayt.yaml", required: false}
				},
			]
			let _allIncludes = list.Concat([_localIncludes, _crossIncludes])
			if len(_allIncludes) > 0 {
				include: _allIncludes
			}

			// bayt-runtime-stub: a buildable service whose only purpose
			// is to expose plugins/bayt/runtime as a build context that
			// other (incremental) services reference via
			// `additional_contexts: bayt-runtime: service:bayt-runtime-stub`.
			// `build.context:` allows `..` escapes (unlike additional_contexts:
			// path: which compose restricts), so this is the only way to
			// get plugins/bayt/runtime into a stage when the project sits
			// below it in the tree. Emitted here in the federation root
			// rather than per-target so the service is defined exactly
			// once per project. Lives in the federation root (not the
			// user root) so cross-project includes pick it up.
			let _hasIncremental = [for _, t in _emit if t.dockerfile.incremental {true}]
			if len(_hasIncremental) > 0 {
				services: "bayt-runtime-stub": {
					build: {
						context:          "\(G._rootFromBayt)plugins/bayt/runtime"
						dockerfile_inline: "FROM scratch\nCOPY . /\n"
					}
				}
			}
		}

		// User root: thin shell that includes the federation root and
		// adds one short-named alias per local target via compose's
		// `extends:`. Lets users type `docker compose up integrate`
		// instead of `docker compose up <project>-integrate`. The
		// alias inherits the full build/runtime config from the
		// qualified service — no duplication, just renaming.
		//
		// `extends: { file: ... }` is required even though
		// compose.bayt.yaml is also in our `include:` list — compose's
		// extends: resolves names against the CURRENT file's own
		// services map, not against included files. Pointing `file:`
		// at the federation sibling makes the aliasing explicit and
		// works regardless of include ordering.
		//
		// The per-target per-compose files IN .bayt/compose.bayt.yaml's
		// include list contain the actual qualified services, and
		// `extends: { file: ./compose.bayt.yaml }` won't resolve those
		// transitively either. So the render here needs the alias's
		// file: to point at the actual per-target compose file where
		// the qualified service is defined: ./compose.<target>.yaml.
		root: {
			include: [{path: "./compose.bayt.yaml", required: false}]

			if len(_emit) > 0 {
				services: {
					for n, _ in _emit {
						let _svc = (_svcName & {pn: G.project.name, tn: n}).out
						(n): {
							extends: {
								file:    "./compose.\(n).yaml"
								service: _svc
							}
						}
					}
				}
			}
		}
	}
}
