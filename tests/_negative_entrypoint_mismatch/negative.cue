// A Dockerfile entrypoint other than the sugar's would run one process in the
// container and another on the host.
package negative_entrypoint_mismatch

import bayt "github.com/bonisoft3/bayt/core:bayt"

_p: bayt.#project & {
	name: "neg"
	dir:  "neg"
	targets: crud: {
		entrypoint: do: "postgrest"
		dockerfile: {
			from: name: "postgrest/postgrest:v12"
			entrypoint: ["/docker-entrypoint.sh"]
		}
	}
}
out: (bayt.#dockerComposeGen & {project: _p, depManifests: {}}).dockerfiles
