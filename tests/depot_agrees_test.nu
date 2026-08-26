#!/usr/bin/env nu
# depot_agrees_test.nu — .bayt/depot.json must describe the same group as
# .bayt/depot.hcl.
#
# The two are generated from one list but written by different code paths:
# the HCL from CUE alone, the JSON from CUE joined against the flattened
# compose. A caller reads the JSON to decide per leaf and the bake reads the
# HCL, so a divergence means building one set and planning another.
#
# Runs against the committed artifacts of every depot project rather than a
# fixture: what must agree is what ships, and regenerating here would need a
# docker daemon to reflatten.

use std/assert
use repo.nu [repo-root repo-glob]

def main [] {
  print "Running bayt/depot agreement tests...\n"

  let root = (repo-root)
  let projects = (repo-glob "**/.bayt/depot.json" | each { |p| $p | path dirname })
  if ($projects | is-empty) {
    print "    SKIP (no project emits depot.json)"
    return
  }

  for d in $projects {
    let name = ($d | path dirname | path relative-to $root)
    test_membership_agrees $d $name
    test_manifests_exist $root $d $name
    test_repos_are_distinct_and_tagless $d $name
    test_repo_matches_what_the_bake_pushes $root $d $name
  }

  print "\nAll bayt/depot agreement tests passed!"
}

# The HCL's list, read the way a bake reads it.
def hcl-targets [dir: string]: nothing -> list<string> {
  open --raw ($dir | path join "depot.hcl")
  | parse -r 'targets = \[(?<body>[^\]]*)\]'
  | get body.0
  | parse -r '"(?<t>[^"]+)"'
  | get t
}

def test_membership_agrees [dir: string, name: string] {
  let plan = (open ($dir | path join "depot.json"))
  assert equal ($plan.targets | get target | sort) (hcl-targets $dir | sort)
  print $"  PASS  ($name): membership agrees with depot.hcl"
}

# Every leaf names a manifest a caller can fingerprint. A group member can be
# an overlay service whose build block names a different target, so this is
# the assertion that the alias actually resolved.
def test_manifests_exist [root: string, dir: string, name: string] {
  let plan = (open ($dir | path join "depot.json"))
  let missing = ($plan.targets | where { |t| not ($root | path join $t.manifest | path exists) })
  assert equal ($missing | get target) []
  print $"  PASS  ($name): every leaf's manifest exists"
}

# The caller appends its own tags, so a repo carrying one would produce
# `<repo>:<tag>:fp-<hash>`. Two leaves sharing a repo would race for the
# same fingerprint tag.
def test_repos_are_distinct_and_tagless [dir: string, name: string] {
  let plan = (open ($dir | path join "depot.json"))
  let repos = ($plan.targets | get repo)
  assert equal ($repos | uniq | length) ($repos | length)
  let tagged = ($repos | where { |r| ($r | split row "/" | last) =~ ':' })
  assert equal $tagged []
  print $"  PASS  ($name): repos are distinct and tag-less"
}

# The repo the plan retags must be the one the bake pushes. depot.yaml is the
# file the bake consumes, so comparing against it closes the loop; a repo-of
# that dropped the registry host or a path segment would satisfy every other
# assertion here and simply miss forever.
def test_repo_matches_what_the_bake_pushes [root: string, dir: string, name: string] {
  use ../core/generate.nu [repo-of]
  let plan = (open ($dir | path join "depot.json"))
  let svcs = (open ($dir | path join "depot.yaml") | get services)
  let wrong = ($plan.targets | each { |t|
    let s = ($svcs | get -o $t.target)
    if $s == null { {target: $t.target, want: "(absent from depot.yaml)", got: $t.repo} } else {
      let want = (repo-of $s.image)
      if $want != $t.repo { {target: $t.target, want: $want, got: $t.repo} } else { null }
    }
  } | compact)
  assert equal $wrong []
  print $"  PASS  ($name): every repo matches the flattened compose"
}
