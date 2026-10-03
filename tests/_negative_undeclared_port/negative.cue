// A value naming a peer port the peer does not expose has no host spelling:
// left as written it would reach for a compose hostname the host cannot
// resolve, so generation names the value and the peer instead.
package negative_undeclared_port

import bayt "github.com/bonisoft3/bayt/core:bayt"

_p: bayt.#project & {
	name: "neg"
	dir:  "neg"
	targets: {
		crud: {
			expose: http: port: 3000
			entrypoint: do: "postgrest"
		}
		check: entrypoint: {
			do: "check"
			env: ADMIN_URL: "http://crud:3001/ready"
		}
	}
}
out: (bayt.#processComposeGen & {project: _p, depManifests: {}}).file
