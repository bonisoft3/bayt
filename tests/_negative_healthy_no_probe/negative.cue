// process-compose waits forever for health a process has no probe to report,
// so the stack would hang instead of failing.
package negative_healthy_no_probe

import bayt "github.com/bonisoft3/bayt/core:bayt"

_p: bayt.#project & {
	name: "neg"
	dir:  "neg"
	targets: {
		worker: entrypoint: do: "worker"
		check: entrypoint: {do: "check", after: worker: "healthy"}
	}
}
out: (bayt.#processComposeGen & {project: _p, depManifests: {}}).file
