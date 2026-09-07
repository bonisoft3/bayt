// reserved_names_check — the reserved-target-name alternation, arm by arm.
//
// #project._reservedNames applies the pattern as a constraint, so one fixture
// that authors one bad name proves only that the rule is wired up: dropping the
// `_outs` or `_bayt` arm, or the underscore that keeps `playbayt` legal, leaves
// that fixture red for the wrong reason and every other name unchecked. Matching
// the pattern directly is concrete in both directions.
package bayt

_rn_rejects: {
	for n in ["bayt", "release_srcs", "release_outs", "release_bayt"] {
		(n): true & (n =~ _reservedNamePattern)
	}
}

// The underscore and the trailing anchor are the whole rule: without either,
// these collide with nothing yet would be rejected.
_rn_allows: {
	for n in ["playbayt", "outside", "mysrcs", "baytish", "bayt-run", "foo_srcs_bar", "lib_bayt_helper"] {
		(n): true & (n !~ _reservedNamePattern)
	}
}
