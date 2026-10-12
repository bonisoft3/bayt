// Two services publishing under one host variable would bind one host port
// whichever value a caller sets; generation names both instead.
package negative_publish_clash

import bayt "github.com/bonisoft3/bayt/core:bayt"

_p: bayt.#project & {
	name: "neg"
	dir:  "neg"
	targets: {
		web: {
			cmd: "builtin": do: "true"
			dockerfile: bayt.busybox
			expose: http: {port: 8080, publish: environment: "WEB_HOST_PORT"}
			compose: {}
		}
		admin: {
			cmd: "builtin": do: "true"
			dockerfile: bayt.busybox
			expose: http: {port: 8081, publish: environment: "WEB_HOST_PORT"}
			compose: {}
		}
	}
}
out: (bayt.#dockerComposeGen & {project: _p, depManifests: {}}).compose
