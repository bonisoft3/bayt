# Developing bayt

Contributor guide for the generator itself — the model behind the emitted
`.bayt/` files and, more importantly, the **compose behaviors that will bite you**
if you touch the runtime emission. README.md is the user-facing pitch; DESIGN.md
is the architecture/rationale; this is "what's actually true and what breaks."

## Target lifecycle flags

Flags placing a target in the build/runtime graphs, each living with the config
it governs — `bake.image` on `bake`, `up`/`manual` on `compose`.

| flag | question | emission |
|---|---|---|
| `bake.image` | ships a release image? | emits the `bake.hcl` build recipe skaffold / goreleaser / depot bake with; push vs load is the `$PUSH_IMAGE` env var |
| `compose.up` | a closure / load-by-name point? | emits `compose.<n>.closure.yaml` |
| `compose.manual` | a harness, off the bare-`up` stack? | `scale: 0` (present, no container); reached by targeting its root alias |
| `deps: []` | build-graph edge (COPY the dep's tree) | Dockerfile `COPY --from` + `additional_contexts` |
| `compose.depends_on` | runtime-graph edge (must be running) | compose `depends_on`, auto-mirrored to `additional_contexts` |

Declaring `compose.up` / `compose.manual` creates the target's compose block, so
it joins the runtime graph.

### Dep-edge shape

A plain dep edge bulk-COPYs the dep's workdir. To take only the declared
interface (a scratch image of `outs.globs`), ref the `:outs` view explicitly:
`deps: [":foo:outs"]`. Nothing infers it from a target's role. See `_depEdge` in
gen_compose.cue (D12/D13/D17).

Don't plain-`deps` a target whose output is an *image*, not workdir files (a
launch/release on a `FROM busybox`-style base): the bulk `COPY --from=<it>
/monorepo/<dir> …` fails when that runtime image has no `/monorepo/<dir>`,
and when it does have one, copies it for nothing. Dep its `:outs` view
instead — emitted for every dockerfile target, `outs: globs: []` included,
and an empty one federates the producer into the consumer's closure without
a COPY or an `additional_contexts` entry (D20 pins both halves).
`compose.depends_on` also gives the edge without a copy, but it *starts* the
producer (gotcha 2 below) — take it only when the consumer needs it running.

## The runtime bring-up model

DESIGN.md describes the roles and what bare `docker compose up` starts. The
invariant to hold when touching the scale gate (gen_compose.cue, guarded by
D16): a container runs on bare `up` iff it declares a compose block and isn't
`manual`. Everything else — build/setup stages, the `_srcs`/`_outs`/`bayt`
synthetics, and `manual` harnesses — is `scale: 0`, present so `service:`
contexts resolve. A `manual` harness is reached by targeting its root alias
(`docker compose up integrate`).

## Compose gotchas (empirically verified — do not "fix" without re-testing)

The load-bearing facts behind the scale-gate design, all reproduced with
`docker compose` directly.

1. **A profiled service is dropped from a profile-less `config`/`up`**, so any
   non-profiled service that `depends_on` it — or build-context-refs it via
   `additional_contexts` — fails project load (`depends on undefined service …`).
   A `scale: 0` service instead stays present (0 replicas) and resolves those
   edges. That's why a `manual` harness is `scale: 0`, **not** profiled: its
   `_outs` synth and any `depends_on` onto it resolve for free — no `--profile`
   gymnastics, and nothing to guard against.
2. **Targeting runs a service regardless of scale/profile**: `docker compose up
   <svc>` starts `<svc>` and its `depends_on` closure. A `manual` harness's root
   alias is `scale: 1` under its own profile, so `up integrate` runs it even
   though the base is `scale: 0`.
3. **`--profile '*'`** is the canonical "give me the fully-evaluated config"
   flatten, passed at every `config`/bake materialization so profiled aliases are
   present. Under `scale: 0` the load-bearing base is already present, so it's
   belt-and-suspenders — kept as the standard call, not relied on.
4. **`required: false` does not tolerate a missing include.** compose errors
   `open …: no such file or directory` either way (repro: a two-line file whose
   only include is optional and absent). So every file compose loads must
   reference only files that exist *where it is loaded*. This is why an
   in-layer entry is a closure — a flat, exact list of the fragments that layer
   carries — and not a project's federation root, which indexes all of a
   project's targets while a layer only carries the ones it deps on.
5. **Nested includes re-parse.** compose-go's `ApplyInclude` walks a subtree
   once per path reaching it, with no dedup, so cost climbs with federation
   size. Flattening the integrate closure instead of the user root is 1.5x
   faster on a 2-cross-root project and 8x on a 7-cross-root one, for the same
   result — point `config` at the flat file wherever a call site has the choice.

## Where computation lives: CUE vs nushell

The split is deliberate — CUE is the pure, deterministic generator; nushell
(`generate.nu`, `cache.nu`, …) is the impure runtime (file I/O, hashing, docker).
Keep new work in CUE: it is the safer half, and only measured cost should move
something out.

It is also a performance boundary, and the measurements say the boundary is
rarely the problem. CUE pass-2 eval is 96–99% of a project's generate time, and
`#dockerComposeGen` is ~70% of that; package load is free. A graph walk is a
small share: `upClosure` costs ~570 ms on a deep cross-project chain (~11% of
that project) and nothing measurable on a wide, shallow one, while the
`depot-build` walk added ~2%. The same walk in nushell runs in ~5 ms, so moving
one is a real but narrow win — worth it only where a chain is deep.

When attributing cost, ablate. CUE evaluates the whole render eagerly, so
`cue export -e <sub-expression>` does **not** prune and every sub-expression
times the same. `BAYT_TIMING=1` breaks generate into scan / per-level phases.

## When you touch the runtime emission

- Changing the scale gate, the closures, or the federation root: re-read the
  gotchas above, then validate with **`sayt integrate`** on a real project (the
  dindbox cascade), not just `test-bayt` — compose behavior is invisible to the
  CUE suite.
- Pick that project for **cross-project deps**. A single-project graph exercises
  none of the in-layer fragment resolution, so it passes changes that break
  every federated project.

## Test layout

`nu tests/test-bayt.nu` runs the CUE suites (positive + negative + the D-guards in
`core/*_check.cue`). The docker-backed integration guards
(`tests/*_integration_test.nu`, wired into `sayt integrate`) exercise real
buildkit — cache-hit, diamond-dedup, and scoped-clamp digest stability. The
D-guards (`docker_compose_check.cue`) are where the emitter's invariants (dep-edge
shape D12/D13/D17, the scale gate D16, closures D17/D18) are pinned.
