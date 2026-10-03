// A DB_HOST rewritten to loopback beside a DB_PORT holding no port the peer
// exposes would connect where the peer does not listen: its port moves.
package negative_bare_host_moving

import bayt "github.com/bonisoft3/bayt/core:bayt"

_p: bayt.#project & {
	name: "neg"
	dir:  "neg"
	targets: {
		database: {
			expose: pg: {port: 5432, env: "PGPORT"}
			entrypoint: do: "postgres"
		}
		crud: entrypoint: {
			do: "postgrest"
			env: {DB_HOST: "database", DB_PORT: "5433"}
		}
	}
}
out: (bayt.#processComposeGen & {project: _p, depManifests: {}}).file
