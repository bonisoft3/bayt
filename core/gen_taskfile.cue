// gen_taskfile.cue — Taskfile.yml + per-target .bayt/Taskfile.<target>.yaml
// emission. Reads the canonical manifest from #manifestGen; consumed by
// generate-bayt.nu which writes the YAML to disk. Pure CUE.
package bayt

import (
	"list"
	"strings"
)


#taskfileGen: G={
	project: #project
	depManifests:   {[string]: _}

	_m: (#manifestGen & {project: G.project, depManifests: G.depManifests})

	// Only targets that declared a taskfile block on their #target.
	_emit: {for n, t in G._m.files if t.taskfile != _|_ {(n): t}}

	// Absolute path from .bayt/ (where each Taskfile lives) to the bayt
	// runtime directory. Uses go-task's {{.TASKFILE_DIR}} which is always
	// the directory of the file that defines the task — immune to
	// nested-include dir-resolution bugs where go-task may apply a
	// sub-include's `dir:` relative to the calling project rather than
	// the included file's location.
	//
	// Depth accounting: each Taskfile lives at <project>/.bayt/, which is
	// one level deeper than the project root, so we need (depth + 1) `../`
	// hops from .bayt/ to reach the workspace root, then descend into
	// plugins/bayt/runtime.
	//   depth=0 (workspace-root): {{.TASKFILE_DIR}}/../plugins/bayt/runtime
	//   depth=1 (plugins/jvm):    {{.TASKFILE_DIR}}/../../plugins/bayt/runtime
	//   depth=2 (libraries/logs): {{.TASKFILE_DIR}}/../../../plugins/bayt/runtime
	_relRoot: strings.Repeat("../", G._m._depth)
	// One extra `../` hop because Taskfiles live in `.bayt/`, one level
	// below the project root. {{.TASKFILE_DIR}} is always the file's
	// own directory regardless of how the task was invoked (nested include,
	// direct call, etc.) so this path is immune to go-task's nested-include
	// dir-resolution behaviour.
	_relRootFromBayt: strings.Repeat("../", G._m._depth+1)
	_runtime: "{{.TASKFILE_DIR}}/\(_relRootFromBayt)plugins/bayt/runtime"

	// Helper: build one full cmd line (activate prefix + rule body).
	_cmdLine: {
		activate: string
		c:        #cmd
		out:      string
		out: [if len(activate) > 0 {"\(activate) \(c.do)"}, c.do][0]
	}

	// Helper: sources with glob-exclude prefix applied (for `sources:`
	// which go-task uses for --watch and as documentation; the authoritative
	// short-circuit is the `status:` hook that calls fingerprint.nu).
	_sources: {
		t: _
		out: [...string]
		out: list.Concat([
			[for s in t.srcs.globs {s}],
			[for e in t.srcs.exclude {"!\(e)"}],
		])
	}

	// Helper: fingerprint.nu invocation. Manifest-driven — all inputs
	// (srcs, excludes, outs, chainedDeps) live in the per-target JSON;
	// fingerprint.nu reads them and handles path math (including
	// cross-project `../` traversal) in nushell, where it belongs.
	// CUE stays out of path manipulation.
	//
	// Hard-coded `mise x --` prefix: the bayt runtime is mise-bound
	// (it ships nu via the project's `.mise.toml`), and that's a
	// guarantee independent of user-side `activate` choices — a target
	// that sets `activate: ""` to skip mise wrapping for its own cmds
	// (workspace-root's setup runs `true`) still needs nu on PATH for
	// the system-emitted fingerprint hook. No cascading defaults from
	// project/target — the leaf composes the prefix it needs.
	_fingerprint: F={
		t:   _
		sub: string // "hash-check" or "hash-stamp"
		// cmd: empty → target-level stamp; non-empty → per-cmd stamp.
		// fingerprint.nu's --cmd flag scopes hash inputs to that cmd's
		// effective srcs and writes/reads .task/bayt/<target>.<cmd>.hash.
		cmd: *"" | string
		out: string
		// Manifest path also uses {{.TASKFILE_DIR}} so it's absolute and
		// immune to the same nested-include working-directory bug.
		let _cmdFlag = [
			if F.cmd == "" {""},
			if F.cmd != "" {" --cmd \(F.cmd)"},
		][0]
		out: "mise x -- nu \(G._runtime)/fingerprint.nu \(sub) --manifest {{.TASKFILE_DIR}}/bayt.\(t.name).json\(_cmdFlag)"
	}

	// Helper: build the YAML cmds list for a (possibly per-cmd) task.
	// Wraps the actual cmd in a defer-EXIT_CODE pattern that writes the
	// stamp only on success, plus the cmd line itself.

	// _baytWrap — emits the value for the per-task BAYTW variable: the
	// full bookkeeping prefix that wraps the inner cmd. Layout:
	//
	//   mise x -- nu <runtime>/cache.nu run --manifest <m>[ --cmd <c>][ --full][ --similar] -- [<activate>]
	//
	// cache.nu restores the manifest's outs on hit, runs the inner cmd
	// (or skips it when --full is set on EXACT hit), and stores outs on
	// success. The hash-stamp defer (in _cmdsBlock below) still fires
	// after — go-task's `status:` short-circuit skips THIS task entirely
	// on next run when the stamp matches, so cache.nu only fires when
	// the local stamp is stale (fresh checkout, branch switch, deleted
	// .task/).
	//
	// Activate (typically `mise x --`) is appended at the tail when
	// non-empty so cmds whose `do:` is just `./gradlew assemble` resolve
	// through mise's shim. Cmds that bake their own activate (e.g.
	// pnpm.install with target.activate="" and do:"mise x -- pnpm
	// install") emit BAYTW with no activate suffix; their c.do carries
	// the activate inline. Either way the resolved string is identical
	// to the pre-BAYTW form.
	_baytWrap: W={
		t:   _
		cmd: *"" | string
		out: string
		// Each flag is `[if cond { value }, ""][0]` — CUE picks the
		// first list element, which is `value` when the condition
		// holds and `""` (the trailing default) otherwise.
		// cache.full → --full (skip cmd entirely on exact hit).
		// cache.similar → --similar (warm-start on miss). Both opt-in;
		// cache.nu without flags = "exact-match only, run cmd on hit".
		let _cmdFlag      = [if W.cmd != ""           {" --cmd \(W.cmd)"},     ""][0]
		let _fullFlag     = [if W.t.cache.full        {" --full"},             ""][0]
		let _similarFlag  = [if W.t.cache.similar     {" --similar"},          ""][0]
		let _activateTail = [if len(W.t.activate) > 0 {" \(W.t.activate)"},    ""][0]

		// Shell wrap: when the matching cmd's shell != "exec", append
		// `<shell> -c` to the BAYTW prefix. The cmds-block then emits
		// the innerDo wrapped in double-quotes so the shell receives
		// it as a single arg. shell == "exec" leaves BAYTW without a
		// wrap; the inner do is interpreted by go-task's runtime
		// shell directly (sh on Linux/macOS, cmd on Windows).
		let _matchingCmds = [for c in W.t.cmds if W.cmd == "" || c.name == W.cmd {c}]
		let _shell        = [if len(_matchingCmds) > 0 {_matchingCmds[0].shell}, "exec"][0]
		let _shellTail    = [if _shell != "exec"       {" \(_shell) -c"},        ""][0]

		out: "mise x -- nu \(G._runtime)/cache.nu run --manifest {{.TASKFILE_DIR}}/bayt.\(W.t.name).json\(_cmdFlag)\(_fullFlag)\(_similarFlag) --\(_activateTail)\(_shellTail)"
	}

	// _cmdsBlock — emits the per-task cmds list as
	//   [ "{{.BAYTW}} <innerDo>", {defer: <hash-stamp>} ]
	// Defer is listed last for visual parity with execution order
	// (go-task fires defers at task exit regardless of position; this
	// is purely a readability win). innerDo is the user's `do:` string
	// untouched — the activate prefix already lives in BAYTW.
	//
	// Shell handling: when the cmd's shell != "exec", BAYTW already
	// ends with `<shell> -c` (see _baytWrap). The innerDo gets wrapped
	// in double quotes and `\` / `"` JSON-escaped so the shell receives
	// the whole script as one argument. exec form leaves innerDo bare.
	_cmdsBlock: B={
		t:       _
		cmd:     *"" | string  // empty = target-level wrapper / single-cmd
		innerDo: string         // c.do — no activate prefix
		out: [...]
		let _matchingCmds = [for c in B.t.cmds if B.cmd == "" || c.name == B.cmd {c}]
		let _shell = [
			if len(_matchingCmds) > 0 {_matchingCmds[0].shell},
			"exec",
		][0]
		let _esc1 = strings.Replace(B.innerDo, "\\", "\\\\", -1)
		let _esc2 = strings.Replace(_esc1, "\"", "\\\"", -1)
		let _innerLine = [
			if _shell == "exec" {"{{.BAYTW}} \(B.innerDo)"},
			if _shell != "exec" {"{{.BAYTW}} \"\(_esc2)\""},
		][0]
		out: [
			_innerLine,
			{defer: "{{if not .EXIT_CODE}}\((_fingerprint & {"t": B.t, sub: "hash-stamp", "cmd": B.cmd}).out){{end}}"},
		]
	}

	// Per-target Taskfile files.
	//
	// Single-cmd target: emit one `default:` task that does it all
	// (sources, status, cmds with defer hash-stamp, generates) — the
	// flat shape, identical in spirit to today.
	//
	// Multi-cmd target: emit N internal cmd-tasks (one per cmd, each
	// with own sources/status/cmds + defer for per-cmd stamp) plus a
	// `default:` wrapper that deps on the last cmd and writes the
	// target-level stamp. Cross-project consumers reading the target
	// stamp via the merkle chain see correct invalidation because the
	// target stamp hashes the full union of all srcs.
	files: {
		for n, t in _emit {
			(n): {
				version: "3"

				// Cross-project deps are intentionally omitted from the
				// per-target Taskfile. go-task's `::` prefix inside a
				// nested-included file escapes only to that file's own
				// root (the including project's namespace), not the
				// absolute launch root. Cross-project build ordering is
				// handled by Docker's COPY --from chains in the
				// Dockerfile; in-container stamp files from dep builds
				// are COPYd in and the fingerprint Merkle chain reads
				// them directly. Same-project deps (e.g. `::bayt:setup`)
				// use `::` safely because setup lives in the same
				// Taskfile root as build.
				let _sameProjectDeps = [for d in t.chainedDeps if d.dir == t.dir {"::bayt:\(d.name)"}]

				if len(t.cmds) <= 1 {
					// SINGLE-CMD (or zero-cmd) PATH — flat default
					// task; status hook scoped to target stamp.
					tasks: default: {
						if t.taskfile.desc != _|_ {desc: t.taskfile.desc}
						if t.taskfile.silent {silent: true}
						if len(_sameProjectDeps) > 0 {deps: _sameProjectDeps}
						if len(t.env) > 0 {env: t.env}

						// status: target-level hash-check (no --cmd).
						// fingerprint.nu reads target.srcs from the
						// manifest. Every target gets one: the manifest
						// itself is an implicit src, so even no-cmd
						// targets (doctor, lint, etc.) participate in
						// the merkle chain via a stable stamp.
						status: [(_fingerprint & {"t": t, sub: "hash-check"}).out]

						if len(t.cmds) == 1 {
							let _c = t.cmds[0]
							// BAYTW absorbs the cache.nu wrapper + activate
							// suffix; the cmd line reads as `{{.BAYTW}} <do>`
							// so the user's actual command stays unobscured.
							vars: BAYTW: (_baytWrap & {"t": t}).out
							cmds: (_cmdsBlock & {"t": t, "innerDo": _c.do}).out
						}

						if t.taskfile.run != _|_ && t.taskfile.run == "always" {
							run: "always"
						}
						if len(t.taskfile.preconditions) > 0 {
							preconditions: t.taskfile.preconditions
						}
					}
				}

				if len(t.cmds) > 1 {
					// MULTI-CMD PATH — one internal task per cmd,
					// chained via deps in priority order; default
					// wrapper holds shared bits and writes the
					// target-level stamp. Per-cmd tasks use --cmd to
					// scope status/stamp to their own srcs.
					let _last = t.cmds[len(t.cmds)-1].name

					tasks: default: {
						if t.taskfile.desc != _|_ {desc: t.taskfile.desc}
						if t.taskfile.silent {silent: true}
						deps: list.Concat([_sameProjectDeps, [_last]])
						// Wrapper writes the target-level stamp (full
						// union of all srcs). Cross-project consumers
						// read this. The defer block runs only when
						// every per-cmd task succeeded, so the target
						// stamp accurately reflects "all cmds passed."
						cmds: [
							{defer: "{{if not .EXIT_CODE}}\((_fingerprint & {"t": t, sub: "hash-stamp"}).out){{end}}"},
						]
						if t.taskfile.run != _|_ && t.taskfile.run == "always" {
							run: "always"
						}
						if len(t.taskfile.preconditions) > 0 {
							preconditions: t.taskfile.preconditions
						}
					}

					tasks: {
						for i, _c in t.cmds {
							(_c.name): {
								internal: true
								// Deps chain: each cmd-task depends on the
								// previous one (priority-ordered). The
								// first cmd has no intra-target dep.
								if i > 0 {
									deps: [t.cmds[i-1].name]
								}
								if len(t.env) > 0 {env: t.env}
								// Per-cmd BAYTW carries `--cmd <name>` so
								// each cmd-subtask's cache lookup scopes
								// to its own srcs/outs slice.
								vars: BAYTW: (_baytWrap & {"t": t, "cmd": _c.name}).out
								status: [(_fingerprint & {"t": t, sub: "hash-check", "cmd": _c.name}).out]
								generates: [".task/bayt/\(t.name).\(_c.name).hash"]
								cmds: (_cmdsBlock & {"t": t, "cmd": _c.name, "innerDo": _c.do}).out
							}
						}
					}
				}
			}
		}
	}

	// Two emitted Taskfiles, layered for stability + ergonomics:
	//
	//   - `<project.dir>/Taskfile.yml`  (the host-facing root) carries
	//     ONE structural include — `bayt: ./.bayt/Taskfile.yml` — plus
	//     any cross-project sibling project roots (`workspaceroot:`,
	//     etc.) needed so absolute refs `:<proj>:bayt:<target>` resolve.
	//     This file's content only changes when the cross-project dep
	//     set changes (rare); a normal source edit doesn't touch it,
	//     keeping the Docker layer that COPYs it durable across edits.
	//
	//   - `<project.dir>/.bayt/Taskfile.yml`  (the bayt namespace)
	//     carries one include per emitted target. Its content changes
	//     only when the target set changes (essentially never), so the
	//     Docker layer that COPYs it is even more durable. No cross-
	//     project includes here — those live in the root so absolute
	//     refs land at a single, well-known root scope (the same one
	//     whether `task` is launched on the host from project root or
	//     from the in-container Dockerfile RUN).
	//
	// All includes carry `optional: true` so a Docker stage that COPYs
	// only the per-target Taskfile fragment for its own target (per-
	// target cache isolation) doesn't crash on missing siblings.
	//
	// `dir:` on each include matters: go-task interprets an included
	// file's `sources:` / `generates:` relative to the include's dir,
	// not the included file's. Anchoring at the project root keeps
	// globs (`.output/**/*`) resolving correctly.

	// root — at <project.dir>/Taskfile.yml. Single bayt include + any
	// cross-project sibling roots. Sibling-project includes target the
	// other project's project-root Taskfile.yml (NOT its .bayt/Taskfile.yml)
	// so the address chain `:<proj>:bayt:<target>` traverses through the
	// other project's own bayt include, mirroring the local structure.
	root: {
		version: "3"
		let _relRootFromProjectDir = strings.Repeat("../", G._m._depth)
		let _baytInclude = {
			bayt: {
				taskfile: "./.bayt/Taskfile.yml"
				dir:      "./"
				optional: true
			}
		}
		let _crossIncludes = {
			for dep in G._m.projectManifest.crossProjectDirs {
				let _depName = [if dep == "" {"workspaceroot"}, strings.Replace(dep, "/", "_", -1)][0]
				let _depPath = [if dep != "" {"\(dep)/"}, ""][0]
				(_depName): {
					taskfile: "\(_relRootFromProjectDir)\(_depPath)Taskfile.yml"
					dir:      "\(_relRootFromProjectDir)\(_depPath)"
					optional: true
				}
			}
		}
		includes: _baytInclude & _crossIncludes
	}

	// bayt_root — at <project.dir>/.bayt/Taskfile.yml. One include per
	// emitted target, pointing at the per-target file. Target includes
	// live here (not at root) so editing one target's Taskfile
	// fragment doesn't churn the project-root Taskfile.yml that's
	// COPY'd into every docker stage.
	bayt_root: {
		version: "3"
		let _localIncludes = {
			for n, _ in _emit {
				(n): {
					taskfile: "./Taskfile.\(n).yaml"
					dir:      "../"
					optional: true
				}
			}
		}
		if len(_localIncludes) > 0 {
			includes: _localIncludes
		}
	}
}
