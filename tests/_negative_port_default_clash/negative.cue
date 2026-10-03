// Two ports defaulting to one number would bind it twice when launched.
package negative_port_default_clash

import bayt "github.com/bonisoft3/bayt/core:bayt"

_p: bayt.#project & {
	name: "neg"
	dir:  "neg"
	targets: {
		web: {
			expose: http: {port: 8000, env: "PORT", host: 3300}
			entrypoint: do: "web"
		}
		admin: {
			expose: http: {port: 8001, env: "PORT", host: 3300}
			entrypoint: do: "admin"
		}
	}
}
out: (bayt.#processComposeGen & {project: _p, depManifests: {}}).file
