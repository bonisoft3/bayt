#!/usr/bin/env nu
# cache_cas_integration_test.nu — the bazel-remote backend's wire contract,
# against a real bazel-remote. Its siblings in runtime/cache_test.nu cover
# the local-FS backend, which needs no server.
#
# Client-side skips are asserted through bazel-remote's request counters
# (--enable_endpoint_metrics), not through what ends up on disk: the CAS
# stores one file per content address no matter how many times it is
# uploaded, so disk state cannot tell a skipped upload from a repeated one.
#
# No docker guard: this is an integration test; it fails if docker is absent.

use std/assert
use ./bazel_remote.nu [start-remote, stop-remote, cas-blobs, cas-count, corrupt-blob]

const cache_nu = (path self | path dirname | path dirname | path join "runtime" "cache.nu")

def main [] {
	print "Running cache.nu bazel-remote CAS integration tests...\n"

	test_roundtrip_restores_content
	test_exec_bit_survives_roundtrip
	test_non_exec_bit_is_restored
	test_payload_lands_in_cas
	test_present_blob_is_not_reuploaded
	test_present_file_is_not_refetched
	test_entry_is_not_at_bare_fingerprint_address
	test_unparseable_entry_body_is_a_miss
	test_corrupt_blob_aborts_restore_intact
	test_directory_at_out_path_is_replaced
	test_nested_paths_roundtrip
	test_empty_outs_roundtrips

	print "\nAll cache CAS integration tests passed!"
}

# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------

def make-fixture []: nothing -> record {
	let proj = (mktemp -d)
	"hello\n" | save -f ($proj | path join "input.txt")
	let fix = {
		manifest: ($proj | path join "manifest.json")
		project:  $proj
	}
	{
		name: "test"
		project: "test_proj"
		dir: ""
		srcs: {globs: ["input.txt"], exclude: []}
		outs: {globs: ["out/**/*"], exclude: []}
		state: {globs: []}
		chainedDeps: []
		cmds: []
	} | to json | save -f $fix.manifest
	$fix
}

def run-cache [rc: record, fix: record, cmd: list<string>, --full]: nothing -> record {
	let flags = (if $full { ["--full"] } else { [] })
	let result = with-env { BAYT_CACHE_URL: $rc.url } {
		do { cd $fix.project; ^nu $cache_nu run --manifest $fix.manifest ...$flags -- ...$cmd } | complete
	}
	{ stdout: $result.stdout, stderr: $result.stderr, exit: $result.exit_code }
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

# Baseline wire contract: store on miss, restore byte-identical on hit.
def test_roundtrip_restores_content [] {
	print "test roundtrip restores content..."
	let rc = (start-remote)
	try {
		let fix = (make-fixture)
		let r1 = (run-cache $rc $fix [sh -c "mkdir -p out && echo computed > out/a.txt"])
		assert ($r1.exit == 0) $"first run exit: ($r1.exit) ($r1.stderr)"
		assert ($r1.stderr | str contains "MISS") "first run should MISS"

		# Wipe the workspace payload; a hit must put it back.
		rm -rf ($fix.project | path join "out")
		let r2 = (run-cache $rc $fix [sh -c "exit 0"] --full)
		assert ($r2.exit == 0) $"second run exit: ($r2.exit) ($r2.stderr)"
		assert ($r2.stderr | str contains "HIT") $"second run should HIT: ($r2.stderr)"
		let restored = ($fix.project | path join "out" "a.txt")
		assert ($restored | path exists) "restored file should exist"
		assert ((open --raw $restored | decode utf-8) == "computed\n") "restored content should match"
		print "  ok\n"
	} catch { |e| stop-remote $rc; error make { msg: $e.msg } }
	stop-remote $rc
}

# A cached binary restored without +x fails at exec time, far from here.
def test_exec_bit_survives_roundtrip [] {
	print "test exec bit survives roundtrip..."
	let rc = (start-remote)
	try {
		let fix = (make-fixture)
		let r1 = (run-cache $rc $fix [sh -c "mkdir -p out && printf '#!/bin/sh\necho ran\n' > out/prog && chmod +x out/prog"])
		assert ($r1.exit == 0) $"first run exit: ($r1.exit) ($r1.stderr)"

		rm -rf ($fix.project | path join "out")
		let r2 = (run-cache $rc $fix [sh -c "exit 0"] --full)
		assert ($r2.stderr | str contains "HIT") "should HIT"

		let prog = ($fix.project | path join "out" "prog")
		assert ($prog | path exists) "restored program should exist"
		# Assert the bit, not an exec attempt: a non-executable file raises
		# rather than completing, which would mask the reason.
		let mode = (ls -l $prog | first | get mode)
		assert ($mode | str starts-with "rwx") $"restored program should keep its exec bit, mode is ($mode)"
		print "  ok\n"
	} catch { |e| stop-remote $rc; error make { msg: $e.msg } }
	stop-remote $rc
}

# Payload bytes belong on /cas/, addressed by their own sha256 — that is
# what makes them shareable between entries.
def test_payload_lands_in_cas [] {
	print "test payload lands in CAS addressed by content hash..."
	let rc = (start-remote)
	try {
		let fix = (make-fixture)
		let r1 = (run-cache $rc $fix [sh -c "mkdir -p out && echo payload > out/a.txt"])
		assert ($r1.exit == 0) $"run exit: ($r1.exit) ($r1.stderr)"

		let digest = (open --raw ($fix.project | path join "out" "a.txt") | hash sha256)
		let blobs = (cas-blobs $rc)
		assert (($blobs | any { |b| $b | str starts-with $digest })) $"payload blob ($digest) should be in CAS; found: ($blobs)"
		print "  ok\n"
	} catch { |e| stop-remote $rc; error make { msg: $e.msg } }
	stop-remote $rc
}

# The store path must probe before uploading, so a payload already in the
# CAS is not sent again. Asserted on the server's `contains` counter: the
# CAS would hold one copy either way, so disk state proves nothing here.
def test_present_blob_is_not_reuploaded [] {
	print "test present blob is not re-uploaded..."
	let rc = (start-remote)
	try {
		let fix = (make-fixture)
		let r1 = (run-cache $rc $fix [sh -c "mkdir -p out && echo same-payload > out/a.txt"])
		assert ($r1.exit == 0) $"run 1 exit: ($r1.exit) ($r1.stderr)"
		let hits_before = (cas-count $rc "contains" "hit")

		# Same payload, different srcs => different entry, same blob.
		"changed\n" | save -f ($fix.project | path join "input.txt")
		let r2 = (run-cache $rc $fix [sh -c "mkdir -p out && echo same-payload > out/a.txt"])
		assert ($r2.exit == 0) $"run 2 exit: ($r2.exit) ($r2.stderr)"
		assert ($r2.stderr | str contains "MISS") "changed srcs should MISS"

		let hits_after = (cas-count $rc "contains" "hit")
		assert ($hits_after > $hits_before) $"second store should probe and find the blob present, hits ($hits_before) -> ($hits_after)"
		print "  ok\n"
	} catch { |e| stop-remote $rc; error make { msg: $e.msg } }
	stop-remote $rc
}

# A file the workspace already holds at the right content must not be
# refetched — the restore-side half of content addressing.
def test_present_file_is_not_refetched [] {
	print "test present file is not refetched..."
	let rc = (start-remote)
	try {
		let fix = (make-fixture)
		let r1 = (run-cache $rc $fix [sh -c "mkdir -p out && echo payload > out/a.txt"])
		assert ($r1.exit == 0) $"run 1 exit: ($r1.exit) ($r1.stderr)"
		let gets_before = (cas-count $rc "get" "hit")

		# Workspace left intact, so the hit has nothing to fetch.
		let r2 = (run-cache $rc $fix [sh -c "exit 0"] --full)
		assert ($r2.stderr | str contains "HIT") $"should HIT: ($r2.stderr)"
		let gets_after = (cas-count $rc "get" "hit")
		assert ($gets_after == $gets_before) $"restore should fetch nothing, gets ($gets_before) -> ($gets_after)"
		print "  ok\n"
	} catch { |e| stop-remote $rc; error make { msg: $e.msg } }
	stop-remote $rc
}

# A stale +x on a file stored non-executable must be cleared. The digest
# check skips such a file entirely, so only the mode pass can fix it.
def test_non_exec_bit_is_restored [] {
	print "test non-exec bit is restored..."
	let rc = (start-remote)
	try {
		let fix = (make-fixture)
		let r1 = (run-cache $rc $fix [sh -c "mkdir -p out && echo plain > out/a.txt"])
		assert ($r1.exit == 0) $"run 1 exit: ($r1.exit) ($r1.stderr)"

		^chmod +x ($fix.project | path join "out" "a.txt")
		let r2 = (run-cache $rc $fix [sh -c "exit 0"] --full)
		assert ($r2.stderr | str contains "HIT") "should HIT"
		let mode = (ls -l ($fix.project | path join "out" "a.txt") | first | get mode)
		assert (not ($mode | str starts-with "rwx")) $"exec bit should be cleared, mode is ($mode)"
		print "  ok\n"
	} catch { |e| stop-remote $rc; error make { msg: $e.msg } }
	stop-remote $rc
}

# The entry must not occupy the bare fingerprint address. That slot is what
# any client derives from the manifest alone, whatever entry format it
# speaks; a reader handed a body it cannot parse cannot tell that from a
# legitimate hit, and answering "hit" there restores nothing while --full
# skips the build outright. Keeping our entry off that address is what makes
# a mismatched reader miss instead.
def test_entry_is_not_at_bare_fingerprint_address [] {
	print "test entry is not at bare fingerprint address..."
	let rc = (start-remote)
	try {
		let fix = (make-fixture)
		let r1 = (run-cache $rc $fix [sh -c "mkdir -p out && echo payload > out/a.txt"])
		assert ($r1.exit == 0) $"run 1 exit: ($r1.exit) ($r1.stderr)"
		let key = ($r1.stderr | parse -r '(?<k>[a-f0-9]{64})' | get k | first)

		let code = (do { ^curl -s -o /dev/null -w "%{http_code}" $"($rc.url)/ac/($key)" } | complete).stdout
		assert ($code == "404") $"bare fingerprint address should hold nothing, got ($code)"
		print "  ok\n"
	} catch { |e| stop-remote $rc; error make { msg: $e.msg } }
	stop-remote $rc
}

# An entry body this client cannot parse is a miss, never a hit: a hit that
# restores nothing is indistinguishable from success, and under --full it
# skips the build.
def test_unparseable_entry_body_is_a_miss [] {
	print "test unparseable entry body is a miss..."
	let rc = (start-remote)
	try {
		let fix = (make-fixture)
		let r1 = (run-cache $rc $fix [sh -c "mkdir -p out && echo payload > out/a.txt"])
		assert ($r1.exit == 0) $"run 1 exit: ($r1.exit) ($r1.stderr)"
		let key = ($r1.stderr | parse -r '(?<k>[a-f0-9]{64})' | get k | first)

		# Overwrite the entry this client actually reads.
		let addr = ($"bayt-ac-v2:($key)" | hash sha256)
		(^curl -s -o /dev/null -X PUT --data-binary "out/a.txt\tZm9v" $"($rc.url)/ac/($addr)") | ignore

		let r2 = (run-cache $rc $fix [sh -c "exit 0"] --full)
		assert ($r2.stderr | str contains "MISS") $"unparseable entry should MISS, got: ($r2.stderr)"
		print "  ok\n"
	} catch { |e| stop-remote $rc; error make { msg: $e.msg } }
	stop-remote $rc
}

# A fetch that fails partway must leave the workspace exactly as it found it:
# the caller treats the failure as a miss and runs the cmd, and the store that
# follows would otherwise publish a mix of restored and stale files under a key
# asserting the payload is complete. (Failing during publish cannot restore the
# prior state, so it clears the outs instead — see bazel-get.)
def test_corrupt_blob_aborts_restore_intact [] {
	print "test corrupt blob aborts restore leaving workspace intact..."
	let rc = (start-remote)
	try {
		let fix = (make-fixture)
		let r1 = (run-cache $rc $fix [sh -c "mkdir -p out && echo alpha > out/a.txt && echo bravo > out/b.txt"])
		assert ($r1.exit == 0) $"run 1 exit: ($r1.exit) ($r1.stderr)"

		corrupt-blob $rc (open --raw ($fix.project | path join "out" "b.txt") | hash sha256)

		rm -rf ($fix.project | path join "out")
		let r2 = (run-cache $rc $fix [sh -c "exit 0"] --full)
		assert ($r2.stderr | str contains "MISS") $"corrupt blob should degrade to MISS: ($r2.stderr)"
		assert (not (($fix.project | path join "out" "a.txt") | path exists)) "sound blob must not be published when a sibling failed"
		print "  ok\n"
	} catch { |e| stop-remote $rc; error make { msg: $e.msg } }
	stop-remote $rc
}

# A directory standing where an out belongs must not swallow the restore.
# POSIX `mv file dir` lands the file inside it and raises nothing, so the
# payload would end up off its declared path while the restore reports a hit —
# and under --full the cmd is skipped, leaving that silently wrong.
def test_directory_at_out_path_is_replaced [] {
	print "test directory standing at an out path is replaced..."
	let rc = (start-remote)
	try {
		let fix = (make-fixture)
		let r1 = (run-cache $rc $fix [sh -c "mkdir -p out && echo payload > out/a.txt"])
		assert ($r1.exit == 0) $"run 1 exit: ($r1.exit) ($r1.stderr)"

		rm -rf ($fix.project | path join "out")
		mkdir ($fix.project | path join "out" "a.txt")
		"blocker\n" | save -f ($fix.project | path join "out" "a.txt" "inner")

		let r2 = (run-cache $rc $fix [sh -c "exit 0"] --full)
		assert ($r2.stderr | str contains "HIT") $"should HIT: ($r2.stderr)"
		let dst = ($fix.project | path join "out" "a.txt")
		assert (($dst | path type) == "file") $"out path should be a file, is ($dst | path type)"
		assert ((open --raw $dst | decode utf-8) == "payload\n") "restored content should match"
		print "  ok\n"
	} catch { |e| stop-remote $rc; error make { msg: $e.msg } }
	stop-remote $rc
}

# Nested directories and multiple files: every other case here is one flat
# file, which would not catch a path-joining or mkdir slip.
def test_nested_paths_roundtrip [] {
	print "test nested paths roundtrip..."
	let rc = (start-remote)
	try {
		let fix = (make-fixture)
		let r1 = (run-cache $rc $fix [sh -c "mkdir -p out/a/b/c && echo one > out/a/b/c/deep.txt && echo two > out/top.txt"])
		assert ($r1.exit == 0) $"run 1 exit: ($r1.exit) ($r1.stderr)"

		rm -rf ($fix.project | path join "out")
		let r2 = (run-cache $rc $fix [sh -c "exit 0"] --full)
		assert ($r2.stderr | str contains "HIT") "should HIT"
		let deep = ($fix.project | path join "out" "a" "b" "c" "deep.txt")
		assert ($deep | path exists) "nested file should restore"
		assert ((open --raw $deep | decode utf-8) == "one\n") "nested content should match"
		assert ((open --raw ($fix.project | path join "out" "top.txt") | decode utf-8) == "two\n") "sibling content should match"
		print "  ok\n"
	} catch { |e| stop-remote $rc; error make { msg: $e.msg } }
	stop-remote $rc
}

# A target with no outs still participates in the merkle chain: the entry
# records "this ran on these inputs". Both backends must agree, or --full
# behaves differently depending on which one is configured.
def test_empty_outs_roundtrips [] {
	print "test empty outs roundtrips..."
	let rc = (start-remote)
	try {
		let fix = (make-fixture)
		{
			name: "test"
			project: "test_proj"
			dir: ""
			srcs: {globs: ["input.txt"], exclude: []}
			outs: {globs: [], exclude: []}
			state: {globs: []}
			chainedDeps: []
			cmds: []
		} | to json | save -f $fix.manifest

		let r1 = (run-cache $rc $fix [sh -c "exit 0"])
		assert ($r1.exit == 0) $"first run exit: ($r1.exit) ($r1.stderr)"
		assert ($r1.stderr | str contains "MISS") "first run should MISS"

		let r2 = (run-cache $rc $fix [sh -c "exit 0"])
		assert ($r2.exit == 0) $"second run exit: ($r2.exit) ($r2.stderr)"
		assert ($r2.stderr | str contains "HIT") $"empty-outs entry should HIT on second run: ($r2.stderr)"
		print "  ok\n"
	} catch { |e| stop-remote $rc; error make { msg: $e.msg } }
	stop-remote $rc
}
