// gen_vscode.cue — per-target vscode task entry emission.
//
// Entries carry the raw engine cmd (activate-prefixed; non-exec
// shells wrapped as `<shell> -c "…"`): the IDE loop wants the engine
// directly — its own incrementality, no gate stamps, no dep walk
// (run setup once first). OS cmd arms emit as vscode-native per-task
// overrides (windows/linux/osx); target env emits as options.env.
// The gated run stays a terminal away: `task -t .bayt/Taskfile.yml
// bayt:<n>`.
//
// tasks.json has no native include mechanism, so we don't write it
// directly. Per-target entries are emitted to .bayt/vscode.<target>.json;
// the user concatenates them into .vscode/tasks.json and `sayt lint`
// warns on drift. Only `build` and `test` targets are emitted — other
// targets don't fit vscode's build/test workflow.
package bayt

import (
	"strings"
)

#vscodeGen: G={
	project:      #project
	depManifests: {[string]: _}

	_m: (#manifestGen & {project: G.project, depManifests: G.depManifests})

	// Build/test only — with a vscode block and at least one host cmd
	// (RUN-only targets have nothing an IDE task could run).
	_emit: {
		for n, t in G._m.files
		if t.vscode != _|_
		if (n == "build" || n == "test")
		if len([for c in t.cmds if c.do != _|_ {c}]) > 0 {(n): t}
	}

	// bayt OS axis → vscode task-override key.
	_vsKey: {windows: "windows", linux: "linux", darwin: "osx"}

	// A cmd's effective (do, shell) for an OS arm ("" = generic).
	_eff: F={
		c:  _
		os: string
		let _o = [if F.os != "" if F.c[F.os] != _|_ {F.c[F.os]}, {}][0]
		do:    [if _o.do != _|_ {_o.do}, F.c.do][0]
		shell: [if _o.shell != _|_ {_o.shell}, F.c.shell][0]
	}

	// One OS arm as a vscode command block. A single exec cmd emits a
	// flat command string; anything else emits `command: "<act><shell>",
	// args: ["-c", body]` — the args array survives vtr's command-string
	// splitting, so the body needs no outer quote-escaping. Multi-cmd
	// bodies chain per-cmd lines with &&, each line honoring its own
	// shell (non-exec lines nest as `<shell> -c "…"`); the joiner shell
	// is sh, pwsh on windows.
	_arm: A={
		act:  string
		cmds: [...]
		os:   string
		let _effs = [for c in A.cmds {(_eff & {"c": c, "os": A.os})}]
		let _one = len(_effs) == 1
		// [if..][0] guard, not direct indexing in conditions — CUE's
		// && doesn't short-circuit.
		let _first = [if _one {_effs[0]}, {do: "", shell: ""}][0]
		out: [
			if _one && _first.shell == "exec" {{command: "\(A.act)\(_first.do)"}},
			if _one {{command: "\(A.act)\(_first.shell)", args: ["-c", _first.do]}},
			{
				command: "\(A.act)\([if A.os == "windows" {"pwsh"}, "sh"][0])"
				args: ["-c", strings.Join([for e in _effs {
					[
						if e.shell == "exec" {e.do},
						"\(e.shell) -c \"\((#shellQuote & {in: e.do}).out)\"",
					][0]
				}], " && ")]
			},
		][0]
	}

	files: {
		for n, t in _emit {
			(n): {
				let _act = [if len(t.activate) > 0 {"\(t.activate) "}, ""][0]
				let _cmds = [for c in t.cmds if c.do != _|_ {c}]
				version: "2.0.0"
				tasks: [{
					label: n
					type:  "shell"
					(_arm & {act: _act, cmds: _cmds, os: ""}).out
					// An OS override emits when any cmd declares that
					// arm; multi-cmd targets always get a windows arm
					// (the posix joiner shell is sh).
					for os, key in _vsKey
					if len([for c in _cmds if c[os] != _|_ {c}]) > 0 || (os == "windows" && len(_cmds) > 1) {
						(key): (_arm & {act: _act, cmds: _cmds, "os": os}).out
					}
					options: {
						cwd: "${workspaceFolder}/\(t.dir)"
						if len(t.env) > 0 {env: t.env}
					}
					if t.vscode.group != _|_ {
						group: t.vscode.group
					}
				}]
			}
		}
	}
}
