#!/usr/bin/env nu
# cache.nu — content-addressable cache for bayt targets.
#
# Wrap a cmd with restore-before-run + store-after-success. Cache key
# comes from fingerprint.nu's compute-fingerprint applied to the same
# manifest as fingerprint.nu's hash-stamp — single source of truth.
#
# Modes (composable; opt-in via flags from gen_taskfile's _cacheWrap):
#   default         exact-match restore + always run cmd
#   --full          exact-match restore + skip cmd  (gradle daemon escape hatch)
#   --similar       on miss, restore closest entry as warm starting state
#
# Backend (env-selected, first match wins):
#   BAYT_CACHE_URL       buchgr/bazel-remote HTTP (start with --disable_http_ac_validation;
#                        bazel-remote handles S3/GCS/Azure/depot.dev chaining itself)
#   BAYT_CACHE_REGISTRY  ORAS OCI registry (`oras` CLI required)
#   (none)               local FS at $BAYT_CACHE_DIR ($XDG_CACHE_HOME/bayt
#                        on *nix, $LOCALAPPDATA/bayt on Windows, or
#                        ~/.cache/bayt fallback)
#
# Other env knobs:
#   BAYT_CACHE_TOKEN     auth bearer for bazel-remote
#   BAYT_CACHE_ENABLED   "false" bypasses the wrap entirely
#   BAYT_CACHE_MAX_SIZE  local-FS GC budget in bytes (default 10GB)
#   BAYT_CACHE_NO_GC     "true" skips gc at end of generate-bayt
#   BAYT_CACHE_DEBUG     path; appends one JSON record per invocation
#                        with the cache decision (for tests + debugging)
#   BAYT_CACHE_BRANCH    used by --similar's metadata scoring
#
# See plugins/bayt/README.md for design rationale and the two-layer
# cache story (cache.nu per-target + tool-native per-task).

use ./fingerprint.nu [compute-fingerprint, resolve-manifest]

# ============================================================================
# Similarity scoring (used by every backend's lookup path)
# ============================================================================
#
# Each cache entry carries a metadata record:
#   {user: string, branch: string, ts: string, inputs: {path: hash, ...}}
# Captured at PUT time. user defaults to $env.USER; branch to
# $env.BAYT_CACHE_BRANCH (caller injects, e.g. from `git rev-parse
# --abbrev-ref HEAD`); ts to current timestamp; inputs to the per-file
# hash map fingerprint.nu produces.
#
# Lookup ranks candidates by weighted intersection. Weights are fixed
# constants — promoting them to a per-project DSL is cheap if real
# usage shows projects want different trade-offs.
const WEIGHT_FILE   = 1.0
const WEIGHT_BRANCH = 30.0
const WEIGHT_USER   = 50.0
const WEIGHT_DAY    = 5.0

def current-meta [project: string, target: string, inputs: record]: nothing -> record {
	{
		project: $project,
		target: $target,
		user: ($env.USER? | default ""),
		branch: ($env.BAYT_CACHE_BRANCH? | default ""),
		ts: (date now | format date "%+"),
		inputs: $inputs,
	}
}

# Score one candidate against the current state. Higher = better
# starting point. Returns 0 for entries with zero overlap (no shared
# files, no shared user/branch, different day) — caller filters those
# out.
def similarity-score [current: record, entry_meta: record]: nothing -> float {
	let file_score = (
		$current.inputs | columns | reduce --fold 0.0 { |path, acc|
			let cur = ($current.inputs | get $path)
			let other = ($entry_meta.inputs? | default {} | get -o $path)
			if $other == $cur { $acc + $WEIGHT_FILE } else { $acc }
		}
	)
	let user_score   = if ($current.user   != "") and ($entry_meta.user?   == $current.user)   { $WEIGHT_USER   } else { 0.0 }
	let branch_score = if ($current.branch != "") and ($entry_meta.branch? == $current.branch) { $WEIGHT_BRANCH } else { 0.0 }
	let day_score    = if ($current.ts | str substring 0..10) == (($entry_meta.ts? | default "") | str substring 0..10) { $WEIGHT_DAY } else { 0.0 }
	$file_score + $user_score + $branch_score + $day_score
}

# ============================================================================
# Backend selection
# ============================================================================

def backend []: nothing -> string {
	if (($env.BAYT_CACHE_URL?      | default "") | is-not-empty) { return "bazel" }
	if (($env.BAYT_CACHE_REGISTRY? | default "") | is-not-empty) { return "oras"  }
	"local"
}

def cache-enabled []: nothing -> bool {
	($env.BAYT_CACHE_ENABLED? | default "true") != "false"
}

# Append one JSON record per cache.nu invocation to BAYT_CACHE_DEBUG
# (if set). Used by tests and "why didn't this hit?" investigations
# to inspect the actual cache decision rather than guess from timing.
# Best-effort: a write failure would only lose telemetry, never block
# the build, so any error is silently dropped.
def debug-log [record: record] {
	let path = ($env.BAYT_CACHE_DEBUG? | default "")
	if ($path | is-empty) { return }
	try {
		mkdir ($path | path dirname)
		$"($record | to json --raw)\n" | save --append $path
	} catch { }
}

# Expand a list of glob patterns to a flat list of matched files.
# Used by every backend's put path. Empty patterns / no-matches yield
# []; malformed glob errors are swallowed (a rare case, not worth
# erroring the build over). Caller resolves files relative to cwd.
#
# `--no-dir` filters real directories but NOT symlinks-to-directories;
# Nuxt-style build trees can include those. The `path type == "file"`
# filter catches both — a file or a symlink-to-file.
def expand-globs [globs: list<string>]: nothing -> list<string> {
	$globs
	| each { |g| try { glob $g --no-dir } catch { [] } }
	| flatten
	| where { |p| ($p | path type) == "file" }
}

# ============================================================================
# Local-FS backend
# ============================================================================

def local-root []: nothing -> path {
	# Resolution order:
	#   1. $BAYT_CACHE_DIR if set (explicit override)
	#   2. $XDG_CACHE_HOME/bayt if set (XDG-compliant *nix default)
	#   3. $LOCALAPPDATA/bayt if set (Windows-idiomatic; undefined on
	#      *nix and inside Linux containers, so the rung short-circuits
	#      there and resolution falls through to the XDG fallback)
	#   4. ~/.cache/bayt (XDG fallback — also the in-container default
	#      since BuildKit's bayt-cache mount lands at /root/.cache/bayt)
	let explicit = ($env.BAYT_CACHE_DIR? | default "")
	if ($explicit | is-not-empty) { return $explicit }
	let xdg = ($env.XDG_CACHE_HOME? | default "")
	if ($xdg | is-not-empty) { return ($xdg | path join "bayt") }
	let lad = ($env.LOCALAPPDATA? | default "")
	if ($lad | is-not-empty) { return ($lad | path join "bayt") }
	$nu.home-dir | path join ".cache" "bayt"
}

# Local entry path, sharded by first 2 hash chars.
def local-entry [key: string]: nothing -> path {
	(local-root) | path join ($key | str substring 0..2) | path join $key
}

# Copy every file under <outs_dir>/** into the corresponding cwd path,
# creating parent dirs as needed. No-op if <outs_dir> is missing —
# entries with empty outs lists are a valid hit. Used by the local-FS
# restore paths (exact and warm).
def restore-outs-from [outs_dir: path] {
	if not ($outs_dir | path exists) { return }
	let cwd = (pwd)
	# Same `path type == "file"` filter as expand-globs — `--no-dir`
	# alone misses symlinks-to-directories.
	for src in (glob ($outs_dir | path join "**/*") --no-dir | where { |p| ($p | path type) == "file" }) {
		let dst = ($cwd | path join ($src | path relative-to $outs_dir))
		mkdir ($dst | path dirname)
		cp $src $dst
	}
}

# Restore from a local entry. Returns true on hit (restored) or the
# entry-doesn't-exist false. Errors during the copy itself bubble up
# to the caller's try/catch as warnings (broken cache shouldn't block
# the build).
def local-get [key: string]: nothing -> bool {
	let entry = (local-entry $key)
	if not ($entry | path exists) { return false }
	restore-outs-from ($entry | path join "outs")
	true
}

# Store an entry locally. Atomic via tempdir + rename. Skip on
# already-published (winner-takes-all race semantics).
def local-put [key: string, outs_globs: list<string>, manifest: string, meta: record] {
	let entry = (local-entry $key)
	if ($entry | path exists) { return }

	let tmp_root = ((local-root) | path join "_tmp")
	mkdir $tmp_root
	let tmp = ($tmp_root | path join (random uuid))
	let outs_tmp = ($tmp | path join "outs")
	mkdir $outs_tmp

	let cwd = (pwd)
	for src in (expand-globs $outs_globs) {
		let dst = ($outs_tmp | path join ($src | path relative-to $cwd))
		mkdir ($dst | path dirname)
		cp $src $dst
	}
	cp $manifest ($tmp | path join "manifest.json")
	$meta | to json | save -f ($tmp | path join "metadata.json")

	mkdir ($entry | path dirname)
	# The path-exists check catches the common race; mv inside try
	# catches the narrow TOCTOU window where another writer publishes
	# between the check and the rename. On macOS, `mv tmp existing-dir`
	# would otherwise move tmp INSIDE existing-dir (silent corruption-
	# by-litter) instead of failing — wrapping in try makes either OS
	# safe. Loser cleans up its tempdir; winner's entry stands.
	if ($entry | path exists) {
		rm -rf $tmp
	} else {
		try { mv $tmp $entry } catch { rm -rf $tmp }
	}
}

# Walk every local entry, score against `current` meta, return the
# best match (with scoring details) if its score > 0. Used on
# exact-key miss to pick a warm starting state — gradle/cargo/etc.
# validate restored state on every invocation so a "close enough"
# entry is safe to restore (worst case: tool re-does more work than
# a perfect match would).
#
# Returns: { entry: path, score: float, candidate_count: int,
#            winner_meta: record } on hit, or null on no candidates.
def local-similar [current: record]: nothing -> any {
	let root = (local-root)
	if not ($root | path exists) { return null }
	let scored = (
		glob ($root | path join "*/*") --no-symlink --no-file
		| where { |p| not ($p | str ends-with "/_tmp") }
		| each { |entry|
			let meta_path = ($entry | path join "metadata.json")
			if not ($meta_path | path exists) { return null }
			let meta = (try { open $meta_path } catch { return null })
			# Different (project, target) entries share storage but
			# never share inputs in any meaningful way.
			if ($meta.project? | default "") != $current.project { return null }
			if ($meta.target?  | default "") != $current.target  { return null }
			{ entry: $entry, meta: $meta, score: (similarity-score $current $meta) }
		}
		| where { |x| $x != null and $x.score > 0 }
		| sort-by score --reverse
	)
	if ($scored | is-empty) { null } else {
		let winner = ($scored | first)
		{
			entry: $winner.entry,
			score: $winner.score,
			candidate_count: ($scored | length),
			winner_meta: $winner.meta,
		}
	}
}

# ============================================================================
# buchgr/bazel-remote HTTP cache backend (pure nushell, no curl/tar)
#
# Stores each entry's outs as a tab-separated archive on /ac/<hash>:
#   <relative-path>\t<base64-content>\n
# Lives on the AC (Action Cache) endpoint rather than CAS because
# bazel-remote's AC accepts arbitrary bytes when started with
# `--disable_http_ac_validation`; without that flag, AC POSTs of
# non-protobuf bytes are rejected. CAS would require us to compute
# bazel-conformant SHA-256 digests for every blob — much more work
# for the same on-the-wire result.
#
# Bring bazel-remote up with:
#   bazel-remote --dir <path> --max_size <gb> --disable_http_ac_validation
# Eviction is bazel-remote's job (--max_size); cache.nu's gc
# subcommand is local-FS only and won't touch this backend.
# ============================================================================

def bazel-url []: nothing -> string { $env.BAYT_CACHE_URL? | default "" }

def bazel-headers []: nothing -> record {
	let token = ($env.BAYT_CACHE_TOKEN? | default "")
	if ($token | is-empty) { {} } else { { Authorization: $"Bearer ($token)" } }
}

def bazel-get [key: string]: nothing -> bool {
	let archive = try { http get --headers (bazel-headers) --raw $"(bazel-url)/ac/($key)" } catch { return false }
	if ($archive | is-empty) { return false }
	let cwd = (pwd)
	$archive | decode utf-8 | lines | where { |l| ($l | is-not-empty) } | each { |line|
		let parts = ($line | split row "\t")
		if ($parts | length) >= 2 {
			let dst = ($cwd | path join ($parts | get 0))
			mkdir ($dst | path dirname)
			$parts | get 1 | decode base64 | save --raw -f $dst
		}
	} | ignore
	true
}

def bazel-put [key: string, outs_globs: list<string>, _manifest: string] {
	let cwd = (pwd)
	let files = (expand-globs $outs_globs)
	# Skip empty PUTs: bazel-get treats an empty response body as miss
	# (no way to distinguish "stored an empty archive" from "404"
	# without an extra HEAD request), so storing an empty archive
	# would fail to round-trip on the next call.
	if ($files | is-empty) { return }
	let archive = ($files | each { |f|
		let rel = ($f | path relative-to $cwd)
		let content = (open --raw $f | encode base64)
		$"($rel)\t($content)"
	} | str join "\n")
	$archive | http put --headers (bazel-headers) --content-type "application/octet-stream" $"(bazel-url)/ac/($key)"
}

# ============================================================================
# ORAS OCI registry backend
#
# Each entry pushed as an OCI artifact tagged <project>-<target>-<hash[0:16]>.
# Including project + target in the tag means a shared registry across
# many projects keeps entries human-browsable (the OCI tag list shows
# what's cached for what); the truncated content hash disambiguates
# different inputs to the same target. ORAS handles transport, manifest
# creation, content addressing on its own; we just shell out. Registry's
# GC policy (e.g. GCR's untagged-image cleanup) handles eviction.
# ============================================================================

def oras-ref [project: string, target: string, key: string]: nothing -> string {
	let short = ($key | str substring 0..16)
	# OCI tag charset: [a-zA-Z0-9._-], max 128. project + target both
	# already pass this constraint by bayt's own naming rules
	# (slash→underscore on dirs, alphanum verbs).
	$"($env.BAYT_CACHE_REGISTRY?):($project)-($target)-($short)"
}

def oras-get [project: string, target: string, key: string]: nothing -> bool {
	if (which oras | is-empty) {
		error make { msg: "cache.nu: BAYT_CACHE_REGISTRY set but `oras` CLI not on PATH" }
	}
	let ref = (oras-ref $project $target $key)
	let exists = (do { ^oras manifest fetch $ref } | complete)
	if $exists.exit_code != 0 { return false }
	^oras pull $ref --output .
	true
}

def oras-put [project: string, target: string, key: string, outs_globs: list<string>, _manifest: string] {
	if (which oras | is-empty) {
		error make { msg: "cache.nu: BAYT_CACHE_REGISTRY set but `oras` CLI not on PATH" }
	}
	let cwd = (pwd)
	let files = (expand-globs $outs_globs | each { |f| $f | path relative-to $cwd })
	if ($files | is-empty) { return }
	^oras push (oras-ref $project $target $key) ...$files
}

# ============================================================================
# Backend dispatch
# ============================================================================

# Backend dispatch.
#
# project + target are passed for ORAS tag construction and local-FS
# similarity scoping. `meta` is the full metadata record (user, branch,
# ts, inputs); each backend persists it however its storage shape
# allows (local: metadata.json sibling; ORAS: OCI annotations;
# bazel-remote: JSON-prefix in the blob). bazel/oras `_meta` ignored
# until phase 2/3 implements their metadata persistence.
def backend-get [project: string, target: string, key: string]: nothing -> bool {
	match (backend) {
		"bazel" => (bazel-get $key)
		"oras"  => (oras-get  $project $target $key)
		_       => (local-get $key)
	}
}

def backend-put [project: string, target: string, key: string, outs_globs: list<string>, manifest: string, meta: record] {
	match (backend) {
		"bazel" => { bazel-put $key $outs_globs $manifest }
		"oras"  => { oras-put  $project $target $key $outs_globs $manifest }
		_       => { local-put $key $outs_globs $manifest $meta }
	}
}

# Find a "similar enough" cached entry to use as a warm starting
# state. Backend-specific:
#   * local-FS: walk all entries, score by weighted similarity
#   * bazel-remote: pointer-based candidate enumeration (phase 2)
#   * ORAS: tag-listing-based enumeration (phase 3)
# Returns a record { entry, score, candidate_count, winner_meta } on
# hit, or null on no match. The structured shape supports debug
# tracing (BAYT_CACHE_DEBUG) without re-walking the cache.
def backend-similar [current: record]: nothing -> any {
	match (backend) {
		"local" => (local-similar $current)
		_ => null   # phase 2/3 will fill in
	}
}

# Restore an entry's outs into the workspace from a backend-specific
# handle (a path for local-FS, a key for bazel/oras).
def backend-restore-from [handle: any] {
	match (backend) {
		"local" => { restore-outs-from ($handle | path join "outs") }
		_ => { }   # phase 2/3
	}
}

# ============================================================================
# Run the wrapped cmd
# ============================================================================

# Run an external cmd, streaming its stdout/stderr live (no buffering),
# returning its exit code without blowing up the cache.nu process on
# non-zero exit.
#
# Three nushell quirks make this fiddly:
#   1. `do --ignore-errors { ^cmd }` zeros LAST_EXIT_CODE (treats the
#      ignored error as success), so we can't use it.
#   2. `^cmd | complete` captures stdout/stderr into a buffer — defeats
#      live progress for long-running cmds like gradle, so we can't
#      use it either.
#   3. `try { ^cmd } catch { }` keeps streaming AND preserves a non-zero
#      LAST_EXIT_CODE, BUT it does NOT reset LAST_EXIT_CODE if cmd
#      succeeded — it's an inherited value from the surrounding scope.
#      So if a *prior* `try { error make ... } catch { }` left
#      LAST_EXIT_CODE=1, a successful ^cmd inside try/catch leaves it
#      at 1 too, silently masking success as failure. Reset it to 0
#      first.
def run-cmd [cmd_args: list<string>]: nothing -> int {
	# nushell's --wrapped passes `--` through literally as the first
	# arg (unlike POSIX shells where the parser consumes it).
	let args = if ($cmd_args | length) > 0 and ($cmd_args | first) == "--" { $cmd_args | skip 1 } else { $cmd_args }
	if ($args | is-empty) { error make { msg: "cache.nu run: empty cmd (need '-- <cmd>')" } }
	$env.LAST_EXIT_CODE = 0
	try { ^($args | first) ...($args | skip 1) } catch { }
	$env.LAST_EXIT_CODE
}

# ============================================================================
# Subcommands
# ============================================================================

# `cache.nu run` — restore on hit, run cmd (or skip if --skip), store
# outs on success. Errors during restore or store are logged but never
# fatal — a broken cache shouldn't block the build.
export def --wrapped "main run" [
	--manifest: string                        # path to .bayt/bayt.<verb>.json
	--cmd: string = ""                        # optional cmd name within manifest's cmds list
	--full                                    # on EXACT hit, skip cmd entirely (trust the restored outs)
	--similar                                 # on EXACT miss, restore closest cached entry as warm starting state
	...cmd_args: string                       # the cmd to execute (everything after `--`)
] {
	if not (cache-enabled) { exit (run-cmd $cmd_args) }
	if ($manifest | is-empty) { error make { msg: "cache.nu run: --manifest required" } }

	# Resolving the manifest + computing the key requires every input
	# in the merkle chain to exist on disk: project srcs, the manifest
	# itself, and (critically) cross-project dep stamps at
	# `../../<dep>/.task/bayt/<n>.hash`. Inside docker these stamps are
	# COPYed in via the Dockerfile chain. On the host they only exist
	# after each dep has been built — `just sayt build` from a fresh
	# tree has none of them. compute-hash errors loudly in that case;
	# the right response here is "no cache key → no cache lookup →
	# run cmd raw" (the cmd's own semantics handle the missing inputs).
	#
	# Resolve manifest, derive cache key + per-file input set + project
	# metadata. project + target identify the (project, verb) namespace;
	# inputs feeds similarity scoring on lookup; the merkle hash IS the
	# exact-match cache key. Bypass if any of these can't be computed
	# (host invocation with missing dep stamps, malformed manifest, …).
	let m_or_err = try {
		let resolved = (resolve-manifest $manifest $cmd)
		let m = (open $manifest)
		let fp = (compute-fingerprint $resolved.paths $resolved.excludes)
		{
			ok: true,
			key: $fp.hash,
			inputs: $fp.inputs,
			outs: $resolved.outs,
			project: $m.project,
			target: $m.name,
		}
	} catch { |e|
		{ ok: false, msg: $e.msg }
	}
	if not $m_or_err.ok {
		print -e $"BAYT_CACHE bypass: ($m_or_err.msg)"
		exit (run-cmd $cmd_args)
	}
	let key     = $m_or_err.key
	let outs    = $m_or_err.outs
	let project = $m_or_err.project
	let target  = $m_or_err.target
	let meta    = (current-meta $project $target $m_or_err.inputs)

	# Three lookup phases:
	#   1. exact-match on content key
	#   2. similar-match on weighted intersection (warm starting state)
	#   3. cold (cmd runs from nothing)
	let exact_hit = try {
		backend-get $project $target $key
	} catch { |e|
		print -e $"BAYT_CACHE warn: backend GET failed for ($key): ($e.msg) — falling through"
		false
	}

	# Warm-start lookup is opt-in via --similar. Without the flag,
	# behaviour collapses to "exact-match only" — the safe-but-low-
	# benefit shape that doesn't risk surprising the user.
	let warm_result = if $exact_hit or (not $similar) { null } else {
		try { backend-similar $meta } catch { null }
	}
	let warm_hit = if $warm_result != null {
		backend-restore-from $warm_result.entry
		true
	} else { false }

	let base_mode = if $full { "full" } else { "run" }
	let mode = if $similar { $base_mode + "+similar" } else { $base_mode }
	let status = if $exact_hit { "HIT" } else if $warm_hit { "WARM" } else { "MISS" }
	print -e $"BAYT_CACHE ($status) ($mode) ($key)"

	debug-log {
		ts: (date now | format date "%+"),
		project: $project,
		target: $target,
		key: $key,
		mode: $mode,
		status: $status,
		similar_attempted: ($similar and not $exact_hit),
		warm_candidate_count: (if $warm_result != null { $warm_result.candidate_count } else { 0 }),
		warm_winner_score: (if $warm_result != null { $warm_result.score } else { 0.0 }),
		warm_winner: (if $warm_result != null {
			{
				user: ($warm_result.winner_meta.user? | default ""),
				branch: ($warm_result.winner_meta.branch? | default ""),
				ts: ($warm_result.winner_meta.ts? | default ""),
			}
		} else { null }),
	}

	# --full + exact-hit is the only case that lets us short-circuit
	# the cmd entirely. --full + warm-hit still runs cmd because warm
	# state is by definition "close, not exact" — the tool's
	# incremental engine has to validate and finish the work.
	if $exact_hit and $full { exit 0 }

	let exit_code = (run-cmd $cmd_args)
	if $exit_code != 0 { exit $exit_code }

	if not $exact_hit {
		# PUT both on miss AND on warm-hit: warm-hit by definition
		# means our exact key wasn't in cache, so we want to record
		# this build's output under our key. No try/catch — silent
		# PUT failure means caching is broken for the user explicitly
		# opted into backend.
		backend-put $project $target $key $outs $manifest $meta
	}
	exit 0
}

# `cache.nu gc` — local-FS only. Walks entries, sums apparent sizes,
# evicts oldest-mtime first until total is under BAYT_CACHE_MAX_SIZE
# (default 10 GB). Quiet on no-op. Generate-bayt.nu invokes this at
# the end of regeneration unless BAYT_CACHE_NO_GC=true.
export def "main gc" [
	--max-bytes: int = 10737418240            # default 10 GB
] {
	if (backend) != "local" { return }                       # remote backends self-manage
	if (($env.BAYT_CACHE_NO_GC? | default "") == "true") { return }
	let root = (local-root)
	if not ($root | path exists) { return }

	# Budget is bytes (int). du returns filesize values; convert via
	# `into int` so arithmetic and comparisons work uniformly.
	let env_budget = ($env.BAYT_CACHE_MAX_SIZE? | default "")
	let budget = if ($env_budget | is-empty) { $max_bytes } else { $env_budget | into int }
	let entries = (
		glob ($root | path join "*/*") --no-symlink --no-file
		| where { |p| not ($p | str ends-with "/_tmp") }
		| each { |p| {
			path: $p,
			size: (du $p | get apparent | math sum | into int),
			mtime: (ls -D $p | get 0.modified)
		} }
	)
	let total = ($entries | get size | math sum | default 0)
	if $total <= $budget { return }

	let to_drop = ($entries | sort-by mtime | reduce --fold {acc: [], saved: 0} { |row, st|
		if (($total - $st.saved) <= $budget) { $st } else {
			{acc: ($st.acc | append $row), saved: ($st.saved + $row.size)}
		}
	})
	for row in $to_drop.acc { rm -rf $row.path }
	let n = ($to_drop.acc | length)
	let reclaimed = ($to_drop.saved | into filesize)
	print -e $"BAYT_CACHE gc: evicted ($n) entries, ($reclaimed) reclaimed"
}

# `cache.nu status` — local-FS only quick view of size + entry count.
export def "main status" [] {
	if (backend) != "local" {
		print $"backend: (backend) — status only meaningful for local-FS"
		return
	}
	let root = (local-root)
	if not ($root | path exists) {
		print $"cache empty: ($root)"
		return
	}
	let entries = (glob ($root | path join "*/*") --no-symlink --no-file | where { |p| not ($p | str ends-with "/_tmp") })
	let total = ($entries | each { |d| (du $d | get apparent | math sum) } | math sum | default 0)
	print { root: $root, entries: ($entries | length), size: ($total | into filesize) }
}

# `cache.nu clear` — wipe local-FS cache. No prompts (regenerable by
# definition). No-op for remote backends (we don't own them).
export def "main clear" [] {
	if (backend) != "local" {
		print -e $"backend: (backend) — clear only supported for local-FS"
		return
	}
	let root = (local-root)
	if ($root | path exists) {
		rm -rf $root
		print $"cleared: ($root)"
	}
}

def main [] {
	print "cache.nu — content-addressable cache for bayt targets"
	print ""
	print "Subcommands:"
	print "  run --manifest <path> [--cmd <name>] [--full] [--similar] -- <cmd...>"
	print "  gc [--max-bytes <N>]"
	print "  status"
	print "  clear"
	print ""
	print "Env: BAYT_CACHE_URL | BAYT_CACHE_REGISTRY | BAYT_CACHE_DIR (selects backend)"
	print "     BAYT_CACHE_TOKEN, BAYT_CACHE_ENABLED, BAYT_CACHE_MAX_SIZE, BAYT_CACHE_NO_GC"
}
