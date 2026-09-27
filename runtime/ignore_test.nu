#!/usr/bin/env nu
# Tests for ignore.nu — the tracked-files-only ignore matcher.
# Run with: nu ignore_test.nu (from plugins/bayt/runtime)

use std/assert
use ./ignore.nu [parse-file, ignored?, to-regex, compile-rules, walk-scope, enumerate-scopes]

def main [] {
	print "Running bayt/ignore tests...\n"

	test_plain_name_floats_to_any_depth
	test_slash_in_pattern_anchors
	test_leading_slash_anchors
	test_trailing_slash_is_directory_only
	test_star_does_not_cross_a_separator
	test_doublestar_crosses_separators
	test_last_match_wins
	test_negation_reincludes
	test_comments_and_blanks_skipped
	test_escaped_hash_is_literal
	test_char_class
	test_nested_file_overrides_shallower
	test_docker_flavor_always_anchors
	test_multi_dot_extension
	test_bare_dotfile_matches_star_ext
	test_leading_doublestar
	test_depth_one_base_overrides_root
	test_to_regex_treats_dot_as_literal
	test_unclosed_class_is_literal
	test_lines_that_trim_to_nothing_are_dropped
	test_docker_trailing_slash_is_not_dir_only

	if $nu.os-info.name == "windows" {
		print "    SKIP walk tests (fixture paths are POSIX-shaped)"
	} else {
		test_walk_seeds_ancestor_rules
		test_walk_applies_a_nested_ignore_file
		test_walk_honours_parent_exclusion
		test_walk_stops_at_a_repository_boundary
		test_walk_scope_without_git_still_enumerates
	test_tool_boundaries_hold_whatever_their_type
	test_enumerate_scopes_agrees_with_walking_each
	test_enumerate_scopes_omits_the_root
	test_non_ascii_paths_agree_between_backends
		test_docker_flavor_does_not_nest
	}

	print "\nAll bayt/ignore tests passed!"
}

def rules [text: string, base: string = ""]: nothing -> list<record> {
	compile-rules (parse-file $text $base)
}

def hit [text: string, path: string, --dir]: nothing -> bool {
	ignored? $path ($dir | default false) (rules $text)
}

def test_plain_name_floats_to_any_depth [] {
	print "test a pattern with no slash matches at any depth..."
	assert (hit "node_modules" "node_modules" --dir) "root level"
	assert (hit "node_modules" "guis/iris/node_modules" --dir) "nested"
	assert (hit "*.log" "a/b/c.log") "nested file by extension"
	assert (not (hit "*.log" "a/b/c.txt")) "non-matching extension"
}

# The rule that trips naive implementations: a slash anywhere but the end
# anchors, so `src/foo` must NOT match `lib/src/foo`.
def test_slash_in_pattern_anchors [] {
	print "test an interior slash anchors the pattern..."
	assert (hit "src/foo" "src/foo") "anchored match"
	assert (not (hit "src/foo" "lib/src/foo")) "must not float when it contains a slash"
}

def test_leading_slash_anchors [] {
	print "test a leading slash anchors to the ignore file's directory..."
	assert (hit "/build" "build" --dir) "root build"
	assert (not (hit "/build" "guis/iris/build" --dir)) "nested build is not anchored-matched"
}

def test_trailing_slash_is_directory_only [] {
	print "test a trailing slash matches directories only..."
	assert (hit "dist/" "a/dist" --dir) "directory matches"
	assert (not (hit "dist/" "a/dist")) "same path as a FILE must not match"
}

def test_star_does_not_cross_a_separator [] {
	print "test * stops at a separator..."
	assert (hit "a/*.txt" "a/x.txt") "single segment"
	assert (not (hit "a/*.txt" "a/b/x.txt")) "* must not cross /"
}

def test_doublestar_crosses_separators [] {
	print "test ** crosses separators..."
	assert (hit "a/**/x.txt" "a/x.txt") "** matches zero segments"
	assert (hit "a/**/x.txt" "a/b/c/x.txt") "** matches many segments"
	assert (hit "logs/**" "logs/a/b.txt") "trailing ** swallows the rest"
}

def test_last_match_wins [] {
	print "test the last matching rule decides..."
	assert (not (hit "*.log\n!keep.log" "keep.log")) "negation after exclude re-includes"
	assert (hit "!keep.log\n*.log" "keep.log") "exclude after negation wins again"
}

def test_negation_reincludes [] {
	print "test ! re-includes a previously excluded file..."
	let r = (rules "build/\n!build/keep.txt")
	assert (ignored? "build" true $r) "directory still excluded"
	assert (not (ignored? "build/keep.txt" false $r)) "explicit re-include wins by last-match"
}

def test_comments_and_blanks_skipped [] {
	print "test comments and blank lines are skipped..."
	let r = (rules "# a comment\n\n   \n*.log")
	let n = ($r | each {|g| $g.rules} | flatten | length)
	assert ($n == 1) $"expected 1 rule, got ($n)"
}

def test_escaped_hash_is_literal [] {
	print "test \\# is a literal hash, not a comment..."
	assert (hit '\#notes' "#notes") "escaped hash matches a real file named #notes"
}

def test_char_class [] {
	print "test character classes..."
	assert (hit "file[0-9].txt" "file3.txt") "in class"
	assert (not (hit "file[0-9].txt" "filex.txt")) "outside class"
	assert (hit "file[!0-9].txt" "filex.txt") "negated class"
}

# A deeper .gitignore overrides a shallower one, so ordering by base depth is
# load-bearing, not cosmetic.
def test_nested_file_overrides_shallower [] {
	print "test a nested ignore file overrides a shallower one..."
	let shallow = (parse-file "*.log" "")
	let deep = (parse-file "!important.log" "guis/iris")
	let all = (compile-rules ($shallow ++ $deep))
	assert (ignored? "a/x.log" false $all) "shallow rule still applies elsewhere"
	assert (not (ignored? "guis/iris/important.log" false $all)) "deeper negation wins in its subtree"
}

def test_docker_flavor_always_anchors [] {
	print "test dockerignore patterns are context-root relative..."
	let r = (compile-rules (parse-file "build" "" "docker"))
	assert (ignored? "build" true $r) "root match"
	assert (not (ignored? "guis/iris/build" true $r)) "docker patterns do not float"
}

# The by_ext index keys on the text after the LAST dot, so an extension carrying
# its own dot must not be indexed there or the rule becomes unreachable.
def test_multi_dot_extension [] {
	print "test a multi-dot extension still matches..."
	assert (hit "*.tar.gz" "a.tar.gz") "*.tar.gz must match a.tar.gz"
	assert (hit "*.tar.gz" "deep/dir/a.tar.gz") "and at any depth"
	assert (not (hit "*.tar.gz" "a.gz")) "but not a bare .gz"
}

# `*` matches empty, so `*.log` matches a file named exactly `.log`. This is why
# the lookup slices at the last dot rather than using `path parse`'s extension.
def test_bare_dotfile_matches_star_ext [] {
	print "test *.ext matches a bare dotfile of that name..."
	assert (hit "*.log" ".log") "*.log must match .log"
	assert (hit "*.log" "a/.log") "and nested"
}

# The header cites `**/.omc/` and `**/.task/` as the real-world shape, so the
# leading form needs its own coverage; the others test interior and trailing.
def test_leading_doublestar [] {
	print "test a leading **/ matches at every depth..."
	assert (hit "**/.omc" ".omc" --dir) "root level"
	assert (hit "**/.omc" "a/b/.omc" --dir) "nested"
}

# compile-rules sorts bases by segment count, which gives root ("") and a
# depth-1 base the same key — the deeper file must still win.
def test_depth_one_base_overrides_root [] {
	print "test a depth-1 ignore file overrides the root's..."
	let all = (compile-rules ((parse-file "*.log" "") ++ (parse-file "!keep.log" "guis")))
	assert (ignored? "a/keep.log" false $all) "root rule still applies elsewhere"
	assert (not (ignored? "guis/keep.log" false $all)) "deeper negation wins in its subtree"
}

def test_to_regex_treats_dot_as_literal [] {
	print "test a literal dot is not a wildcard..."
	assert (hit "a.b" "a.b") "exact"
	assert (not (hit "a.b" "axb")) "dot must not match an arbitrary character"
}

def test_unclosed_class_is_literal [] {
	print "test an unclosed [ falls back to a literal bracket..."
	assert (hit "file[0-9.txt" "file[0-9.txt") "unclosed class matches itself"
}

def test_lines_that_trim_to_nothing_are_dropped [] {
	print "test lines that trim to nothing produce no rule..."
	let n = (rules "foo   \n/\n!\n!/" | each {|g| $g.rules} | flatten | length)
	assert ($n == 1) $"expected only the foo rule, got ($n)"
}

# dockerignore has no directory-only form; a trailing slash is just a slash.
def test_docker_trailing_slash_is_not_dir_only [] {
	print "test dockerignore has no directory-only suffix..."
	let r = (parse-file "build/" "" "docker" | first)
	assert (not $r.dir_only) "docker patterns are never directory-only"
}

# ---- walk-level tests, over real fixture trees ----

def fixture [spec: record]: nothing -> string {
	let dir = (mktemp -d)
	for path in ($spec | columns) {
		let full = ($dir | path join $path)
		mkdir ($full | path dirname)
		($spec | get $path) | save -f $full
	}
	$dir
}

# A scope nested under the root is still governed by the root's ignore file, so
# without ancestor seeding the walk enumerates files the rules exclude.
def test_walk_seeds_ancestor_rules [] {
	print "test walk seeds ignore rules from every ancestor..."
	let fx = (fixture {".gitignore": "*.log\n", "a/b/keep.txt": "x", "a/b/drop.log": "x"})
	let got = (walk-scope $fx "a/b" "git" --no-git | sort)
	assert ($got == ["a/b/keep.txt"]) $"expected only keep.txt, got ($got | to json --raw)"
	rm -rf $fx
}

def test_walk_applies_a_nested_ignore_file [] {
	print "test walk picks up a nested ignore file as it descends..."
	let fx = (fixture {".gitignore": "", "a/.gitignore": "*.tmp\n", "a/x.tmp": "x", "a/y.txt": "x", "z.tmp": "x"})
	let got = (walk-scope $fx "" "git" --no-git | sort)
	assert ("a/y.txt" in $got) "unignored nested file kept"
	assert (not ("a/x.tmp" in $got)) "nested rule applies in its own subtree"
	assert ("z.tmp" in $got) "nested rule must not leak upward"
	rm -rf $fx
}

# The invariant the header calls load-bearing: pruning is sound because nothing
# under an excluded directory can be re-included, so the walk never descends it.
def test_walk_honours_parent_exclusion [] {
	print "test a negation cannot re-include under an excluded directory..."
	let fx = (fixture {".gitignore": "build/\n!build/keep.txt\n", "build/keep.txt": "x", "src.txt": "x"})
	let got = (walk-scope $fx "" "git" --no-git | sort)
	assert (not ("build/keep.txt" in $got)) $"build/ must stay pruned, got ($got | to json --raw)"
	assert ("src.txt" in $got) "unignored files still enumerate"
	rm -rf $fx
}

def test_walk_stops_at_a_repository_boundary [] {
	print "test a nested .git marks a boundary the walk does not cross..."
	let fx = (fixture {".gitignore": "", "vendor/.git": "gitdir: elsewhere", "vendor/code.rs": "x", "mine.txt": "x"})
	let got = (walk-scope $fx "" "git" --no-git | sort)
	assert (not ("vendor/code.rs" in $got)) $"vendor/ belongs to another repo, got ($got | to json --raw)"
	assert ("mine.txt" in $got) "this repo's own files still enumerate"
	rm -rf $fx
}

# A fixture tree is not a work tree, so the fast path must decline and the walk
# must still answer — a fast path that always returned null would hide here.
def test_walk_scope_without_git_still_enumerates [] {
	print "test walk-scope enumerates outside a git work tree..."
	let fx = (fixture {".gitignore": "*.log\n", "a.txt": "x", "b.log": "x"})
	let got = (walk-scope $fx "" | sort)
	assert ("a.txt" in $got) "fast path declines, walk answers"
	assert (not ("b.log" in $got)) "and the rules were applied"
	rm -rf $fx
}

# `.git` is a directory in a clone and a `gitdir:` pointer FILE in a worktree.
# A dir-only boundary check let that file through, so one commit enumerated
# differently in a worktree than in a clone.
def test_tool_boundaries_hold_whatever_their_type [] {
	print "test .git and .task are boundaries as file or directory..."
	let fx = (fixture {
		".gitignore": "", ".git": "gitdir: elsewhere", ".task": "x",
		"src/.task": "y", "keep.txt": "x",
	})
	let got = (walk-scope $fx "" "git" --no-git | sort)
	assert ("keep.txt" in $got) "ordinary files still enumerate"
	for b in [".git" ".task" "src/.task"] {
		assert (not ($b in $got)) $"($b) is a tool boundary, got ($got | to json --raw)"
	}
	rm -rf $fx
}

# enumerate-scopes exists to answer for many scopes at once, and the fingerprint
# is only unchanged by that if each answer equals the scope's own walk. The two
# backends fill it differently, so both are pinned, including a scope nested
# under another and one that holds no files.
def test_enumerate_scopes_agrees_with_walking_each [] {
	print "test enumerate-scopes answers what walk-scope answers, per backend..."
	let fx = (fixture {
		".gitignore": "*.log\n", "a/one.rs": "x", "a/skip.log": "x",
		"a/deep/two.rs": "x", "b/three.rs": "x", "empty/.keep": "x",
	})
	rm ($fx | path join "empty/.keep")
	let scopes = ["a" "a/deep" "b" "empty"]
	# Once outside a work tree, where the walk fills the memo, and once inside
	# one, where git fills it in a single call and the result is bucketed by
	# scope. A fixture that is not a repository exercises only the first, which
	# is how the bucketing went untested.
	for repo in [false true] {
		if $repo { ^git -C $fx init -q }
		# git's own toplevel, not the fixture path: on macOS a temp dir reaches it
		# through a symlink, and git-enumerate declines when the two differ — which
		# is how a fixture inside a repository still exercised only the walk.
		let root = if $repo { ^git -C $fx rev-parse --show-toplevel | str trim } else { $fx }
		for flavor in ["git" "docker"] {
			let got = (enumerate-scopes $root $scopes $flavor)
			for s in $scopes {
				let direct = (walk-scope $root $s $flavor --no-git | sort)
				assert (($got | get $s | sort) == $direct) $"repo=($repo) ($flavor)/($s): ($got | get $s | to json --raw) vs ($direct | to json --raw)"
			}
		}
	}
	rm -rf $fx
}

# The repo root is deliberately absent: enumerating it would descend the whole
# tree for a caller that usually wants literal paths, and compute-fingerprint
# walks it on demand instead.
# git renders a path holding a non-ASCII byte as an escaped, quoted C string
# unless asked otherwise; the walk reports it raw. Both name the same file now.
def test_non_ascii_paths_agree_between_backends [] {
	print "test a non-ascii path enumerates the same either way..."
	let fx = (fixture {".gitignore": "", "a/café.go": "x", "a/plain.go": "y"})
	^git -C $fx init -q
	let root = (^git -C $fx rev-parse --show-toplevel | str trim)
	let fast = (walk-scope $root "a" "git" | sort)
	let walked = (walk-scope $root "a" "git" --no-git | sort)
	assert ($fast == $walked) $"($fast | to json --raw) vs ($walked | to json --raw)"
	assert ("a/café.go" in $fast) $"expected the raw path, got ($fast | to json --raw)"
	rm -rf $fx
}

def test_enumerate_scopes_omits_the_root [] {
	print "test enumerate-scopes leaves the repo root to the caller..."
	let fx = (fixture {".gitignore": "", "a/one.rs": "x", "top.rs": "x"})
	let got = (enumerate-scopes $fx ["" "a"] "git")
	assert (($got | columns) == ["a"]) $"expected only a, got ($got | columns | to json --raw)"
	rm -rf $fx
}

def test_docker_flavor_does_not_nest [] {
	print "test only the context-root .dockerignore is honoured..."
	let fx = (fixture {".dockerignore": "*.md\n", "a/.dockerignore": "*.txt\n", "a/keep.txt": "x", "drop.md": "x"})
	let got = (walk-scope $fx "" "docker" --no-git | sort)
	assert ("a/keep.txt" in $got) "a nested .dockerignore has no effect"
	assert (not ("drop.md" in $got)) "the context-root file still applies"
	rm -rf $fx
}
