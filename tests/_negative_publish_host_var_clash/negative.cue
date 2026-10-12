// A published container port moving by the variable a host process's port
// moves by would bind wherever that variable says, twice; generation names both.
package negative_publish_host_var_clash

import bayt "github.com/bonisoft3/bayt/core:bayt"

_p: bayt.#project & {
	name: "neg"
	dir:  "neg"
	targets: {
		api: {
			cmd: "builtin": do: "true"
			dockerfile: bayt.busybox
			expose: http: {port: 8080, publish: environment: "WEB_HTTP_PORT"}
			compose: {}
		}
		web: {
			entrypoint: do: "web"
			expose: http: {port: 9000, env: "PORT"}
		}
	}
}
out: (bayt.#dockerComposeGen & {project: _p, depManifests: {}}).compose
