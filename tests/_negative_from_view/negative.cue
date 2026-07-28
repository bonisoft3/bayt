// A synthetic view as a FROM base must fail schema validation
// (#dockerfile.from.ref): the views are scratch packaging stages, so the
// inheriting stage would come up with no toolchain.
package negative_from_view

import bayt "github.com/bonisoft3/bayt/core:bayt"

_p: bayt.#project & {
	name: "nfv"
	dir:  "nfv"
	targets: {
		"setup": {cmd: "builtin": do: "true", dockerfile: bayt.nubox}
		"build": {
			cmd: "builtin": do: "true"
			dockerfile: {from: ref: ":setup:bayt"}
		}
	}
}

project: _p
