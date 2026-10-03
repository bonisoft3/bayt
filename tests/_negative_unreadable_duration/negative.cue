// An unreadable duration read as anything at all would silently shrink a
// probe's grace window and kill a slow start; generation names it instead.
package negative_unreadable_duration

import bayt "github.com/bonisoft3/bayt/core:bayt"

_p: bayt.#project & {
	name: "neg"
	dir:  "neg"
	targets: crud: bayt.healthcheck.http & {
		healthcheck: {url: "http://127.0.0.1:3001/ready", start_period: "30 s"}
		entrypoint: do: "postgrest"
		dockerfile: from: name: "postgrest/postgrest:v12"
	}
}
out: (bayt.#processComposeGen & {project: _p, depManifests: {}}).file
