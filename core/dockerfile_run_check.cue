// dockerfile_run_check.cue — pins the `dockerfile.do` RUN-only axis: a
// cmd with only `dockerfile.do` renders a Dockerfile RUN but no go-task.
package bayt

import "strings"

_dr1: #project & {
	name: "dr1"
	dir:  "dr1"
	targets: {
		"deps": {
			taskfile: {}
			dockerfile: from: name: "alpine"
			cmd: "resolve": {do: "resolve-here", shell: "sh"}
			// RUN-only: no base `do`, so no task; the RUN carries its own
			// network:none independent of resolve's RUN.
			cmd: "materialize": {
				priority: 1
				dockerfile: {do: "materialize-here", shell: "sh", network: "none"}
			}
		}
	}
}

// Dockerfile: both cmds render as RUNs; the RUN-only materialize keeps
// its own `--network=none`.
_dr1_dc:   (#dockerComposeGen & {project: _dr1, depManifests: {}})
_dr1_body: _dr1_dc.dockerfiles.deps
_dr1_has_resolve:     strings.Contains(_dr1_body, "resolve-here") & true
_dr1_has_materialize: strings.Contains(_dr1_body, "materialize-here") & true
_dr1_materialize_net: strings.Contains(_dr1_body, "--network=none") & true

// Taskfile: the RUN-only cmd is NOT a task. One task cmd (resolve) →
// single-cmd `default:` path, so `tasks` has no key but `default`. A
// `materialize` task (or a multi-cmd wrapper) would violate this closed
// constraint and fail the check.
_dr1_tf: (#taskfileGen & {project: _dr1, depManifests: {}})
_dr1_tf: files: deps: tasks: {[!="default"]: _|_}

// Secret recovery and teardown must surround Task, not disappear when RUNs become incremental.
_dr2: #project & {
	name: "dr2"
	dir: "dr2"
	activate: ""
	targets: check: {
		taskfile: incremental: false
		dockerfile: {
			from: name: "alpine"
			incremental: true
			secrets: token: environment: "TOKEN"
		}
		cmd: builtin: {
			do: "echo leaf-command"
			shell: "sh"
			dockerfile: {
				network: "host"
				inject: {
					secrets: [{id: "token", var: contents: "TOKEN"}]
					steps: [{pre: "echo setup-marker", post: "echo teardown-marker"}]
				}
			}
		}
	}
}
_dr2_body: (#dockerComposeGen & {project: _dr2, depManifests: {}}).dockerfiles.check
_dr2_secret: strings.Contains(_dr2_body, "--mount=type=secret,id=token") & true
_dr2_export: strings.Contains(_dr2_body, "export TOKEN=") & true
_dr2_setup: strings.Contains(_dr2_body, "echo setup-marker") & true
_dr2_teardown: strings.Contains(_dr2_body, "trap 'echo teardown-marker' EXIT") & true
_dr2_network: strings.Contains(_dr2_body, "--network=host") & true
_dr2_task: strings.Contains(_dr2_body, "task -t .bayt/Taskfile.yml bayt:check") & true
_dr2_not_inline: strings.Contains(_dr2_body, "echo leaf-command") & false
_dr2_staged: strings.Contains(_dr2_body, "COPY .bayt/Taskfile.yml") & true
_dr2_leaf: (#taskfileGen & {project: _dr2, depManifests: {}}).files.check.tasks.default.cmds & ["sh -c \"echo leaf-command\""]
