// Only `env` is rewritten for the host, so a peer named in the command would
// reach for a compose hostname there; generation asks for it through env.
package negative_command_names_peer

import bayt "github.com/bonisoft3/bayt/core:bayt"

_p: bayt.#project & {
	name: "neg"
	dir:  "neg"
	targets: {
		crud: {
			expose: http: {port: 3000, env: "PORT"}
			entrypoint: do: "postgrest"
		}
		check: entrypoint: {do: "deno run check.ts http://crud:3000/x", shell: "sh"}
	}
}
out: (bayt.#processComposeGen & {project: _p, depManifests: {}}).file
