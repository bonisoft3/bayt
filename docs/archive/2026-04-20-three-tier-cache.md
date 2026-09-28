---
type: decision
title: Cache layers
description: A Merkle-chained stamp gates whether a command runs, a content-addressed cache whether its work is reused, BuildKit its layers, and a tool's own cache composes with all three.
status: done
moved_to: ../../SPEC.md#the-cache
---

# Cache layers

Each layer skips something different at a different scope, and none depends
on another being enabled.

| Layer | Engine | Key | Scope |
|---|---|---|---|
| **The stamp** | `bayt fingerprint` in go-task's `status:` | SHA-256 of platform key (kernel, arch, libc), manifest, srcs and direct deps' stamps | one worktree |
| **The cache** | `bayt cache run` around every command: local disk, bazel-remote or ORAS, chosen by environment | the stamp's key | one machine, or shared with CI |
| **BuildKit** | Docker's content-addressed layer store | the Dockerfile slice and COPY'd bytes | per host, plus a registry cache |

## The stamp

The emitter writes the wiring; a project never does. A `cache.full` target, as
emitted outside the monorepo (one command line per OS; linux shown):

```yaml
# .bayt/Taskfile.build.yaml
tasks:
  default:
    deps: ["::bayt:deps", "::bayt:cross_libraries_xproto_build"]
    if: "bayt cache check --manifest '{{.TASKFILE_DIR}}/bayt.build.json' --stamp-file .task/bayt/build.hash; [ $? -ne 10 ]"
    run: once
    status:
    - "bayt fingerprint --manifest '{{.TASKFILE_DIR}}/bayt.build.json' --stamp-file .task/bayt/build.hash"
    vars:
      BAYTW: "bayt cache run --manifest '{{.TASKFILE_DIR}}/bayt.build.json' --full -- mise x --"
    cmds:
    - cmd: "{{.BAYTW}} ./gradlew --init-script .bayt/init.gradle.kts assemble"
      platforms: [linux]
    - defer: "{{if not .EXIT_CODE}}bayt fingerprint --manifest '{{.TASKFILE_DIR}}/bayt.build.json' --stamp-file .task/bayt/build.hash --update-stamp{{end}}"
```

The `if:` is [the cache check](../../CONTRIBUTING.md#the-cache-check). Every
input lives in `.bayt/bayt.<n>.json`, which CUE emits once and every other
emitter, `fingerprint.nu` and `cache.nu` read, so the generator stays
deterministic and the runtime replaceable. A missing out forces a rerun that
the cache can answer with a fetch.

**Hashing a dep's stamp, not its srcs,** is what makes invalidation transitive
in O(direct deps) per check:

```
stamp(T) = hash(platform-key ∪ manifest(T) ∪ srcs(T) ∪ {stamp(d) for d in directDeps(T)})
```

go-task runs deps before it evaluates the parent's `status:`, so each dep's
stamp is fresh when read, and a leaf's change bubbles up one layer at a time
with no recursive walk in CUE or nushell. The stamp is written atomically in the task's `defer:`,
and a missing literal file or a failing `git hash-object` fails the check
rather than poisoning the cache. It needs only nushell and git, so it runs in
containers, on Windows and in air-gapped CI.

## The cache

`bayt cache run [--full] [--similar] -- <cmd>` computes the same key, restores
an exact hit's outs, and with `--full` skips the command on that hit; otherwise
it runs the command over the warm outs, which gradle, cargo or vitest then
no-op quickly, and stores the outs on a miss that succeeds. `--similar`
restores the closest entry as warm state on a miss. `bayt.cache.full` suits a
command whose own no-op is expensive — the gradle stack sets it on `assemble`
and `integrationTest` because the daemon's cold start costs more than the
restore.

On bazel-remote, payload files go to `/cas/<sha256>`, one blob each, and the
entry — `[{path, size, sha256, exec}]` — to `/ac/<key>`. Addressing payload by
content stores and transfers a file shared by two entries once, the common case
since most outs survive a rebuild, and keeps raw bytes where a single-blob
entry would need an encoding wrapper. The entry's address folds in a format
tag, so a client speaking another entry format lands on another key instead of
a body it cannot parse. The entry is not a REAPI ActionResult, hence
`--disable_http_ac_validation`; the CAS half needs no flag, since bazel-remote
validates each upload against its digest. Remote storage behind it (S3, GCS,
Azure, a proxy) is bazel-remote's own configuration.

A failed GET or an unresolvable manifest warns and counts as a miss. A restore
that fails partway clears the target's declared outs first, so the rerun starts
from nothing rather than from a mix the next store would publish as complete. A
failed PUT, a missing `oras` CLI under ORAS, or a failed GC dies.

The key is input-only. A toolchain change still invalidates, because
`.mise.toml` and `mise.lock` flow through the workspace-root setup target's
outs into every consumer's key.

## BuildKit, and the tool's own cache

BuildKit gates individual layers: `COPY --link` keeps one target's srcs from
invalidating another's layers, cache mounts keep tool caches (`~/.gradle`, the
pnpm store, `~/.cache/go-build`) across builds, and a registry cache shares
layers across machines.

A tool's own cache is a fourth participant, not a competitor: the gradle stack
points gradle's build cache at `$BAYT_CACHE_DIR/gradle` through
`.bayt/init.gradle.kts`, so gradle's per-task cache and bayt's per-target cache
share one store. Per-task hits cover the case where some inputs changed; a
`cache.full` hit covers the case where none did and skips the daemon entirely.
