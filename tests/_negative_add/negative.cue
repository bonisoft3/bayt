// _negative_add/negative.cue — remote dockerfile.add WITHOUT a
// checksum, must fail cue eval: the DSL has no unpinned ADD (see
// #dockerfile.#add's closed disjunction).
//
// Kept in its own subdirectory (package `baytaddnegative`) so the main
// bayt package still vets clean. tests/test-bayt.nu runs `cue export`
// on this directory (missing required fields are incomplete, which
// only export rejects) and asserts exit != 0. The binding is a regular
// field for the same reason: export must walk it.
package baytaddnegative

import "github.com/bonisoft3/bayt/core:bayt"

bad_unpinned: bayt.#project & {
	name: "bad-add"
	dir:  "test/bad-add"
	targets: {
		"release": {
			cmd: "builtin": do: "true"
			dockerfile: {
				from: name: "busybox:musl@sha256:03db190ed4c1ceb1c55d179a0940e2d71d42130636a780272629735893292223"
				add: [{url: "https://example.com/blob", dest: "/blob"}]
			}
		}
	}
}
