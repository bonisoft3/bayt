#!/usr/bin/env nu
# Tests for cache.nu — local-FS content-addressable cache.
#
# Each test uses a fresh tempdir for both the project workspace and
# the cache root (BAYT_CACHE_DIR override) so there's zero leakage
# between tests. Synthetic manifests are minimal — just enough to
# exercise resolve-manifest's path-walking + compute-hash's input set.
# Real bayt manifests carry many more fields; cache.nu only consumes
# srcs (via fingerprint.nu) and outs (for restore/store), so the
# minimal shape suffices.
#
# Run with: nu cache_test.nu (from this directory).

use std/assert

const cache_nu = (path self | path dirname | path join "cache.nu")

def main [] {
	print "Running cache.nu tests...\n"

	test_miss_runs_cmd_and_stores
	test_hit_restores_and_runs_cmd
	test_hit_full_restores_without_running
	test_disabled_bypasses_entirely
	test_failed_cmd_does_not_pollute_cache
	test_gc_evicts_oldest_to_budget
	test_gc_noop_under_budget
	test_unresolvable_manifest_bypasses
	test_warm_hit_restores_similar_entry
	test_no_similar_flag_no_warm_restore
	test_debug_log_records_decisions
	test_similarity_picks_closest_among_candidates

	print "\nAll cache.nu tests passed!"
}

def make-fixture []: nothing -> record {
	let proj = (mktemp -d)
	let cache = (mktemp -d)
	"hello\n" | save -f ($proj | path join "input.txt")
	let fix = {
		manifest: ($proj | path join "manifest.json")
		input:    ($proj | path join "input.txt")
		output:   ($proj | path join "output.txt")
		project:  $proj
		cache:    $cache
	}
	# Standard manifest for the fixture: srcs = input.txt, outs =
	# output.txt, no deps, no cmds. Tests that need a different shape
	# overwrite $fix.manifest after this returns.
	{
		name: "test"
		project: "test_proj"
		dir: ""
		srcs: {globs: ["input.txt"], exclude: []}
		outs: {globs: ["output.txt"], exclude: []}
		chainedDeps: []
		cmds: []
	} | to json | save -f $fix.manifest
	$fix
}

# Run cache.nu against the fixture's manifest. cmd is passed as a
# single list to avoid nushell's flag parser eating cmd flags like -c
# before they reach cache.nu's `--`.
def run-cache [
	fix: record,
	cmd: list<string>,
	--full,
	--similar,
	--debug: string = "",        # path for BAYT_CACHE_DEBUG
	--user: string = "",         # override $USER for this invocation
	--branch: string = "",       # set BAYT_CACHE_BRANCH
]: nothing -> record {
	let flags = ([
		(if $full    { ["--full"]    } else { [] }),
		(if $similar { ["--similar"] } else { [] }),
	] | flatten)
	mut envs = { BAYT_CACHE_DIR: $fix.cache }
	if ($debug | is-not-empty)  { $envs = ($envs | merge { BAYT_CACHE_DEBUG: $debug }) }
	if ($user | is-not-empty)   { $envs = ($envs | merge { USER: $user }) }
	if ($branch | is-not-empty) { $envs = ($envs | merge { BAYT_CACHE_BRANCH: $branch }) }
	let result = with-env $envs {
		do { cd $fix.project; ^nu $cache_nu run --manifest $fix.manifest ...$flags -- ...$cmd } | complete
	}
	{stdout: $result.stdout, exit: $result.exit_code}
}

# Read the BAYT_CACHE_DEBUG log — JSON lines, one per cache.nu run.
def read-debug-log [path: string]: nothing -> list {
	if not ($path | path exists) { return [] }
	open --raw $path | lines | where { |l| ($l | is-not-empty) } | each { |l| $l | from json }
}

# (1) cold cache → cmd runs → outs land in cache + workspace.
def test_miss_runs_cmd_and_stores [] {
	print "test miss runs cmd and stores outs..."
	let fix = (make-fixture)

	let r = (run-cache $fix [sh -c "echo computed > output.txt && echo MARKER"])
	assert ($r.exit == 0) $"unexpected exit: ($r.exit)"
	assert ($r.stdout | str contains "MARKER") "cmd stdout should reach caller on miss"
	assert (($fix.output | path exists)) "output.txt should be written by the cmd"

	# Cache directory has at least one shard with one entry.
	let entries = (glob ($fix.cache | path join "*/*") | where { |p| ($p | path type) == "dir" })
	assert ((($entries | length) >= 1)) "expected at least one cache entry after miss"
	print "  ok\n"
}

# (2) warm cache → cmd runs again, but cache pre-restored outs first.
# Verified by deleting output.txt before the second invocation: if
# cache.nu didn't restore it, the cmd would either fail or have
# nothing to find. With restore, the file is present when cmd starts.
def test_hit_restores_and_runs_cmd [] {
	print "test hit restores outs and still runs cmd..."
	let fix = (make-fixture)

	# Populate.
	run-cache $fix [sh -c "echo first > output.txt"]
	# Wipe the workspace output.
	rm $fix.output
	assert (not ($fix.output | path exists)) "precondition: output cleared"

	# Re-run with a cmd that ASSERTS the output is already there (cache
	# restored it before cmd ran), then OVERWRITES it (cmd executed).
	let r = (run-cache $fix [sh -c "test -f output.txt && echo SAW_RESTORED && echo modified > output.txt"])
	assert ($r.exit == 0) $"unexpected exit: ($r.exit)"
	assert ($r.stdout | str contains "SAW_RESTORED") "cmd should see restored output before running"
	assert ((open $fix.output | str trim) == "modified") "cmd should have run and overwritten output"
	print "  ok\n"
}

# (3) warm cache + --full → cmd is NOT invoked, outs come from cache.
def test_hit_full_restores_without_running [] {
	print "test hit + --full restores without running cmd..."
	let fix = (make-fixture)

	run-cache $fix [sh -c "echo from-cache > output.txt"]
	rm $fix.output

	# A failing cmd that would print something on execution. If --full
	# works, neither the failure nor the print is observed.
	let r = (run-cache $fix [sh -c "echo SHOULD_NOT_RUN; exit 99"] --full)
	assert ($r.exit == 0) $"--full should short-circuit success regardless of cmd: ($r.exit)"
	assert (not ($r.stdout | str contains "SHOULD_NOT_RUN")) "cmd should never have run"
	assert ((open $fix.output | str trim) == "from-cache") "output should come from cache, not cmd"
	print "  ok\n"
}

# (4) BAYT_CACHE_ENABLED=false → cmd runs, no cache reads or writes.
def test_disabled_bypasses_entirely [] {
	print "test BAYT_CACHE_ENABLED=false bypasses cache..."
	let fix = (make-fixture)

	let result = with-env { BAYT_CACHE_DIR: $fix.cache, BAYT_CACHE_ENABLED: "false" } {
		do { cd $fix.project; ^nu $cache_nu run --manifest $fix.manifest -- sh -c "echo bypassed > output.txt" } | complete
	}
	assert ($result.exit_code == 0) "bypass should still propagate cmd exit"
	# No shard dirs created — cache wasn't touched.
	let shards = (glob ($fix.cache | path join "*") | where { |p| ($p | path type) == "dir" })
	assert (($shards | is-empty)) "cache root should remain empty when disabled"
	print "  ok\n"
}

# Build a fake cache dir with N entries of `bytes_each` bytes apiece,
# mtimes set so entry-1 is oldest, entry-N is newest. Returns the cache
# root. Used by gc tests to set up deterministic eviction scenarios.
def make-fake-cache [n: int, bytes_each: int]: nothing -> path {
	let root = (mktemp -d)
	mkdir ($root | path join "ab")
	for i in 1..$n {
		let hash = $"abc($i)defabcdefabcdefabcdefabcdefabcdef"
		let entry = ($root | path join "ab" | path join $hash)
		mkdir ($entry | path join "outs")
		let blob = ($entry | path join "outs" | path join "blob")
		# `truncate -s` is portable enough; macOS ships it via brew or
		# coreutils, BSD also has it. Falls back to dd.
		do { ^truncate -s $bytes_each $blob } | complete | if $in.exit_code != 0 {
			^dd if=/dev/zero of=$blob bs=1 count=$bytes_each err> /dev/null
		}
		# Older index → older mtime. macOS `touch -t YYYYMMDDhhmm`.
		^touch -t $"2025010($i)0000" $entry
	}
	$root
}

# Run cache.nu gc against a synthetic cache, returning the entry hashes
# that survived (sorted).
def gc-survivors [root: path, max_size: int]: nothing -> list<string> {
	with-env { BAYT_CACHE_DIR: $root, BAYT_CACHE_MAX_SIZE: ($max_size | into string) } {
		do { ^nu $cache_nu gc } | complete | ignore
	}
	if not (($root | path join "ab") | path exists) { return [] }
	ls ($root | path join "ab") | get name | each { |p| $p | path basename } | sort
}

# (6) gc must evict oldest-mtime entries first until total ≤ budget.
def test_gc_evicts_oldest_to_budget [] {
	print "test gc evicts oldest entries until under budget..."
	# 5 entries × 1MB ~= 5.2MB on disk (with dir overhead); budget 3MB
	# requires evicting the 3 oldest, leaving abc4 + abc5.
	let root = (make-fake-cache 5 1048576)
	let survivors = (gc-survivors $root 3145728)
	assert (($survivors | length) <= 3) $"too many survivors: ($survivors)"
	# Surviving entries must be the newest by mtime — abc4, abc5 at
	# minimum (we may keep abc3 if disk-overhead math leaves room).
	assert ("abc4defabcdefabcdefabcdefabcdefabcdef" in $survivors) "abc4 (newer) should survive"
	assert ("abc5defabcdefabcdefabcdefabcdefabcdef" in $survivors) "abc5 (newest) should survive"
	assert (not ("abc1defabcdefabcdefabcdefabcdefabcdef" in $survivors)) "abc1 (oldest) should be evicted"
	print "  ok\n"
}

# (7) gc under budget must be a no-op (don't touch anything).
def test_gc_noop_under_budget [] {
	print "test gc no-op when total is under budget..."
	let root = (make-fake-cache 3 1048576)   # ~3.2MB total
	let survivors = (gc-survivors $root 10485760)   # 10MB budget
	assert (($survivors | length) == 3) $"all 3 entries should survive: ($survivors)"
	print "  ok\n"
}

# (9) On exact-match miss, lookup falls back to a similar cached entry
# (same project+target with overlapping inputs / metadata) and
# restores its outs as a warm starting state. The cmd then runs on
# top of that state — not skipped, just given a head start.
def test_warm_hit_restores_similar_entry [] {
	print "test --similar restores closest entry on exact miss..."
	let fix = (make-fixture)

	# First run with input "v1" → caches under K_v1.
	"v1" | save -f $fix.input
	run-cache $fix [sh -c "echo from-v1 > output.txt"] --similar

	let v1_entries = (glob ($fix.cache | path join "*/*") | where { |p| ($p | path type) == "dir" })
	assert ((($v1_entries | length) >= 1)) "v1 entry should be cached"

	# Change input to "v2" → exact-match miss, but the v1 entry shares
	# user/branch/day so similarity > 0. Wipe output.txt first so we
	# can tell whether the warm restore actually placed it back.
	"v2" | save -f $fix.input
	rm $fix.output

	# With --similar, cache.nu finds v1 as the closest entry, restores
	# it, then runs cmd which sees the warm v1 output before producing v2.
	let r = (run-cache $fix [sh -c "test -f output.txt && cat output.txt | tr -d '\\n' && echo ' SAW_WARM' && echo from-v2 > output.txt"] --similar)
	assert ($r.exit == 0) $"unexpected exit: ($r.exit)"
	assert ($r.stdout | str contains "SAW_WARM") "cmd should see warm-restored output before running"
	assert ($r.stdout | str contains "from-v1") "warm restore should have placed v1's output"
	assert ((open $fix.output | str trim) == "from-v2") "cmd should have run and produced v2"

	let final_entries = (glob ($fix.cache | path join "*/*") | where { |p| ($p | path type) == "dir" })
	assert ((($final_entries | length) >= 2)) "v2 entry should now be cached alongside v1"
	print "  ok\n"
}

# (11) BAYT_CACHE_DEBUG appends a structured trace per invocation;
# tests can read it and assert on the actual decisions cache.nu made.
# Verifies the debug record's shape AND that mode/status reflect the
# actual flag combination on each call.
def test_debug_log_records_decisions [] {
	print "test BAYT_CACHE_DEBUG records decisions for inspection..."
	let fix = (make-fixture)
	let log = ($fix.project | path join "debug.jsonl")

	# Three invocations covering MISS / HIT / WARM:
	"v1" | save -f $fix.input
	run-cache $fix [sh -c "echo from-v1 > output.txt"] --debug $log              # MISS run
	run-cache $fix [sh -c "echo from-v1 > output.txt"] --debug $log              # HIT run
	"v2" | save -f $fix.input
	run-cache $fix [sh -c "echo from-v2 > output.txt"] --similar --debug $log   # WARM (similar finds v1)

	let records = (read-debug-log $log)
	assert ((($records | length) == 3)) $"expected 3 records, got: ($records | length)"

	let r1 = ($records | get 0)
	let r2 = ($records | get 1)
	let r3 = ($records | get 2)

	assert ($r1.status == "MISS") $"first run should be MISS, got ($r1.status)"
	assert ($r1.mode == "run")     $"first run mode should be 'run', got ($r1.mode)"

	assert ($r2.status == "HIT")  $"second run should be HIT, got ($r2.status)"
	assert ($r2.mode == "run")    $"second run mode should be 'run', got ($r2.mode)"
	assert ($r2.key == $r1.key)   "exact-hit should reuse the same key"

	assert ($r3.status == "WARM")             $"third run should be WARM, got ($r3.status)"
	assert ($r3.mode == "run+similar")        $"third run mode should be 'run+similar', got ($r3.mode)"
	assert ($r3.key != $r1.key)                "WARM means a different key than the v1 entry"
	assert ($r3.warm_winner_score > 0)         "WARM score must be positive"
	assert ($r3.warm_candidate_count >= 1)     "WARM should report >=1 candidate considered"
	assert ($r3.warm_winner != null)           "WARM winner metadata should be populated"

	print "  ok\n"
}

# (12) When several candidates exist, scoring picks the one with the
# best metadata match. Three entries — A and C have my user/branch,
# B has someone else's — query input doesn't match any entry's
# content, so the difference is purely metadata.
#
# Score breakdown for each candidate (today's entries all share day):
#   A: my user (50) + my branch (30) + day (5) = 85
#   B: day (5)                                 = 5
#   C: my user (50) + my branch (30) + day (5) = 85
# A and C tie on score. The local-similar implementation breaks ties
# by glob order; tests assert "winner.user == me + winner.branch ==
# mine" without depending on which of A/C is picked.
def test_similarity_picks_closest_among_candidates [] {
	print "test similarity picks the closest candidate among many..."
	let fix = (make-fixture)
	let log = ($fix.project | path join "debug.jsonl")

	# Three distinct inputs → three distinct cache keys → three
	# distinct entries.
	"contentA" | save -f $fix.input
	run-cache $fix [sh -c "echo A > output.txt"] --user "me"    --branch "mine"
	"contentB" | save -f $fix.input
	run-cache $fix [sh -c "echo B > output.txt"] --user "other" --branch "theirs"
	"contentC" | save -f $fix.input
	run-cache $fix [sh -c "echo C > output.txt"] --user "me"    --branch "mine"

	# Query with input "Q" — no entry has this content, so exact-match
	# misses and similar fires.
	"contentQ" | save -f $fix.input
	rm -f $log
	run-cache $fix [sh -c "echo new > output.txt"] --user "me" --branch "mine" --similar --debug $log

	let records = (read-debug-log $log)
	assert ((($records | length) == 1)) $"expected 1 record, got ($records | length)"
	let r = ($records | first)

	assert ($r.status == "WARM") $"expected WARM, got ($r.status)"
	assert ($r.warm_candidate_count == 3) $"expected 3 candidates, got ($r.warm_candidate_count)"
	# Winner must have matched our user + branch — A or C, never B.
	assert ($r.warm_winner.user == "me")     $"winner user should be 'me', got ($r.warm_winner.user)"
	assert ($r.warm_winner.branch == "mine") $"winner branch should be 'mine', got ($r.warm_winner.branch)"
	# Score should reflect user 50 + branch 30 + day 5 = 85.
	assert ($r.warm_winner_score >= 85.0) $"winner score should be >=85, got ($r.warm_winner_score)"

	print "  ok\n"
}

# (10) WITHOUT --similar, an exact-miss does NOT restore any warm
# entry — the opt-in semantics matter. Same setup as above; cmd
# should NOT see any pre-existing output.txt.
def test_no_similar_flag_no_warm_restore [] {
	print "test no --similar flag -> no warm restore on miss..."
	let fix = (make-fixture)

	"v1" | save -f $fix.input
	run-cache $fix [sh -c "echo from-v1 > output.txt"]

	"v2" | save -f $fix.input
	rm $fix.output

	# Without --similar: pure miss, cmd runs from a clean workspace.
	let r = (run-cache $fix [sh -c "test ! -f output.txt && echo COLD && echo from-v2 > output.txt"])
	assert ($r.exit == 0) $"unexpected exit: ($r.exit)"
	assert ($r.stdout | str contains "COLD") "without --similar, cmd should see no pre-restored output"
	print "  ok\n"
}

# (8) Unresolvable manifest (file missing, malformed JSON, etc.) must
# bypass the cache, run the cmd raw, propagate its exit code, and
# never write a cache entry. Regression cover for the host-side
# `just sayt build` failure where resolve-manifest's underlying
# `open <manifest>` would error before gradle even ran. The narrower
# "missing literal in srcs" case is now warned + skipped by
# fingerprint.nu's compute-hash itself; bypass is the broader fallback
# for anything resolve-manifest can't make sense of.
def test_unresolvable_manifest_bypasses [] {
	print "test unresolvable manifest bypasses cache..."
	let fix = (make-fixture)
	# Manifest path doesn't exist — resolve-manifest's `open` errors,
	# the try-catch in cache.nu's main run catches it and routes to
	# the bypass branch.
	let bogus_manifest = ($fix.project | path join "does-not-exist.json")

	let result = with-env { BAYT_CACHE_DIR: $fix.cache } {
		do { cd $fix.project; ^nu $cache_nu run --manifest $bogus_manifest -- sh -c "echo BYPASSED && exit 0" } | complete
	}
	assert ($result.exit_code == 0) $"expected bypass + exit 0, got: ($result.exit_code)"
	assert ($result.stdout | str contains "BYPASSED") "cmd should run on bypass"
	let entries = (try { glob ($fix.cache | path join "*/*") | where { |p| ($p | path type) == "dir" } } catch { [] })
	assert (($entries | is-empty)) "bypass should NOT write a cache entry"
	print "  ok\n"
}

# (5) failed cmd must NOT publish a cache entry (storing on failure
# would let bad outputs satisfy future hits).
def test_failed_cmd_does_not_pollute_cache [] {
	print "test failed cmd does not pollute cache..."
	let fix = (make-fixture)

	let r = (run-cache $fix [sh -c "echo partial > output.txt; exit 7"])
	assert ($r.exit == 7) $"failure exit should propagate: ($r.exit)"
	# Should be no published entry. _tmp may exist (mktemp scratch);
	# the real entries live in <shard>/<hash>/ dirs.
	let entries = (
		glob ($fix.cache | path join "*/*")
		| where { |p| ($p | path type) == "dir" and not ($p | str contains "_tmp") }
	)
	assert (($entries | is-empty)) "no entry should be published for a failed cmd"
	print "  ok\n"
}
