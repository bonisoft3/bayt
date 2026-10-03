---
type: reference
title: The bayt target, specified
description: What a bayt.cue may contain beyond its field list — #cmd and its override levels, refs and views, runtime bring-up, transitive walking — and the cache that keys on it.
---

# The bayt target, specified

Normative: the guards in `core/*_check.cue` fail a target that violates the
shape, so a statement here is a claim `bayt_test` can refute. The field list is
`core/bayt.cue` (`#project`, `#target`, the output blocks); this is what the
field list cannot say.

## A `bayt.cue`

One per project directory, in its own package, exporting `project:
bayt.#project`. Generation is two CUE passes: pass 1 collects the cross-project
refs; pass 2 loads each referenced project's emitted manifests and renders
through a generated driver, `.bayt/render.cue`. Projects never import each
other's CUE: cross-project facts travel as emitted manifests, which keeps every
project relocatable.

`project.dir` is relative to the workspace root. At the root, both `""` and
`"."` mean depth zero: a closure inside `.bayt/` needs one `../` to reach its
project files. The manifest retains the declared spelling; the manifest
generator treats both root spellings alike when calculating depth and prefixes.

Verbs, presets and capabilities (`sayt.build`, `bayt.nubox`, `bayt.cache.full`)
are plain struct values unified into a target, not closed definitions:
composition is unification, never inheritance, so a fragment is declared far
from the target and merged at evaluation. Keyed entries (`defaultGlobs`,
`defaultPreamble`, `cmd`) let another stack or the project add, reorder by
`priority` or delete with `null`.

## `#cmd` and the three override levels

```cue
#cmd: {
    priority: *0 | int              // lower runs first
    shell:    *"exec" | "nu" | "sh" | "bash" | "pwsh" | …
    do?:      string                // host form; omit for a RUN-only cmd
    stop:     *false | bool
    srcs:     {globs, defaultGlobs, exclude, defaultExclude}   // additive; per-cmd stamps
    windows?: {do?, shell?}         // OS axis: each fully overrides do/shell
    linux?:   {do?, shell?}
    darwin?:  {do?, shell?}
    dockerfile?: {                  // format axis: only the Dockerfile emitter reads it
        inject?, mounts?, secrets?, network?
        do?:      string            // RUN-only form; with no base `do`, no task is emitted
    }
}
```

`inject` forces `shell: "sh"`: the wrapped body is a heredoc `RUN` that
`/bin/sh` interprets.

```cue
// 1. Shorthand: `do` is the "builtin" rule.
targets: build: do: "./gradlew assemble"

// 2. Rulemap: named rules, priority order, null to delete.
targets: build: cmd: {
    "pregen":  {priority: -10, do: "./scripts/gen-code.nu"}
    "builtin": {do: "./gradlew assemble"}
}

// 3. Far-away decoration: a stack adds a mount to the "builtin" rule only.
targets: build: cmd: "builtin": dockerfile: mounts: [{type: "cache", target: "/root/.gradle", scope: "global"}]
```

The OS axis lives on the command, not the output block: the Taskfile emits one
line per variant under `platforms:`, the vscode entry emits `windows:`, and the
Dockerfile, compose, skaffold and bake are Linux and drop the Windows arm. A
target with several `do` cmds emits one internal task per cmd, chained by
priority, each with its own stamp and cache entry; the default task writes the
target stamp when all pass.

## Refs and synthetic views

```
":target"                                 same project
"project:target"                          cross project (project = the producer's #project.name,
                                          by default its dir with / → _)
":target:srcs" | "project:target:srcs"    scratch image of the target's srcs
":target:outs" | "project:target:outs"    scratch image of its outs
":target:bayt" | "project:target:bayt"    scratch image of its scaffolding
```

Every dockerfile target gets the three views as sibling compose services
(`<project>-<target>_srcs`, `_outs`, `_bayt`). A plain dep copies the producer's
workdir; `:outs` copies exactly its `outs`. `:outs` is
declared even when `outs` is empty, where it emits no image: depping it
federates the producer's compose fragments into the consumer's closure and
orders the two without copying, which is how a consumer names an image-only
producer (launch, release). `:bayt` carries the target's fragment, Dockerfile,
taskfile, manifest, go-task roots and up closure plus its deps' chained
scaffolding, nothing from siblings, so a sibling's churn never invalidates a
consumer layer. A `from: ref` is inheritance only and rejects views; a
cross-project `from: ref` federates on its own, and `deps` is added only when
the consumer also wants the dep's outs copied in.

Visibility is checked at the direct consumer-to-dep boundary: a cross-project
`deps` or `from.ref` onto an `internal` target fails generation. Once crossed,
transitive deps ride along regardless of their own visibility.

## Runtime bring-up

A container runs on bare `docker compose up` iff it declares a compose block and
is not `compose.manual` (a harness; the sayt stack sets it on integrate).
Everything else — build and setup stages, the synthetics,
manual harnesses — is emitted at `scale: 0`: in the model so `service:` build
contexts resolve, running no container. A user `compose.scale` wins. The root
`.bayt/compose.yaml` adds one short alias per target (`extends` the qualified
service), profile-gated under its own name and `scale: 1`, so `docker compose up
integrate` runs the harness and bare `up` skips it; flattening the root
(`compose config` for bake) needs `--profile "*"` or the aliases drop out. Why
`scale: 0` rather than profiles is measured in
[CONTRIBUTING.md](CONTRIBUTING.md#the-scale-gate).

Each `compose.up` target (a load-by-name point: launch, integrate) also gets
`compose.<n>.closure.yaml`: a flat include of the
manifest's `upClosure` (own fragment, same-project deps' closures, cross deps'
closures from their manifests — closed at generate time, never nested) plus the
project's `compose.includes`, defining one service, the reserved `bayt` alias at
`scale: 1`. It loads with no user root and no federation files, on the host or
at `/monorepo` inside a layer. A project with overlays widens every closure to
the union of its targets' closures, since hand-alias names in overlays cannot be
resolved to targets.

`.bayt/depot.hcl` names the images a CI build phase must push: a bake `group
"depot-build"` of `integrate` plus its transitive `compose.depends_on`, in its
own file because `bake.hcl` binds `tags = [IMAGE]` onto every matrix member and
HCL cannot say "leave unset". `.bayt/depot.yaml` is the graph pre-flattened at
generate time, kept as compose because `buildx bake --print` would resolve the
`${…}` CI still has to bind.

## The runtime process

`entrypoint` is the process a target runs, whether it serves until stopped or
runs to completion: a `#cmd` (so `do`, `shell` and the `dockerfile` axis) plus
`env`, `after` and `host`, without the `windows`/`linux`/`darwin` variants a
container would ignore and process-compose cannot select. `expose` names the ports it listens on, each
`{port, env}`. Like `healthcheck`, both are sugar over every projection; a field
set both ways must agree, or generation fails. `host: false` keeps a process only
its image can run out of `.bayt/process-compose.yaml` and every host rule below.

| | container | host |
|---|---|---|
| process | Dockerfile `ENTRYPOINT`, exec form | a process in `.bayt/process-compose.yaml` |
| `env` | compose `environment` | process `environment`, peers rewritten |
| `after` | compose `depends_on`, `service_*` | process `depends_on`, `process_*` |
| `expose` | `EXPOSE`; `env` set to the canonical port | `env` set to the port's variable |

**The process.** An image whose own entrypoint does work, as postgres's initdb
and user switch, has that wrapper lifted into `do` (`docker-entrypoint.sh
postgres`), so both sides run it. `ENTRYPOINT` resets only the `CMD` a base image
carries, so `dockerfile.cmd` or `compose.command` beside the sugar fails
generation rather than becoming its arguments, and a `dockerfile.entrypoint` or
`compose.entrypoint` must be the same argv, as a list. A container's process
starts from what its image baked in; an image whose process needs a wrapper
says so in `dockerfile.do`. On the host the target's `activate` wraps the
entrypoint and its probes, whole command and shell included, and
`process-compose.activate` replaces it where the process's toolchain differs from
the one the target's build cmds run under. The file sets `MISE_LOCKED=0` for
every process and probe: host toolchains are pinned by version in `activate`,
which no lockfile lists.

**Containers.** The compose side lowers only into a target with a `compose`
block, which is what runs a container. A container's `after` names only peers
that have one, and that its `deps` name, since a compose file includes only what
its target depends on.

**Ports.** A port reaches its process only through `env`, read directly or by
the entrypoint's shell (`-p "$PORT"`), which expands at run time on both sides.
On the host it is `${<TARGET>_<NAME>_PORT:-<n>}`, where `<n>` is the port's
`host`, or else a hash of project, target and port into 10000–32767, below the
Linux and macOS ephemeral ranges: two projects differ, and two checkouts of one
collide loudly on the bind. Two host processes' ports on one variable or one
default fail generation; containers each have their own network. A port without
`env` keeps its number on the host, where no caller can move it either.

**Addresses.** A value names a peer as compose does, `<target>:<port>` or
`<project>-<target>:<port>`, and the host projection rewrites it to `127.0.0.1`
and the peer's variable; a process's own loopback references
(`http://localhost:3000`) move with its ports. A port ends where a port ends, so
`redis:7-alpine` is an image, `user:1234@` a password, `tcp(db:3306)` an address
and `mirror.database:5432` another host; a whole value such as `postgres:18`
beside a target named `postgres` still reads as an address. Under a key naming a
host (a `_HOST`, `_HOSTNAME`, `_ADDR` or `_SERVER` suffix, or libpq's `PGHOST`), a
whole value naming a peer becomes `127.0.0.1`. When the peer's ports move, a host
key's port key (`DB_HOST`'s `DB_PORT`) must hold a port the peer exposes, and is
rewritten with it; other host keys name such a peer as `<peer>:<port>`. Elsewhere a target's name
is just a word, as a `POSTGRES_USER` of `postgres`. Only `env` is rewritten:
generation fails on a value naming a port the peer does not expose, a peer as a
URL host the rewrite cannot place, a service the host does not run, or an
entrypoint command naming a peer. These rules read the project's own targets: a
process-compose file runs one project, so another project's services are not
peers.

**Expansion and probes.** process-compose expands `${…}` at load, from the
launching environment, and reads `$$` as `$`; it renders a probe's command as a
Go template too. Environment values and probes use that, as compose does; the
entrypoint has every `$` doubled, so its own shell expands it at run time, as in
a container. A host process using a `healthcheck` template gets the container's
check as its readiness probe, on the host's spelling of each own port. A target
with no image takes the check alone, `healthcheck: bayt.healthcheck.#<kind> &
{…}`, since the template also writes the Dockerfile and compose checks.
microcheck's run through `bayt microcheck`, from checksum-pinned stubs that a
`bayt:<checker>` one-shot installs before the process probing with them starts,
and need a Linux or macOS host, microcheck publishing no Windows build. process-compose
terminates a process that misses `failure_threshold` and skips what waits on it,
so the threshold covers `start_period` as well as the retries; a duration compose
would refuse fails generation. It waits forever for health a process has no probe
to report, so `after: X: "healthy"` fails generation when X has none. A
`process-compose.readiness_probe` beside a template's must agree with it.

**Running.** process-compose runs the file from the project directory, which
`working_dir` and the in-tree paths resolve against: `process-compose -f
.bayt/process-compose.yaml up <n>` keeps the stack running, and `run <n>` exits
with the process's code and stops what it started, as compose's `up` and `run`
do. Its HTTP server defaults to TCP 8080, so a caller passes `--no-server` or
`--use-uds`. A host process whose target has a `taskfile` block waits on a
`<n>:build` one-shot, `task -t .bayt/Taskfile.yml bayt:<n>`, so a stack builds
what it starts, as `compose up --build` does, and `default` stays the build
every dependent reaches. A caller moves the stack by setting its port variables
before load; process-compose's `env_cmds` reach only the processes, never the
`${…}` the file expands. Every process sets `exit_on_skipped`, or a stack that
cannot start would pass its check, and the stack stops in reverse dependency
order. The `process-compose` block passes
`availability` (restart policies), the probes, `shutdown` and `working_dir`
through; a one-shot that exits 0 is a success, and what needs it finished waits
on `"completed"`.

## Transitive walking

The manifest carries `chainedDeps` (`{name, project, dir, outs}` per direct
dep, same or cross project), `transitiveCrossDeps`, `crossProjectDirs` and
`upClosure`. Three pipelines feed them:

1. **Same-project chain.** `deps: [":b"]` or `from: ref: ":b"` inherits `:b`'s
   same-project transitive deps, and the emitter COPYs each entry's `outs`
   unless the FROM-chained upstream already provides it.
2. **Cross-project federation.** A dep `proj:b` brings `proj:b`'s own
   `transitiveCrossDeps` from its manifest, so the consumer names its immediate
   dep only; compose includes and `additional_contexts` follow.
3. **`:srcs` federation.** A `:srcs` view mirrors its parent's chain with each
   ref flipped to `:srcs`, so a consumer of `:integrate:srcs` pulls every
   upstream's `:setup:srcs` (toolchain files) without listing them.

`fingerprint.nu` reads the same `chainedDeps`: a target's key is its own inputs
plus each dep's hash, trusting a dep's stamp when go-task has just refreshed it
and walking the dep's manifest when it has not
([the cache check](CONTRIBUTING.md#the-cache-check)).

## The cache

Three layers each skip something different at a different scope, and none
depends on another being enabled.

| Layer | Engine | Key | Scope |
|---|---|---|---|
| **The stamp** | `bayt fingerprint` in go-task's `status:` | SHA-256 of the platform key (kernel, arch, libc), the manifest, `srcs` and the direct deps' stamps | one worktree |
| **The cache** | `bayt cache run` around every command: local disk, bazel-remote or ORAS, chosen by environment | the stamp's key | one machine, or shared with CI |
| **BuildKit** | Docker's content-addressed layer store | the Dockerfile slice and the bytes it COPYs | per host, plus a registry cache |

**The stamp** is

    stamp(T) = hash(platform-key ∪ manifest(T) ∪ srcs(T) ∪ {stamp(d) for d in directDeps(T)})

go-task runs a task's deps before it evaluates its `status:`, so each dep's
stamp is fresh when read, and invalidation is transitive at O(direct deps) per
target. The task's `defer:` writes the stamp atomically after a success. A
missing literal file is skipped with a warning, srcs that match no file fail the
check, and a missing out forces a rerun, which the cache can answer with a
fetch. Files hash with nushell's `hash sha256`, memoized by path, size and
mtime in `.task/bayt/index`; git, when bayt's root is a work tree's top level,
only lists the files faster. The stamp needs only nushell, so it runs in
containers, on Windows and in air-gapped CI.

**`bayt cache run [--full] [--similar] -- <cmd>`** computes the same key and
restores an exact hit's outs. With `--full` (`bayt.cache.full`) it skips the
command on that hit, which suits a command whose own no-op is expensive, such
as gradle's daemon start; otherwise it runs the command over the warm outs, and
it stores the outs after a miss that succeeds. `--similar` restores the closest
entry as warm state on a miss, on the local backend only; bazel-remote and ORAS
answer no similarity lookup. The key is input-only: a toolchain change
invalidates because `.mise.toml` and `mise.lock` reach every consumer's key
through the workspace-root setup target's outs. A failed GET warns and counts
as a miss; an unresolvable manifest warns and bypasses the cache, running the
command raw and storing nothing; a restore that fails partway
clears the target's declared outs first; a failed PUT, a missing `oras` CLI
under ORAS, or a failed GC dies. The backends, their environment and
bazel-remote's storage layout are [`cache.nu`](runtime/cache.nu)'s.

**`bayt cache check`** is a single-command `cache.full` target's task-level
`if:`, spelled `bayt cache check …; [ $? -ne 10 ]`, which go-task evaluates
before the deps. It exits 10 when the target is satisfied without running
anything: the stamp holds the key and every declared out and `state` path is
present, or an exact hit restored the outs and the check wrote the stamp.
Anything else exits 0, and go-task runs the deps, `status:` and the command.
The check walks the key from manifests, trusting only the stamp of a dep with
no manifest on disk. `task --force` bypasses `status:`, not `if:`; to force a
run, delete the stamp and outs, or set `BAYT_CACHE_ENABLED=false` with no
stamp.

**BuildKit and the tool's own cache.** `COPY --link` keeps one target's srcs
from invalidating another's layers, cache mounts keep tool caches (`~/.gradle`,
the pnpm store, `~/.cache/go-build`) across builds, and a registry cache shares
layers across machines. A tool's own cache composes with all three: the gradle
stack points gradle's build cache at `$BAYT_CACHE_DIR/gradle` through
`.bayt/init.gradle.kts`, so gradle's per-task hits cover a change to some
inputs and a `cache.full` hit covers a change to none.

### Rejected

- **Hashing a dep's srcs instead of its stamp** — every check would walk the
  closure, in CUE or nushell; the stamp go-task has just refreshed carries it.
  Only the check, which runs before the deps, pays the walk.
- **Folding tool versions into the key** — `.mise.toml` and `mise.lock` already
  reach every key through the setup target's outs.
- **bayt's cache in place of a tool's own** — a per-target key misses whenever
  any input changed, where gradle's per-task cache still hits on the rest.
