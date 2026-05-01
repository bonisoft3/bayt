// gen_vscode.cue — per-target vscode task entry emission.
//
// Every entry shells out to `task <name>:<name>`. That hands work-
// avoidance + dep resolution off to the Taskfile pipeline (go-task's
// `status:` hook calls fingerprint.nu — see #taskfileGen), so vscode
// task runs are sub-second when inputs are unchanged instead of
// re-invoking the builder directly.
//
// For targets with a `vscode` block but no `taskfile` block (rare —
// a pure-compose or pure-skaffold target), we fall back to direct
// cmd invocation with the `activate` prefix.
//
// tasks.json has no native include mechanism, so we don't write it
// directly. Per-target entries are emitted to .bayt/vscode.<target>.json
// (named after the generator, not after vscode's tasks.json — the file
// can't be included into tasks.json anyway, so we keep the bayt.<target>
// / vscode.<target> family naming consistent). The user concatenates
// them into .vscode/tasks.json and `sayt lint` flags drift. Only
// `build` and `test` targets are emitted — other targets (setup,
// integrate, release, ...) don't fit vscode's build/test workflow and
// don't belong in the IDE's run/build menu.
package bayt

import "strings"

#vscodeGen: G={
	project: #project
	depManifests:   {[string]: _}

	_m: (#manifestGen & {project: G.project, depManifests: G.depManifests})

	// Build/test only — and only if they declared a vscode block.
	_emit: {for n, t in G._m.files if t.vscode != _|_ if (n == "build" || n == "test") {(n): t}}

	// Direct-cmd fallback for vscode-only targets (no taskfile block).
	// Priority-sorted rules are joined with `&&` so vscode runs them
	// in order, stopping on first failure — matches go-task semantics.
	_directCmd: {
		t: _
		out: string
		let _bodies = [for c in t.cmds {
			[if len(t.activate) > 0 {"\(t.activate) \(c.do)"}, c.do][0]
		}]
		out: [if len(_bodies) > 0 {strings.Join(_bodies, " && ")}, "true"][0]
	}

	// The vscode command for a target:
	//   - `task bayt:<n>`  if the target emits a Taskfile (workflow-like)
	//   - direct cmd       otherwise (rare)
	// `bayt:<n>` resolves through the project-root Taskfile.yml's
	// single `bayt:` include into .bayt/Taskfile.yml's per-target
	// include, then to the per-target file's `default:` task. One
	// namespace, no double-target addresses.
	_command: {
		t: _
		out: string
		out: [if t.taskfile != _|_ {"task bayt:\(t.name)"}, (_directCmd & {"t": t}).out][0]
	}

	// Windows override pulled from cmd.builtin.vscode.windows, if set.
	// Only applies when we're using the direct-cmd path; `task` runs
	// identically on all platforms.
	_windowsCmd: {
		t: _
		out: {
			hasOverride: bool
			command?:    string
		}
		let _c = [if t.cmds[0] != _|_ {t.cmds[0]}, {}][0]
		let _has = _c.vscode != _|_ && _c.vscode.windows != _|_ && _c.vscode.windows.command != _|_
		out: {
			hasOverride: _has
			if _has {
				command: _c.vscode.windows.command
			}
		}
	}

	// Per-target task entry. Each emitted file at .bayt/vscode.<target>.json
	// contains a single tasks.json-shaped record (version + tasks array
	// of one). The user concatenates these into .vscode/tasks.json and
	// `sayt lint` warns on drift (vscode tasks.json has no native
	// include mechanism, so we don't overwrite the user's file).
	files: {
		for n, t in _emit {
			let _cmd = (_command & {"t": t}).out
			let _wc = (_windowsCmd & {"t": t}).out
			let _useTask = t.taskfile != _|_
			(n): {
				version: "2.0.0"
				tasks: [{
					label: [
						if t.vscode.label != _|_ {t.vscode.label},
						if t.vscode.label == _|_ {"\(t.project) \(n)"},
					][0]
					type:    "shell"
					command: _cmd
					if !_useTask && _wc.hasOverride {
						windows: command: _wc.command
					}
					options: cwd: "${workspaceFolder}/\(t.dir)"
					if t.vscode.group != _|_ {
						group: t.vscode.group
					}
					if t.vscode.detail != _|_ {
						detail: t.vscode.detail
					}
					if len(t.vscode.dependsOn) > 0 {
						dependsOn:    t.vscode.dependsOn
						dependsOrder: t.vscode.dependsOrder
					}
					let _pm = [
						if t.cmds[0] != _|_ && t.cmds[0].vscode != _|_ && t.cmds[0].vscode.problemMatcher != _|_ {
							t.cmds[0].vscode.problemMatcher
						},
						if true {[]},
					][0]
					if len(_pm) > 0 {
						problemMatcher: _pm
					}
				}]
			}
		}
	}
}
