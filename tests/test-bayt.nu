#!/usr/bin/env nu
# test-bayt.nu — run the bayt CUE test suite.
#
# Invoke from the bayt plugin root (plugins/bayt/) or pass `--root`.
# The runner resolves source files under <root>/bayt/ and stack /
# negative cue packages relative to <root>/.
#
# Positive suites:
#   - core bayt (schema + images + rulemap + unification)
#   - stacks/gradle consumers
#   - stacks/pnpm   consumers
# Negative suite:
#   - A→B→A cycle must fail CUE evaluation.
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

def main [] {
	# Run from the plugin root: plugins/bayt/. Core files live under
	# ./bayt/; stacks + tests are relative packages.
	#
	# Check files use the `_check.cue` suffix (not `_test.cue`) because
	# `cue eval` silently excludes `_test.cue` files in non-test mode.
	# Files carrying the `.cue.pending` extension are check files
	# that haven't been migrated to the current schema yet — CUE
	# skips them during package import so they don't break stack
	# evaluation. Rename them back to `.cue` as each one is updated.
	let core = [
		"./bayt/bayt.cue"
		"./bayt/mapaslist.cue"
		"./bayt/listutils.cue"
		"./bayt/images.cue"
		"./bayt/images.lock.cue"
		"./bayt/capabilities.cue"
		"./bayt/gen_bayt.cue"
		"./bayt/gen_taskfile.cue"
		"./bayt/gen_compose.cue"
		"./bayt/gen_skaffold.cue"
		"./bayt/gen_vscode.cue"
		"./bayt/gen_bake.cue"
		"./bayt/emitter.cue"
		# Smoke check: minimal project struct + Tests aggregator.
		"./bayt/bayt_smoke_check.cue"
		"./bayt/images_check.cue"
		"./bayt/capabilities_check.cue"
		"./bayt/skaffold_vscode_bake_check.cue"
		"./bayt/emitter_check.cue"
		"./bayt/docker_compose_check.cue"
		"./bayt/taskfile_check.cue"
		"./bayt/bayt_cycle_check.cue"
		"./bayt/bayt_cycle_deep_check.cue"
	]
	# cue rejects absolute paths for package args — keep these relative.
	# stacks/sayt holds the sayt-verb conventions + standard sayt.gradle
	# / sayt.pnpm / sayt.pnpmWorkspace mappings; sibling stacks (gradle,
	# pnpm, mise) hold pure toolchain concepts.
	let sayt = ["./stacks/sayt/"]
	let neg  = ["./tests/_negative/"]

	mut failed = 0
	print "positive suites"
	$failed = $failed + (eval-pass "core bayt" $core)
	$failed = $failed + (eval-pass "stacks/sayt" $sayt)
	print "negative suites"
	$failed = $failed + (eval-fail "A→B→A cycle must fail" $neg)

	if $failed > 0 {
		print $"($failed) failure\(s\)"
		exit 1
	}
	print "all tests passed"
}
