#!/usr/bin/env nu
# test-bayt.nu — run the bayt CUE test suite.
#
# Invoke from the bayt plugin root (plugins/bayt/) or pass `--root`.
# The runner resolves source files under <root>/core/ and stack /
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
	# ./core/; stacks + tests are relative packages.
	#
	# Check files use the `_check.cue` suffix (not `_test.cue`) because
	# `cue eval` silently excludes `_test.cue` files in non-test mode.
	# Files carrying the `.cue.pending` extension are check files
	# that haven't been migrated to the current schema yet — CUE
	# skips them during package import so they don't break stack
	# evaluation. Rename them back to `.cue` as each one is updated.
	let core = [
		"./core/bayt.cue"
		"./core/mapaslist.cue"
		"./core/listutils.cue"
		"./core/images.cue"
		"./core/images.lock.cue"
		"./core/capabilities.cue"
		"./core/gen_bayt.cue"
		"./core/gen_taskfile.cue"
		"./core/gen_compose.cue"
		"./core/gen_skaffold.cue"
		"./core/gen_vscode.cue"
		"./core/gen_bake.cue"
		"./core/emitter.cue"
		# Smoke check: minimal project struct + Tests aggregator.
		"./core/bayt_smoke_check.cue"
		"./core/images_check.cue"
		"./core/capabilities_check.cue"
		"./core/skaffold_vscode_bake_check.cue"
		"./core/emitter_check.cue"
		"./core/docker_compose_check.cue"
		"./core/taskfile_check.cue"
		"./core/bayt_cycle_check.cue"
		"./core/bayt_cycle_deep_check.cue"
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
