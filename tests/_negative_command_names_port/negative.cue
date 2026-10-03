// An exposed port in a command is an address only env is rewritten for, so
// `redis:6379` would reach the host process as a name it cannot resolve.
package negative_command_names_port

import bayt "github.com/bonisoft3/bayt/core:bayt"

_p: bayt.#project & {
	name: "neg"
	dir:  "neg"
	targets: {
		redis: {
			expose: tcp: {port: 6379, env: "PORT"}
			entrypoint: do: "redis-server"
		}
		proxy: entrypoint: do: "proxy --upstream redis:6379"
	}
}
out: (bayt.#processComposeGen & {project: _p, depManifests: {}}).file
