# A hit skips its deps

How a `cache.full` target that is already built, locally or in a remote cache,
stops its dependency subgraph from running, and why that needs no new
metadata.

## The gap

go-task runs a task's `deps` before it evaluates the task's `status:`. A
`cache.full` target whose exact key is in the cache therefore restores its outs
and skips its command, but only after every dep beneath it has run.

Most of those deps are `cache.full` too, and they hit and skip in turn. The ones
that are not pay in full. The clearest case is gradle's `deps` target: it
resolves the dependency closure into `$GRADLE_USER_HOME`, a product that is
neither `outs` nor `state` because it lives outside the project. Its cache entry
can only record "ran on these inputs", so a hit still runs the resolve. On a
fresh runner with a warm remote cache, `services/tracker:build` hit on every
`cache.full` target and still spent 3m37s in `deps`. Bazel, on the same tree and
cache, took 15.7s.

Bazel does not pay this because it is lazy about inputs. An action's inputs are
materialized only if the action executes, and when every action is a remote hit
nothing executes, so nothing is fetched. It also leaves intermediate outputs in
the remote cache ("build without the bytes").

## Why `state` cannot close it

One reading of the gap is that `deps` should be `cache.full` because its product
is only a warm cache that gradle refills on demand. That reasoning belongs to the
consumer's tool, not to the target. `state` says the owning tool is the canonical
cache and "its own invocation the restore path". It says nothing about whether a
consumer can rebuild it. `guis/web`'s `setup` declares `node_modules` as state,
and a `vite build` that misses will not install anything. Marking state
producers `full` would be correct for gradle and wrong for pnpm.

The property that matters is different: **nothing that needs the state runs.**
That can be decided without knowing anything about the state.

## The mechanism

A `cache.full` target gets a task-level `if:` that runs a cache check. go-task
evaluates a task's `if:` in `RunTask` before `startExecution` and `runDeps`
(v3.49.1, `task.go`). When the condition fails, the task is skipped with its
deps. No new tasks are emitted, and the check lives on the task it gates.

```yaml
# .bayt/Taskfile.build.yaml (generated, cache.full target)
tasks:
  default:
    if: "bayt cache check --manifest '{{.TASKFILE_DIR}}/bayt.build.json' --stamp-file .task/bayt/build.hash; [ $? -ne 10 ]"
    deps: ["::bayt:deps", "::bayt:cross_libraries_xproto_build", ...]
    status: [...]                   # unchanged
    cmds: [...]                     # unchanged: bayt cache run --full -- ...
```

`bayt cache check` computes the target's key and answers one question: can this
target be satisfied without running anything?

1. **Local stamp.** The stamp holds the key, and every declared out and state
   path is present. Exit 10.
2. **Cache hit.** The cache is enabled and has an entry at the exact key. Restore
   its outs, write the stamp, exit 10.
3. **Anything else.** Exit 0: go-task runs the deps, then `status:`, then the
   command, exactly as before.

The check writes the stamp in step 2 itself, because a task skipped by `if:`
never reaches its `defer`.

## Exit 10, not exit 1

go-task reads any non-zero exit from `if:` as "skip". If a bare `bayt cache
check` were the condition, a crash (a missing manifest, a nu error, a backend
failure) would skip the build silently. The condition is the check followed by
`[ $? -ne 10 ]`, so only the check's positive answer skips. Every other outcome,
a crash included, runs the task as if the check were not there. go-task
discards an `if:` command's output, so a check that crashes costs its runtime
and says nothing; it never costs a build. go-task runs `if:` through its
built-in POSIX shell on every platform, Windows included, so `$?` is available
everywhere.

## The key is walked, not read from dep stamps

`fingerprint.nu` builds a key from the target's own inputs and its deps' hashes.
For each dep it trusts the dep's stamp when one exists and walks the dep's
manifest otherwise. That shortcut is sound only because go-task runs deps first:
by the time a consumer's `status:` reads a dep's stamp, the dep has refreshed it.

The check runs before the deps, so a dep's stamp can be stale. Edit a source in
`libraries/xproto`, and xproto's stamp still holds the old hash until xproto
runs. A check that trusted it would compute tracker's old key and skip wrongly.
So the check walks the closure from manifests instead of reading dep stamps.
`manifest-fingerprint` gains a flag for this, and `fingerprint` and `cache run`
keep the stamp shortcut.

The one stamp the walk still reads belongs to a dep with no manifest on disk.
A container COPYs a dep's outs and stamp but never its `.bayt`, so that dep's
runner is skipped and the dep cannot run there; its stamp cannot go stale, and
it is all there is to hash.

The walk is the price. Hashing `services/tracker:build`'s closure from scratch
takes about 3.5s, nu startup included. A hit pays it once, at the top, because
none of the targets below run. A miss pays it at each `cache.full` level on the
way down, where the build it precedes dominates. A per-file digest memo keyed by
path, size and mtime (bazel's own trick) would cut it, and is left for later.

## What changes

- **A remote hit restores only the targets asked for.** Deps are not run, and
  intermediate outs are not fetched.
- **A no-op local build skips the subgraph too.** Step 1 answers before any dep
  is visited. A dep whose `state` was deleted is not rebuilt unless something
  that needs it runs; a target that needs it lists it as a dep and runs it
  itself.
- **Non-`full` targets are unchanged.** They run their command on a hit by
  design, so they keep `status:` and get no `if:`.
- **Multi-cmd targets are unchanged.** Their cache entries are per cmd, so there
  is no target-level entry for a check to restore. The single-cmd path covers
  every `cache.full` target in the stacks today.

## Caveats

- **`if:` is not deduplicated.** go-task evaluates it per call, before the
  run-once gate, so a target reached by two paths is checked twice. The second
  check usually finds the stamp written by the first and answers at step 1. Two
  checks that start together both restore; they write identical bytes with
  atomic renames, so the cost is a wasted fetch, not a wrong tree.
- **`task --force` does not force a hit.** `--force` bypasses `status:`, not
  `if:`, so a `cache.full` target already in the cache still skips.
  Deleting its stamp and outs, or `BAYT_CACHE_ENABLED=false` with no stamp,
  runs it.
- **A miss looks the key up twice**, once in the check and once in `cache run`.
  The second lookup is a single GET.
