#!/usr/bin/env nu
# developing_scrub_test.nu — every copybara text scrub must still match the
# text it scrubs.
#
# The scrubs run with `noop_behavior = "IGNORE_NOOP"`, so a `before` that has
# drifted from its source does not fail the sync — it silently copies the text
# it exists to remove, into a public repo. The failure mode is a leak that
# looks like a successful sync, which no other check in the tree would notice.
#
# Covers every `.md` scrub in the config, not only bayt's: they share the
# mechanism and therefore the failure.

use std/assert
use repo.nu [repo-root]

def main [] {
  print "Running copybara scrub tests...\n"

  let root = (repo-root)
  let cfg = ($root | path join "copy.bara.sky")
  assert ($cfg | path exists) "copy.bara.sky is missing"

  let scrubs = (md-scrubs $cfg)
  assert (($scrubs | length) > 0) "no .md scrubs found — the parse below stopped matching the config"

  for s in $scrubs { test_scrub_still_matches $root $s }

  print $"\nAll copybara scrub tests passed! \(($scrubs | length) scrub\(s\)\)"
}

# Each `core.replace` whose paths glob names a markdown file, with its `before`
# text unescaped from the Starlark string literal.
def md-scrubs [cfg: string]: nothing -> list<record> {
  let lines = (open --raw $cfg | lines)
  $lines
    | enumerate
    | where { |r| ($r.item | str trim) starts-with 'before = "' }
    | each { |r|
        # The paths glob sits within a few lines of its before.
        let window = ($lines | skip ($r.index + 1) | first 4 | str join "\n")
        let md = ($window | parse -r 'glob\(\["(?<f>[^"]*\.md)"\]\)' | get -o f.0)
        if $md == null { null } else {
          {file: $md, before: (unescape ($r.item | str trim | str substring 10..<(($r.item | str trim | str length) - 2)))}
        }
      }
    | compact
}

# Starlark double-quoted escapes, innermost last so a literal backslash before
# an `n` is not turned into a newline.
def unescape [s: string]: nothing -> string {
  $s | str replace --all '\n' (char newline) | str replace --all '\"' '"' | str replace --all '\\' '\'
}

def test_scrub_still_matches [root: string, s: record] {
  # The glob is relative to the mirrored root, which is some plugins/<name>/.
  let candidates = (glob $"($root)/plugins/*/($s.file)")
  let hits = ($candidates | where { |c| (open --raw $c) | str contains $s.before })
  assert (($hits | length) > 0) $"no file matches the scrub for ($s.file) — copybara would silently ship the unscrubbed text"
  print $"  PASS  ($s.file): scrub matches ($hits | length) file\(s\)"
}
