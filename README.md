# bayt

Bayt gives you Bazel-quality incremental invalidation on top of the build tools you already use — gradle, pnpm, go, cargo, make, whatever. One CUE declaration per target generates every file your existing tools expect: `Taskfile.yml`, per-target `Dockerfile`s, `compose.yaml`, `skaffold.yaml`, `docker-bake.hcl`, `.vscode/tasks.json`, plus a canonical per-target JSON manifest.

You don't migrate away from your build tool. You just stop hand-maintaining seven files that all describe the same target in slightly different ways.

Bayt is the declarative layer under [sayt](https://github.com/bonisoft3/sayt) — sayt covers the day-to-day verbs (`setup`, `build`, `test`, …), bayt defines what those verbs operate on when a project opts into fine-grained targets. If you're happy with `.vscode/tasks.json` you don't need bayt. If you're tired of your build graph disagreeing with your compose graph which disagrees with your CI graph, bayt is the DSL that makes one source of truth for all of them.

## Why bayt?

- **One target, every format.** `srcs`, `deps`, `outs`, `cmd` — declared once in CUE, emitted into Taskfile, Dockerfile, compose, skaffold, bake, and vscode. No drift, no copy-paste.
- **Merkle-chain fingerprinting.** Every target hashes its own manifest + srcs + each direct dep's stamp file. A change anywhere in the DAG cascades exactly once per layer. Same correctness guarantee Bazel gives you, with no sandbox, no Starlark, no rule ecosystem to learn.
- **Works with what you have.** Your gradle/pnpm/go commands keep running them. Bayt doesn't replace `./gradlew` or `pnpm install`; it just makes sure they run exactly when they need to.
- **Shared stack definitions.** Concept libraries (`gradle`, `pnpm`, `mise`) capture per-toolchain primitives; the `sayt` umbrella maps them onto the canonical 10-verb shape. A new gradle service is five lines of CUE: `_proj: sayt.gradle & { dir: "..." }`.
- **Content-addressable caching, two layers.** `cache.nu` wraps every Taskfile cmd with content-addressed restore-and-run. Stack-side, gradle/cargo/go/etc. get their own native build cache pointed at the same `$BAYT_CACHE_DIR` directory — gradle's per-task cache for example is ~15× finer than bayt's per-target cache. The two layers compose: bayt skips the whole cmd when the target hasn't changed; the tool skips most of its work when only some inputs changed. Backends for the bayt layer: local-FS (default, XDG-compliant), `BAYT_CACHE_URL` for buchgr/bazel-remote, `BAYT_CACHE_REGISTRY` for ORAS OCI. Per-target `bayt.cache.full` skips cmd entirely on exact hit (the gradle daemon cold-start escape hatch).
- **Gradual adoption.** Start with one target. Add more when the hand-maintained files get painful. No all-in moment.

## Install

Bayt is distributed as a claude plugin and as a CUE module you import into your own `cue.mod`.

**Claude Code (plugin):**
```bash
claude plugin marketplace add bonisoft3/bayt
claude plugin install bayt@bonisoft3-bayt
```

**Embedded as a submodule (preferred for monorepos):**
```bash
git submodule add https://github.com/bonisoft3/bayt plugins/bayt
```

**Plain copy (no submodule):**
```bash
git clone --depth 1 https://github.com/bonisoft3/bayt /tmp/bayt
cp -r /tmp/bayt plugins/bayt
rm -rf plugins/bayt/.git
```

Bayt expects to live at `plugins/bayt/` within your monorepo so the generated Taskfiles can reference the runtime nushell scripts by relative path. That constraint mirrors sayt's relocatable layout.

If you already use sayt, the `auto-bayt` generator rule in `.sayt/config.cue` picks up bayt automatically — run `sayt generate` and bayt is part of the pipeline.

## Getting started

Start with one target. Here's a gradle service:

```cue
// services/my-service/bayt.cue
package my_service

import (
    bayt "bonisoft.org/plugins/bayt/bayt"
    sayt "bonisoft.org/plugins/bayt/stacks/sayt"
)

_proj: sayt.gradle & {
    dir: "services/my-service"
    targets: {
        "release": skaffold: image: "gcr.io/proj/my-service"
    }
}

project: _proj

depManifestsIn: {[string]: _}
_render: (bayt.#render & {project: _proj, depManifests: depManifestsIn})
```

From the project dir:

```bash
nu ../../plugins/bayt/runtime/generate-bayt.nu
```

This emits `Taskfile.yml`, `.bayt/Taskfile.<verb>.yaml`, `.bayt/<verb>.Dockerfile`, `compose.yaml`, `.bayt/compose.<verb>.yaml`, `skaffold.yaml`, `.bayt/skaffold.<verb>.yaml`, `.bayt/bake.<verb>.hcl`, `.vscode/tasks.json`, and the per-target JSON manifests under `.bayt/targets/`. All are committed — lint enforces "don't hand-edit."

Now `task build:build` runs `./gradlew assemble` only when sources changed. `task test:test` runs only when build or test sources changed. Touching any upstream file cascades through the chain automatically. If you run the same target twice with no changes, nothing happens.

Adding a second service takes five more lines of CUE. Cross-project dependencies are first-class — `services/tracker` depending on `libraries/xproto` gets xproto's build stamp folded into tracker's fingerprint, so tracker rebuilds when xproto's srcs change.

## The fields

Every `#target` is described by a small, fixed set of fields. Declare them once, emit everywhere.

| Field            | Meaning                                                             | Matches Bazel       |
|------------------|---------------------------------------------------------------------|---------------------|
| `srcs.globs`     | Files whose content change invalidates this target.                 | `srcs`              |
| `srcs.exclude`   | Glob patterns pruned from srcs walks (`node_modules/**`, etc.).     | `glob(exclude=)`    |
| `outs.globs`     | Files this target exposes to consumers. Missing outs force re-run.  | `outs`              |
| `outs.exclude`   | Glob patterns pruned from outs.                                     | —                   |
| `deps`           | Other targets to build first. Strings (same-project: `:target`, cross-project: `project:target`). | `deps`              |
| `visibility`     | `"internal"` (default) or `"public"`. Public targets are consumable cross-project. | `visibility` |
| `cmd`            | The action to run. Shorthand `do: "cmd"` or the full rulemap.       | `cmd` / `exec`      |
| `env`            | Environment variables passed to cmd.                                | `env` (via `--action_env`) |
| `activate`       | Toolchain prefix (usually `mise x --`). Defaults from `#project`.   | `toolchains`        |
| `dockerfile.from`| FROM source for this target's Dockerfile stage. Either a fresh image (`from: name: ...`, typically via an image preset like `bayt.nubox`) or a chain to another target (`from: ref: ":<target>"`). Default: scratch (when no preset). | — |
| `cache.full`     | When true, on EXACT cache hit restore outs and skip cmd entirely. Default false (restore + run cmd, letting its own incremental engine no-op on warm outputs). Use `bayt.cache.full` capability to set. | — |
| `cache.similar`  | When true, on EXACT-match miss look for the closest cached entry (weighted intersection over inputs + user/branch/day) and restore as warm starting state. Default false. Use `bayt.cache.similar` capability to set. | — |

`srcs` and `outs` are structured `{globs, exclude}`. The shorthand for the common case (no exclude) is one line:

```cue
srcs: globs: ["src/**/*.kt", "build.gradle.kts"]
outs: globs: ["build/libs/**/*.jar"]
```

A minimal target:

```cue
"build": bayt.build & {
    srcs: globs: ["src/**/*.go", "go.mod", "go.sum"]
    outs: globs: ["bin/app"]
    do: "go build -o bin/app"
}
```

For the 20% of targets that need OS variants, dockerfile mounts, or compose decoration, the full `cmd: "builtin": { do, windows, dockerfile, compose }` rulemap is available alongside.

### Producer-controlled exposure: `outs` and `visibility`

What flows from a producer to its consumers is declared by the producer, never by framework heuristic:

- **`outs.globs/exclude`** — the producer's public interface. Cross-project consumers (`deps: ["foo:build"]`) get exactly these files via per-glob `COPY --from=<producer>` in the consumer's Dockerfile. If the producer wants `.task/stamps/<target>.hash` to flow (so the consumer's task chain short-circuits the cross-project dep), they include it in outs. If not, they exclude it. No framework `--exclude=.task` magic.
- **`visibility`** — `"internal"` (default) means same-project consumers only. `"public"` means cross-project consumers can `deps:` or `from:` reference this target. Generation fails at CUE-evaluation time if a cross-project dep targets an internal target.

### `dockerfile.from`: chain or fresh image

Each emitted Dockerfile stage's FROM is the producer's choice. Bazel-style refs: `:target` (same project) or `project:target` (cross):

```cue
// Leaf: FROM an image. Use a base preset (sets stage + preamble too).
"setup": dockerfile: bayt.nubox

// Chain: FROM another target in the same project. Inherits the upstream
// stage's filesystem (toolchain installs in /root/.local/, .task/ stamps,
// project tree). Stack defaults already do this for build/test/integrate.
"build": dockerfile: from: ref: ":setup"

// Cross-project chain (rare; for shared toolchains across projects).
"build": dockerfile: from: ref: "other_project:base"
```

The chain form means the build stage *is* the setup stage extended — no `mise install` re-run inside build, and `task bayt:build`'s `::bayt:setup` dep correctly short-circuits on the inherited stamp.

## Stacks: toolchain knowledge, reusable

A *stack* captures what a language toolchain needs. Bayt ships four:

- **`stacks/gradle`** — kotlin/java/gradle concept fragments: `assemble`, `test`, `integrationTest`, `jibBuildTar`, `check`, `run`. Default srcs scoped to `src/main/` for `assemble` (so test edits don't invalidate build); `bayt.cache.full` on `assemble` and `integrationTest` (gradle's daemon cold-start is too costly to pay on every cache hit). Emits `.bayt/init.gradle.kts` per project pointing gradle's local build cache at `$BAYT_CACHE_DIR/gradle` — gradle's per-task cache and bayt's per-target cache share the same on-disk store and complement each other (per-task hits when only some inputs changed, per-target full skips when nothing changed).
- **`stacks/pnpm`** — pnpm/node/vite/vitest concept fragments: `install`, `build`, `test`, `dev`, `testInt`, `testE2E`, `lint`. Test srcs split between `srcsTest` (`*.test.ts(x)`) and `srcsIntegrate` (`*.spec.ts(x)`) matching the repo's vitest convention. pnpm store cache mount.
- **`stacks/mise`** — toolchain installer. `install` (provisions the project's `.mise.toml`), `exec` (sets `activate: "mise x --"` so cmds resolve through mise's shim layer), `doctor`. Used as a building block by other stacks.
- **`stacks/sayt`** — umbrella that maps the 10 sayt verbs (setup/build/test/launch/integrate/release/verify/generate/lint/doctor) onto stack fragments. `sayt.gradle`, `sayt.pnpm`, `sayt.pnpmWorkspace` are the standard mappings projects compose against.

Using the umbrella collapses a typical service to a handful of lines:

```cue
_tracker: sayt.gradle & {
    dir: "services/tracker"
    targets: {
        // Cross-project deps: producer must mark visibility "public".
        "build": deps: [
            ":setup", "workspaceroot:setup",
            "libraries_xproto:build",
            "plugins_jvm:build",
        ]
        "release": skaffold: image: "gcr.io/proj/tracker"
    }
}
```

A consumed library declares `visibility: "public"` on the verbs it exposes:

```cue
_xproto: sayt.gradle & {
    dir: "libraries/xproto"
    targets: "build": visibility: "public"   // tracker can deps: ["libraries_xproto:build"]
}
```

## Merkle-chain invalidation, in one diagram

```
Edit a source in libraries/xproto
        │
        ▼
xproto.build.hash changes              (own srcs fingerprint flips)
        │
        ▼                              (consumer fingerprints xproto's stamp)
services/tracker/build.hash changes
        │
        ▼
services/tracker/test.hash changes     (test fingerprints build's stamp)
```

Each task's stamp = `hash(platform-key + srcs + each direct-dep stamp file)`. Because go-task runs deps before evaluating the parent's `status:`, each dep's stamp on disk reflects its latest state by the time the parent reads it. Invalidation propagates one hop at a time through the real file system — no recursive walk, no dependency-graph library, just stamp files on disk acting as content-addressed identities for each subtree.

That's the same key recipe the remote cache (bazel-remote / ORAS) uses, so a L0 miss can become a L1/L2 fetch instead of a rebuild whenever someone else has already built the same content.

## Comparing to Bazel: an opinionated take

Bazel is a great system — a lot of bayt's design is explicitly borrowed from it (`srcs`, `deps`, `outs` as attribute names; Merkle hashing for correctness; content-addressable remote caching; composable rules/stacks). The comparison below is about fit, not quality.

**Where Bazel is more effective:**

- **In-process action sandboxing.** Bazel sandboxes every action so it can only see the inputs you declared. That gives reproducibility guarantees bayt's default mode doesn't match — your `./gradlew` invocation has access to `$HOME`, the network, and whatever else gradle decides to poke. Bayt has a different answer (docker-based, see below) but at the per-action level Bazel's sandbox is tighter.
- **Action-level granularity.** Bazel splits a compile into per-source actions that can be cached, replayed, and distributed individually. Bayt's unit is the task (one gradle invocation, one pnpm build). For a monorepo with thousands of Go packages where you want to rebuild three of them, Bazel's model wins — bayt re-runs the whole gradle subproject on any invalidation inside it. For teams whose bottleneck is cross-package incrementality, that's a real gap.
- **Mature rule ecosystem.** `rules_go`, `rules_nodejs`, `rules_cc`, `rules_python`, `rules_kotlin`, `rules_proto` — Bazel has battle-tested rules for virtually every language, often maintained by the language vendors. Bayt has two stacks (gradle, pnpm) and expects new stacks to be authored per monorepo.
- **Query and analysis.** `bazel query`, `bazel cquery`, `bazel aquery` are unmatched for introspecting the build graph. Bayt's graph lives in `.bayt/targets/*.json` — readable, but no query CLI yet.

**Where bayt has its own answer:**

- **Docker-based hermeticity.** Bayt's hermeticity story runs through Docker, not a per-action sandbox. A target with `bayt.incremental` runs inside a Dockerfile stage the emitter generates — the environment is defined by the base image + declared srcs + cache mounts, which is arguably *more* hermetic than Bazel's sandbox because you control the entire OS layer, not just the filesystem inputs. `launch` and `integrate` verbs extend this: your app runs in docker with testcontainers or compose-managed dependencies, so "hermetic run" is a first-class concept alongside "hermetic build." This is the path google3 takes for many services internally, and it's what Docker/BuildKit was designed for.

- **Remote execution via BuildKit.** For docker-centric flows, [depot.dev](https://depot.dev) and similar services already provide remote BuildKit execution — your Dockerfile builds run on managed infrastructure, outputs come back cached. For bayt targets that use `bayt.incremental`, this gives you Bazel's remote-execution value (run the action elsewhere, ship artifacts back) without standing up a Bazel RE cluster. Testcontainers, Kubernetes jobs, or Cloud Run can play the same role for short-lived execution of integration tests.

- **Two-layer cache, composed.** `cache.nu` provides per-target content-addressed cache (full skip on exact hit via `bayt.cache.full`; warm-start on miss via `bayt.cache.similar`). Stack-side, each language stack configures its own native build cache at the same `$BAYT_CACHE_DIR` directory — gradle's per-task cache via init.gradle.kts, planned go GOCACHE, cargo sccache, etc. The two layers compose: bayt skips the whole cmd when nothing changed; the tool skips most of its own work when only some inputs changed. Same Merkle hash key as the local L0 stamp. Backends for the bayt layer: local-FS (default, XDG-compliant), `BAYT_CACHE_URL` for buchgr/bazel-remote (which itself can chain to S3/GCS/Azure or proxy to depot.dev / BuildBuddy), `BAYT_CACHE_REGISTRY` for ORAS OCI. Stable BuildKit cache mount (`id=bayt-cache`) means hits work inside Dockerfile RUNs across stage rebuilds.

- **Onboarding cost.** A team can adopt bayt on a single service in an afternoon. The common mode is "add a `bayt.cue` next to an existing `build.gradle.kts`, run the generator, check the Taskfile in." A Bazel migration is typically measured in quarters — most are successful, but the up-front commitment is real, and partial migrations are painful because coexistence with native tools isn't Bazel's strength. Bayt is designed for incremental adoption; one target at a time is a normal path.

- **Integration with existing tools.** Your IDE already understands `./gradlew`, your CI already runs `docker compose`, your ops team already deploys via skaffold. Bayt emits files those tools natively consume. No Bazel build wrapper, no `ibazel`, no "why doesn't VSCode see my imports." For teams whose day-to-day already runs on those tools, bayt is essentially transparent.

- **Tools keep their internal caching.** gradle's incremental compile still works *inside* bayt's task boundary. pnpm's store cache still works. You benefit from both the tool's internal caching AND bayt's task-level cache. Bazel replaces the tool's own caching with Bazel's, which is great when the replacement is solid and painful when there's a mismatch (gradle's worker daemon behavior, for instance, is notoriously hard to preserve under Bazel).

- **CUE vs. Starlark.** CUE's unification catches a lot at evaluation time. CUE stacks compose by structural unification; Starlark rules compose by function call. Both are valid; CUE's flavor is the one bayt chose.

- **Heterogeneous stacks.** A monorepo with one gradle service, two pnpm apps, and a Go tool is bayt's happy path — three stack definitions, each scoped to its language. Bazel can handle this but the ruleset upkeep and cross-rule interop effort is non-trivial.

- **Operations cost.** Bayt's remote cache is a single `bazel-remote` container or an OCI registry. Bazel's remote *execution* needs a worker pool, a scheduler, a disk farm, a rollout story — great when a company has a build infrastructure squad to own it. For teams that don't, bayt + depot.dev (or similar) reaches a similar outcome without the operational surface.

**Where the comparison lands:**

Bayt is in many ways a Bazel subset implemented under different constraints. It keeps Bazel's correctness guarantees (Merkle-tree invalidation, content-addressable cache keys) and borrows Bazel's core vocabulary (srcs/deps/outs). It trades Bazel's per-action sandboxing and rule ecosystem for easier interop with native tools and a dramatically lower onboarding cost. For monorepos with mixed stacks, moderate size, and a team that would rather extend their existing tooling than migrate to a new build system, bayt is the better fit. For monorepos with thousands of same-language packages, heavy cross-package incrementality needs, or companies with a dedicated build-infra team already invested in Bazel, Bazel remains the right answer.

Worth noting: the two aren't mutually exclusive. `.bayt/targets/<n>.json` is a machine-readable description of every target's action; a team that grows into needing Bazel can feed that into a rule-gen layer rather than starting from scratch. Bayt is useful scaffolding whether you stop there or eventually move beyond.

## Emitted files

All bayt-generated files use the `<tool>.<verb>.<ext>` convention under
`.bayt/`. The user-authored tool roots (`Taskfile.yml`, `compose.yaml`,
`skaffold.yaml`) sit alongside as single root files that include
their per-target sibling.

| Path                        | Purpose                                                          |
|-----------------------------|------------------------------------------------------------------|
| `.bayt/bayt.<n>.json`       | canonical per-target manifest (srcs, outs, deps, cmds, …)        |
| `Taskfile.yml`              | root go-task (version + includes)                                |
| `.bayt/Taskfile.<n>.yaml`   | per-target go-task include                                       |
| `.bayt/Dockerfile.<n>`      | per-target Dockerfile body                                       |
| `compose.yaml`              | root compose (include of bayt-generated services)                |
| `.bayt/compose.<n>.yaml`    | per-target compose service                                       |
| `skaffold.yaml`             | root skaffold (`requires:` of bayt-generated configs)            |
| `.bayt/skaffold.<n>.yaml`   | per-target skaffold config                                       |
| `.bayt/bake.<n>.hcl`        | per-target bake HCL                                              |
| `.bayt/vscode.<n>.json`     | per-target vscode task entries (build/test only). User merges into `.vscode/tasks.json`; `sayt lint` warns on drift. vscode's tasks.json has no native include, so bayt doesn't overwrite it directly. |

The `.bayt/` directory is generated but committed. A single `sayt generate` (or `nu plugins/bayt/runtime/generate-bayt.nu`) rebuilds the whole tree atomically.

## Design principles

1. **One declaration, every format.** Cross-cutting concerns live once on `#target`; each emitter projects into its own output format.
2. **Canonical manifest as the source of truth.** `#manifestGen` produces format-neutral JSON; every other emitter consumes it. So do downstream tools like `fingerprint.nu` and `cache.nu`.
3. **Pure CUE for schemas; impure nushell for I/O.** `generate-bayt.nu` is the only layer that touches the filesystem. `fingerprint.nu` hashes files. `cache.nu` talks to HTTP caches. CUE stays deterministic and sandboxable.
4. **No path math in CUE.** Repo-relative `../` computation lives in nushell, which has a proper path library. CUE carries structured data (`{name, projectDir}`), nushell joins it.
5. **Fragments via unification, not inheritance.** Verbs (`setup`, `build`, …) and base presets (`nubox`, `busybox`, …) are plain structs, not closed `#`-prefixed definitions — CUE's closed conjunction rejects cross-def fields. See the closedness note in `bayt/bayt.cue`.
6. **Version intent vs. version lock.** Base image tags go in `bayt.cue`; digests live in `bases.lock.cue`. `pin-bases.nu` refreshes the lock.
7. **Never swallow errors.** fingerprint.nu and cache.nu fail fast on missing inputs, malformed manifests, git-hash-object errors. A misconfigured target surfaces immediately instead of poisoning the cache with silent defaults.

## Claude Code plugin

Bayt ships as a [Claude Code plugin](https://docs.anthropic.com/en/docs/claude-code/plugins) with skills that teach Claude how to write and edit `bayt.cue`, add new stacks, and debug the generated output.

| Skill | What Claude learns |
|-------|--------------------|
| **bayt-target** | How to write a `bayt.cue` — the seven `#target` fields, cmd rulemap, dep references, skaffold/bake blocks. Auto-invoked when editing `bayt.cue`. |
| **bayt-stack** | How to author a new language stack — workspace prefix, verb defaults, cache mounts, what belongs in the stack vs. the consumer. |
| **bayt-debug** | How to diagnose fingerprint mismatches, missing-src errors, cross-project stamp resolution. |

The **bayt-dev-loop** agent can drive the generate → build → verify cycle for a new service end-to-end.

## Layout

```
plugins/bayt/
├── README.md              ← this file
├── DESIGN.md              ← full design doc (rationale, cross-cutting concerns)
├── bayt/                  ← CUE package `bayt`: schema + emitters
│   ├── bayt.cue             (#target, #project, #cmd, #dockerfile, #compose,
│   │                         #skaffold, #bake, #vscode, #taskfile, #mount)
│   ├── capabilities.cue     (bayt.incremental, bayt.hostenv, …)
│   ├── images.cue           (nubox / busybox / staging / wolfi / dind /
│   │                         dockerCli presets — set dockerfile.from)
│   ├── images.lock.cue      (digest pin per image — package.json-style)
│   ├── emitter.cue          (#render — composes the per-format generators)
│   ├── gen_bayt.cue         (manifest emitter — the canonical .bayt/bayt.<n>.json)
│   ├── gen_taskfile.cue     (Taskfile + per-target Taskfile.<n>.yaml)
│   ├── gen_compose.cue      (Dockerfile.<n> + compose.<n>.yaml)
│   ├── gen_skaffold.cue
│   ├── gen_vscode.cue
│   ├── gen_bake.cue
│   ├── mapaslist.cue        (#MapAsList helper for compose-friendly defaults)
│   ├── listutils.cue
│   └── *_check.cue          (vet-as-test stress patterns)
├── stacks/                ← language preset libraries
│   ├── gradle/gradle.cue   (gradle concept fragments: assemble, test,
│   │                        integrationTest, jibBuildTar, check, run)
│   ├── pnpm/pnpm.cue       (pnpm concept fragments + pnpmWorkspace)
│   ├── mise/mise.cue       (install / exec / doctor — used by other stacks)
│   └── sayt/sayt.cue       (umbrella — maps 10 sayt verbs onto stack
│                            fragments; sayt.gradle, sayt.pnpm, …)
├── runtime/               ← impure nushell bits invoked by generated files
│   ├── generate-bayt.nu     (reads `render` output, writes files atomically;
│   │                         runs cache.nu gc at end of generation)
│   ├── fingerprint.nu       (content hash + Merkle chain, git-aware,
│   │                         platform-key includes arch + libc flavor)
│   ├── cache.nu             (3-backend cache wrap: local-FS / bazel-remote /
│   │                         ORAS; `cache.nu run` is the per-cmd wrap;
│   │                         `cache.nu gc` evicts oldest mtimes to budget)
│   └── cache_test.nu        (12-test suite: miss / hit / hit+full /
│                             disabled / failed-cmd / gc-evicts /
│                             gc-noop / manifest-bypass / warm-with-
│                             similar / no-similar-no-warm / debug-log /
│                             similarity-picks-closest)
└── tests/
    ├── test-bayt.nu         (positive + negative suite runner)
    └── _negative/           (intentional-cycle test; separate CUE package)
```

## Run the tests

bayt's own dev workflow is wired through standard sayt verbs (so the
sayt:sayt-dev-loop TDD skill can drive it):

```bash
cd plugins/bayt
just sayt build      # full CUE positive + negative suite
just sayt test       # bayt suite + cache.nu nu test suite
just sayt integrate  # same as test today (docker variant deferred)
```

Direct invocation also works (skip the sayt wrapper):

```bash
nu tests/test-bayt.nu          # 4 CUE suites: core schema + sayt
                               # mappings + stacks consumers + negative
                               # cycle (intentional A→B→A must fail
                               # `cue eval`). Strict `cue eval`, not
                               # lenient `cue vet`.

nu runtime/cache_test.nu       # 12 nu tests: miss / hit / hit-with-full
                               # / disabled / failed-cmd / gc-evicts /
                               # gc-noop / manifest-bypass / warm with
                               # --similar / no warm without --similar
                               # / debug-log records decisions /
                               # similarity picks closest candidate.
```

## Contributing

- Bayt is written in CUE + nushell. Every piece of file I/O lives in `runtime/*.nu`; everything else is pure CUE.
- Prefer to add new capabilities as plain structs unifiable into `#target`, not as closed `#`-prefixed definitions.
- Run the test suite before opening a PR — `nu tests/test-bayt.nu` covers both positive and negative paths.
- Keep the core schema small. Stacks are where toolchain-specific knowledge lives.
- No path math in CUE. Use nushell's `path` primitives from `fingerprint.nu` or equivalent.
- Never swallow errors — `try/catch` with a fallback is a smell. Let misconfigurations fail fast.

## License

MIT. See the sayt repo for the license file.
