// A peer that runs only as a container has no host process to rewrite to, so
// naming it would reach a loopback port nothing binds.
package negative_env_names_container_peer

import bayt "github.com/bonisoft3/bayt/core:bayt"

_p: bayt.#project & {
	name: "neg"
	dir:  "neg"
	targets: {
		database: {
			expose: pg: {port: 5432, env: "PGPORT"}
			dockerfile: from: name: "postgres:18"
			compose: {}
		}
		crud: entrypoint: {
			do: "postgrest"
			env: PG_URI: "postgres://database:5432/app"
		}
	}
}
out: (bayt.#processComposeGen & {project: _p, depManifests: {}}).file
