#!/usr/bin/env nu
# fingerprint_observes_test.nu — a target's fingerprint must move when the
# sources that go into its image change.
#
# Runs against the repo's own generated manifests, not a fixture. A fixture
# written from an assumption about manifest shape asserts the assumption: the
# file set of a synthetic view lives in `outs.globs` while `srcs.globs` is
# empty, and a target's real inputs can live entirely in `cmds[*].srcs` — so a
# hand-built manifest is exactly the wrong oracle here.
#
# Stability is not the property under test: a fingerprint that observes nothing
# is perfectly stable.
#
# A probe is a new untracked file where one can be placed — enumeration is
# `git ls-files -co`, so an untracked file counts. Where the input under test
# IS a tracked file, the probe appends and restores the saved bytes.

use std/assert

def repo-root []: nothing -> string {
  (^git rev-parse --show-toplevel | str trim)
}

def main [] {
  print "Running bayt/fingerprint observation tests...\n"

  let root = (repo-root)
  # No skip arm: the image scope and the context walk have no other coverage,
  # so a missing fixture must fail rather than silently disarm the only guard.
  let depot = ($root | path join "guis/iris/.bayt/depot.json")
  assert ($depot | path exists) "guis/iris/.bayt/depot.json is missing - this suite is the only coverage for the image scope"

  # manifest, the file a change lands in, and what reaches it.
  let cases = [
    {
      manifest: "guis/iris/.bayt/bayt.integrate.json"
      probe:    "guis/iris/e2e/__bayt_fp_probe__.ts"
      via:      "its own cmds[*].srcs"
    }
    {
      manifest: "guis/iris/.bayt/bayt.integrate.json"
      probe:    "plugins/omnishell/src/__bayt_fp_probe__.ts"
      via:      "a cross-project :srcs view"
    }
    {
      manifest: "guis/iris/.bayt/bayt.ci-run.json"
      probe:    "guis/iris/app/__bayt_fp_probe__.ts"
      via:      "a same-project :srcs view"
    }
    {
      manifest: "guis/iris/.bayt/bayt.release-crud.json"
      probe:    "guis/iris/.bayt/Dockerfile.release-crud"
      via:      "its own bayt view (the rendered recipe)"
    }
    {
      manifest: "guis/iris/.bayt/bayt.release-crud.json"
      probe:    "guis/iris/.bayt/Taskfile.bayt.yml"
      via:      "its own bayt view (project-wide scaffolding)"
    }
    {
      manifest: "guis/iris/.bayt/bayt.ci-run.json"
      probe:    "plugins/omnishell/src/__bayt_fp_probe__.ts"
      via:      "transitiveCrossDeps"
    }
    {
      manifest: "guis/iris/.bayt/bayt.ci-run.json"
      probe:    "plugins/bayt/runtime/__bayt_fp_probe__.nu"
      via:      "an additional_context directory"
    }
  ]

  for c in $cases { test_probe_moves_the_hash $root $c }

  print "\nAll bayt/fingerprint observation tests passed!"
}

def fp [root: string, manifest: string]: nothing -> string {
  let fp_nu = ($root | path join "plugins/bayt/runtime/fingerprint.nu")
  let r = (do { cd $root; ^nu $fp_nu --manifest $manifest --all-cmds --quiet } | complete)
  if $r.exit_code != 0 {
    error make { msg: $"fingerprint failed for ($manifest): ($r.stderr)" }
  }
  $r.stdout | str trim
}

def test_probe_moves_the_hash [root: string, c: record] {
  let target = ($c.manifest | path basename)
  let probe = ($root | path join $c.probe)
  # An existing probe is a tracked file: append and put its bytes back. Only a
  # path that does not exist may be created and removed, or the restore would
  # delete a real file.
  let existing = ($probe | path exists)
  let saved = (if $existing { open --raw $probe } else { "" })
  let restore = { || if $existing { $saved | save -f $probe } else { rm -f $probe } }

  let before = (fp $root $c.manifest)
  $"($saved)# bayt fingerprint probe\n" | save -f $probe
  let after = (try { fp $root $c.manifest } catch { |e| do $restore; error make $e.rawvalue })
  do $restore

  assert ($before != $after) $"($target) did not observe ($c.probe) via ($c.via) — the hash licenses a skip it has not earned"
  print $"  PASS  ($target) observes ($c.probe) via ($c.via)"
}
