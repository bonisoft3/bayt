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
	let pos_ci_srcs = ["./tests/_positive_ci_srcs/"]

	mut failed = 0
	print "positive suites"
	$failed = $failed + (eval-pass "core bayt" $core)
	$failed = $failed + (eval-pass "stacks/sayt" $sayt)
	$failed = $failed + (eval-pass "ci `:X:bayt` with `:X:srcs` must pass" $pos_ci_srcs)
	print "negative suites"
	$failed = $failed + (eval-fail "A→B→A cycle must fail" $neg)
	$failed = $failed + (export-fail "remote add without checksum must fail" $neg_add)
	$failed = $failed + (eval-fail "synthetic view as FROM base must fail" $neg_view)
	$failed = $failed + (eval-fail "ci `:X:bayt` without `:X:srcs` must fail" $neg_ci_srcs)

	if $failed > 0 {
		print $"($failed) failure\(s\)"
		exit 1
	}
	print "all tests passed"
}
