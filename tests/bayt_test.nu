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

def export-fail-msg [label: string, files: list<string>, msg: string]: nothing -> int {
	let r = (do { ^cue export ...$files } | complete)
	if $r.exit_code != 0 and ($r.stderr | str contains $msg) {
		print $"  PASS  ($label)"
		0
	} else {
		print $"  FAIL  ($label) exit=($r.exit_code), expected a failure naming: ($msg)"
		print $r.stderr
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

# Non-zero is not enough when the point of a rule is the error it names: an
# unrelated break in the fixture keeps a bare eval-fail green while the
# message regresses to something that locates nothing.
def eval-fail-msg [label: string, files: list<string>, msg: string]: nothing -> int {
	let r = (do { ^cue eval ...$files } | complete)
	if $r.exit_code != 0 and ($r.stderr | str contains $msg) {
		print $"  PASS  ($label) exit=($r.exit_code) as expected"
		0
	} else {
		print $"  FAIL  ($label) exit=($r.exit_code), stderr lacks ($msg)"
		print $r.stderr
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
	let go   = ["./stacks/go/"]
	let mise = ["./stacks/mise/"]
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
	let neg_reserved = ["./tests/_negative_reserved_name/"]
	let neg_nonascii = ["./tests/_negative_nonascii_scope/"]
	let neg_undeclared_port = ["./tests/_negative_undeclared_port/"]
	let neg_entrypoint_cmd = ["./tests/_negative_entrypoint_cmd/"]
	let neg_port_var_clash = ["./tests/_negative_port_var_clash/"]
	let neg_container_waits_host = ["./tests/_negative_container_waits_host/"]
	let neg_healthy_no_probe = ["./tests/_negative_healthy_no_probe/"]
	let neg_entrypoint_mismatch = ["./tests/_negative_entrypoint_mismatch/"]
	let neg_port_default_clash = ["./tests/_negative_port_default_clash/"]
	let neg_command_names_peer = ["./tests/_negative_command_names_peer/"]
	let neg_compose_command = ["./tests/_negative_compose_command/"]
	let neg_fixed_port_clash = ["./tests/_negative_fixed_port_clash/"]
	let neg_bare_host_moving = ["./tests/_negative_bare_host_moving/"]
	let neg_env_names_container_peer = ["./tests/_negative_env_names_container_peer/"]
	let neg_bare_names_container = ["./tests/_negative_bare_names_container/"]
	let neg_unreadable_duration = ["./tests/_negative_unreadable_duration/"]
	let neg_wait_without_dep = ["./tests/_negative_wait_without_dep/"]
	let neg_url_without_port = ["./tests/_negative_url_without_port/"]
	let neg_compose_entrypoint_string = ["./tests/_negative_compose_entrypoint_string/"]
	let neg_command_names_port = ["./tests/_negative_command_names_port/"]
	let neg_rooted_unnamed = ["./tests/_negative_rooted_unnamed/"]
	let neg_discriminator = ["./tests/_negative_discriminator/"]
	let pos_ci_srcs = ["./tests/_positive_ci_srcs/"]
	# Consumer-side proof that a distros fragment unifies into both the
	# preamble arm and #cmd.dockerfile, the way a project composes it.
	let pos_preamble = ["./tests/_positive_preamble/"]

	mut failed = 0
	print "positive suites"
	$failed = $failed + (eval-pass "core bayt" $core)
	$failed = $failed + (dedup-suite)
	$failed = $failed + (eval-pass "stacks/sayt" $sayt)
	$failed = $failed + (eval-pass "stacks/go" $go)
	$failed = $failed + (eval-pass "stacks/mise" $mise)
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
	$failed = $failed + (eval-fail-msg "a target name colliding with a synthetic must fail, naming the key" $neg_reserved "_reservedNames.thing_srcs")
	$failed = $failed + (eval-fail-msg "a scope outside the tag charset must hit the budget bound, not SliceRunes" $neg_nonascii "out of bound >=18")
	$failed = $failed + (eval-fail-msg "a peer port the peer does not expose has no host spelling" $neg_undeclared_port "names a port of crud that crud does not expose")
	$failed = $failed + (eval-fail-msg "an entrypoint beside a Dockerfile CMD would take the CMD as arguments" $neg_entrypoint_cmd "entrypoint and dockerfile.cmd together")
	$failed = $failed + (eval-fail-msg "two ports collapsing to one host variable must fail, naming both" $neg_port_var_clash "web.expose.admin_http and web-admin.expose.http both map to WEB_ADMIN_HTTP_PORT")
	$failed = $failed + (eval-fail-msg "a container waiting on a host-only process must fail" $neg_container_waits_host "waits on migrate, which has no container to wait on")
	$failed = $failed + (eval-fail-msg "a health wait on a process with no probe would hang, so it must fail" $neg_healthy_no_probe "waits for worker to be healthy, but worker has no readiness probe")
	$failed = $failed + (eval-fail-msg "a Dockerfile entrypoint other than the sugar's must fail" $neg_entrypoint_mismatch "dockerfile.entrypoint and entrypoint name different processes")
	$failed = $failed + (eval-fail-msg "two ports on one default must fail, naming both" $neg_port_default_clash "both default to port 3300")
	$failed = $failed + (eval-fail-msg "a command naming a peer must fail, asking for env" $neg_command_names_peer "its command names crud; pass the address through env")
	$failed = $failed + (eval-fail-msg "a compose command beside the entrypoint must fail" $neg_compose_command "entrypoint and compose.command together")
	$failed = $failed + (eval-fail-msg "two fixed ports on one number must fail" $neg_fixed_port_clash "auth.expose.http and ticker.expose.http both default to port 9999")
	$failed = $failed + (eval-fail-msg "a bare host whose peer's ports move must fail" $neg_bare_host_moving "DB_HOST names database alone, whose ports move on the host")
	$failed = $failed + (eval-fail-msg "a value naming a container-only peer must fail" $neg_env_names_container_peer "PG_URI names a port of database that database does not expose on the host")
	$failed = $failed + (eval-fail-msg "a bare value naming a container-only service must fail" $neg_bare_names_container "REDIS_HOST names redis, which does not run on the host")
	$failed = $failed + (eval-fail-msg "an unreadable duration must fail, naming it" $neg_unreadable_duration "30 s is not a duration")
	$failed = $failed + (eval-fail-msg "a container wait outside the deps must fail, naming the dep" $neg_wait_without_dep "waits on database without depending on it")
	$failed = $failed + (eval-fail-msg "a peer URL without a port must fail" $neg_url_without_port "URL names web as a host the rewrite cannot place")
	$failed = $failed + (eval-fail-msg "a string compose entrypoint beside the sugar must fail" $neg_compose_entrypoint_string "write compose.entrypoint as a list")
	$failed = $failed + (eval-fail-msg "a command naming a peer's exposed port must fail" $neg_command_names_port "its command names redis by a port it exposes")
	$failed = $failed + (export-fail-msg "a project rooted at itself must name itself" $neg_rooted_unnamed "out.name: incomplete value string")
	$failed = $failed + (eval-fail-msg "a malformed discriminator must fail" $neg_discriminator "out.discriminator")

	if $failed > 0 {
		print $"($failed) failure\(s\)"
		exit 1
	}
	print "all tests passed"
}
