// A peer compose does not run — no compose block — leaves a container's wait on
// it unanswerable: an undefined or scale-0 service in depends_on.
package negative_container_waits_host

import bayt "github.com/bonisoft3/bayt/core:bayt"

_p: bayt.#project & {
	name: "neg"
	dir:  "neg"
	targets: {
		migrate: entrypoint: do: "migrate"
		crud: {
			deps: [":migrate"]
			entrypoint: {do: "postgrest", after: migrate: "completed"}
			dockerfile: from: name: "postgrest/postgrest:v12"
			compose: {}
		}
	}
}
out: (bayt.#dockerComposeGen & {project: _p, depManifests: {}}).compose
