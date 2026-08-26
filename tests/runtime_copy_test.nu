#!/usr/bin/env nu
# runtime_copy_test.nu — the runtime image's root IS the runtime tree, so a
# consumer COPYs `.` from it.
#
# Asserted against the repo's committed Dockerfiles rather than a fixture: the
# selector is agreement between two artifacts — what `capabilities.incremental`
# emits and what `Dockerfile.runtime` publishes — and a fixture can only state
# one side of that. A `runtime` selector here would copy a subdirectory the
# image does not have, and every build would fail on a path that reads like a
# missing file rather than a wrong contract.

use std/assert
use repo.nu [repo-root repo-glob]

def main [] {
  print "Running bayt/runtime-copy tests...\n"

  let root = (repo-root)
  let dockerfiles = (repo-glob "**/.bayt/Dockerfile.*")
  assert (($dockerfiles | length) > 0) "no generated Dockerfiles found"

  test_every_bayt_copy_takes_the_whole_context $dockerfiles
  test_the_runtime_image_root_is_the_tree $root

  print "\nAll bayt/runtime-copy tests passed!"
}

def test_every_bayt_copy_takes_the_whole_context [dockerfiles: list<string>] {
  let bad = ($dockerfiles | each { |f|
    let lines = (open --raw $f | lines | where { |l| $l =~ 'COPY .*--from=bayt ' })
    let wrong = ($lines | where { |l| not ($l =~ 'COPY (--link )?--from=bayt \. ') })
    if ($wrong | is-empty) { null } else { {file: ($f | path basename), lines: $wrong} }
  } | compact)
  assert equal $bad []
  let n = ($dockerfiles | length)
  print $"  PASS  every `COPY --from=bayt` takes the whole context \(($n) Dockerfiles\)"
}

# The other side of the agreement: the published tree has no `runtime/` inside
# it, which is what makes `.` the only correct selector.
def test_the_runtime_image_root_is_the_tree [root: string] {
  let df = ($root | path join "plugins/bayt/Dockerfile.runtime")
  assert ($df | path exists) "Dockerfile.runtime is missing"
  let copies = (open --raw $df | lines | where { |l| $l starts-with "COPY " })
  assert equal $copies ["COPY runtime/ /"]
  print "  PASS  the runtime image's root is the runtime tree"
}
