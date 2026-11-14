#!/usr/bin/env nu
# Tests for cache.nu — local-FS content-addressable cache.
#
# Each test uses a fresh tempdir for both the project workspace and
# the cache root (BAYT_CACHE_DIR override) so there's zero leakage
# between tests. Synthetic manifests are minimal — just enough to
# exercise resolve-manifest's path-walking + compute-fingerprint's input set.
# Real bayt manifests carry many more fields; cache.nu only consumes
# srcs (via fingerprint.nu) and outs (for restore/store), so the
# minimal shape suffices.
#
# Run with: nu cache_test.nu (from this directory).

use std/assert

const cache_nu = (path self | path dirname | path join "cache.nu")
const fingerprint_nu = (path self | path dirname | path join "fingerprint.nu")

def main [] {
	hide-env -i BAYT_CACHE_URL BAYT_CACHE_TOKEN BAYT_CACHE_REGISTRY BAYT_CACHE_ENABLED
	print "Running cache.nu tests...\n"

	test_miss_runs_cmd_and_stores
	test_outs_exclude_filters_store
	test_outs_exclude_under_a_glob_prefix
	test_hit_restores_and_runs_cmd
	test_hit_full_restores_without_running
	test_full_keys_each_cmd_apart
	test_glob_srcs_reach_the_cache
	test_cross_dep_without_outs_refuses
	test_cross_dep_ignores_internal_task_stamps
	test_check_hit_restores_and_stamps
	test_check_miss_runs
	test_check_failure_runs
	test_check_missing_state_runs
	test_check_invalidates_missing_dep_state
	test_check_ignores_static_view_deps
	test_check_drops_target_stamp_when_a_dep_runs
	test_check_sees_a_missing_per_cmd_stamp
	test_check_skips_cross_deps_without_a_taskfile
	test_check_drops_only_the_deps_own_stamps
	test_check_state_probe_ignores_checkout_brackets
	test_check_walks_past_stale_dep_stamp
	test_check_trusts_stamp_of_dep_without_bayt
	test_corrupt_entry_degrades_to_miss
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

# Same escape hazard as cache.nu's glob-pat.
def cache-pat [root: path, pat: string]: nothing -> string {
	($root | path join $pat) | str replace -a '\' '/'
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
		state: {globs: []}
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
	--cmd-name: string = "",     # run one cmd of a multi-cmd manifest (cache.nu's --cmd)
]: nothing -> record {
	let flags = ([
		(if $full    { ["--full"]    } else { [] }),
		(if $similar { ["--similar"] } else { [] }),
		(if ($cmd_name | is-not-empty) { ["--cmd" $cmd_name] } else { [] }),
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

	# Cache directory has at least one shard with one entry, carrying
	# the full v2 schema (both manifests are required by local-verify).
	let entries = (glob (cache-pat $fix.cache "*/*") | where { |p| ($p | path type) == "dir" })
	assert ((($entries | length) >= 1)) "expected at least one cache entry after miss"
	let entry = ($entries | first)
	for f in ["outs.manifest.json" "srcs.manifest.json" "metadata.json" "manifest.json"] {
		assert ((($entry | path join $f) | path exists)) $"entry should carry ($f)"
	}
	assert ("inputs" not-in (open ($entry | path join "metadata.json") | columns)) "metadata.json should not carry inputs anymore"
	print "  ok\n"
}

# outs.exclude prunes the store-side glob walk — tool-owned trees
# (node_modules) must not enter the entry payload.
def test_outs_exclude_filters_store [] {
	print "test outs exclude filters stored payload..."
	let fix = (make-fixture)
	{
		name: "test"
		project: "test_proj"
		dir: ""
		srcs: {globs: ["input.txt"], exclude: []}
		outs: {globs: ["**/package.json"], exclude: ["**/node_modules/**"]}
		state: {globs: []}
		chainedDeps: []
		cmds: []
	} | to json | save -f $fix.manifest
	mkdir ($fix.project | path join "pkg")
	mkdir ($fix.project | path join "node_modules" "dep")
	"{}" | save -f ($fix.project | path join "pkg" "package.json")
	"{}" | save -f ($fix.project | path join "node_modules" "dep" "package.json")

	let r = (run-cache $fix [sh -c "exit 0"])
	assert ($r.exit == 0) $"unexpected exit: ($r.exit)"

	let entries = (glob (cache-pat $fix.cache "*/*") | where { |p| ($p | path type) == "dir" and not ($p | str contains "_tmp") })
	assert ((($entries | length) == 1)) "expected one cache entry"
	let stored = (open (($entries | first) | path join "outs.manifest.json") | get path)
	assert ("pkg/package.json" in $stored) "tracked package.json should be stored"
	assert (($stored | where { |p| $p | str contains "node_modules" } | is-empty)) "excluded node_modules files must not be stored"
	print "  ok\n"
}

# Excludes are project-relative, like the globs. `build/distributions/**`
# under `build/**/*` is the shape the gradle stack declares.
def test_outs_exclude_under_a_glob_prefix [] {
	print "test outs exclude under a glob prefix..."
	let fix = (make-fixture)
	{
		name: "test"
		project: "test_proj"
		dir: ""
		srcs: {globs: ["input.txt"], exclude: []}
		outs: {globs: ["build/**/*"], exclude: ["build/distributions/**"]}
		state: {globs: []}
		chainedDeps: []
		cmds: []
	} | to json | save -f $fix.manifest

	let r = (run-cache $fix [sh -c "mkdir -p build/libs build/distributions && echo j > build/libs/a.jar && echo t > build/distributions/a.tar"])
	assert ($r.exit == 0) $"unexpected exit: ($r.exit)"

	let entries = (glob (cache-pat $fix.cache "*/*") | where { |p| ($p | path type) == "dir" and not ($p | str contains "_tmp") })
	let stored = (open (($entries | first) | path join "outs.manifest.json") | get path)
	assert ("build/libs/a.jar" in $stored) $"the jar should be stored: ($stored)"
	assert (not ("build/distributions/a.tar" in $stored)) $"the excluded archive must not be stored: ($stored)"
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

# Corrupt entry (payload truncated after store) → quarantined, treated
# as a miss: the cmd runs again and the entry is re-stored.
def test_corrupt_entry_degrades_to_miss [] {
	print "test corrupt entry quarantined and rerun..."
	let fix = (make-fixture)

	run-cache $fix [sh -c "echo first > output.txt"]
	# Hollow the stored payload: truncate the copied out inside the entry.
	let payloads = (glob (cache-pat $fix.cache "*/*/outs/**/*") --no-dir)
	assert (($payloads | length) >= 1) "precondition: entry payload exists"
	"" | save -f ($payloads | first)
	rm $fix.output

	let r = (run-cache $fix [sh -c "echo repaired > output.txt && echo RAN"])
	assert ($r.exit == 0) $"unexpected exit: ($r.exit)"
	assert ($r.stdout | str contains "RAN") "cmd should have rerun (corrupt entry = miss)"
	assert ((open $fix.output | str trim) == "repaired") "workspace out should be the rerun's"
	# Quarantine + re-store: the fresh entry's payload matches the rerun.
	let stored = (glob (cache-pat $fix.cache "*/*/outs/**/*") --no-dir)
	assert (($stored | length) >= 1) "entry should be re-stored after quarantine"
	assert ((open ($stored | first) | str trim) == "repaired") "re-stored payload should be fresh"
	print "  ok\n"
}

# (3) warm cache + --full → cmd is NOT invoked, outs come from cache.
# A multi-cmd target runs one `cache run --cmd <c>` per cmd. Two cmds with
# no srcs of their own share the target's scope, so they must still not
# share an entry: the second would hit the first's (stored before it ran)
# and, under --full, skip. As onhappy-backend's build: composer
# dump-autoload, then the Vite build, whose manifest never got written.
def test_full_keys_each_cmd_apart [] {
	print "test --full keys each cmd of a multi-cmd target apart..."
	let fix = (make-fixture)
	{
		name: "test"
		project: "test_proj"
		dir: ""
		srcs: {globs: ["input.txt"], exclude: []}
		outs: {globs: ["vendor/autoload.txt", "public/build/manifest.json"], exclude: []}
		state: {globs: []}
		chainedDeps: []
		cmds: [
			{name: "composer", do: "dump", srcs: {globs: [], exclude: []}}
			{name: "builtin", do: "assets", srcs: {globs: [], exclude: []}}
		]
	} | to json | save -f $fix.manifest
	let first = (run-cache $fix [sh -c "mkdir -p vendor && echo autoload > vendor/autoload.txt"] --full --cmd-name composer)
	assert ($first.exit == 0) $"the first cmd should run: ($first.exit)"
	let second = (run-cache $fix [sh -c "echo ASSETS_RAN; mkdir -p public/build && echo '{}' > public/build/manifest.json"] --full --cmd-name builtin)
	assert ($second.exit == 0) $"the second cmd should run: ($second.exit)"
	assert ($second.stdout | str contains "ASSETS_RAN") "the second cmd must not hit the first cmd's entry"
	assert ($fix.project | path join "public" "build" "manifest.json" | path exists) "the second cmd's out should be built"

	# Each cmd's own entry still hits on a rerun.
	rm -rf ($fix.project | path join "vendor") ($fix.project | path join "public")
	let again = (run-cache $fix [sh -c "echo ASSETS_RAN"] --full --cmd-name builtin)
	assert (not ($again.stdout | str contains "ASSETS_RAN")) "a rerun of the same cmd hits its own entry"
	assert ($fix.project | path join "public" "build" "manifest.json" | path exists) "and restores its outs"
	print "  ok\n"
}

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

# A glob in srcs must reach the cache. Every real manifest has one
# (`src/**/*.kt`), while the fixture above names its src as a literal,
# which never enters the globbing branch — the branch where a relative
# root cut the head off an absolute project path, so every host
# invocation bypassed and every test here still passed.
def test_glob_srcs_reach_the_cache [] {
	print "test glob srcs reach the cache..."
	let fix = (make-fixture)
	mkdir ($fix.project | path join "src")
	"hello\n" | save -f ($fix.project | path join "src" "a.txt")
	{
		name: "test"
		project: "test_proj"
		dir: ""
		srcs: {globs: ["src/**/*.txt"], exclude: []}
		outs: {globs: ["output.txt"], exclude: []}
		state: {globs: []}
		chainedDeps: []
		cmds: []
	} | to json | save -f $fix.manifest

	run-cache $fix [sh -c "echo from-cache > output.txt"]
	rm $fix.output

	# A bypass stores nothing, so this --full run would miss and execute.
	let r = (run-cache $fix [sh -c "echo SHOULD_NOT_RUN; exit 99"] --full)
	assert ($r.exit == 0) $"a glob-keyed entry should hit: exit ($r.exit)"
	assert (not ($r.stdout | str contains "SHOULD_NOT_RUN")) "cmd should never have run"
	assert ((open $fix.output | str trim) == "from-cache") "output should come from the cache"
	print "  ok\n"
}

# A cross-project dep must leave its outs before its dependent runs. Its
# runner is skipped where the dep project has no `.bayt`, so a dep skipped
# where it should have built would otherwise let this target build on nothing.
def test_cross_dep_without_outs_refuses [] {
	print "test cross dep without outs refuses..."
	let fix = (make-fixture)
	{
		name: "test"
		project: "test_proj"
		dir: ""
		srcs: {globs: ["input.txt"], exclude: []}
		outs: {globs: ["output.txt"], exclude: []}
		state: {globs: []}
		chainedDeps: [{name: "build", project: "libs_dep", dir: "libs/dep", outs: {globs: ["out/lib.txt"], exclude: []}}]
		cmds: []
	} | to json | save -f $fix.manifest

	let r = (run-cache $fix [sh -c "echo SHOULD_NOT_RUN; echo built > output.txt"])
	assert ($r.exit != 0) "a cross dep with no outs should stop the target"
	assert (not ($r.stdout | str contains "SHOULD_NOT_RUN")) "the cmd should never have run"
	assert (not ($fix.output | path exists)) "nothing should have been built"

	mkdir ($fix.project | path join "libs" "dep" "out")
	"lib\n" | save -f ($fix.project | path join "libs" "dep" "out" "lib.txt")
	let ok = (run-cache $fix [sh -c "echo built > output.txt"])
	assert ($ok.exit == 0) $"with the dep's outs present the target should run: exit ($ok.exit)"
	assert ($fix.output | path exists) "output should have been built"
	print "  ok\n"
}

# Internal task stamps (.task/bayt/*.hash) are not runtime build artifacts and
# must not cause a cross-dep check failure in containers where task did not run.
def test_cross_dep_ignores_internal_task_stamps [] {
	print "test cross dep ignores internal task stamps..."
	let fix = (make-fixture)
	{
		name: "test"
		project: "test_proj"
		dir: ""
		srcs: {globs: ["input.txt"], exclude: []}
		outs: {globs: ["output.txt"], exclude: []}
		state: {globs: []}
		chainedDeps: [{name: "build", project: "libs_dep", dir: "libs/dep", outs: {globs: ["out/lib.txt", ".task/bayt/build.hash"], exclude: []}}]
		cmds: []
	} | to json | save -f $fix.manifest

	mkdir ($fix.project | path join "libs" "dep" "out")
	"lib\n" | save -f ($fix.project | path join "libs" "dep" "out" "lib.txt")
	# Notice: .task/bayt/build.hash is intentionally NOT created on disk.
	let ok = (run-cache $fix [sh -c "echo built > output.txt"])
	assert ($ok.exit == 0) $"target should run despite missing .task stamp: exit ($ok.exit)"
	assert ($fix.output | path exists) "output should have been built"
	print "  ok\n"
}

# `cache.nu check` against the fixture, as a cache.full target's `if:` runs it.
def run-check [fix: record, --manifest: string = "", --outs-only]: nothing -> record {
	let m = (if ($manifest | is-empty) { $fix.manifest } else { $manifest })
	let only = (if $outs_only { ["--outs-only"] } else { [] })
	let result = with-env { BAYT_CACHE_DIR: $fix.cache } {
		do { cd $fix.project; ^nu $cache_nu check --manifest $m --stamp-file .task/bayt/test.hash ...$only } | complete
	}
	{exit: $result.exit_code, stderr: $result.stderr}
}

# A hit answers yes and leaves the target as its own run would have: outs
# restored and the stamp written, since a task skipped by `if:` never reaches
# its stamping defer. The next check answers from the stamp alone.
def test_check_hit_restores_and_stamps [] {
	print "test check hit restores and stamps..."
	let fix = (make-fixture)
	run-cache $fix [sh -c "echo from-cache > output.txt"] --full
	rm $fix.output

	let r = (run-check $fix --outs-only)
	assert ($r.exit == 10) $"a hit should answer 10: ($r.exit) ($r.stderr)"
	assert ((open $fix.output | str trim) == "from-cache") "the hit should restore the outs"
	let stamp = ($fix.project | path join ".task" "bayt" "test.hash")
	assert ($stamp | path exists) "the hit should write the stamp"

	rm -rf $fix.cache
	let again = (run-check $fix --outs-only)
	assert ($again.exit == 10) $"a matching stamp should answer 10 without the cache: ($again.exit)"
	print "  ok\n"
}

def test_check_miss_runs [] {
	print "test check miss runs..."
	let fix = (make-fixture)
	let r = (run-check $fix --outs-only)
	assert ($r.exit == 0) $"a miss should answer 0: ($r.exit) ($r.stderr)"
	assert (not ($fix.output | path exists)) "a miss should restore nothing"
	print "  ok\n"
}

# The `if:` skips on 10 alone, so a check that cannot run must not answer 10.
def test_check_failure_runs [] {
	print "test check failure runs..."
	let fix = (make-fixture)
	let r = (run-check $fix --outs-only --manifest ($fix.project | path join "missing.json"))
	assert ($r.exit != 10) "a failing check must not answer 10"
	print "  ok\n"
}

# A restore brings back outs, not state; a target whose state is gone has to
# run to rebuild it.
def test_check_missing_state_runs [] {
	print "test check missing state runs..."
	let fix = (make-fixture)
	{
		name: "test"
		project: "test_proj"
		dir: ""
		srcs: {globs: ["input.txt"], exclude: []}
		outs: {globs: ["output.txt"], exclude: []}
		state: {globs: ["tool_state"]}
		chainedDeps: []
		cmds: []
	} | to json | save -f $fix.manifest
	run-cache $fix [sh -c "echo from-cache > output.txt"] --full
	rm $fix.output

	let r = (run-check $fix --outs-only)
	assert ($r.exit == 0) $"with state missing the target should run: ($r.exit) ($r.stderr)"
	print "  ok\n"
}

# Without --outs-only the check never skips: a target with a consumer needs
# its deps to rebuild their state for a consumer that misses. Its outs live
# inside the dep's state dir (composer's vendor/autoload.php inside setup's
# vendor/), so the check drops the dep's stamps while the state is visibly
# missing, before the restore recreates the dir and would fake it, and still
# restores the outs. Any dep that runs may rewrite those outs, so the check
# never stamps: the target's own `cache run --full` restores them again after
# the deps and stamps it.
def test_check_invalidates_missing_dep_state [] {
	print "test check invalidates a dep whose state is missing..."
	let fix = (make-fixture)
	mkdir ($fix.project | path join ".bayt")
	let setup = {
		name: "setup"
		project: "test_proj"
		dir: ""
		srcs: {globs: ["input.txt"], exclude: []}
		outs: {globs: [], exclude: []}
		# An optional (bracket-only) pattern with no match counts as present, as
		# in the stamp check's own outs-present; only vendor decides.
		state: {globs: ["vendor", "[o]ptional.lock"]}
		chainedDeps: []
		cmds: [{name: "composer", do: "composer install", srcs: {globs: [], exclude: []}}, {name: "npm", do: "npm ci", srcs: {globs: [], exclude: []}}]
	}
	$setup | to json | save -f ($fix.project | path join ".bayt" "bayt.setup.json")
	{
		name: "test"
		project: "test_proj"
		dir: ""
		srcs: {globs: ["input.txt"], exclude: []}
		outs: {globs: ["vendor/autoload.txt"], exclude: []}
		state: {globs: []}
		chainedDeps: [{name: "setup", project: "test_proj", dir: ""}]
		cmds: []
	} | to json | save -f $fix.manifest
	mkdir ($fix.project | path join "vendor")
	run-cache $fix [sh -c "echo from-cache > vendor/autoload.txt"] --full
	let stamps = ($fix.project | path join ".task" "bayt")
	mkdir $stamps
	for st in ["setup" "setup.composer" "setup.npm" "setup.docs"] { "stale\n" | save -f ($stamps | path join $"($st).hash") }
	# A fresh checkout: the stamps came back from a CI cache, vendor/ did not.
	rm -rf ($fix.project | path join "vendor")

	let r = (run-check $fix)
	assert ($r.exit == 0) $"without --outs-only the check must never answer 10: ($r.exit) ($r.stderr)"
	assert ((open ($fix.project | path join "vendor" "autoload.txt") | str trim) == "from-cache") "the hit should still restore the outs first"
	for st in ["setup" "setup.composer" "setup.npm"] {
		assert (not ($stamps | path join $"($st).hash" | path exists)) $"the dep's stamp ($st) should be dropped"
	}
	assert ($stamps | path join "setup.docs.hash" | path exists) "a dotted sibling target's stamp is not the dep's"
	assert (not ($stamps | path join "test.hash" | path exists)) "without --outs-only the check never stamps"

	# go-task now runs the dep, which rewrites the out they share; the
	# target's own `cache run --full` then restores it again and skips.
	"from-setup\n" | save -f ($fix.project | path join "vendor" "autoload.txt")
	let run = (run-cache $fix [sh -c "echo SHOULD_NOT_RUN; echo rebuilt > vendor/autoload.txt"] --full)
	assert ($run.exit == 0) $"the target's cache run should hit: ($run.exit)"
	assert (not ($run.stdout | str contains "SHOULD_NOT_RUN")) "an exact hit skips the cmd"
	assert ((open ($fix.project | path join "vendor" "autoload.txt") | str trim) == "from-cache") "the run restores the out over what the dep wrote"

	# With the state present nothing is dropped, and still nothing is stamped.
	"fresh\n" | save -f ($stamps | path join "setup.hash")
	let again = (run-check $fix)
	assert ($again.exit == 0) $"without --outs-only the check must never answer 10: ($again.exit)"
	assert ($stamps | path join "setup.hash" | path exists) "a dep whose state is present keeps its stamp"
	assert (not ($stamps | path join "test.hash" | path exists)) "without --outs-only the check never stamps"
	print "  ok\n"
}

# A single-cmd dep has only `<name>.hash`: the generator makes per-cmd tasks
# (and stamps) only for several cmds with a `do`. `setup.builtin.hash` would
# be a sibling target named `setup.builtin`, so it stays.
def test_check_drops_only_the_deps_own_stamps [] {
	print "test check drops only the dep's own stamps..."
	let fix = (make-fixture)
	mkdir ($fix.project | path join ".bayt")
	{
		name: "setup", project: "test_proj", dir: ""
		srcs: {globs: ["input.txt"], exclude: []}
		outs: {globs: [], exclude: []}
		state: {globs: ["vendor"]}
		chainedDeps: []
		cmds: [{name: "builtin", do: "true", srcs: {globs: [], exclude: []}}]
	} | to json | save -f ($fix.project | path join ".bayt" "bayt.setup.json")
	{
		name: "test", project: "test_proj", dir: ""
		srcs: {globs: ["input.txt"], exclude: []}
		outs: {globs: ["output.txt"], exclude: []}
		state: {globs: []}
		chainedDeps: [{name: "setup", project: "test_proj", dir: ""}]
		cmds: []
	} | to json | save -f $fix.manifest
	let stamps = ($fix.project | path join ".task" "bayt")
	mkdir $stamps
	for st in ["setup" "setup.builtin"] { "stale\n" | save -f ($stamps | path join $"($st).hash") }
	let r = (run-check $fix)
	assert ($r.exit == 0) $"without --outs-only the check must never answer 10: ($r.exit) ($r.stderr)"
	assert (not ($stamps | path join "setup.hash" | path exists)) "the dep's own stamp should be dropped"
	assert ($stamps | path join "setup.builtin.hash" | path exists) "a single-cmd dep has no per-cmd stamp to drop"
	print "  ok\n"
}

# The state probe runs from the dep's dir: rooted under a checkout path with
# a `[`, `vendor` would read as an optional bracket pattern and pass.
def test_check_state_probe_ignores_checkout_brackets [] {
	print "test check state probe ignores brackets in the checkout path..."
	let outer = (mktemp -d)
	let proj = ($outer | path join "proj[1]")
	mkdir ($proj | path join ".bayt")
	"hello\n" | save -f ($proj | path join "input.txt")
	let fix = {
		manifest: ($proj | path join "manifest.json")
		input:    ($proj | path join "input.txt")
		output:   ($proj | path join "output.txt")
		project:  $proj
		cache:    (mktemp -d)
	}
	{
		name: "setup", project: "test_proj", dir: ""
		srcs: {globs: ["input.txt"], exclude: []}
		outs: {globs: [], exclude: []}
		state: {globs: ["vendor"]}
		chainedDeps: []
		cmds: []
	} | to json | save -f ($proj | path join ".bayt" "bayt.setup.json")
	{
		name: "test", project: "test_proj", dir: ""
		srcs: {globs: ["input.txt"], exclude: []}
		outs: {globs: ["output.txt"], exclude: []}
		state: {globs: []}
		chainedDeps: [{name: "setup", project: "test_proj", dir: ""}]
		cmds: []
	} | to json | save -f $fix.manifest
	let stamps = ($proj | path join ".task" "bayt")
	mkdir $stamps
	"stale\n" | save -f ($stamps | path join "setup.hash")
	let r = (run-check $fix)
	assert ($r.exit == 0) $"without --outs-only the check must never answer 10: ($r.exit) ($r.stderr)"
	assert (not ($stamps | path join "setup.hash" | path exists)) "missing state under a bracketed checkout path must still drop the stamp"
	print "  ok\n"
}

# A target stamp from an earlier run survives only while no dep is going to
# run: a dep that reruns (here, its stamp lost while its state is present)
# may rewrite a shared out, and `status:` passing on the old stamp would skip
# the target's second restore.
def test_check_drops_target_stamp_when_a_dep_runs [] {
	print "test check drops the target stamp when a dep is going to run..."
	let fix = (make-fixture)
	mkdir ($fix.project | path join ".bayt")
	{
		name: "setup", project: "test_proj", dir: ""
		srcs: {globs: ["input.txt"], exclude: []}
		outs: {globs: [], exclude: []}
		state: {globs: ["vendor"]}
		chainedDeps: []
		cmds: []
		taskfile: {incremental: true}
	} | to json | save -f ($fix.project | path join ".bayt" "bayt.setup.json")
	{
		name: "test", project: "test_proj", dir: ""
		srcs: {globs: ["input.txt"], exclude: []}
		outs: {globs: ["output.txt"], exclude: []}
		state: {globs: []}
		chainedDeps: [{name: "setup", project: "test_proj", dir: ""}]
		cmds: []
	} | to json | save -f $fix.manifest
	mkdir ($fix.project | path join "vendor")
	"built\n" | save -f $fix.output
	let stamps = ($fix.project | path join ".task" "bayt")
	# Both built and stamped, as a finished `task` run leaves them.
	do { cd $fix.project; ^nu $fingerprint_nu --manifest ($fix.project | path join ".bayt" "bayt.setup.json") --stamp-file .task/bayt/setup.hash --update-stamp }
	do { cd $fix.project; ^nu $fingerprint_nu --manifest $fix.manifest --stamp-file .task/bayt/test.hash --update-stamp }

	let kept = (run-check $fix)
	assert ($kept.exit == 0) $"without --outs-only the check must never answer 10: ($kept.exit) ($kept.stderr)"
	assert ($stamps | path join "test.hash" | path exists) "with no dep going to run, the target keeps its stamp"

	# A stamp written by a run on other inputs: present, but its status: misses.
	"0123stale\n" | save -f ($stamps | path join "setup.hash")
	let stale = (run-check $fix)
	assert ($stale.exit == 0) $"without --outs-only the check must never answer 10: ($stale.exit) ($stale.stderr)"
	assert (not ($stamps | path join "test.hash" | path exists)) "a dep with a stale stamp is going to run, so the target's stamp goes"

	do { cd $fix.project; ^nu $fingerprint_nu --manifest ($fix.project | path join ".bayt" "bayt.setup.json") --stamp-file .task/bayt/setup.hash --update-stamp }
	do { cd $fix.project; ^nu $fingerprint_nu --manifest $fix.manifest --stamp-file .task/bayt/test.hash --update-stamp }
	rm ($stamps | path join "setup.hash")
	let r = (run-check $fix)
	assert ($r.exit == 0) $"without --outs-only the check must never answer 10: ($r.exit) ($r.stderr)"
	assert (not ($stamps | path join "test.hash" | path exists)) "a dep with no stamp is going to run, so the target's stamp goes"
	print "  ok\n"
}

# A multi-cmd dep runs per-cmd tasks gated by `<name>.<cmd>.hash`: one of
# them missing means that cmd reruns, even with the aggregate stamp in place.
def test_check_sees_a_missing_per_cmd_stamp [] {
	print "test check sees a multi-cmd dep's missing per-cmd stamp..."
	let fix = (make-fixture)
	mkdir ($fix.project | path join ".bayt")
	let setup_manifest = ($fix.project | path join ".bayt" "bayt.setup.json")
	{
		name: "setup", project: "test_proj", dir: ""
		srcs: {globs: ["input.txt"], exclude: []}
		outs: {globs: [], exclude: []}
		state: {globs: []}
		chainedDeps: []
		cmds: [{name: "composer", do: "composer install", srcs: {globs: ["input.txt"], exclude: []}}, {name: "npm", do: "npm ci", srcs: {globs: ["input.txt"], exclude: []}}]
		taskfile: {incremental: true}
	} | to json | save -f $setup_manifest
	{
		name: "test", project: "test_proj", dir: ""
		srcs: {globs: ["input.txt"], exclude: []}
		outs: {globs: ["output.txt"], exclude: []}
		state: {globs: []}
		chainedDeps: [{name: "setup", project: "test_proj", dir: ""}]
		cmds: []
	} | to json | save -f $fix.manifest
	"built\n" | save -f $fix.output
	let stamps = ($fix.project | path join ".task" "bayt")
	do {
		cd $fix.project
		^nu $fingerprint_nu --manifest $setup_manifest --cmd composer --stamp-file .task/bayt/setup.composer.hash --update-stamp
		^nu $fingerprint_nu --manifest $setup_manifest --cmd npm --stamp-file .task/bayt/setup.npm.hash --update-stamp
		^nu $fingerprint_nu --manifest $setup_manifest --stamp-file .task/bayt/setup.hash --update-stamp
		^nu $fingerprint_nu --manifest $fix.manifest --stamp-file .task/bayt/test.hash --update-stamp
	}
	let kept = (run-check $fix)
	assert ($stamps | path join "test.hash" | path exists) $"with every per-cmd stamp current the target keeps its stamp: ($kept.stderr)"

	rm ($stamps | path join "setup.npm.hash")
	let r = (run-check $fix)
	assert ($r.exit == 0) $"without --outs-only the check must never answer 10: ($r.exit) ($r.stderr)"
	assert (not ($stamps | path join "test.hash" | path exists)) "a missing per-cmd stamp means that cmd reruns, so the target's stamp goes"
	print "  ok\n"
}

# A cross-project dep runs through a runner that skips it when the dep's
# project has no Taskfile.yml, so there it cannot rewrite anything and the
# target keeps its stamp; with the file present it runs (here, always).
def test_check_skips_cross_deps_without_a_taskfile [] {
	print "test check skips cross-project deps whose runner would skip..."
	let fix = (make-fixture)
	let dep = ($fix.project | path join "libs" "dep")
	mkdir ($dep | path join ".bayt")
	{
		name: "build", project: "libs_dep", dir: "libs/dep"
		srcs: {globs: [], exclude: []}
		outs: {globs: [], exclude: []}
		state: {globs: []}
		chainedDeps: []
		cmds: []
		taskfile: {incremental: false}
	} | to json | save -f ($dep | path join ".bayt" "bayt.build.json")
	{
		name: "test", project: "test_proj", dir: ""
		srcs: {globs: ["input.txt"], exclude: []}
		outs: {globs: ["output.txt"], exclude: []}
		state: {globs: []}
		chainedDeps: [{name: "build", project: "libs_dep", dir: "libs/dep"}]
		cmds: []
	} | to json | save -f $fix.manifest
	"built\n" | save -f $fix.output
	let stamps = ($fix.project | path join ".task" "bayt")
	do { cd $fix.project; ^nu $fingerprint_nu --manifest $fix.manifest --stamp-file .task/bayt/test.hash --update-stamp }

	let kept = (run-check $fix)
	assert ($kept.exit == 0) $"without --outs-only the check must never answer 10: ($kept.exit) ($kept.stderr)"
	assert ($stamps | path join "test.hash" | path exists) "a cross dep whose runner skips keeps the target's stamp"

	"version: '3'\n" | save -f ($dep | path join "Taskfile.yml")
	let r = (run-check $fix)
	assert (not ($stamps | path join "test.hash" | path exists)) "with its Taskfile.yml the non-incremental cross dep runs, so the target's stamp goes"
	print "  ok\n"
}

# A `_srcs` (or `_bayt`) edge is a static view with no runnable task behind
# it: nothing would rebuild the producer's state or restamp it, so the walk
# does not follow it.
def test_check_ignores_static_view_deps [] {
	print "test check ignores static view deps..."
	let fix = (make-fixture)
	mkdir ($fix.project | path join ".bayt")
	{
		name: "setup"
		project: "test_proj"
		dir: ""
		srcs: {globs: ["input.txt"], exclude: []}
		outs: {globs: [], exclude: []}
		state: {globs: ["vendor"]}
		chainedDeps: []
		cmds: []
		synthetics: {srcs: {
			name: "setup_srcs", project: "test_proj", dir: "", activate: ""
			srcs: {globs: [], exclude: []}
			outs: {globs: ["input.txt"], exclude: []}
			state: {globs: []}
			chainedDeps: []
			cmds: []
		}}
	} | to json | save -f ($fix.project | path join ".bayt" "bayt.setup.json")
	{
		name: "test"
		project: "test_proj"
		dir: ""
		srcs: {globs: ["input.txt"], exclude: []}
		outs: {globs: ["output.txt"], exclude: []}
		state: {globs: []}
		chainedDeps: [{name: "setup_srcs", project: "test_proj", dir: ""}]
		cmds: []
	} | to json | save -f $fix.manifest
	let stamps = ($fix.project | path join ".task" "bayt")
	mkdir $stamps
	"kept\n" | save -f ($stamps | path join "setup.hash")
	let r = (run-check $fix)
	assert ($r.exit == 0) $"without --outs-only the check must never answer 10: ($r.exit) ($r.stderr)"
	assert ($stamps | path join "setup.hash" | path exists) "a _srcs edge must not drop the producer's stamps"
	print "  ok\n"
}

# The check runs before the deps, so a dep's stamp can predate an edit to
# the dep. Trusting it would reproduce the consumer's old key and skip.
def test_check_walks_past_stale_dep_stamp [] {
	print "test check walks past a stale dep stamp..."
	let fix = (make-fixture)
	let dep = ($fix.project | path join "libs" "dep")
	mkdir ($dep | path join ".bayt")
	"v1\n" | save -f ($dep | path join "a.txt")
	{
		name: "build"
		project: "libs_dep"
		dir: "libs/dep"
		srcs: {globs: ["a.txt"], exclude: []}
		outs: {globs: [], exclude: []}
		state: {globs: []}
		chainedDeps: []
		cmds: []
	} | to json | save -f ($dep | path join ".bayt" "bayt.build.json")
	{
		name: "test"
		project: "test_proj"
		dir: ""
		srcs: {globs: ["input.txt"], exclude: []}
		outs: {globs: ["output.txt"], exclude: []}
		state: {globs: []}
		chainedDeps: [{name: "build", project: "libs_dep", dir: "libs/dep"}]
		cmds: []
	} | to json | save -f $fix.manifest

	# Both built and stamped, as a finished `task` run leaves them.
	do { cd $dep; ^nu $fingerprint_nu --manifest ($dep | path join ".bayt" "bayt.build.json") --stamp-file .task/bayt/build.hash --update-stamp }
	"built\n" | save -f $fix.output
	do { cd $fix.project; ^nu $fingerprint_nu --manifest $fix.manifest --stamp-file .task/bayt/test.hash --update-stamp }
	assert ((run-check $fix --outs-only).exit == 10) "a built, unedited tree should answer 10"

	# Edit the dep; its stamp is not refreshed until it runs.
	"v2\n" | save -f ($dep | path join "a.txt")
	let r = (run-check $fix --outs-only)
	assert ($r.exit == 0) $"an edited dep should make the consumer run: ($r.exit)"
	print "  ok\n"
}

# A container COPYs a dep's outs and stamp but never its `.bayt`. With no
# manifest to walk, the dep cannot run here either, so its stamp stands.
def test_check_trusts_stamp_of_dep_without_bayt [] {
	print "test check trusts the stamp of a dep without .bayt..."
	let fix = (make-fixture)
	let dep = ($fix.project | path join "libs" "dep")
	mkdir ($dep | path join ".task" "bayt")
	"0123abcd" | save -f ($dep | path join ".task" "bayt" "build.hash")
	{
		name: "test"
		project: "test_proj"
		dir: ""
		srcs: {globs: ["input.txt"], exclude: []}
		outs: {globs: ["output.txt"], exclude: []}
		state: {globs: []}
		chainedDeps: [{name: "build", project: "libs_dep", dir: "libs/dep"}]
		cmds: []
	} | to json | save -f $fix.manifest
	"built\n" | save -f $fix.output
	do { cd $fix.project; ^nu $fingerprint_nu --manifest $fix.manifest --stamp-file .task/bayt/test.hash --update-stamp }

	let r = (run-check $fix --outs-only)
	assert ($r.exit == 10) $"a stamped consumer of a .bayt-less dep should answer 10: ($r.exit) ($r.stderr)"
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
	let shards = (glob (cache-pat $fix.cache "*") | where { |p| ($p | path type) == "dir" })
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
		let stamp = $"2025-01-0($i) 00:00:00"
		0..<$bytes_each | each { |_| bytes build 0x00 } | bytes collect | save -f $blob
		# Older index → older mtime.
		touch --modified --date $stamp $entry
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

	let v1_entries = (glob (cache-pat $fix.cache "*/*") | where { |p| ($p | path type) == "dir" })
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

	let final_entries = (glob (cache-pat $fix.cache "*/*") | where { |p| ($p | path type) == "dir" })
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
# fingerprint.nu's compute-fingerprint itself; bypass is the broader fallback
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
	let entries = (try { glob (cache-pat $fix.cache "*/*") | where { |p| ($p | path type) == "dir" } } catch { [] })
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
		glob (cache-pat $fix.cache "*/*")
		| where { |p| ($p | path type) == "dir" and not ($p | str contains "_tmp") }
	)
	assert (($entries | is-empty)) "no entry should be published for a failed cmd"
	print "  ok\n"
}
