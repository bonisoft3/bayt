// A compose file includes only what its target depends on, so a wait on a
// peer outside its deps names a service the file never loads.
package negative_wait_without_dep

import bayt "github.com/bonisoft3/bayt/core:bayt"

_p: bayt.#project & {
	name: "neg"
	dir:  "neg"
	targets: {
		database: {
			entrypoint: do: "postgres"
			dockerfile: from: name: "postgres:18"
			compose: {}
		}
		crud: {
			entrypoint: {do: "postgrest", after: database: "started"}
			dockerfile: from: name: "postgrest/postgrest:v12"
			compose: {}
		}
	}
}
out: (bayt.#dockerComposeGen & {project: _p, depManifests: {}}).compose
