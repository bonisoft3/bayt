#!/usr/bin/env nu
# ignore_agrees_it.nu — the two enumeration paths must answer identically.
#
# walk-scope prefers git and falls back to the nushell walk, so both run in
# production: the host has git, and the build container does not (`.git` is
# dockerignored). A silent disagreement would mean a fingerprint that moves
# when a build crosses that boundary, which is exactly the drift the matcher
# exists to prevent.
#
# The comparison is only sound because `--exclude-per-directory` reads the
# per-directory ignore files and nothing else. `--exclude-standard` would drag
# in `.git/info/exclude` and `core.excludesFile`, making git's answer a
# function of the machine and useless as an oracle.
#
# Runs against this repo rather than a fixture: the point is agreement over
# real nesting, negations and worktrees, which a toy tree would not exercise.

use std/assert
use ../runtime/ignore.nu [walk-scope]

def repo-root []: nothing -> string {
  (^git rev-parse --show-toplevel | str trim)
}

def main [] {
  print "Running bayt/ignore agreement tests...\n"

  if (which git | is-empty) {
    print "    SKIP (no git binary; nothing to compare against)"
    return
  }

  let root = (repo-root)
  test_paths_agree $root ""
  test_paths_agree $root "guis/iris"
  test_tracked_but_ignored_is_subtracted $root
  test_subdir_root_stays_on_the_walk $root

  print "\nAll bayt/ignore agreement tests passed!"
}

# git's own answer, built the way walk-scope's fast path builds it.
def git-set [root: string, sub: string]: nothing -> list<string> {
  let scope = if ($sub | is-empty) { [] } else { ["--" $sub] }
  let all = (^git -C $root ls-files -co --exclude-per-directory=.gitignore ...$scope | lines)
  let ign = (^git -C $root ls-files -ci --exclude-per-directory=.gitignore ...$scope | lines)
  $all | where { |p| not ($p in $ign) } | sort
}

def test_paths_agree [root: string, sub: string] {
  let label = if ($sub | is-empty) { "repo root" } else { $sub }
  print $"test git and the walk agree over ($label)..."
  # walk-scope with git left on, so git-enumerate itself executes; git-set is an
  # independent third oracle in case both in-module paths drift together.
  let fast = (walk-scope $root $sub | sort)
  let g = (git-set $root $sub)
  let w = (walk-scope $root $sub --no-git | sort)
  assert ($fast == $g) "the fast path disagrees with a direct git query"
  let only_git = ($g | where { |p| not ($p in $w) })
  let only_walk = ($w | where { |p| not ($p in $g) })
  assert ($only_git | is-empty) $"only git has: ($only_git | first 5 | str join ', ')"
  assert ($only_walk | is-empty) $"only the walk has: ($only_walk | first 5 | str join ', ')"
  assert (($g | length) > 0) "expected a non-empty enumeration"
}

# `-c` lists a tracked file even when an ignore rule matches it. Here rules
# apply to everything, so those have to come back out — without the
# subtraction the fast path would report inputs the walk never sees.
def test_tracked_but_ignored_is_subtracted [root: string] {
  print "test tracked-but-ignored files are excluded by both paths..."
  let ti = (^git -C $root ls-files -ci --exclude-per-directory=.gitignore | lines)
  if ($ti | is-empty) {
    print "      (none in this tree — subtraction is a no-op here)"
    return
  }
  let w = (walk-scope $root "" --no-git)
  let leaked = ($ti | where { |p| $p in $w })
  assert ($leaked | is-empty) $"tracked-but-ignored leaked into the walk: ($leaked | str join ', ')"
}

# git resolves ignore rules from every ancestor up to the real repo root, so a
# `root` below the toplevel would enumerate a different set than the walk, which
# treats `root` as the top of the path space. The fast path must decline there.
def test_subdir_root_stays_on_the_walk [root: string] {
  print "test a non-toplevel root falls back to the walk..."
  let sub = ($root | path join "plugins" "bayt")
  if not ($sub | path exists) {
    print "      (plugins/bayt missing — skipped)"
    return
  }
  let fast = (walk-scope $sub "" | sort)
  let pure = (walk-scope $sub "" --no-git | sort)
  assert ($fast == $pure) "a subdirectory root must not take the git fast path"
}
