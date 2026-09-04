// `do` is emitted into `RUN` verbatim, so a newline in a `then` entry ends
// the instruction and leaves the remaining lines parsed as Dockerfile —
// `unknown instruction: MAKE`. Multi-step is spelled as multiple entries,
// which join with `&&`.
//
// Paired with tests/_positive_preamble, as above.
package negative_then_multiline

import apt "github.com/bonisoft3/bayt/distros/apt"

out: (apt.#install & {pkgs: ["curl"], then: ["set -e\nmake"]}).out
