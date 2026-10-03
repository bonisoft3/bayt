// Compose splits a string entrypoint by shell words, which no comparison here
// repeats faithfully; beside the sugar it must be a list.
package negative_compose_entrypoint_string

import bayt "github.com/bonisoft3/bayt/core:bayt"

_p: bayt.#project & {
	name: "neg"
	dir:  "neg"
	targets: crud: {
		entrypoint: do: "postgrest"
		dockerfile: from: name: "postgrest/postgrest:v12"
		compose: entrypoint: "postgrest"
	}
}
out: (bayt.#dockerComposeGen & {project: _p, depManifests: {}}).compose
