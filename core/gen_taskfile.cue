// gen_taskfile.cue — Taskfile.yml + per-target .bayt/Taskfile.<target>.yaml
// emission. Reads the canonical manifest from #manifestGen; consumed by
// generate-bayt.nu which writes the YAML to disk. Pure CUE.
package bayt

import (
	"list"
	"path"
	"strings"
)


#taskfileGen: G={
	project: #project
	depManifests:   {[string]: _}
	runtime: *"" | string

	_m: (#manifestGen & {project: G.project, depManifests: G.depManifests})

	// Only targets that declared a taskfile block on their #target.
	_emit: {for n, t in G._m.files if t.taskfile != _|_ {(n): t}}

	// bayt/sayt invocation tokens. Consumer mode (runtime == ""): bare
	// names resolved via PATH (`mise install github:bonisoft3/bayt`).
	// Monorepo mode (`bayt generate --runtime plugins/bayt`): depth-
	// aware in-tree paths — the POSIX launcher on the else arm, the
	// mise tool-stub pair on Windows (a sh script Windows cannot exec);
	// go-task templates the OS branch at run time. Workspaceroot
	// (depth 0) prefixes `./` for argv unambiguity.
	let _prefix = [if G._m._depth == 0 {"./"}, strings.Repeat("../", G._m._depth)][0]
	let _rt = "\(_prefix)\(G.runtime)/runtime"
	_baytPath: [
		if G.runtime != "" {"{{if eq OS \"windows\"}}mise tool-stub \(_rt)/nu.toml \(_rt)/bayt.nu{{else}}\(_rt)/bayt{{end}}"},
		"bayt",
	][0]
	// sayt lives beside bayt (`<parent>/sayt`); its entry is nu source.
	_saytPath: [
		if G.runtime != "" {"nu \(_prefix)\(path.Dir(G.runtime))/sayt/sayt.nu"},
		"sayt",
	][0]

	// Helper: fingerprint.nu invocation. Manifest carries srcs/excludes/
	// outs/chainedDeps; fingerprint.nu reads them and handles cross-
	// project `../` traversal for dep stamps. The local stamp path is
	// composed here (CUE knows the target + cmd names) and passed via
	// --stamp-file so fingerprint.nu's contract is one-flag-per-concern.
	//
	// No outer `mise x --` prefix: bayt's launcher already invokes
	// `runtime/nu.toml` (a mise tool-stub), so nu — and any other
	// pinned tool bayt internally uses — is resolved through mise
	// inside-out. Wrapping the whole thing in another `mise x --`
	// is redundant AND active interference: mise's exec context can
	// sanitize PATH and lose the Dockerfile-set
	// `/monorepo/plugins/bayt/bin` entry, leaving `bayt` unreachable
	// in container RUN stages.
	_fingerprint: F={
		t:    _
		mode: "check" | "stamp"
		// cmd: empty → target-level stamp; non-empty → per-cmd stamp.
		// fingerprint.nu's --cmd flag scopes hash inputs to that cmd's
		// effective srcs; the stamp file name appends .<cmd> to match.
		cmd: *"" | string
		out: string
		// Manifest path uses {{.TASKFILE_DIR}} so it's absolute and
		// immune to the nested-include working-directory bug. The stamp
		// path stays cwd-relative; go-task runs each task from the
		// Taskfile's dir, so `.task/bayt/` lands in the same project.
		let _cmdFlag    = [if F.cmd != "" {" --cmd \(F.cmd)"}, ""][0]
		let _stampName  = [if F.cmd != "" {"\(F.t.name).\(F.cmd)"}, F.t.name][0]
		let _updateFlag = [if F.mode == "stamp" {" --update-stamp"}, ""][0]
		out: "\(_baytPath) fingerprint --manifest {{.TASKFILE_DIR}}/bayt.\(F.t.name).json\(_cmdFlag) --stamp-file .task/bayt/\(_stampName).hash\(_updateFlag)"
	}

	// _baytWrap — the per-task BAYTW variable: the cache-run prefix that
	// wraps each cmd line. Layout:
	//
	//   bayt cache run --manifest <m>[ --cmd <c>][ --full][ --similar] --[ <activate>]
	//
	// The activate suffix (typically `mise x --`) resolves cmds through
	// mise's shim; cmds that bake their own activate get no suffix.
	_baytWrap: W={
		t:   _
		cmd: *"" | string
		out: string
		// cache.full → --full (skip cmd on exact hit); cache.similar →
		// --similar (warm-start on miss). Both opt-in.
		let _cmdFlag      = [if W.cmd != ""           {" --cmd \(W.cmd)"},     ""][0]
		let _fullFlag     = [if W.t.cache.full        {" --full"},             ""][0]
		let _similarFlag  = [if W.t.cache.similar     {" --similar"},          ""][0]
		let _activateTail = [if len(W.t.activate) > 0 {" \(W.t.activate)"},    ""][0]

		// No shell wrap here: per-OS variants can each pick their own
		// shell, so `<shell> -c` lives per-line in _osCmdList.
		out: "\(_baytPath) cache run --manifest {{.TASKFILE_DIR}}/bayt.\(W.t.name).json\(_cmdFlag)\(_fullFlag)\(_similarFlag) --\(_activateTail)"
	}

	// _taskCmdLine — a (do, shell) pair as a go-task cmd string, prefixed
	// by `bw` (the BAYTW cache-run prefix, "" for raw cmds). A non-exec
	// shell gets `<shell> -c "…"` so the whole do reaches it as one arg.
	// _crossName — runner-task name for a cross-project chainedDep
	// (`cross_<proj-slug>_<target>`; workspaceroot when dir is "").
	_crossName: N={
		d: _
		out: "cross_\([if N.d.dir == "" {"workspaceroot"}, strings.Replace(N.d.dir, "/", "_", -1)][0])_\(N.d.name)"
	}

	// No {{.CLI_ARGS}} forwarding: the variable is run-global in
	// go-task, so it would leak the caller's args into every dep task.
	// Gate cmds are closed; interactive args go through `sayt <verb>`.
	_taskCmdLine: L={
		do:    string
		shell: string
		bw:    string
		// bayt/sayt-prefixed dos take the runtime-aware token (prefix
		// form only — a mid-string `sayt` never rewrites).
		let _do = [
			if strings.HasPrefix(L.do, "bayt ") {_baytPath + strings.TrimPrefix(L.do, "bayt")},
			if strings.HasPrefix(L.do, "sayt ") {_saytPath + strings.TrimPrefix(L.do, "sayt")},
			L.do,
		][0]
		out: [
			if L.shell == "exec" {"\(L.bw)\(_do)"},
			"\(L.bw)\(L.shell) -c \"\((#shellQuote & {in: _do}).out)\"",
		][0]
	}

	// _osCmdList — a cmd's task-cmds entries: one line, or one `platforms:`
	// branch per OS (carrying that OS's effective do/shell) when the cmd
	// has a windows/linux/darwin override. A host outside those three
	// matches no branch and runs nothing — safer than an untested unix-ism.
	_osCmdList: X={
		c:  _
		bw: string
		out: [...]
		let _oses  = ["windows", "linux", "darwin"]
		let _hasOS = len([for os in _oses if X.c[os] != _|_ {os}]) > 0
		out: [
			if !_hasOS {[(_taskCmdLine & {do: X.c.do, shell: X.c.shell, bw: X.bw}).out]},
			[for os in _oses {
				let _o = X.c[os]
				{
					cmd: (_taskCmdLine & {
						do:    [if _o != _|_ && _o.do != _|_ {_o.do}, X.c.do][0]
						shell: [if _o != _|_ && _o.shell != _|_ {_o.shell}, X.c.shell][0]
						bw:    X.bw
						ca:    X.ca
					}).out
					platforms: [os]
				}
			}],
		][0]
	}

	// _cmdsBlock — a cmd's _osCmdList lines plus the defer hash-stamp. The
	// defer is unguarded (runs on every host); its list position is
	// cosmetic (go-task fires defers at task exit).
	_cmdsBlock: B={
		t:   _
		cmd: *"" | string  // empty = target-level wrapper / single-cmd
		c:   _             // the cmd object — drives OS branching + shell
		out: [...]
		out: list.Concat([
			(_osCmdList & {"c": B.c, bw: "{{.BAYTW}} "}).out,
			[{defer: "{{if not .EXIT_CODE}}\((_fingerprint & {"t": B.t, mode: "stamp", "cmd": B.cmd}).out){{end}}"}],
		])
	}

	// Per-target Taskfile files.
	//
	// Single-cmd target: emit one `default:` task with sources, status,
	// cmds, and a defer hash-stamp.
	//
	// Multi-cmd target: emit N internal cmd-tasks (each with its own
	// sources/status/cmds + defer for the per-cmd stamp) plus a
	// `default:` wrapper that deps on the last cmd and writes the
	// target-level stamp. Cross-project consumers reading the target
	// stamp via the merkle chain see correct invalidation because the
	// target stamp hashes the full union of all srcs.
	files: {
		for n, t in _emit {
			(n): {
				version: "3"

				// Same-project deps use `::` (setup lives in the same
				// Taskfile root as build). Cross-project deps cannot —
				// go-task's `::` inside a nested include escapes only to
				// that file's own root, not the absolute launch root — so
				// they address the `cross_*` runners in bayt_root instead.
				// `_srcs`/`_bayt` views are committed files — no runnable
				// task, filtered from both. `_outs` views are PRODUCTS:
				// on host the base target's run is what materializes
				// them, so the ref maps to the base task.
				let _sameRefs = [for name in t.sameProjectDeps if !(name =~ "_(srcs|bayt)$") {"::bayt:\(strings.TrimSuffix(name, "_outs"))"}]
				let _sameProjectDeps = [for i, r in _sameRefs if !list.Contains(list.Slice(_sameRefs, 0, i), r) {r}]
				let _crossRefs = [
					for d in t.chainedDeps
					if d.dir != G.project.dir
					if !(d.name =~ "_(srcs|bayt)$") {
						"::bayt:\((_crossName & {"d": {dir: d.dir, name: strings.TrimSuffix(d.name, "_outs")}}).out)"
					},
				]
				let _crossDeps = [for i, r in _crossRefs if !list.Contains(list.Slice(_crossRefs, 0, i), r) {r}]
				let _allDeps = list.Concat([_sameProjectDeps, _crossDeps])
				// Cmds with a base `do` emit tasks; a cmd with only
				// `dockerfile.do` is RUN-only (Dockerfile RUN, no task).
				let _taskCmds = [for c in t.cmds if c.do != _|_ {c}]

				if len(_taskCmds) <= 1 {
					// SINGLE-CMD (or zero-cmd) PATH — flat default
					// task. When taskfile.incremental is true (default),
					// the cmd is wrapped in the cache.nu BAYTW + the
					// target stamp short-circuits reruns via `status:`.
					// When false, cmds emit raw — no machinery.
					tasks: default: {
						if len(_allDeps) > 0 {deps: _allDeps}
						if len(t.env) > 0 {env: t.env}

						// status: target-level hash-check (no --cmd).
						// fingerprint.nu reads target.srcs from the
						// manifest. Every incremental target gets one:
						// the manifest itself is an implicit src, so even
						// no-cmd targets (doctor, lint, etc.) participate
						// in the merkle chain via a stable stamp.
						if t.taskfile.incremental {
							status: [(_fingerprint & {"t": t, mode: "check"}).out]
						}

						if len(_taskCmds) == 1 {
							let _c = _taskCmds[0]
							if t.taskfile.incremental {
								// BAYTW absorbs cache.nu wrapper + activate
								// suffix; cmd reads as `{{.BAYTW}} <do>`
								// so the user's actual command stays
								// unobscured.
								vars: BAYTW: (_baytWrap & {"t": t}).out
								cmds: (_cmdsBlock & {"t": t, "c": _c}).out
							}
							if !t.taskfile.incremental {
								// Raw cmd — go-task evaluates as a shell
								// command. No stamp-skip; no cache.nu
								// wrap. Use when the cmd should run every
								// time it's invoked (ephemeral / runtime
								// driven by outer cache layers). Still
								// OS-branched (bw: "") so a windows/darwin
								// override is honored here too.
								cmds: (_osCmdList & {"c": _c, bw: ""}).out
							}
						}

						if t.taskfile.run != _|_ && t.taskfile.run == "always" {
							run: "always"
						}
						if len(t.taskfile.preconditions) > 0 {
							preconditions: t.taskfile.preconditions
						}
					}
				}

				if len(_taskCmds) > 1 {
					// MULTI-CMD PATH — one internal task per cmd,
					// chained via deps in priority order; default
					// wrapper holds shared bits and (when incremental)
					// writes the target-level stamp. Per-cmd tasks gate
					// status/stamp/BAYTW on taskfile.incremental.
					let _last = _taskCmds[len(_taskCmds)-1].name

					tasks: default: {
						// _allDeps ride the first cmd-task; listing them
						// here too would start them a second time, in
						// parallel with the cmd chain.
						deps: [_last]
						if t.taskfile.incremental {
							// Wrapper writes the target-level stamp (full
							// union of all srcs). Cross-project consumers
							// read this. The defer block runs only when
							// every per-cmd task succeeded, so the target
							// stamp accurately reflects "all cmds passed."
							cmds: [
								{defer: "{{if not .EXIT_CODE}}\((_fingerprint & {"t": t, mode: "stamp"}).out){{end}}"},
							]
						}
						if t.taskfile.run != _|_ && t.taskfile.run == "always" {
							run: "always"
						}
						if len(t.taskfile.preconditions) > 0 {
							preconditions: t.taskfile.preconditions
						}
					}

					tasks: {
						for i, _c in _taskCmds {
							(_c.name): {
								internal: true
								// Deps chain in priority order. The first
								// cmd carries the target's dep set: deps
								// anchored only on the default wrapper run
								// parallel to the cmd chain — :generate
								// would rewrite this target's manifest and
								// cross runners would write stamps mid-read.
								if i == 0 && len(_allDeps) > 0 {
									deps: _allDeps
								}
								if i > 0 {
									deps: [_taskCmds[i-1].name]
								}
								if len(t.env) > 0 {env: t.env}
								if t.taskfile.incremental {
									// Per-cmd BAYTW carries `--cmd <name>` so
									// each cmd-subtask's cache lookup scopes
									// to its own srcs/outs slice.
									vars: BAYTW: (_baytWrap & {"t": t, "cmd": _c.name}).out
									status: [(_fingerprint & {"t": t, mode: "check", "cmd": _c.name}).out]
									generates: [".task/bayt/\(t.name).\(_c.name).hash"]
									cmds: (_cmdsBlock & {"t": t, "cmd": _c.name, "c": _c}).out
								}
								if !t.taskfile.incremental {
									cmds: (_osCmdList & {"c": _c, bw: ""}).out
								}
							}
						}
					}
				}
			}
		}
	}

	// bayt_root — <project.dir>/.bayt/Taskfile.bayt.yml, the `bayt`
	// namespace (naming mirrors compose.bayt.yaml). The user-authored
	// project-root Taskfile.yml includes this file.
	// One include per emitted target plus one per cross-project dep;
	// dep includes target the dep's project-root Taskfile.yml so
	// `bayt:<proj>:bayt:<target>` traverses the dep's own root.
	// `dir:` anchors at the owning project's root —
	// go-task resolves an included file's sources/generates globs
	// against the include's dir, not the included file's location.
	bayt_root: {
		version: "3"
		let _relRootFromBayt = "../" + strings.Repeat("../", G._m._depth)

		// cross_* gate runners — host-side merkle completion. The
		// fingerprint chain reads dep-project stamps
		// (`../../<dep>/.task/bayt/<t>.hash`); containers materialize
		// them via COPY --from, but on the host only these runners
		// produce and refresh them. One runner per cross-project
		// chainedDep, union over all targets: living here (not in the
		// per-target files) lets `run: once` dedupe a dep shared by
		// build and deps within one graph walk. `task -t` into the
		// dep's own launch root sidesteps the nested-include `::`
		// limitation; `{{.TASK_EXE}}` pins the running task binary.
		// The workspace-root `.git` probe skips runners in containers
		// (images COPY no .git; the COPY chain is the stamp authority
		// there). Recursion terminates at projects without cross deps;
		// bayt's cycle checks forbid dep cycles.
		let _rootRelFromProject = strings.Repeat("../", G._m._depth)
		let _crossChain = {
			for _, t in _emit
			for d in t.chainedDeps
			if d.dir != G.project.dir
			if !(d.name =~ "_(srcs|bayt)$") {
				let _b = {dir: d.dir, name: strings.TrimSuffix(d.name, "_outs")}
				((_crossName & {"d": _b}).out): _b
			}
		}
		if len(_crossChain) > 0 {
			tasks: {
				for k, d in _crossChain {
					let _depPath = [if d.dir != "" {"\(d.dir)/"}, ""][0]
					(k): {
						internal: true
						run:      "once"
						status: ["test ! -e \(_rootRelFromProject).git"]
						cmds: ["{{.TASK_EXE}} -t \(_rootRelFromProject)\(_depPath).bayt/Taskfile.yml bayt:\(d.name)"]
					}
				}
			}
		}

		let _localIncludes = {
			for n, _ in _emit {
				(n): {
					taskfile: "./Taskfile.\(n).yaml"
					dir:      "../"
					optional: true
				}
			}
			for dep in G._m.projectManifest.crossProjectDirs {
				let _depName = [if dep == "" {"workspaceroot"}, strings.Replace(dep, "/", "_", -1)][0]
				let _depPath = [if dep != "" {"\(dep)/"}, ""][0]
				(_depName): {
					taskfile: "\(_relRootFromBayt)\(_depPath)Taskfile.yml"
					dir:      "\(_relRootFromBayt)\(_depPath)"
					optional: true
				}
			}
		}
		if len(_localIncludes) > 0 {
			includes: _localIncludes
		}
	}

	// root — <project.dir>/.bayt/Taskfile.yml. Launch root for
	// bayt-initiated invocations (`task -t .bayt/Taskfile.yml bayt:<n>`,
	// naming mirrors compose.yaml): same shape and addresses as the
	// user-authored root shim, so fragments' `::bayt:<dep>` refs
	// resolve under either, without depending on the user-authored file.
	root: {
		version: "3"
		includes: bayt: {
			taskfile: "./Taskfile.bayt.yml"
			dir:      "../"
			optional: true
		}
	}
}
