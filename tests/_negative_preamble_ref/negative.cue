// The preamble's invariant is enforced by the arms, not by convention:
// a copy arm cannot name a sibling target. Without this the invariant is
// only documentation — and a ref-arm copy in the preamble reintroduces
// exactly the invalidation the region exists to prevent, since the
// referenced target is source-derived.
//
// Paired with tests/_positive_preamble, which must stay green: eval-fail
// accepts any non-zero exit, so unrelated breakage would keep this
// vacuously passing.
package negative_preamble_ref

import bayt "github.com/bonisoft3/bayt/core:bayt"

_p: bayt.#project & {
	name: "npr"
	dir:  "npr"
	targets: {
		"build": {cmd: "builtin": do: "true", dockerfile: bayt.nubox}
		"late": {
			cmd: "builtin": do: "true"
			dockerfile: bayt.nubox & {
				defaultPreamble: "bad": copy: {
					from: {ref: ":build"}
					srcs: ["/out"]
					dst:  "/out"
				}
			}
		}
	}
}

project: _p
