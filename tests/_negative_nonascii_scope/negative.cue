// A scope outside the OCI tag charset drives the segment's budget below zero,
// because the budget counts bytes and the slice counts runes. #cacheTagFit's
// lower bound on `max` is what stands between that and an `index out of range`
// inside SliceRunes.
//
// Nothing legal reaches here — a multi-byte rune is not a valid tag character —
// so this is the bound's only way to fire, and a bound that cannot fire reads
// as decoration.
package negative_nonascii_scope

import (
	bayt "github.com/bonisoft3/bayt/core:bayt"
	"strings"
)

out: bayt.#project & {
	dir: "neg"
	bake: cache: {type: "registry", registry: "reg.example/p", scope: strings.Repeat("é", 30)}
	targets: "build": {
		srcs: globs: ["src/**"]
		cmd: "builtin": do: "true"
		dockerfile: bayt.busybox
	}
}
