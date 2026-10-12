// A published container port defaulting to the host port a host process binds
// would bind it twice; generation names both instead.
package negative_publish_host_clash

import bayt "github.com/bonisoft3/bayt/core:bayt"

_p: bayt.#project & {
	name: "neg"
	dir:  "neg"
	targets: {
		web: {
			cmd: "builtin": do: "true"
			dockerfile: bayt.busybox
			expose: http: {port: 8080, publish: true, host: 9000}
			compose: {}
		}
		admin: {
			entrypoint: do: "admin"
			expose: http: port: 9000
		}
	}
}
out: (bayt.#dockerComposeGen & {project: _p, depManifests: {}}).compose
