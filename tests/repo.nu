#!/usr/bin/env nu
# repo.nu — locating this commit's own files, for suites that assert against
# the repo's real generated tree rather than a fixture.

# Worktrees nested under the root are other branches' checkouts, so a suite
# asserting about this commit must not read them. The exclusion anchors on the
# root: inside a worktree every path contains `/.worktrees/`, and an unanchored
# filter matches them all, leaving nothing to assert and a suite that passes
# by finding no work.
export def repo-glob [pattern: string]: nothing -> list<string> {
  let root = (repo-root)
  let nested = $"($root)/.worktrees/"
  glob $"($root)/($pattern)" | where { |p| not ($p | str starts-with $nested) }
}

export def repo-root []: nothing -> string {
  (^git rev-parse --show-toplevel | str trim)
}
