---
type: decision
title: Cache check before deps
description: A cache.full target is checked in its task's `if:`, before go-task runs its deps, so an exact hit restores the target and skips its whole subgraph.
status: done
moved_to: ../../CONTRIBUTING.md#the-cache-check
---

# Cache check before deps

## The gap

go-task runs a task's `deps` before it evaluates the task's `status:`. A
`cache.full` target whose exact key is cached therefore restores its outs and
skips its command, but only after every dep beneath it has run. The deps that
are not `cache.full` pay in full. The clearest is gradle's `deps` target: it
resolves the dependency closure into `$GRADLE_USER_HOME`, outside the project,
so its product is neither `outs` nor `state` and a hit still runs the resolve.
On a fresh runner with a warm remote cache, `services/tracker:build` hit on
every `cache.full` target and still spent 3m37s in `deps`; Bazel, on the same
tree and cache, took 15.7s, because it materializes an action's inputs only if
the action executes.

## Why `state` cannot close it

One reading is that `deps` should be `cache.full` because gradle refills its
product on demand. That is the consumer's tool speaking, not the target: `state`
says the owning tool is the canonical cache and its own invocation the restore
path, and nothing about whether a consumer can rebuild it. `guis/web`'s `setup`
declares `node_modules` as state, and a `vite build` that misses installs
nothing. Marking state producers `full` would be right for gradle and wrong for
pnpm. The property that matters is different — **nothing that needs the state
runs** — and it can be decided without knowing anything about the state.

## The mechanism

A `cache.full` target carries a task-level `if:` that runs `bayt cache check`.
go-task evaluates `if:` in `RunTask` before `startExecution` and `runDeps`
(v3.49.1, `task.go`), and a failed condition skips the task with its deps. No
task is added, and the check lives on the task it gates. The check answers one
question — can this target be satisfied without running anything?

1. **Local stamp.** The stamp holds the key and every declared out and state
   path is present: exit 10.
2. **Cache hit.** An entry exists at the exact key: restore its outs, write the
   stamp (a task skipped by `if:` never reaches its `defer`), exit 10.
3. **Anything else.** Exit 0, and go-task runs the deps, then `status:`, then
   the command, as before.

**Exit 10, not 1.** go-task reads any non-zero `if:` as "skip", so a bare
`bayt cache check` that crashed would skip the build in silence. The condition
is the check followed by `[ $? -ne 10 ]`: only the positive answer skips, and
a crash runs the task as if the check were absent. go-task discards the
command's output and runs `if:` through its built-in POSIX shell on every
platform, Windows included.

## The key is walked, not read from dep stamps

`fingerprint` and `cache run` trust a dep's stamp, which is sound only because
go-task has just run the dep. The check runs before the deps, so a dep's stamp
can be stale — edit `libraries/xproto` and its stamp holds the old hash until it
runs — and a check trusting it would compute the consumer's old key and skip
wrongly. So the check walks the closure from manifests. The one stamp it still
reads belongs to a dep with no manifest on disk: inside a container that COPYs
a dep's outs and stamp but not its `.bayt`, the dep cannot run, so its stamp
cannot go stale.

The walk is the price: about 3.5s for `services/tracker:build`'s closure, nu
startup included. A hit pays it once at the top, because nothing below runs; a
miss pays it at each `cache.full` level on the way down, where the build it
precedes dominates. A per-file digest memo keyed by path, size and mtime would
cut it.

## Consequences

- A remote hit restores only the targets asked for; deps do not run and
  intermediate outs are not fetched. A no-op local build skips the subgraph too,
  and a dep whose `state` was deleted is rebuilt only when something that lists
  it runs.
- Non-`full` targets run their command on a hit by design, so they get no `if:`;
  multi-cmd targets cache per cmd, so there is no target-level entry to check.
- `if:` is evaluated per call, before the run-once gate. A second check usually
  answers at step 1; two concurrent ones restore identical bytes with atomic
  renames, costing a fetch, not a wrong tree.
- `task --force` bypasses `status:`, not `if:`; delete the stamp and outs, or
  set `BAYT_CACHE_ENABLED=false` with no stamp, to force a run.
- A miss looks the key up twice, once in the check and once in `cache run`.
