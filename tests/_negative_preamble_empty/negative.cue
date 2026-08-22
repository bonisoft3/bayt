// A preamble entry must pick an arm. One that names none is INCOMPLETE
// rather than a conflict, so `cue eval` tolerates it and only `cue export`
// rejects — and export is what generate's pass-2 runs. Covered with
// export-fail for the same reason as _negative_add.
//
// Without this the arms could stop being mutually exhaustive and the only
// symptom would be a generate-time error nobody had ever seen.
package negative_preamble_empty

import bayt "github.com/bonisoft3/bayt/core:bayt"

_p: bayt.#project & {
	name: "npe"
	dir:  "npe"
	targets: "build": {
		cmd: "builtin": do: "true"
		dockerfile: bayt.nubox & {
			defaultPreamble: "armless": {priority: -5}
		}
	}
}

project: _p
