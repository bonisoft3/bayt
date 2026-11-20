#!/usr/bin/env nu
use std/assert
use ../core/depot.nu [depot-targets]
use repo.nu [repo-root]

def main [] {
  let root = (pwd)
  let plan = {
    group: {depot-build: {targets: [database app]}}
    target: {
      database: {context: $root, target: release-db, tags: ["localhost:5000/db:ci"]}
      app: {context: $root, target: release, tags: ["registry.example/app:ci", "registry.example/app:latest"]}
      setup: {context: $root, target: setup}
    }
  }
  # Alias names differ from Dockerfile stages; dependency-only targets have no push repo.
  let rows = (depot-targets $plan)
  assert equal ($rows | get target) [database app]
  assert equal ($rows | get repo) ["localhost:5000/db" "registry.example/app"]
  assert equal $rows.0.manifest ($root | path join .bayt bayt.release-db.json)
  assert equal $rows.1.manifest ($root | path join .bayt bayt.release.json)
  for bad in [
    ($plan | update group.depot-build.targets [missing])
    ($plan | update group.depot-build.targets [setup])
    ($plan | update target.database.tags [])
  ] {
    let failed = (try { depot-targets $bad | ignore; false } catch { true })
    assert $failed "an unplannable leaf must fail instead of silently disappearing"
  }
  let workspace = (repo-root)
  let context = ($workspace | path join guis iris)
  let live = ($plan | update target.database.context $context | update target.database.target release-database | update target.app.context $context)
  let file = (mktemp --suffix .json)
  $live | to json | save -f $file
  let cli = (do { cd $workspace; ^$nu.current-exe plugins/bayt/bayt.nu depot-plan --plan $file } | complete)
  # Invoked from outside the workspace root, depot-plan still anchors scopes and
  # index lookups on each manifest's own root rather than cwd.
  let out_cwd = (mktemp -d)
  let bayt_nu = ($workspace | path join plugins bayt bayt.nu)
  let cli_outside = (do { cd $out_cwd; ^$nu.current-exe $bayt_nu depot-plan --plan $file } | complete)
  rm -rf $out_cwd
  rm $file
  assert equal $cli.exit_code 0 $cli.stderr
  assert equal $cli_outside.exit_code 0 $cli_outside.stderr
  let leaves = ($cli.stdout | from json)
  assert equal ($cli_outside.stdout | from json) $leaves
  for row in (depot-targets $live) {
    let fp = (do { cd $workspace; ^$nu.current-exe plugins/bayt/runtime/fingerprint.nu --manifest $row.manifest --all-cmds --quiet } | complete)
    assert equal $fp.exit_code 0 $fp.stderr
    let leaf = ($leaves | where target == $row.target | first)
    assert equal $leaf.repo $row.repo
    assert equal $leaf.fingerprint ($fp.stdout | str trim)
    assert ($leaf.fingerprint | is-not-empty)
  }

  # Cold no-git workspace: shared scope enumeration walks once, skips index
  # writes, and broken leaves (missing dep dir, malformed scope entry, or
  # unreadable .gitignore on both globbed and literal-only leaves) fail open on
  # their own without taking down healthy leaves.
  let cold = (mktemp -d)
  mkdir ($cold | path join shared .bayt) ($cold | path join a .bayt) ($cold | path join b .bayt) ($cold | path join broken .bayt) ($cold | path join bad-ignore .bayt) ($cold | path join bad-lit .bayt) ($cold | path join bad-dir .bayt)
  "shared\n" | save -f ($cold | path join shared lib.txt)
  "alpha\n"  | save -f ($cold | path join a main.txt)
  "beta\n"   | save -f ($cold | path join b main.txt)
  "broken\n" | save -f ($cold | path join broken main.txt)
  "bad\n"    | save -f ($cold | path join bad-ignore main.txt)
  "lit\n"    | save -f ($cold | path join bad-lit main.txt)
  "num\n"    | save -f ($cold | path join bad-dir main.txt)
  if $nu.os-info.name != "windows" {
    ^ln -s ($cold | path join does-not-exist) ($cold | path join bad-ignore .gitignore)
    ^ln -s ($cold | path join does-not-exist) ($cold | path join bad-lit .gitignore)
  }
  {name: "lib", dir: "shared", srcs: {globs: ["**/*"], exclude: []}, outs: {globs: [], exclude: []}, state: {globs: []}, chainedDeps: [], cmds: []}
    | to json | save -f ($cold | path join shared .bayt bayt.lib.json)
  {name: "release", dir: "a", srcs: {globs: ["**/*"], exclude: []}, outs: {globs: [], exclude: []}, state: {globs: []}, chainedDeps: [{name: "lib", dir: "shared"}], cmds: []}
    | to json | save -f ($cold | path join a .bayt bayt.release.json)
  {name: "release", dir: "b", srcs: {globs: ["**/*"], exclude: []}, outs: {globs: [], exclude: []}, state: {globs: []}, chainedDeps: [{name: "lib", dir: "shared"}], cmds: []}
    | to json | save -f ($cold | path join b .bayt bayt.release.json)
  {name: "release", dir: "broken", srcs: {globs: ["**/*"], exclude: []}, outs: {globs: [], exclude: []}, state: {globs: []}, chainedDeps: [{name: "missing", dir: "no-such-dir"}], cmds: []}
    | to json | save -f ($cold | path join broken .bayt bayt.release.json)
  {name: "release", dir: "bad-ignore", srcs: {globs: ["**/*"], exclude: []}, outs: {globs: [], exclude: []}, state: {globs: []}, chainedDeps: [], cmds: []}
    | to json | save -f ($cold | path join bad-ignore .bayt bayt.release.json)
  {name: "release", dir: "bad-lit", srcs: {globs: ["main.txt"], exclude: []}, outs: {globs: [], exclude: []}, state: {globs: []}, chainedDeps: [], cmds: []}
    | to json | save -f ($cold | path join bad-lit .bayt bayt.release.json)
  {name: "release", dir: "bad-dir", srcs: {globs: ["main.txt"], exclude: []}, outs: {globs: [], exclude: []}, state: {globs: []}, chainedDeps: [{name: "lib", dir: 123}], cmds: []}
    | to json | save -f ($cold | path join bad-dir .bayt bayt.release.json)
  let cold_targets = (if $nu.os-info.name == "windows" {
    [svc-a svc-b svc-broken svc-bad-lit svc-bad-dir svc-missing-manifest]
  } else {
    [svc-a svc-b svc-broken svc-bad-ignore svc-bad-lit svc-bad-dir svc-missing-manifest]
  })
  let cold_plan = ($cold | path join plan.json)
  {
    group: {depot-build: {targets: $cold_targets}}
    target: {
      svc-a: {context: ($cold | path join a), target: release, tags: ["r.example/a:ci"]}
      svc-b: {context: ($cold | path join b), target: release, tags: ["r.example/b:ci"]}
      svc-broken: {context: ($cold | path join broken), target: release, tags: ["r.example/broken:ci"]}
      svc-bad-ignore: {context: ($cold | path join bad-ignore), target: release, tags: ["r.example/bad-ignore:ci"]}
      svc-bad-lit: {context: ($cold | path join bad-lit), target: release, tags: ["r.example/bad-lit:ci"]}
      svc-bad-dir: {context: ($cold | path join bad-dir), target: release, tags: ["r.example/bad-dir:ci"]}
      svc-missing-manifest: {context: ($cold | path join nowhere), target: release, tags: ["r.example/nowhere:ci"]}
    }
  } | to json | save -f $cold_plan
  let cold_res = (do { cd $cold; ^$nu.current-exe $bayt_nu depot-plan --plan $cold_plan } | complete)
  assert equal $cold_res.exit_code 0 $cold_res.stderr
  assert (not ($cold | path join .task bayt index | path exists)) "depot-plan must not write .task/bayt/index"
  let cold_leaves = ($cold_res.stdout | from json)
  let fp_nu = ($workspace | path join plugins bayt runtime fingerprint.nu)
  let ref_a = (do { cd $cold; ^$nu.current-exe $fp_nu --manifest ($cold | path join a .bayt bayt.release.json) --all-cmds --quiet } | complete)
  let ref_b = (do { cd $cold; ^$nu.current-exe $fp_nu --manifest ($cold | path join b .bayt bayt.release.json) --all-cmds --quiet } | complete)
  let ref_lit = (do { cd $cold; ^$nu.current-exe $fp_nu --manifest ($cold | path join bad-lit .bayt bayt.release.json) --all-cmds --quiet } | complete)
  rm -rf $cold
  assert equal $ref_a.exit_code 0 $ref_a.stderr
  assert equal $ref_b.exit_code 0 $ref_b.stderr
  assert equal $ref_lit.exit_code 0 $ref_lit.stderr
  let exp_a = ($ref_a.stdout | str trim)
  let exp_b = ($ref_b.stdout | str trim)
  let exp_lit = ($ref_lit.stdout | str trim)
  assert ($exp_a | is-not-empty)
  assert ($exp_b | is-not-empty)
  assert ($exp_lit | is-not-empty)
  assert equal ($cold_leaves | where target == svc-a | first | get fingerprint) $exp_a
  assert equal ($cold_leaves | where target == svc-b | first | get fingerprint) $exp_b
  assert equal ($cold_leaves | where target == svc-broken | first | get fingerprint) ""
  assert equal ($cold_leaves | where target == svc-bad-dir | first | get fingerprint) ""
  assert equal ($cold_leaves | where target == svc-bad-lit | first | get fingerprint) $exp_lit
  if $nu.os-info.name != "windows" {
    assert equal ($cold_leaves | where target == svc-bad-ignore | first | get fingerprint) ""
  }
  assert equal ($cold_leaves | where target == svc-missing-manifest | first | get fingerprint) ""

  # Self-rooted (`dir: "."`) dependency with a context named `shared` must keep
  # its own `nested/shared` scope separate from an outer target's `shared`
  # context when planned together.
  let multi = (mktemp -d)
  mkdir ($multi | path join a .bayt) ($multi | path join b .bayt) ($multi | path join nested .bayt) ($multi | path join shared) ($multi | path join nested shared)
  "outer\n" | save -f ($multi | path join shared common.txt)
  "outer\n" | save -f ($multi | path join nested shared common.txt)
  "inner-only\n" | save -f ($multi | path join nested shared extra.txt)
  {name: "build", dir: ".", srcs: {globs: [], exclude: []}, outs: {globs: [], exclude: []}, state: {globs: []}, chainedDeps: [], cmds: [], dockerfile: {preambleCopyContexts: [{image: "shared"}]}}
    | to json | save -f ($multi | path join nested .bayt bayt.build.json)
  {name: "build", dir: "a", srcs: {globs: [], exclude: []}, outs: {globs: [], exclude: []}, state: {globs: []}, chainedDeps: [{name: "build", dir: "nested"}], cmds: []}
    | to json | save -f ($multi | path join a .bayt bayt.build.json)
  {name: "build", dir: "b", srcs: {globs: [], exclude: []}, outs: {globs: [], exclude: []}, state: {globs: []}, chainedDeps: [], cmds: [], dockerfile: {preambleCopyContexts: [{image: "shared"}]}}
    | to json | save -f ($multi | path join b .bayt bayt.build.json)
  let targets_def = {
    a: {context: ($multi | path join a), target: build, tags: ["r.example/a:ci"]}
    b: {context: ($multi | path join b), target: build, tags: ["r.example/b:ci"]}
  }
  {group: {depot-build: {targets: [a]}}, target: $targets_def} | to json | save -f ($multi | path join solo.json)
  {group: {depot-build: {targets: [a b]}}, target: $targets_def} | to json | save -f ($multi | path join pair.json)
  {group: {depot-build: {targets: [b a]}}, target: $targets_def} | to json | save -f ($multi | path join rev.json)
  let solo_res = (do { cd $multi; ^$nu.current-exe $bayt_nu depot-plan --plan ($multi | path join solo.json) } | complete)
  let pair_res = (do { cd $multi; ^$nu.current-exe $bayt_nu depot-plan --plan ($multi | path join pair.json) } | complete)
  let rev_res  = (do { cd $multi; ^$nu.current-exe $bayt_nu depot-plan --plan ($multi | path join rev.json) } | complete)
  rm -rf $multi
  for r in [$solo_res $pair_res $rev_res] { assert equal $r.exit_code 0 $r.stderr }
  let solo_a = (($solo_res.stdout | from json) | where target == a | first | get fingerprint)
  let pair_a = (($pair_res.stdout | from json) | where target == a | first | get fingerprint)
  let rev_a  = (($rev_res.stdout  | from json) | where target == a | first | get fingerprint)
  assert ($solo_a | is-not-empty)
  assert equal $pair_a $solo_a "outer shared context must not shadow nested self-rooted shared context"
  assert equal $rev_a $solo_a "leaf ordering must not change self-rooted dep context resolution"

  # Transitive malformed dep (`A -> B` where B has `dir: 123`) and out-of-repo
  # dep pathspec (`../outside`) alongside a root-gitignored globbed leaf must
  # neither abort `depot-plan` nor switch the healthy leaf off the git backend.
  let edge_parent = (mktemp -d)
  let edge = ($edge_parent | path join repo)
  mkdir ($edge | path join good .bayt) ($edge | path join hop .bayt) ($edge | path join bad_b .bayt) ($edge | path join outdep .bayt) ($edge_parent | path join outside)
  ^git init -q $edge
  "good/\n" | save -f ($edge | path join .gitignore)
  "untracked\n" | save -f ($edge | path join good main.txt)
  "hop\n" | save -f ($edge | path join hop main.txt)
  "out\n" | save -f ($edge | path join outdep main.txt)
  {name: "release", dir: "good", srcs: {globs: ["**/*"], exclude: []}, outs: {globs: [], exclude: []}, state: {globs: []}, chainedDeps: [], cmds: []}
    | to json | save -f ($edge | path join good .bayt bayt.release.json)
  {name: "release", dir: "bad_b", srcs: {globs: ["main.txt"], exclude: []}, outs: {globs: [], exclude: []}, state: {globs: []}, chainedDeps: [{name: "release", dir: 123}], cmds: []}
    | to json | save -f ($edge | path join bad_b .bayt bayt.release.json)
  {name: "release", dir: "hop", srcs: {globs: ["main.txt"], exclude: []}, outs: {globs: [], exclude: []}, state: {globs: []}, chainedDeps: [{name: "release", dir: "bad_b"}], cmds: []}
    | to json | save -f ($edge | path join hop .bayt bayt.release.json)
  {name: "release", dir: "outdep", srcs: {globs: ["main.txt"], exclude: []}, outs: {globs: [], exclude: []}, state: {globs: []}, chainedDeps: [{name: "release", dir: "../outside"}], cmds: []}
    | to json | save -f ($edge | path join outdep .bayt bayt.release.json)
  let edge_targets = {
    good: {context: ($edge | path join good), target: release, tags: ["r.example/good:ci"]}
    hop: {context: ($edge | path join hop), target: release, tags: ["r.example/hop:ci"]}
    outdep: {context: ($edge | path join outdep), target: release, tags: ["r.example/outdep:ci"]}
  }
  {group: {depot-build: {targets: [good]}}, target: $edge_targets} | to json | save -f ($edge | path join solo.json)
  {group: {depot-build: {targets: [good hop outdep]}}, target: $edge_targets} | to json | save -f ($edge | path join all.json)
  let edge_solo = (do { cd $edge; ^$nu.current-exe $bayt_nu depot-plan --plan ($edge | path join solo.json) } | complete)
  let edge_all  = (do { cd $edge; ^$nu.current-exe $bayt_nu depot-plan --plan ($edge | path join all.json) } | complete)
  rm -rf $edge_parent
  assert equal $edge_solo.exit_code 0 $edge_solo.stderr
  assert equal $edge_all.exit_code 0 $edge_all.stderr
  let good_solo = (($edge_solo.stdout | from json) | where target == good | first | get fingerprint)
  let all_rows  = ($edge_all.stdout | from json)
  assert ($good_solo | is-not-empty)
  assert equal ($all_rows | where target == good | first | get fingerprint) $good_solo "out-of-repo dep pathspec must not flip healthy leaf off git backend"
  assert equal ($all_rows | where target == hop | first | get fingerprint) ""
  assert equal ($all_rows | where target == outdep | first | get fingerprint) ""

  print "All depot target tests passed!"
}
