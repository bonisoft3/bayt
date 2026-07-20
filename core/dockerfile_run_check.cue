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
