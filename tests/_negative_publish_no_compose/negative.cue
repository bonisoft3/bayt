// A published port on a target with no compose service would write an overlay
// service holding only `ports`, which compose refuses to load; generation names
// the port instead.
package negative_publish_no_compose

import bayt "github.com/bonisoft3/bayt/core:bayt"

_p: bayt.#project & {
	name: "neg"
	dir:  "neg"
	targets: web: {
		entrypoint: do: "web"
		expose: http: {port: 8080, env: "PORT", publish: true}
	}
}
out: (bayt.#dockerComposeGen & {project: _p, depManifests: {}}).compose
