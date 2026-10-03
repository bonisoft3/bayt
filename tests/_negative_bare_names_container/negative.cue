// A service only a container runs has no address on the host, so a whole value
// naming it would reach for a name the host cannot resolve.
package negative_bare_names_container

import bayt "github.com/bonisoft3/bayt/core:bayt"

_p: bayt.#project & {
	name: "neg"
	dir:  "neg"
	targets: {
		redis: {
			dockerfile: from: name: "redis:7"
			compose: {}
		}
		api: entrypoint: {
			do: "api"
			env: REDIS_HOST: "redis"
		}
	}
}
out: (bayt.#processComposeGen & {project: _p, depManifests: {}}).file
