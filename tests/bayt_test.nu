#!/usr/bin/env nu
# bayt_test.nu — run the bayt CUE test suite.
#
# Invoke from plugins/bayt/; every path below is relative to it. main()
# names the suites it runs.
#
# `cue vet` is lenient about some schema-incomplete errors, so we use
# `cue eval` which is strict. Exit non-zero if any expectation diverges.

def eval-pass [label: string, files: list<string>]: nothing -> int {
	let r = (do { ^cue eval ...$files } | complete)
	if $r.exit_code == 0 {
		print $"  PASS  ($label)"
		0
	} else {
		print $"  FAIL  ($label) exit=($r.exit_code)"
		print $r.stderr
		1
	}
}

def eval-fail [label: string, files: list<string>]: nothing -> int {
	let r = (do { ^cue eval ...$files } | complete)
	if $r.exit_code != 0 {
		print $"  PASS  ($label) exit=($r.exit_code) as expected"
		0
	} else {
		print $"  FAIL  ($label) expected non-zero exit, got 0"
		1
	}
}

# Missing required fields are INCOMPLETE (not a conflict), which plain
# `cue eval` tolerates — `cue export` rejects them, and export is what
# `bayt generate` pass-2 actually runs.
def export-fail [label: string, files: list<string>]: nothing -> int {
	let r = (do { ^cue export ...$files } | complete)
	if $r.exit_code != 0 {
		print $"  PASS  ($label) exit=($r.exit_code) as expected"
		0
	} else {
		print $"  FAIL  ($label) expected non-zero exit, got 0"
		1
	}
}

# _dedup-x-bake guards: dedup only inside x-bake and only for pure
# scalar items (a dropped mapping-item head re-attaches its continuation
# to the previous item); blank lines and cross-field duplicates survive.
def dedup-suite []: nothing -> int {
	use ../core/generate.nu [_dedup-x-bake]
	let diamond = "services:\n  s:\n    build:\n      x-bake:\n        cache-from:\n          - a=1\n          - a=1\n\n          - a=1\n        cache-to:\n          - a=1\n    command:\n      - -v\n      - -v\n"
	let got = (_dedup-x-bake $diamond)
	let want = "services:\n  s:\n    build:\n      x-bake:\n        cache-from:\n          - a=1\n\n        cache-to:\n          - a=1\n    command:\n      - -v\n      - -v\n"
	let mapping = "x-bake:\n  contexts:\n    - id: one\n    - id: one\n      src: /p2\n"
	if $got == $want and (_dedup-x-bake $mapping) == $mapping and (_dedup-x-bake $want) == $want {
		print "  PASS  x-bake dedup (scalar-only, blank-safe, idempotent)"
		0
	} else {
		print $"  FAIL  x-bake dedup\n($got)"
		1
	}
}

def main [] {
	# Check files use the `_check.cue` suffix (not `_test.cue`) because
	# Package dirs, not file lists — new gen_*/_check files join the
	# suite by existing. CUE's package import already excludes
	# `_test.cue` (non-test mode) and `.cue.pending` (extension).
	# cue rejects absolute paths for package args — keep these relative.
	let core = ["./core/"]
	# stacks/sayt holds the sayt-verb conventions + standard sayt.gradle
	# / sayt.pnpm / sayt.pnpmWorkspace mappings; sibling stacks (gradle,
	# pnpm, mise) hold pure toolchain concepts.
	let sayt = ["./stacks/sayt/"]
	let neg  = ["./tests/_negative/"]
	let neg_add = ["./tests/_negative_add/"]
	let neg_view = ["./tests/_negative_from_view/"]
	let neg_ci_srcs = ["./tests/_negative_ci_srcs/"]
	# The preamble invariant is a type, not a convention: a copy arm that
	# names a sibling target must not evaluate.
	let neg_preamble = ["./tests/_negative_preamble_ref/"]
	let neg_preamble_empty = ["./tests/_negative_preamble_empty/"]
	# Both projected inline — the shape a consumer writes, and the one an
	# optional scalar `then?` would not have caught.
	let neg_then_empty = ["./tests/_negative_then_empty/"]
	let neg_then_multiline = ["./tests/_negative_then_multiline/"]
	let neg_unpinned = ["./tests/_negative_unpinned_zypper/"]
	let neg_unpinned_lock = ["./tests/_negative_unpinned_lock/"]
	let pos_ci_srcs = ["./tests/_positive_ci_srcs/"]
	# Consumer-side proof that a distros fragment unifies into both the
	# preamble arm and #cmd.dockerfile, the way a project composes it.
	let pos_preamble = ["./tests/_positive_preamble/"]

	mut failed = 0
	print "positive suites"
	$failed = $failed + (eval-pass "core bayt" $core)
	$failed = $failed + (dedup-suite)
	$failed = $failed + (eval-pass "stacks/sayt" $sayt)
	$failed = $failed + (eval-pass "ci `:X:bayt` with `:X:srcs` must pass" $pos_ci_srcs)
	$failed = $failed + (eval-pass "distros fragment in both positions" $pos_preamble)
	print "negative suites"
	$failed = $failed + (eval-fail "A→B→A cycle must fail" $neg)
	$failed = $failed + (export-fail "remote add without checksum must fail" $neg_add)
	$failed = $failed + (eval-fail "synthetic view as FROM base must fail" $neg_view)
	$failed = $failed + (eval-fail "ci `:X:bayt` without `:X:srcs` must fail" $neg_ci_srcs)
	$failed = $failed + (eval-fail "preamble copy arm with a target ref must fail" $neg_preamble)
	$failed = $failed + (export-fail "preamble entry naming no arm must fail" $neg_preamble_empty)
	$failed = $failed + (eval-fail "an empty `then` entry must fail" $neg_then_empty)
	$failed = $failed + (eval-fail "a multi-line `then` entry must fail" $neg_then_multiline)
	$failed = $failed + (eval-fail "an unpinned zypper package must fail" $neg_unpinned)
	$failed = $failed + (eval-fail "an unpinned zypper lock entry must fail" $neg_unpinned_lock)

	if $failed > 0 {
		print $"($failed) failure\(s\)"
		exit 1
	}
	print "all tests passed"
}
