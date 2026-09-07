// A target name colliding with a synthetic puts two services at the same
// qualified name and two Dockerfiles at the same path — the second silently
// wins. #project._reservedNames rejects it.
//
// The driver asserts the error message, not just a non-zero exit: the buried
// form this rule's placement avoids exits non-zero too.
package negative_reserved_name

import bayt "github.com/bonisoft3/bayt/core:bayt"

out: bayt.#project & {
	dir: "neg"
	targets: "thing_srcs": {
		srcs: globs: ["src/**"]
		cmd: "builtin": do: "true"
		dockerfile: bayt.busybox
	}
}
