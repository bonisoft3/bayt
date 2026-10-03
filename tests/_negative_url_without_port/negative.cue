// A peer as a URL host with no port has no `<peer>:<port>` to rewrite, so it
// would reach the host process as a name it cannot resolve.
package negative_url_without_port

import bayt "github.com/bonisoft3/bayt/core:bayt"

_p: bayt.#project & {
	name: "neg"
	dir:  "neg"
	targets: {
		web: {
			expose: http: {port: 80, env: "PORT"}
			entrypoint: do: "web"
		}
		check: entrypoint: {
			do: "check"
			env: URL: "http://web/health"
		}
	}
}
out: (bayt.#processComposeGen & {project: _p, depManifests: {}}).file
