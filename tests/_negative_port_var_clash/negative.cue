// Two ports whose names collapse to one host variable would bind the same
// port whichever value a caller sets; generation names both instead.
package negative_port_var_clash

import bayt "github.com/bonisoft3/bayt/core:bayt"

_p: bayt.#project & {
	name: "neg"
	dir:  "neg"
	targets: {
		web: {
			expose: admin_http: {port: 8001, env: "ADMIN_PORT"}
			entrypoint: do: "web"
		}
		"web-admin": {
			expose: http: {port: 8000, env: "PORT"}
			entrypoint: do: "admin"
		}
	}
}
out: (bayt.#processComposeGen & {project: _p, depManifests: {}}).file
