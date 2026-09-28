---
type: howto
title: Contributing to bayt
description: The layout of plugins/bayt, why the runtime emission has its shape, and what validates a change to the generator.
---

# Contributing to bayt

For changing the generator itself. [README.md](README.md) is the user's entry
and maps the tree ([Layout](README.md#layout)), [SPEC.md](SPEC.md) states what a
`bayt.cue` may contain, and [docs/index.md](docs/index.md) lists the decisions
behind that shape.

## The cache check

go-task runs a task's `deps` before its `status:`, so a `status:` hit comes
only after every dep beneath it has run, and the deps that are not
`cache.full` run in full. gradle's `deps` target resolves into
`$GRADLE_USER_HOME`, outside `outs` and `state`, so a hit still pays the
resolve: 3m37s of `services/tracker:build` on a fresh runner with a warm remote
cache, where Bazel, which materializes an action's inputs only if the action
executes, took 15.7s. A `cache.full` target is therefore checked in its task's
`if:`, which go-task evaluates in `RunTask` before `runDeps` (v3.49.1,
`task.go`): an exact hit restores the target and skips its whole subgraph, and
a miss runs the deps as usual. The contract is [SPEC's](SPEC.md#the-cache); the
emitted check is `gen_taskfile.cue`'s.

**`state` producers cannot close the gap themselves.** `state` says the owning
tool is the canonical cache and its own invocation the restore path, and
nothing about whether a consumer rebuilds it. gradle refills its closure on
demand, but `guis/web`'s `setup` declares `node_modules` as state and a `vite
build` that misses installs nothing, so marking state producers `full` is right
for gradle and wrong for pnpm. What matters is that nothing needing the state
runs, and that is decided without knowing anything about the state.

**Exit 10, not 1.** go-task reads any non-zero `if:` as "skip", so a bare check
that crashed would skip the build in silence. The condition tests for 10 alone,
so a crash runs the task as if the check were absent. go-task runs `if:`
through its built-in POSIX shell on every platform, Windows included.

**The key is walked, not read from dep stamps.** The check runs before the
deps, so a dep's stamp can predate an edit, and a check trusting it would skip
on the old key. A dep with no manifest on disk, inside a container that COPYs
its outs and stamp but not its `.bayt`, cannot run, so its stamp cannot go
stale. A hit pays the walk once at the top, and a miss at each `cache.full`
level on the way down, where the build it precedes dominates.

## Dep-edge shape

`deps` is a build-graph edge (`COPY --from` plus `additional_contexts`);
`compose.depends_on` is a runtime-graph edge — the producer must be running —
auto-mirrored into `additional_contexts`. Which COPY a dep gets is chosen by the
ref, never inferred from a target's role (`_depEdge` in `gen_compose.cue`, D12,
D13, D17).

Don't plain-`deps` a target whose output is an *image* rather than workdir
files (a launch or release on a `FROM busybox`-style base): the bulk `COPY
--from=<it> /monorepo/<dir> …` fails when that image has no `/monorepo/<dir>`,
and copies it for nothing when it does. Dep its `:outs` view instead, which
federates without a copy when `outs` is empty (D20). `compose.depends_on` also
gives the edge without a copy, but it *starts* the producer (finding 2 below).

## The scale gate

The scale gate (`gen_compose.cue`, D16) holds [SPEC's bring-up
invariant](SPEC.md#runtime-bring-up). Each finding below was reproduced with
`docker compose` directly; re-measure before changing any, because the CUE
suite cannot see compose behaviour.

1. **A profiled service is dropped from a profile-less `config`/`up`**, so a
   non-profiled service that `depends_on` it or refs it through
   `additional_contexts` fails project load (`depends on undefined service …`).
   A `scale: 0` service stays present and resolves those edges, with no
   `--profile` to pass.
2. **Targeting runs a service regardless of scale or profile**: `docker compose
   up <svc>` starts `<svc>` and its `depends_on` closure. A `manual` harness's
   root alias is `scale: 1` under its own profile, so `up integrate` runs it.
3. **`required: false` does not tolerate a missing include**: compose errors
   `open …: no such file or directory` either way. Every file compose loads must
   reference only files that exist where it is loaded, which is why an in-layer
   entry is a closure — the exact fragments that layer carries — and not a
   project's federation root.
4. **Nested includes re-parse.** compose-go walks a subtree once per path
   reaching it, so cost climbs with federation size; flattening the integrate
   closure instead of the user root was 1.5x faster on a 2-cross-root project
   and 8x on a 7-cross-root one. Point `config` at the flat file wherever a call
   site has the choice.

## Driving the compose model by hand

- A runtime-only `up` is `up --no-build`, or `BAYT_PULL_POLICY=missing` under
  `bake.images.pull`, which pulls what a build phase pushed instead of failing
  on the closure's `pull_policy: build`.
- Every `config` or bake flatten, and a manual `docker compose down` of
  containers started through an alias, passes `--profile "*"`; `sayt integrate`
  tears down by project label, which is profile-blind.
- `docker compose -f .bayt/compose.<n>.closure.yaml up bayt` works in every
  project and inside a dindbox, where the user root may not exist; the generated
  ci RUN bodies and `sayt/depot`'s run phase use it.

## Where computation lives: CUE vs nushell

CUE is the pure, deterministic generator; nushell (`generate.nu`, `cache.nu`, …)
is the impure runtime (file I/O, hashing, docker), and the emitted manifest is
the boundary. Keep new work in CUE, the safer half; only measured cost moves
something out, and a graph walk is a small share of pass-2 evaluation except on
deep chains. Attribute cost by ablation: CUE evaluates the whole render eagerly,
so `cue export -e <sub-expression>` does **not** prune. `BAYT_TIMING=1` breaks
generate into scan and per-level phases.

## Image pins and the archive

The pinning policy is the README's [design principle 7](README.md#design-principles).
`nubox` is leap rather than a rolling distro such as wolfi for the same reason:
a rolling base moves its digest on every refresh, while leap's releases live
long enough that a moved pin is rare and its diff gets read.

## Validating a change to the runtime emission

The CUE suite proves the emitter agrees with itself, not what compose does with
the output. A change to the scale gate, the closures or the federation root is
validated with **`sayt integrate`** on a real project with **cross-project
deps** — a single-project graph exercises none of the in-layer fragment
resolution, which is how a change passes locally and breaks every federated
project.

## Test layout

bayt's own loop rides the sayt verbs (`.say.yaml`):

```bash
cd plugins/bayt
just sayt build      # nu tests/bayt_test.nu — the CUE positive + negative suites
just sayt test       # every *_test.nu suite, in parallel; no daemon needed
just sayt integrate  # every *_it.nu suite; needs docker
```

`bayt_test.nu` evaluates the CUE suites and the D-guards (`core/*_check.cue`;
the emitter's invariants are in `docker_compose_check.cue`) with strict `cue
eval`, not lenient `cue vet`. Any `*_test.nu` also runs alone with `nu <file>`;
the `*_it.nu` guards exercise real buildkit.

## Releasing

Two artifacts on two independent tag streams: `bonitao/bayt` — the generator's
CUE, CLI and release assets — and `bonitao/bayt-runtime`, built by
`Dockerfile.runtime`. Neither references the other's source, so neither release
has to follow the other.

**Generator.** Merge, then tag the merge commit; the image and release assets
publish.

**Runtime.** Only when `runtime/` changes: bump `runtime/VERSION`, merge, tag,
then bump `images.lock.cue` to the published digest in an ordinary pull request.

    docker buildx imagetools inspect bonitao/bayt-runtime:X.Y.Z \
      --format '{{json .Manifest.Digest}}'

That build is reproducible only while left alone; `.github/workflows/cd.yml`
says what not to change.

### What stops you

- **`verify-generated`** runs `just generate-all` on the *tagged* commit, not on
  main: regenerating only the project you touched passes locally and fails there,
  and a fix landing after the newest component-touching commit leaves nothing
  taggable until you land a component-touching change on top of it.
- **Tag versus VERSION.** A tag disagreeing with its component's `VERSION` is
  rejected — in CI, and in `sayt release` before the tag is pushed.
- **`sayt lint`** holds the frontend digest equal across every file stating it.

### Cutting a tag

Tags are prefixed per component: `plugins/bayt/vX.Y.Z`,
`plugins/bayt/runtime/vX.Y.Z`. Tag the merge commit; nothing has to be synced
first, because `propagate-tag` publishes the component to its mirror before
looking the commit up there. Copybara replays a bounded batch per run, so a
mirror far behind may not reach the tagged commit in one — the lookup is what
reports it, and `sync.yml` run again closes the gap.
