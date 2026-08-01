// The passing twin of _negative_ci_srcs. Without it that suite could go
// vacuously green: eval-fail accepts any non-zero exit, so unrelated
// breakage in ci would keep it passing while the pairing rule stopped
// being exercised.
//
// Two deps here are load-bearing against a rewrite of `_pairedSrcs` that
// matches the view as a trailing string rather than the third segment:
// a bare `:bayt`, and a srcs sibling spelled with the explicit project
// segment. Both would then demand a sibling nothing emits.
package positive_ci_srcs

import (
	bayt "github.com/bonisoft3/bayt/core:bayt"
	sayt "github.com/bonisoft3/bayt/stacks/sayt"
)

_p: bayt.#project & {
	name: "pcs"
	dir:  "pcs"
	targets: {
		"integrate": {cmd: "builtin": do: "true", srcs: globs: ["it/**"], dockerfile: bayt.nubox}
		"test": {cmd: "builtin": do: "true", srcs: globs: ["test/**"], dockerfile: bayt.nubox}
		"dindbox": sayt.dindbox
		"ci":      sayt.ci & {deps: [":integrate:srcs", "pcs:test:srcs", ":bayt", ":integrate:bayt", ":test:bayt"]}
	}
}

project: _p
