// An ENTRYPOINT beside a CMD in the same Dockerfile takes the CMD as its
// arguments — Docker resets only the CMD a base image carries — so the
// process would run as `postgrest postgrest`.
package negative_entrypoint_cmd

import bayt "github.com/bonisoft3/bayt/core:bayt"

_p: bayt.#project & {
	name: "neg"
	dir:  "neg"
	targets: crud: {
		entrypoint: do: "postgrest"
		dockerfile: {
			from: name: "postgrest/postgrest:v12"
			cmd: ["postgrest"]
		}
	}
}
out: (bayt.#dockerComposeGen & {project: _p, depManifests: {}}).dockerfiles
