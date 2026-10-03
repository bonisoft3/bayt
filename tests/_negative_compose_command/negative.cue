// The image's ENTRYPOINT is the sugar's, so a compose command would become its
// arguments: the container would run `postgrest postgrest`.
package negative_compose_command

import bayt "github.com/bonisoft3/bayt/core:bayt"

_p: bayt.#project & {
	name: "neg"
	dir:  "neg"
	targets: crud: {
		entrypoint: do: "postgrest"
		dockerfile: from: name: "postgrest/postgrest:v12"
		compose: command: ["postgrest"]
	}
}
out: (bayt.#dockerComposeGen & {project: _p, depManifests: {}}).compose
