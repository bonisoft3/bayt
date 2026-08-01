// A `:X:bayt` dep without its `:X:srcs` sibling must fail (ci._pairedSrcs
// in stacks/sayt/sayt.cue carries why). `:integrate:srcs` is present so
// this isolates the pairing rule from ci's "at least one :srcs" rule.
package negative_ci_srcs

import (
	bayt "github.com/bonisoft3/bayt/core:bayt"
	sayt "github.com/bonisoft3/bayt/stacks/sayt"
)

_p: bayt.#project & {
	name: "ncs"
	dir:  "ncs"
	targets: {
		"integrate": {cmd: "builtin": do: "true", srcs: globs: ["it/**"], dockerfile: bayt.nubox}
		"test": {cmd: "builtin": do: "true", srcs: globs: ["test/**"], dockerfile: bayt.nubox}
		"dindbox": sayt.dindbox
		"ci":      sayt.ci & {deps: [":integrate:srcs", ":integrate:bayt", ":test:bayt"]}
	}
}

project: _p
