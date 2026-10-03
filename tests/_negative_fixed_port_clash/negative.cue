// Ports with no variable cannot be moved, so two on one number collide every
// time both launch.
package negative_fixed_port_clash

import bayt "github.com/bonisoft3/bayt/core:bayt"

_p: bayt.#project & {
	name: "neg"
	dir:  "neg"
	targets: {
		auth: {
			expose: http: port: 9999
			entrypoint: do: "auth"
		}
		ticker: {
			expose: http: port: 9999
			entrypoint: do: "ticker"
		}
	}
}
out: (bayt.#processComposeGen & {project: _p, depManifests: {}}).file
