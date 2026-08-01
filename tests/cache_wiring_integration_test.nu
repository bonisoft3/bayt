#!/usr/bin/env nu
# cache_wiring_integration_test.nu — the generated wiring, end to end.
#
# Its sibling cache_cas_integration_test.nu drives cache.nu directly with a
# hand-written manifest, so it proves the backend's wire contract and nothing
# about how a build reaches it. This one runs `task` against a checked-in
# generated Taskfile and asserts the payload travels: emitted manifest →
# BAYTW → `bayt cache run` → CAS → restored outs.
#
# services/hello is the target because it is the tier-1 reference project and
# its `build` is toolchain-free, so this stays a bayt test rather than a rust
# or gradle one. `cache: full: true` there is what makes the assertion sharp:
# on an exact hit the cmd is skipped entirely, so outs appearing in a wiped
# workspace can only have come from the remote.
#
# No docker guard: this is an integration test; it fails if docker is absent.

use std/assert
use ./bazel_remote.nu [start-remote, stop-remote, cas-count]

const hello = (path self | path dirname | path dirname | path dirname | path dirname | path join "services" "hello")
# go-task comes from hello's own .mise.toml, not whatever the host has: its
# version governs how `status:` and `sources:` are evaluated, which is what
# this suite asserts on.

def main [] {
	print "Running cache.nu generated-wiring integration tests...\n"

	# hello's toolchain is not this package's: CI provisions the matrix
	# package (plugins/bayt) and nothing else, and `mise x` will not install
	# a missing tool — it fails with "couldn't exec process".
	let r = (do { cd $hello; ^mise install } | complete)
	if $r.exit_code != 0 {
		error make { msg: $"could not install services/hello toolchain: ($r.stderr)" }
	}

	test_generated_taskfile_stores_and_restores

	print "\nAll cache wiring integration tests passed!"
}

# `task` in the project, with the cache pointed at a throwaway remote. The
# stamp dir is the go-task side of the merkle chain; wiping it is what forces
# `status:` to fail and the cmd line — hence cache.nu — to be reached at all.
def run-task [rc: record]: nothing -> record {
	let result = with-env { BAYT_CACHE_URL: $rc.url } {
		do { cd $hello; ^mise x -- task -t .bayt/Taskfile.yml bayt:build } | complete
	}
	{ stdout: $result.stdout, stderr: $result.stderr, exit: $result.exit_code }
}

def clean []: nothing -> nothing {
	rm -rf ($hello | path join "out")
	rm -rf ($hello | path join ".task")
}

def test_generated_taskfile_stores_and_restores [] {
	print "test generated taskfile stores and restores through the remote..."
	let rc = (start-remote)
	try {
		clean
		let r1 = (run-task $rc)
		assert ($r1.exit == 0) $"first run exit: ($r1.exit) ($r1.stderr)"
		assert (($r1.stdout + $r1.stderr) | str contains "MISS") $"first run should MISS: ($r1.stderr)"
		let produced = ($hello | path join "out" "test.py")
		assert ($produced | path exists) "cmd should produce the payload on a miss"
		let want = (open --raw $produced)

		# The blob must have reached the CAS, not just an /ac/ entry.
		let digest = ($want | hash sha256)
		assert ((cas-count $rc "contains" "miss") > 0) "store should have probed the CAS"

		clean
		let gets_before = (cas-count $rc "get" "hit")
		let r2 = (run-task $rc)
		assert ($r2.exit == 0) $"second run exit: ($r2.exit) ($r2.stderr)"
		assert (($r2.stdout + $r2.stderr) | str contains "HIT") $"second run should HIT: ($r2.stderr)"

		# --full means the cmd did not run, so this payload came off the wire.
		let restored = ($hello | path join "out" "test.py")
		assert ($restored | path exists) "outs should be restored from the remote"
		assert ((open --raw $restored) == $want) "restored payload should be byte-identical"
		assert ((cas-count $rc "get" "hit") > $gets_before) "restore should have fetched the blob from the CAS"
		print "  ok\n"
	} catch { |e| clean; stop-remote $rc; error make { msg: $e.msg } }
	clean
	stop-remote $rc
}
