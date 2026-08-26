#!/usr/bin/env nu
# Tests for fingerprint.nu — content fingerprint CLI.
# Run with: nu fingerprint_test.nu (from plugins/bayt/runtime/).
#
# Each test uses a fresh tempdir. Most tests run in no-git mode
# (compute-fingerprint falls back to glob + per-file sha256), which
# keeps fixtures minimal. One test git-init's its tempdir to exercise
# the git-mode path (ls-files + hash-object).

use std/assert

const fp_nu = (path self | path dirname | path join "fingerprint.nu")

def main [] {
	print "Running fingerprint.nu tests...\n"

	# determinism + sensitivity
	test_a_synthetic_dep_resolves_from_its_parent
	test_an_unemitted_srcs_view_contributes_nothing
	test_an_unemitted_other_view_is_an_error
	test_a_dep_stamp_never_narrows_the_image_scope
	test_hash_stable_across_runs
	test_hash_changes_with_content
	test_docker_hash_differs_from_content
	test_docker_hash_stable_across_runs

	# output modes
	test_quiet_emits_single_hash_line
	test_quiet_json_emits_hash_object
	test_default_emits_per_file_tsv
	test_json_emits_ndjson_rows
	test_docker_dump_has_extra_columns

	# stamp ops
	test_write_then_check_matches
	test_check_misses_when_content_changed
	test_check_misses_when_stamp_missing
	test_check_misses_when_outs_missing
	test_outs_present_passes_check
	test_update_stamp_without_stamp_file_errors
	test_check_mode_is_silent
	test_write_is_atomic

	# input merging
	test_manifest_provides_srcs
	test_positional_unions_with_manifest
	test_dep_change_reaches_the_root
	test_absent_stamp_still_counts_the_dep
	test_stamp_memo_agrees_with_recompute
	test_manifest_spelling_does_not_change_the_hash
	test_cmd_scopes_srcs_to_cmd_entry
	test_exclude_filters_files
	test_no_paths_errors

	# git mode
	test_git_mode_succeeds

	# state: in-place products gate presence like outs
	test_state_absence_fails_check

	# bracket-class globs (the optional-file idiom: `[m]ise.toml`)
	test_bracket_glob_hashes_matching_file
	test_bracket_glob_hashes_in_git_mode
	test_check_tolerates_missing_optional_bracket_out

	print "\nAll fingerprint.nu tests passed!"
}

# --- helpers --------------------------------------------------------

def make-tmp []: nothing -> string {
	mktemp -d
}

# Run fingerprint.nu as a subprocess from $tmp. Args is a list of
# strings so flags like "-q" don't collide with nu's flag parser.
def run-fp [tmp: string, args: list<string>]: nothing -> record {
	let r = (do { cd $tmp; ^nu $fp_nu ...$args } | complete)
	{stdout: $r.stdout, stderr: $r.stderr, exit: $r.exit_code}
}

# Write a minimal bayt manifest. `srcs` / `cmds` / `outs` overridable.
def write-manifest [
	path: string
	srcs: list<string>
	--outs: list<string> = []
	--state: list<string> = []
	--cmds: list = []
	--name: string = "test"
	--deps: list = []
] {
	{
		name: $name
		dir: ""
		srcs: {globs: $srcs, exclude: []}
		outs: {globs: $outs, exclude: []}
		state: {globs: $state}
		chainedDeps: $deps
		cmds: $cmds
	} | to json | save -f $path
}

# Write a manifest carrying a synthetic view, the shape gen_bayt emits: the
# view lives inside `synthetics`, never as a `bayt.<n>_<view>.json` file, and
# it declares no `state`.
def write-synthetic-owner [
	path: string
	--name: string = "owner"
	--view: string = "srcs"
	--view-srcs: list<string> = []
] {
	{
		name: $name
		dir: ""
		srcs: {globs: [], exclude: []}
		outs: {globs: [], exclude: []}
		state: {globs: []}
		chainedDeps: []
		cmds: []
		synthetics: {
			($view): {
				name: $"($name)_($view)"
				dir: ""
				# A view's file set is its INTERFACE: the generator emits it as
				# `outs` and leaves `srcs` empty. A fixture that puts files in
				# `srcs` asserts a shape that cannot occur.
				srcs: {globs: [], exclude: []}
				outs: {globs: $view_srcs, exclude: []}
				chainedDeps: []
				transitiveDeps: []
				transitiveCrossDeps: []
				cmds: []
			}
		}
	} | to json | save -f $path
}

# A `:X:srcs` dep resolves to its parent manifest's `synthetics` entry. Deriving
# a `bayt.X_srcs.json` path instead finds no file and the whole walk errors, so
# any target whose chain reaches a synthetic cannot be fingerprinted at all.
def test_a_synthetic_dep_resolves_from_its_parent [] {
	print "test a synthetic view dep resolves from its parent manifest..."
	let tmp = (make-tmp)
	mkdir ($tmp | path join ".bayt")
	"payload\n" | save -f ($tmp | path join "viewed.txt")
	"own\n" | save -f ($tmp | path join "own.txt")

	write-synthetic-owner ($tmp | path join ".bayt/bayt.owner.json") --view-srcs ["viewed.txt"]
	write-manifest ($tmp | path join ".bayt/bayt.consumer.json") ["own.txt"] --name "consumer" --deps [
		{name: "owner_srcs", dir: ""}
	]

	let r = (run-fp $tmp ["-q" "--manifest" ".bayt/bayt.consumer.json"])
	assert ($r.exit == 0) $"synthetic dep did not resolve: ($r.stderr)"
	let first = $r.stdout

	# The view's own files are folded in: editing one must move the consumer.
	"payload changed\n" | save -f ($tmp | path join "viewed.txt")
	let r2 = (run-fp $tmp ["-q" "--manifest" ".bayt/bayt.consumer.json"])
	assert ($r2.stdout != $first) "editing the synthetic's srcs did not move the consumer's hash"
	rm -rf $tmp
	print "  ok\n"
}

# A target with `emitsSrcs: false` exports no sources, so it emits no `srcs`
# view and a consumer's `:X:srcs` edge carries no files. Erroring there would
# make any consumer of such a target unfingerprintable.
def test_an_unemitted_srcs_view_contributes_nothing [] {
	print "test a srcs view that was never emitted contributes nothing..."
	let tmp = (make-tmp)
	mkdir ($tmp | path join ".bayt")
	"own\n" | save -f ($tmp | path join "own.txt")
	{
		name: "owner", dir: "", emitsSrcs: false
		srcs: {globs: [], exclude: []}, outs: {globs: [], exclude: []}
		state: {globs: []}, chainedDeps: [], cmds: []
		synthetics: {bayt: {name: "owner_bayt", dir: "", srcs: {globs: [], exclude: []}, outs: {globs: [], exclude: []}, chainedDeps: [], cmds: []}}
	} | to json | save -f ($tmp | path join ".bayt/bayt.owner.json")
	write-manifest ($tmp | path join ".bayt/bayt.consumer.json") ["own.txt"] --name "consumer" --deps [
		{name: "owner_srcs", dir: ""}
	]

	let r = (run-fp $tmp ["-q" "--manifest" ".bayt/bayt.consumer.json"])
	assert ($r.exit == 0) $"an unemitted srcs view should contribute nothing: ($r.stderr)"
	rm -rf $tmp
	print "  ok\n"
}

# Only `emitsSrcs: false` explains an absent view. Anything else is a
# generator bug, and dropping the dep would weaken the hash silently.
def test_an_unemitted_other_view_is_an_error [] {
	print "test an absent view with no emitsSrcs reason is an error..."
	let tmp = (make-tmp)
	mkdir ($tmp | path join ".bayt")
	"own\n" | save -f ($tmp | path join "own.txt")
	{
		name: "owner", dir: "", emitsSrcs: true
		srcs: {globs: [], exclude: []}, outs: {globs: [], exclude: []}
		state: {globs: []}, chainedDeps: [], cmds: []
		synthetics: {srcs: {name: "owner_srcs", dir: "", srcs: {globs: [], exclude: []}, outs: {globs: [], exclude: []}, chainedDeps: [], cmds: []}}
	} | to json | save -f ($tmp | path join ".bayt/bayt.owner.json")
	write-manifest ($tmp | path join ".bayt/bayt.consumer.json") ["own.txt"] --name "consumer" --deps [
		{name: "owner_outs", dir: ""}
	]

	let r = (run-fp $tmp ["-q" "--manifest" ".bayt/bayt.consumer.json"])
	assert ($r.exit != 0) "an absent `outs` view must not be treated as empty"
	rm -rf $tmp
	print "  ok\n"
}

# A stamp is written only at the narrow cmd scope, so consuming one under
# --all-cmds swaps a wide hash for a narrow one. The failure needs a .task/
# tree to appear, so it reaches any host that has run a task and no CI
# workspace check can see it: .task/ is gitignored.
def test_a_dep_stamp_never_narrows_the_image_scope [] {
	print "test a dep stamp does not narrow the image scope..."
	let tmp = (make-tmp)
	mkdir ($tmp | path join ".bayt")
	"own\n" | save -f ($tmp | path join "own.txt")
	"dep\n" | save -f ($tmp | path join "dep.txt")
	write-manifest ($tmp | path join ".bayt/bayt.owner.json") ["dep.txt"] --name "owner"
	write-manifest ($tmp | path join ".bayt/bayt.consumer.json") ["own.txt"] --name "consumer" --deps [
		{name: "owner", dir: ""}
	]

	let clean = (run-fp $tmp ["-q" "--all-cmds" "--manifest" ".bayt/bayt.consumer.json"])
	assert ($clean.exit == 0) $"unexpected exit: ($clean.stderr)"

	mkdir ($tmp | path join ".task/bayt")
	"DEADBEEF\n" | save -f ($tmp | path join ".task/bayt/owner.hash")
	let stamped = (run-fp $tmp ["-q" "--all-cmds" "--manifest" ".bayt/bayt.consumer.json"])

	assert ($clean.stdout == $stamped.stdout) "a stale stamp replaced the recomputed closure under --all-cmds"
	rm -rf $tmp
	print "  ok\n"
}

# --- determinism + sensitivity --------------------------------------

# (1) Same content, two runs → identical hash.
def test_hash_stable_across_runs [] {
	print "test hash stable across runs with unchanged content..."
	let tmp = (make-tmp)
	"alpha\n" | save -f ($tmp | path join "a.txt")
	"beta\n"  | save -f ($tmp | path join "b.txt")

	let r1 = (run-fp $tmp ["-q" "a.txt" "b.txt"])
	let r2 = (run-fp $tmp ["-q" "a.txt" "b.txt"])
	assert ($r1.exit == 0) $"unexpected exit: ($r1.exit): ($r1.stderr)"
	assert ($r1.stdout == $r2.stdout) $"hash drifted: ($r1.stdout) vs ($r2.stdout)"
	rm -rf $tmp
	print "  ok\n"
}

# (2) Content edit → hash changes.
def test_hash_changes_with_content [] {
	print "test hash changes when file content changes..."
	let tmp = (make-tmp)
	"v1\n" | save -f ($tmp | path join "x.txt")
	let r1 = (run-fp $tmp ["-q" "x.txt"])
	"v2\n" | save -f ($tmp | path join "x.txt")
	let r2 = (run-fp $tmp ["-q" "x.txt"])
	assert ($r1.stdout != $r2.stdout) "hash should differ after edit"
	rm -rf $tmp
	print "  ok\n"
}

# (3) --docker rolled-up hash diverges from content-only.
def test_docker_hash_differs_from_content [] {
	print "test --docker hash differs from content-only..."
	let tmp = (make-tmp)
	"data\n" | save -f ($tmp | path join "f.txt")
	let content = (run-fp $tmp ["-q" "f.txt"])
	let docker  = (run-fp $tmp ["-q" "--docker" "f.txt"])
	assert ($content.stdout != $docker.stdout) "hashes should differ"
	rm -rf $tmp
	print "  ok\n"
}

# (4) --docker hash also stable across runs (despite carrying mtime).
def test_docker_hash_stable_across_runs [] {
	print "test --docker hash stable across runs..."
	let tmp = (make-tmp)
	"data\n" | save -f ($tmp | path join "f.txt")
	let r1 = (run-fp $tmp ["-q" "--docker" "f.txt"])
	let r2 = (run-fp $tmp ["-q" "--docker" "f.txt"])
	assert ($r1.stdout == $r2.stdout) $"docker hash drifted: ($r1.stdout) vs ($r2.stdout)"
	rm -rf $tmp
	print "  ok\n"
}

# --- output modes ---------------------------------------------------

# -q emits exactly one line — the rolled-up hash.
def test_quiet_emits_single_hash_line [] {
	print "test -q emits a single hash line..."
	let tmp = (make-tmp)
	"a\n" | save -f ($tmp | path join "a.txt")
	"b\n" | save -f ($tmp | path join "b.txt")
	let r = (run-fp $tmp ["-q" "a.txt" "b.txt"])
	let lines = ($r.stdout | lines | where { |l| not ($l | is-empty) })
	assert (($lines | length) == 1) $"expected 1 line, got ($lines | length)"
	assert (($lines | first | str length) > 0) "hash should be non-empty"
	rm -rf $tmp
	print "  ok\n"
}

# -q --json wraps the hash in a single-line object.
def test_quiet_json_emits_hash_object [] {
	print "test -q --json emits {hash: ...} object..."
	let tmp = (make-tmp)
	"a\n" | save -f ($tmp | path join "a.txt")
	let r = (run-fp $tmp ["-q" "--json" "a.txt"])
	let obj = ($r.stdout | from json)
	assert (($obj | columns) == ["hash"]) $"expected only hash key, got ($obj | columns)"
	rm -rf $tmp
	print "  ok\n"
}

# Default mode emits one TSV row per file.
def test_default_emits_per_file_tsv [] {
	print "test default emits per-file TSV rows..."
	let tmp = (make-tmp)
	"a\n" | save -f ($tmp | path join "a.txt")
	"b\n" | save -f ($tmp | path join "b.txt")
	let r = (run-fp $tmp ["a.txt" "b.txt"])
	let rows = ($r.stdout | lines | where { |l| not ($l | is-empty) })
	assert (($rows | length) == 2) $"expected 2 rows, got ($rows | length)"
	for row in $rows {
		let cols = ($row | split row "\t")
		assert (($cols | length) == 2) $"plain row should have 2 cols, got ($cols | length)"
	}
	rm -rf $tmp
	print "  ok\n"
}

# --json emits NDJSON; each line has sha256 + path.
def test_json_emits_ndjson_rows [] {
	print "test --json emits NDJSON rows..."
	let tmp = (make-tmp)
	"a\n" | save -f ($tmp | path join "a.txt")
	"b\n" | save -f ($tmp | path join "b.txt")
	let r = (run-fp $tmp ["--json" "a.txt" "b.txt"])
	let rows = ($r.stdout | lines | where { |l| not ($l | is-empty) } | each { from json })
	assert (($rows | length) == 2) $"expected 2 NDJSON lines, got ($rows | length)"
	for row in $rows {
		let cols = ($row | columns)
		assert ("sha256" in $cols) "row should have sha256"
		assert ("path"   in $cols) "row should have path"
	}
	rm -rf $tmp
	print "  ok\n"
}

# --docker dump rows carry extra columns (mode/uid:gid/mtime/size).
def test_docker_dump_has_extra_columns [] {
	print "test --docker rows have extra columns..."
	let tmp = (make-tmp)
	"data\n" | save -f ($tmp | path join "f.txt")
	let r = (run-fp $tmp ["--docker" "f.txt"])
	let row = ($r.stdout | str trim)
	let cols = ($row | split row "\t")
	# At least: sha256, mode, user:group, mtime, size, path = 6 columns.
	# Plus xattr when a reader is on PATH = 7. Either is acceptable.
	assert (($cols | length) >= 6) $"docker row should have ≥6 cols, got ($cols | length): ($row)"
	rm -rf $tmp
	print "  ok\n"
}

# --- stamp ops ------------------------------------------------------

# Write then check round-trips successfully.
def test_write_then_check_matches [] {
	print "test stamp write then check matches..."
	let tmp = (make-tmp)
	"stable\n" | save -f ($tmp | path join "x.txt")
	let stamp = ($tmp | path join "stamp.hash")
	let w = (run-fp $tmp ["--stamp-file" $stamp "--update-stamp" "x.txt"])
	assert ($w.exit == 0) $"write should exit 0, got ($w.exit): ($w.stderr)"
	assert ($stamp | path exists) "stamp should exist after write"
	let c = (run-fp $tmp ["--stamp-file" $stamp "x.txt"])
	assert ($c.exit == 0) $"check should exit 0, got ($c.exit): ($c.stderr)"
	rm -rf $tmp
	print "  ok\n"
}

# After content edit, check exits 1.
def test_check_misses_when_content_changed [] {
	print "test check misses after content edit..."
	let tmp = (make-tmp)
	"v1\n" | save -f ($tmp | path join "x.txt")
	let stamp = ($tmp | path join "s.hash")
	run-fp $tmp ["--stamp-file" $stamp "--update-stamp" "x.txt"]
	"v2\n" | save -f ($tmp | path join "x.txt")
	let r = (run-fp $tmp ["--stamp-file" $stamp "x.txt"])
	assert ($r.exit == 1) $"check should fail (1) after edit, got ($r.exit)"
	rm -rf $tmp
	print "  ok\n"
}

# Missing stamp file → exit 1.
def test_check_misses_when_stamp_missing [] {
	print "test check misses when stamp file doesn't exist..."
	let tmp = (make-tmp)
	"x\n" | save -f ($tmp | path join "f.txt")
	let r = (run-fp $tmp ["--stamp-file" ($tmp | path join "no.hash") "f.txt"])
	assert ($r.exit == 1) "check on missing stamp should exit 1"
	rm -rf $tmp
	print "  ok\n"
}

# Stamp matches but an outs glob has no files → exit 1.
def test_check_misses_when_outs_missing [] {
	print "test check misses when --outs file is absent..."
	let tmp = (make-tmp)
	"src\n" | save -f ($tmp | path join "src.txt")
	"out\n" | save -f ($tmp | path join "out.txt")
	let stamp = ($tmp | path join "s.hash")
	run-fp $tmp ["--stamp-file" $stamp "--update-stamp" "src.txt"]
	rm ($tmp | path join "out.txt")
	let r = (run-fp $tmp ["--stamp-file" $stamp "--outs" "out.txt" "src.txt"])
	assert ($r.exit == 1) "check should fail when outs missing"
	rm -rf $tmp
	print "  ok\n"
}

# Stamp matches and outs exist → exit 0.
def test_outs_present_passes_check [] {
	print "test check passes when --outs file exists..."
	let tmp = (make-tmp)
	"src\n" | save -f ($tmp | path join "src.txt")
	"out\n" | save -f ($tmp | path join "out.txt")
	let stamp = ($tmp | path join "s.hash")
	run-fp $tmp ["--stamp-file" $stamp "--update-stamp" "src.txt"]
	let r = (run-fp $tmp ["--stamp-file" $stamp "--outs" "out.txt" "src.txt"])
	assert ($r.exit == 0) $"check should pass, got ($r.exit): ($r.stderr)"
	rm -rf $tmp
	print "  ok\n"
}

# --update-stamp without --stamp-file errors with a clear message.
def test_update_stamp_without_stamp_file_errors [] {
	print "test --update-stamp without --stamp-file errors..."
	let tmp = (make-tmp)
	"x\n" | save -f ($tmp | path join "f.txt")
	let r = (run-fp $tmp ["--update-stamp" "f.txt"])
	assert ($r.exit != 0) "should error without --stamp-file"
	assert ($r.stderr | str contains "requires --stamp-file") "error should explain"
	rm -rf $tmp
	print "  ok\n"
}

# Both check and write are silent on stdout (exit-code-driven contract).
def test_check_mode_is_silent [] {
	print "test stamp ops produce no stdout..."
	let tmp = (make-tmp)
	"x\n" | save -f ($tmp | path join "f.txt")
	let stamp = ($tmp | path join "s.hash")
	let w = (run-fp $tmp ["--stamp-file" $stamp "--update-stamp" "f.txt"])
	let c = (run-fp $tmp ["--stamp-file" $stamp "f.txt"])
	assert (($w.stdout | str trim) == "") $"write should be silent, got: ($w.stdout)"
	assert (($c.stdout | str trim) == "") $"check should be silent, got: ($c.stdout)"
	rm -rf $tmp
	print "  ok\n"
}

# Stamp writes go through a `.tmp` + rename, so a crash mid-write
# leaves the prior stamp intact. Hard to truly crash-test from nu;
# verify at least that no `.tmp` leftover remains after a clean write.
def test_write_is_atomic [] {
	print "test stamp write leaves no .tmp leftover..."
	let tmp = (make-tmp)
	"x\n" | save -f ($tmp | path join "f.txt")
	let stamp = ($tmp | path join "s.hash")
	run-fp $tmp ["--stamp-file" $stamp "--update-stamp" "f.txt"]
	assert ($stamp | path exists) "stamp should exist"
	assert (not ($"($stamp).tmp" | path exists)) "no .tmp leftover should remain"
	rm -rf $tmp
	print "  ok\n"
}

# --- input merging --------------------------------------------------

# --manifest provides srcs even without positional paths.
def test_manifest_provides_srcs [] {
	print "test --manifest provides srcs..."
	let tmp = (make-tmp)
	"data\n" | save -f ($tmp | path join "input.txt")
	let m = ($tmp | path join "bayt.test.json")
	write-manifest $m ["input.txt"]
	let r = (run-fp $tmp ["-q" "--manifest" $m])
	assert ($r.exit == 0) $"should succeed: ($r.stderr)"
	assert (($r.stdout | str trim | str length) > 0) "should emit a hash"
	rm -rf $tmp
	print "  ok\n"
}

# Positional paths union with --manifest srcs.
def test_positional_unions_with_manifest [] {
	print "test positional paths union with --manifest..."
	let tmp = (make-tmp)
	"a\n" | save -f ($tmp | path join "a.txt")
	"b\n" | save -f ($tmp | path join "b.txt")
	let m = ($tmp | path join "bayt.test.json")
	write-manifest $m ["a.txt"]

	let m_only   = (run-fp $tmp ["-q" "--manifest" $m])
	let unioned  = (run-fp $tmp ["-q" "--manifest" $m "b.txt"])
	# Adding b.txt via positional must change the hash.
	assert ($m_only.stdout != $unioned.stdout) "positional addition should change hash"
	rm -rf $tmp
	print "  ok\n"
}

# --cmd picks per-cmd srcs; resulting hash differs from target-level.
def test_cmd_scopes_srcs_to_cmd_entry [] {
	print "test --cmd scopes hash to per-cmd srcs..."
	let tmp = (make-tmp)
	"a\n" | save -f ($tmp | path join "a.txt")
	"b\n" | save -f ($tmp | path join "b.txt")
	let m = ($tmp | path join "bayt.test.json")
	write-manifest $m ["a.txt"] --cmds [
		{name: "foo", srcs: {globs: ["b.txt"], exclude: []}}
	]
	let target  = (run-fp $tmp ["-q" "--manifest" $m])
	let cmd_foo = (run-fp $tmp ["-q" "--manifest" $m "--cmd" "foo"])
	assert ($target.exit == 0)  $"target run failed: ($target.stderr)"
	assert ($cmd_foo.exit == 0) $"cmd run failed: ($cmd_foo.stderr)"
	assert ($target.stdout != $cmd_foo.stdout) "target and per-cmd hashes should differ"
	rm -rf $tmp
	print "  ok\n"
}

# --exclude filters files out of the hash input.
def test_exclude_filters_files [] {
	print "test --exclude filters files..."
	let tmp = (make-tmp)
	mkdir ($tmp | path join "src")
	mkdir ($tmp | path join "src/skip")
	"keep\n" | save -f ($tmp | path join "src/k.txt")
	"drop\n" | save -f ($tmp | path join "src/skip/d.txt")

	let with_skip = (run-fp $tmp ["-q" "src"])
	let no_skip   = (run-fp $tmp ["-q" "--exclude" "**/skip/**" "src"])
	assert ($with_skip.stdout != $no_skip.stdout) "excluding files should change hash"
	rm -rf $tmp
	print "  ok\n"
}

# Bare invocation (no paths, no manifest) errors loudly.
def test_no_paths_errors [] {
	print "test no paths + no --manifest errors..."
	let tmp = (make-tmp)
	let r = (run-fp $tmp ["-q"])
	assert ($r.exit != 0) "should error without input"
	assert ($r.stderr | str contains "path required") "error should explain"
	rm -rf $tmp
	print "  ok\n"
}

# --- git mode -------------------------------------------------------

# A tracked file in a git work tree hashes via git hash-object.
# This exercises the git branch of compute-fingerprint (vs. the
# glob+sha256 fallback every other test runs).
# Bracket-class pattern must resolve to its file (no-git mode) — a
# pattern like `[m]ise.toml` is a glob, not a literal, and editing the
# matched file must flip the hash.
def test_bracket_glob_hashes_matching_file [] {
	print "test bracket glob hashes its matching file..."
	let tmp = (make-tmp)
	"tools-v1\n" | save -f ($tmp | path join "mise.toml")
	let r1 = (run-fp $tmp ["-q" "[m]ise.toml"])
	assert ($r1.exit == 0) $"bracket glob should resolve: ($r1.stderr)"
	let direct = (run-fp $tmp ["-q" "mise.toml"])
	assert ($r1.stdout == $direct.stdout) "bracket glob should hash the same file as the literal"
	"tools-v2\n" | save -f ($tmp | path join "mise.toml")
	let r2 = (run-fp $tmp ["-q" "[m]ise.toml"])
	assert ($r1.stdout != $r2.stdout) "hash should change when the bracket-matched file changes"
	rm -rf $tmp
	print "  ok\n"
}

# Same contract in git mode: bracket patterns route through the git
# pathspec branch (git ls-files understands them), not the literal
# existence probe.
def test_bracket_glob_hashes_in_git_mode [] {
	print "test bracket glob resolves through git pathspecs..."
	let tmp = (make-tmp)
	"tools\n" | save -f ($tmp | path join "mise.toml")
	let init = (do {
		cd $tmp
		^git init -q
		^git -c user.email=t@t -c user.name=t add mise.toml
		^git -c user.email=t@t -c user.name=t commit -q -m init
	} | complete)
	assert ($init.exit_code == 0) $"git init/commit failed: ($init.stderr)"
	let r = (run-fp $tmp ["-q" "[m]ise.toml"])
	assert ($r.exit == 0) $"git-mode bracket glob should succeed: ($r.stderr)"
	assert (not ($r.stderr | str contains "skipping")) $"bracket glob must not be dropped as a missing literal: ($r.stderr)"
	rm -rf $tmp
	print "  ok\n"
}

# Bracket-only outs are the optional-file idiom: absence is a valid
# state and must not fail the stamp check. Star globs keep the strict
# ≥1-match contract (covered by test_check_misses_when_outs_missing).
def test_check_tolerates_missing_optional_bracket_out [] {
	print "test check tolerates absent bracket-only optional out..."
	let tmp = (make-tmp)
	"src\n" | save -f ($tmp | path join "src.txt")
	let stamp = ($tmp | path join "s.hash")
	run-fp $tmp ["--stamp-file" $stamp "--update-stamp" "src.txt"]
	let r = (run-fp $tmp ["--stamp-file" $stamp "--outs" "[o]ptional.toml" "src.txt"])
	assert ($r.exit == 0) $"optional bracket out should not fail the check, got ($r.exit): ($r.stderr)"
	rm -rf $tmp
	print "  ok\n"
}

# state entries join the presence probe (never the cache payload): a
# stamped check fails when a state path is deleted, forcing the cmd —
# whose tool owns the restore — to rerun.
def test_state_absence_fails_check [] {
	print "test state absence fails the stamp check..."
	let tmp = (make-tmp)
	"src\n" | save -f ($tmp | path join "src.txt")
	mkdir ($tmp | path join "node_modules")
	"x\n" | save -f ($tmp | path join "node_modules/marker")
	write-manifest ($tmp | path join "m.json") ["src.txt"] --state ["node_modules"]
	let stamp = ($tmp | path join "s.hash")
	run-fp $tmp ["--manifest" "m.json" "--stamp-file" $stamp "--update-stamp"]
	let ok = (run-fp $tmp ["--manifest" "m.json" "--stamp-file" $stamp])
	assert ($ok.exit == 0) $"check should pass with state present: ($ok.stderr)"
	rm -rf ($tmp | path join "node_modules")
	let r = (run-fp $tmp ["--manifest" "m.json" "--stamp-file" $stamp])
	assert ($r.exit == 1) "check must fail when a state path is deleted"
	rm -rf $tmp
	print "  ok\n"
}

def test_git_mode_succeeds [] {
	print "test git-mode (ls-files + hash-object) succeeds..."
	let tmp = (make-tmp)
	"tracked\n" | save -f ($tmp | path join "t.txt")
	let init = (do {
		cd $tmp
		^git init -q
		^git -c user.email=t@t -c user.name=t add t.txt
		^git -c user.email=t@t -c user.name=t commit -q -m init
	} | complete)
	assert ($init.exit_code == 0) $"git init/commit failed: ($init.stderr)"
	let r = (run-fp $tmp ["-q" "t.txt"])
	assert ($r.exit == 0) $"git-mode hash should succeed: ($r.stderr)"
	assert (($r.stdout | str trim | str length) > 0) "should emit a hash"
	rm -rf $tmp
	print "  ok\n"
}

# A dep contributes its own fingerprint, so a change anywhere in the chain
# reaches the root.
def test_dep_change_reaches_the_root [] {
	print "test a change in a dep moves the dependent's hash..."
	let tmp = (make-tmp)
	mkdir ($tmp | path join ".bayt")
	"leaf\n" | save -f ($tmp | path join "leaf.txt")
	"root\n" | save -f ($tmp | path join "root.txt")
	write-manifest ($tmp | path join ".bayt" "bayt.leaf.json") ["leaf.txt"] --name "leaf"
	write-manifest ($tmp | path join ".bayt" "bayt.root.json") ["root.txt"] --name "root" --deps [{name: "leaf", dir: ""}]

	let before = (run-fp $tmp ["-q" "--manifest" ($tmp | path join ".bayt" "bayt.root.json")])
	"leaf changed\n" | save -f ($tmp | path join "leaf.txt")
	let after = (run-fp $tmp ["-q" "--manifest" ($tmp | path join ".bayt" "bayt.root.json")])
	assert ($before.stdout != $after.stdout) "a dep source change must move the dependent's hash"
	rm -rf $tmp
	print "  ok\n"
}

# With no stamp to read, the dep must still be hashed. Dropping it yields a
# hash that collides across trees differing only inside that dep.
def test_absent_stamp_still_counts_the_dep [] {
	print "test a missing dep stamp does not drop the dep..."
	let tmp = (make-tmp)
	mkdir ($tmp | path join ".bayt")
	"leaf\n" | save -f ($tmp | path join "leaf.txt")
	write-manifest ($tmp | path join ".bayt" "bayt.leaf.json") ["leaf.txt"] --name "leaf"
	write-manifest ($tmp | path join ".bayt" "bayt.root.json") [] --name "root" --deps [{name: "leaf", dir: ""}]
	let mroot = ($tmp | path join ".bayt" "bayt.root.json")

	# No stamps anywhere: the dep must still be walked.
	let a = (run-fp $tmp ["-q" "--manifest" $mroot])
	"leaf changed\n" | save -f ($tmp | path join "leaf.txt")
	let b = (run-fp $tmp ["-q" "--manifest" $mroot])
	assert ($a.stdout != $b.stdout) "with no stamp the dep must still be hashed"
	rm -rf $tmp
	print "  ok\n"
}

# A present stamp is read instead of recomputing, and must agree with what
# recomputation would have produced.
def test_stamp_memo_agrees_with_recompute [] {
	print "test a fresh stamp memo agrees with recomputing the dep..."
	let tmp = (make-tmp)
	mkdir ($tmp | path join ".bayt")
	mkdir ($tmp | path join ".task" "bayt")
	"leaf\n" | save -f ($tmp | path join "leaf.txt")
	write-manifest ($tmp | path join ".bayt" "bayt.leaf.json") ["leaf.txt"] --name "leaf"
	write-manifest ($tmp | path join ".bayt" "bayt.root.json") [] --name "root" --deps [{name: "leaf", dir: ""}]
	let mroot = ($tmp | path join ".bayt" "bayt.root.json")

	let no_memo = (run-fp $tmp ["-q" "--manifest" $mroot])
	run-fp $tmp ["--manifest" ($tmp | path join ".bayt" "bayt.leaf.json")
	             "--stamp-file" ".task/bayt/leaf.hash" "--update-stamp"]
	let with_memo = (run-fp $tmp ["-q" "--manifest" $mroot])
	assert ($with_memo.stdout == $no_memo.stdout) "reading the memo must equal recomputing"
	rm -rf $tmp
	print "  ok\n"
}

# The manifest is one of its own srcs, so the walk finds it too. Two spellings
# of the same file survive dedup and get hashed twice, moving the digest.
def test_manifest_spelling_does_not_change_the_hash [] {
	print "test relative and absolute --manifest agree..."
	let tmp = (make-tmp)
	mkdir ($tmp | path join ".bayt")
	"x\n" | save -f ($tmp | path join "a.txt")
	let m = ($tmp | path join ".bayt" "bayt.test.json")
	write-manifest $m ["**/*"]
	let absolute = (run-fp $tmp ["-q" "--manifest" $m])
	let relative = (run-fp $tmp ["-q" "--manifest" ".bayt/bayt.test.json"])
	assert ($absolute.stdout == $relative.stdout) "path spelling must not change the hash"
	rm -rf $tmp
	print "  ok\n"
}
