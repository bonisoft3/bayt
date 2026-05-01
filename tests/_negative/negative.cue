// bayt_cycle_negative/negative.cue — INTENTIONAL cycle, must fail cue eval.
//
// Kept in its own subdirectory (package `baytcyclenegative`) so the main
// bayt package still vets clean. The runner nu test/cycle-negative.nu
// invokes `cue eval` on this file and asserts exit != 0.
//
// If this file ever passes, either CUE cycle detection regressed or our
// schema has grown an exploitable loophole — stop and investigate.
package baytcyclenegative

import "bonisoft.org/plugins/bayt/bayt"

// Direct A → B → A loop.
_bad_selfcycle: bayt.#project & {
	name: "bad-cycle"
	dir:  "test/bad"
	targets: {
		"a": bayt.build & {deps: [targets.b]}
		"b": bayt.build & {deps: [targets.a]}
	}
}
