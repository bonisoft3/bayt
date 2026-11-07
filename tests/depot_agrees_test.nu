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
  rm $file
  assert equal $cli.exit_code 0 $cli.stderr
  let leaves = ($cli.stdout | from json)
  for row in (depot-targets $live) {
    let fp = (do { cd $workspace; ^$nu.current-exe plugins/bayt/runtime/fingerprint.nu --manifest $row.manifest --all-cmds --quiet } | complete)
    assert equal $fp.exit_code 0 $fp.stderr
    let leaf = ($leaves | where target == $row.target | first)
    assert equal $leaf.repo $row.repo
    assert equal $leaf.fingerprint ($fp.stdout | str trim)
    assert ($leaf.fingerprint | is-not-empty)
  }
  print "All depot target tests passed!"
}
