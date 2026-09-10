# The bayt target, specified

What a `bayt.cue` may contain and what each field means. Normative: the
D-guards in `core/*_check.cue` fail a target that violates the shape, so a
statement here is a claim `bayt_test` can refute.

`README.md` is the pitch, `CONTRIBUTING.md` is the working guide, and `docs/`
argues the decisions behind the shape rather than stating it.

## Core schema: `#target`

One type describes a build unit. Portable action fields up top; optional output-file-named blocks below. Presence of a block = emit that format.

```cue
#target: close({
    // --- Identity (bound by the enclosing #project.targets map key) ---
    name:    string
    project: string  // injected by #project during unification

    // --- Portable action (format-agnostic) ---
    srcs:        [...string]       // input file globs, relative to project.dir
    exclude:     [...string]       // glob exclusions applied to srcs
    extraInputs: [...string]       // files that affect the cache key but aren't srcs
                                   // (e.g. ".mise.lock", "../../bases.lock.cue")
    outs:        [...string]       // output file globs produced by cmd

    // Toolchain activator. Project-level default; per-target override rare.
    activate: *project.activate | string

    // Commands: rulemap keyed by name, priority-sorted, nullable to delete.
    // "builtin" is the canonical default rule (matches sayt's _builtinDo).
    cmd: [Name=string]: #cmd & {name: Name} | null
    env: [string]: string

    // --- Dependencies (format-agnostic; each generator translates) ---
    deps: [...#target | string]   // CUE refs preferred; string names allowed

    // --- Output-file-named blocks (all optional; presence = support) ---
    // Named after the files they emit, not the "platforms" they target.
    dockerfile?: #dockerfileBlock   // -> .bayt/<name>.Dockerfile
    compose?:    #composeBlock      // -> .bayt/compose.<name>.yaml
    taskfile?:   #taskfileBlock     // -> .bayt/Taskfile.<name>.yaml
    skaffold?:   #skaffoldBlock     // -> .bayt/skaffold.<name>.yaml
    vscode?:     #vscodeBlock       // -> contribution to .vscode/tasks.json
    bake?:       #bakeBlock         // -> contribution to docker-bake.hcl
    // process-compose, gha-matrix, etc. added under the same pattern.
})
```

`#project` carries the shared knobs and the map of targets:

```cue
#project: close({
    name: string            // defaults to last segment of dir; lint verifies
    dir:  string            // relative to monorepo root; copybara-friendly
    activate: *"mise x --" | string

    // Shared defaults unified into every target.
    defaults?: #target

    // Targets. Map key becomes target.name; project ref is injected.
    targets: [Name=string]: #target & {
        name:    Name
        project: name
        // Merge in defaults. Per-target fields still win via unification.
        if defaults != _|_ { defaults }
    }
})
```

Key invariants:

- **Name comes from the map key.** Same rulemap trick used in `plugins/sayt/config.cue:#MapAsList`. Prevents name drift and lets refs be CUE field accesses (`project.targets.build`), not strings.
- **Deps by reference, not by name.** `deps: [project.targets.setup]` is the canonical form. String names still work (useful in loosely-coupled cases), resolved at emit time.
- **No `#action` / `#envelope` / `#recipe` split.** One `#target`. Output-file blocks are the only differentiation. Far-away unification composes everything.
- **Hashes are per-output, not per-target.** Runtime computes hash from (target JSON, output name) so that a dockerfile-only change doesn't invalidate the Taskfile cache and vice versa.

## `#cmd`: rulemap + two decoration axes

`cmd` on a target is an ordered map of named rules, each running in priority order. Comes from `plugins/sayt/config.cue`'s `#MapAsList` / `#MapToList` / `#verb` pattern. Gives three levels of override and two orthogonal decoration axes — OS and output-format — without exploding into combinatorial schemas.

```cue
#cmd: close({
    name:     string
    priority: *0 | int         // lower runs first; stable by name on ties
    shell:    *"nu" | "bash" | "sh" | "pwsh"
    do:       string           // the command body (in `shell`'s language)
    stop:     *false | bool    // if true, later rules in the map are skipped

    // --- Axis 1: OS escape hatch ------------------------------------------
    // Picked by the runtime based on host OS. Each fully overrides `do`/`shell`.
    windows?: close({ do?: string, shell?: "pwsh" | "cmd" | "nu" })
    linux?:   close({ do?: string, shell?: string })
    darwin?:  close({ do?: string, shell?: string })

    // --- Axis 2: Output-format decoration ---------------------------------
    // Applies only when emitting that specific file. Far-away unification
    // lets the dockerfile block decorate a cmd without the cmd knowing.
    dockerfile?: close({
        inject?: {                      // structured wrap: secrets + setup/teardown
            secrets: [...{id: string, target?: string, mode?: string, var?: {contents?: string, path?: string}}]
            defaultSteps: *null | #MapAsList // keyed map of {pre, post?, priority?}
            steps:        *[] | [...{pre: string, post?: string}]
        }
        mounts?:  [...#mount]           // --mount=type=cache|secret|bind|ssh
        secrets?: [...string]           // secret ids required by this rule
        network?: *"default" | "none" | "host"
    })
    taskfile?: close({
        interactive?: bool              // go-task: interactive: true
        silent?:      bool
    })
    vscode?: close({
        problemMatcher?: [...string]
        presentation?:   { reveal?: string, panel?: string, ... }
        windows?:        { command?: string, args?: [...string] }  // per-task OS override
    })
    bake?: close({
        cacheFrom?: [...string]
        cacheTo?:   [...string]
    })
})

#mount: close({
    type:      "cache" | "secret" | "bind" | "ssh" | "tmpfs"
    target?:   string
    source?:   string
    id?:       string
    sharing?:  *"locked" | "shared" | "private"
    required?: bool
})
```

### The three override levels (mirrors `#verb` in `config.cue`)

```cue
// Level 1: shorthand. Replaces the default "builtin" rule.
targets: build: cmd: "builtin": do: "./gradlew assemble"

// Level 2: rulemap. Add named rules, sort by priority, nullable to delete.
targets: build: cmd: {
    "pregen":  { priority: -10, do: "./scripts/gen-code.nu" }
    "builtin": { do: "./gradlew assemble" }
    "verify":  { priority:  10, do: "./scripts/check-outputs.nu" }
}

// Level 3: far-away decoration via unification.
// The dockerfile block adds a cache mount to just the "builtin" rule.
targets: build: {
    dockerfile: {}  // presence marker
    cmd: "builtin": dockerfile: mounts: [
        {type: "cache", target: "/root/.gradle", sharing: "locked"},
    ]
}
```

### OS escape hatch on `cmd`, not on the output block

Windows vs Linux differences are a property of the command, not the output file. A Windows developer running `just build` from vscode hits the same OS axis as the Windows shell runner. One knob, applied wherever the command is invoked.

```cue
cmd: "builtin": {
    do:      "./gradlew assemble"
    windows: { do: ".\\gradlew.bat assemble", shell: "pwsh" }
}
```

Each generator picks the right variant:

- Taskfile — emits all three variants under `cmds:` with `platforms:` guards (go-task native).
- vscode — emits the top-level `command` plus `windows: { command: ... }` override (matches `services/api/.vscode/tasks.json` pattern).
- Dockerfile — build is always Linux in a container; Windows branch is dropped.
- compose / skaffold / bake — Linux only; Windows branch dropped.

## Output blocks

Each block carries only what can't be derived from the portable action. Keep them narrow, skinny, and unification-friendly.

### `#dockerfileBlock`

```cue
#dockerfileBlock: close({
    // Base image: version intent lives here, version lock in bases.lock.cue.
    base:     string              // e.g. "chainguard/wolfi-base:latest"
    baseLock: =~"@sha256:[a-f0-9]{64}" | *null  // refreshed by pin-bases.nu

    workdir: *"/monorepo/\(project.dir)" | string
    mounts:  [...#mount]          // stage-level mounts (union'd with per-cmd)
    secrets: [...string]          // secret ids (surfaced for docker-compose too)
    expose:  [...int]             // published ports (runtime block consumers)

    // Stage type. Derived when possible; overridable.
    stage: *"build" | "runtime" | "scratch"

    // Extra stanzas before/after COPY+RUN. Escape hatch; use sparingly.
    preamble: [...string]
    epilogue: [...string]
})
```

Generation rules:

1. Each target emits its own `.bayt/<name>.Dockerfile` file.
2. Source files → `COPY --link <src> ./<src>` (one line per src, maximum layer independence).
3. Dep targets → `COPY --from=<dep-stage> --link /out /monorepo/<dep.dir>/out`. Deps are built as earlier stages in the same Dockerfile, or pulled from a prior target's file via `FROM <name> AS <dep-stage>` (BuildKit resolves). `--link` ensures cache independence.
4. `cmd.*` rules emit as `RUN --mount=... <shell> -c 'do'`, priority-sorted. Mounts come from `cmd.<name>.dockerfile.mounts` unioned with `dockerfile.mounts`.
5. `extraInputs` → separate `COPY --link` lines so they invalidate only themselves.

### `#composeBlock`

```cue
#composeBlock: close({
    // Service name in compose.yaml (defaults to target name).
    service: *name | string

    // Compose envelope.
    build?: close({
        target:              *name | string
        dockerfile:          *".bayt/\(name).Dockerfile" | string
        // Cross-target refs emitted as additional_contexts.
        additional_contexts: [dep=string]: "service:\(dep)" | string
        secrets:             [...string]
        args:                [string]: string
    })
    runtime?: close({
        image?:       string    // for pull-only services (bazel-remote, etc.)
        command?:     [...string]
        environment: [string]: string
        ports:       [...string]  // "host:container"
        volumes:     [...string]
        depends_on:  [...string]
        healthcheck?: {...}
    })
    develop?: close({
        watch: [...#watch]     // HMR: sync vs rebuild per path
    })
})

#watch: close({
    action: "sync" | "sync+restart" | "rebuild"
    path:   string
    target: string
    ignore: [...string]
})
```

Generation rules:

- One `.bayt/compose.<name>.yaml` per target. Root `compose.yaml` lists each via `additional_contexts` OR uses `include:` (compose v2.20+).
- Deps projected as `depends_on` (runtime) and `additional_contexts: {dep: "service:<n>"}` (build). Container can COPY --from the dep service's image without rebuilding it.
- `develop.watch` drives HMR. `sync` for source hot-reload, `rebuild` for dependency changes (touching `package.json`, `go.mod`, `.mise.toml`).

### `#taskfileBlock`

```cue
#taskfileBlock: close({
    task:    *name | string          // task label in Taskfile (colon-delimited ok)
    run:     *"when_changed" | "once" | "always"
    silent:  *false | bool
    desc?:   string

    // Extra srcs/outs beyond target.srcs/outs (tool configs, etc.).
    extraSources:   [...string]
    extraGenerates: [...string]

    // Preconditions (go-task: preconditions).
    preconditions: [...{ sh: string, msg?: string }]
})
```

Generation rules:

- One `.bayt/Taskfile.<name>.yaml` per target. Root `Taskfile.yml` has `includes: { <name>: ./.bayt/Taskfile.<name>.yaml }`.
- `sources:` = `project.dir + srcs`, exclusions translated to `!glob` entries.
- `generates:` = `project.dir + outs`. Enables go-task's fingerprint-based skip.
- `status:` = `nu cache.nu hash-check <target>` (L0 stamp check, shell-invariant). Works even when `sources:` can't enumerate everything.
- `cmds:` = priority-sorted `cmd.*` rules, each prefixed by `activate` and wrapped with `cache.nu run` when `cache` is enabled.
- `deps:` = dep targets' Taskfile labels.

### `#skaffoldBlock`

```cue
#skaffoldBlock: close({
    image:    string             // e.g. "gcr.io/example-proj/services.api"
    platform: *"linux/amd64" | string
    context:  *"../../" | string // monorepo root relative to project.dir
    sync?:    close({
        manual: [...{ src: string, dest: string }]
        auto:   *false | bool
    })
    manifests: [...string]       // k8s manifests to deploy after build
    requires:  [...string]       // cross-project skaffold refs
})
```

Generation rules:

- One `.bayt/skaffold.<name>.yaml` per target with `dockerfile` = `.bayt/<name>.Dockerfile`.
- `requires:` lists other `.bayt/skaffold.<dep>.yaml` files for cross-project composition (skaffold native).
- `sync.manual` drives k8s HMR; paths match `compose.develop.watch` entries where both exist.

### `#vscodeBlock` and `#bakeBlock`

```cue
#vscodeBlock: close({
    label:    *"\(project.name) \(name)" | string
    group?:   close({ kind: "build" | "test" | "none", isDefault?: bool })
    detail?:  string
    dependsOn: [...string]       // label refs to other targets' vscode entries
    dependsOrder: *"sequence" | "parallel"
    // Windows override lives per-cmd on #cmd.vscode.windows; this block
    // only carries label/group metadata and task-level dependsOn.
})

#bakeBlock: close({
    target:    *name | string
    platforms: *["linux/amd64", "linux/arm64"] | [...string]
    tags:      [...string]
    args:      [string]: string
    cacheFrom: [...string]
    cacheTo:   [...string]
})
```

vscode contributions merge into a single `.vscode/tasks.json` (tasks.json has no native include mechanism; lint enforces drift). Bake contributions merge into a single `docker-bake.hcl` at project root.

## Deps as a single concept

Deps are declared once on `#target` as CUE references (or names), format-agnostic. Each generator translates them into its native idiom. No per-output `deps`; no "platform-specific" graph.

```cue
targets: "integrate": {
    deps: [targets.build, targets.setup]   // CUE refs; type-checked
    // OR, for loose coupling:
    // deps: ["build", "setup"]
}
```

Per-format translation:

| Format | Translation | Layer independence |
|---|---|---|
| **Dockerfile** | `COPY --from=<dep-name> --link /out /monorepo/<dep.dir>/out` for each dep output. | `--link` keeps dep layers parallel so dep changes don't invalidate unrelated target layers. |
| **compose** | `additional_contexts: { <dep-name>: "service:<dep-name>" }` (build-time) + `depends_on: [<dep-name>]` (runtime, if dep has a `runtime` block). | Compose builds deps first, then wires the context in. |
| **Taskfile** | `deps: [<dep-qualified-label>]` — go-task runs deps in parallel. | Native. |
| **skaffold** | `requires: [{ path: ./.bayt/skaffold.<dep>.yaml }]` for cross-target, `artifact.requires` for within-target. | Skaffold native. |
| **vscode** | `dependsOn: [<dep-label>]`, `dependsOrder: sequence`. | vscode runs in order. |
| **bake** | `contexts: { <dep-name>: "target:<dep-name>" }` — bake-native cross-target wiring. | Bake native. |

### Runtime bring-up: `bake.image` / `compose.up` / `compose.manual`

A target's build/runtime role is set by flags on the config they govern:

- **`bake.image`** — a release image: its presence emits the `bake.hcl` build
  recipe (push vs load is the `$PUSH_IMAGE` env var, not a static flag).
- **`compose.up`** — a load-by-name closure point (launch, integrate).
- **`compose.manual`** — a harness kept off the bare-`up` stack, emitted at
  `scale: 0` and reached by targeting its root alias (`docker compose up <n>`).

`docker compose up` starts every non-`manual` service with a compose block (the
app + its always-on infra); everything else — build/setup stages and `manual`
harnesses — sits at `scale: 0`, present so `service:` build contexts resolve but
running no container. Keeping harnesses at `scale: 0` (rather than behind a
profile) is what lets `depends_on`/context edges onto them resolve with no
`--profile`; the measurements behind it are in CONTRIBUTING.md.

The `:outs` interface is opt-in per dep edge (`deps: [":foo:outs"]`), not
inferred from a target's role. A target in this group ships an image rather
than workdir files, so its interface is empty — and an empty `:outs` is still
a ref: it federates the producer's fragments into the consumer's closure and
orders the two, copying nothing. That is how a consumer says "I need this
service in my closure, not its files"; a plain `deps:` on the same producer
bulk-COPYs a runtime image instead.

Which of those images a CI build phase must actually push is a third question,
answered by `.bayt/depot.hcl`: a bake `group` naming `integrate` plus its
transitive `compose.depends_on`, derived in CUE from the model. bake builds a
`target:`-context dep but drops its output, so anything a later phase pulls has
to be named. It is a `group` and nothing else, in its own file, because
`bake.hcl` binds `tags = [IMAGE]` onto every release-matrix member by name and
bake HCL cannot express "leave unset" — an empty list overrides and `null` is
rejected — so a caller wanting only the selection would otherwise lose those
targets' tags and outputs.

Its partner `.bayt/depot.yaml` is that graph pre-flattened at generate time,
keeping the compose walk out of CI. It is compose, not a stored bake definition,
because tag/cache/output are late-bound and `buildx bake --print` resolves
variables as it prints — a stored bake file would carry `:latest`, an unscoped
cache namespace and a local load. Compose keeps `${…}` literal until CI bakes.

### Bazel-style refs

Deps use the same string-ref vocabulary across same- and cross-project:

```cue
"build": {
    deps: [
        ":setup",                      // same-project
        "libraries_proto:build",      // cross-project
        "libraries_proto:build:srcs", // cross-project synthetic view
    ]
}
```

Leading `:` = same-project. Bare `<project>:<target>` = cross-project. Three-segment refs (`<project>:<target>:<view>`) address synthetic views (next section). The emitted manifest carries `chainedDeps: [{name, project, dir, outs}]` resolved at CUE-emit time; nushell's `dep-to-dir` handles the runtime path math. Cross-project resolution happens via two CUE passes: pass 1 extracts the refs, nushell loads each referenced project's manifest, pass 2 federates the loaded manifests as `depManifestsIn`. No CUE imports between projects — keeps the dependency graph copybara-safe.

### Synthetic views: `:srcs`, `:outs`, `:foo:bayt`

Every target with a dockerfile auto-emits three sibling synthetics that consumers can address with the `:view` suffix:

| Synthetic | Content | Use case |
|---|---|---|
| `:foo:srcs` | A scratch image holding the target's `srcs.globs` (the input source closure). | Source-closure deps for dindbox cascades — the outer ci stage stays COPY-only while the inner bake reconstructs the dep's build chain. |
| `:foo:outs` | A scratch image holding the target's `outs.globs` (the output artifact view). Declared for every dockerfile target; empty `outs` emits no image. | Cross-project consumers that need only artifacts, not sources — empty, an image-only producer (above). |
| `:foo:bayt` | A scratch image holding the target's scaffolding fileset (fragment, Dockerfile, taskfile, manifest, go-task roots, up closure) plus its deps' chained scaffolding. | Containerized task-runner and compose invocation inside dindbox layers, scoped to the up target's closure. |

The generator emits each as its own compose service + Dockerfile fragment. From the consumer side they're addressed identically to regular targets — bayt's machinery picks the right COPY shape.

### Transitive walking

Transitivity is implicit at the dep-graph level. Three pipelines feed it:

1. **Same-project chain.** A consumer `:a` whose target chains via `from: ref: ":b"` (or `deps: [":b"]`) inherits `:b`'s same-project transitive deps. The COPY emission walks `_transitiveDeps[a]` (resolved name list) and emits one COPY per transitive entry, sourcing each from its `outs.globs`.
2. **Cross-project federation.** A cross-project dep `proj:b` brings its own `transitiveCrossDeps` via the dep's emitted manifest (loaded as `G.depManifests[proj:b].transitiveCrossDeps`). The consumer doesn't need to enumerate `proj:b`'s upstreams — they ride in via the manifest.
3. **Synthetic `:srcs` federation.** A `:srcs` synthetic mirrors its parent's chain with each ref flipped to its `:srcs` sibling. Cross-project deps map `proj:b` → `proj:b:srcs`; same-project transitive deps in the dep's project surface in the manifest's `transitiveCrossDeps` (expressed as cross-project entries from the downstream's perspective) so a consumer of `:integrate:srcs` automatically pulls each upstream's `:setup:srcs` for toolchain config files (.mise.toml, mise.lock, wrapper.properties).

Visibility (`public` vs `internal`) is checked at the direct consumer-to-dep boundary via `_buildCrossEntry`'s `_visibility & "public"` unification. Once that boundary is crossed, transitive deps flow regardless of their own visibility — internal upstreams ride along the public surface.

## Version intent vs version lock

Package-manager-style split. Intent (semver-ish ranges, tag names) in the hand-written CUE; lock (immutable digests) in a generated file; refresh command impure.

```cue
// bayt.cue — version intent (hand-written, committed)
dockerfile: base: "chainguard/wolfi-base:latest"

// bases.lock.cue — version lock (generated, committed, refreshed by pin-bases.nu)
// Keyed by the intent string, so the lookup is order-independent.
bases: {
    "chainguard/wolfi-base:latest": "@sha256:9925d3017788558fa8f27e8bb160b791e56202b60c91fbcc5c867de3175986c8"
    "busybox:musl":                "@sha256:03db190ed4c1ceb1c55d179a0940e2d71d42130636a780272629735893292223"
    "docker:29.2.0-cli":           "@sha256:ae2609c051339b48c157d97edc4f1171026251607b29a2b0f25f990898586334"
    "opensuse/leap:15.6":          "@sha256:b084d6e29d975..."
    "bonisoft3/lazybox:v0.3.0":    "@sha256:..."
}
```

At emit time, the dockerfile generator looks up `bases[base]` and emits `FROM <base>@<digest>`:

```dockerfile
FROM chainguard/wolfi-base:latest@sha256:9925d30... AS test
```

`plugins/sayt/pin-bases.nu`:

- Reads all `#dockerfileBlock.base` values across the repo (impure: globs, reads CUE outputs).
- For each, runs `skopeo inspect docker://<base>` (or `docker manifest inspect`) to fetch the current digest.
- Rewrites `bases.lock.cue` atomically.
- Commits. Reviewed like a lockfile bump.

Runs on a schedule (cron, renovate-style) or manually before a release. Never from a regular build path.

Benefits:

- **Reproducibility.** Every rebuild from the same SHA gets the same base bytes.
- **Auditable bumps.** Lock-file diff shows exactly which digests moved.
- **No drift.** `latest` in `bayt.cue` is intent, not resolution — nothing ever pulls `:latest` in CI.
- **CUE-resolvable.** Because lock is CUE (not JSON), a base can participate in unification: e.g., a security policy `#policy: bases: [base=string]: =~"@sha256:"` enforces that every base has a digest.

## Base image presets

Three base presets cover 95% of cases. All ship in `plugins/sayt/bases.cue` as `#dockerfileBlock` fragments. Each target unifies one in.

```cue
// #nubox — build stage. Leap-based, non-rolling, pinned. Ships mise, nushell, lazybox.
#nubox: #dockerfileBlock & {
    base:    "opensuse/leap:15.6"
    stage:   "build"
    workdir: *"/monorepo/\(project.dir)" | string
    preamble: [
        "COPY --from=bonisoft3/lazybox /lazybox /usr/local",
        "RUN zypper -n install curl ca-certificates && curl -fsSL https://mise.run | sh",
        "ENV PATH=/root/.local/bin:$PATH",
        "ENV MISE_TRUSTED_CONFIG_PATHS=/monorepo",
    ]
}

// #busybox — minimal runner. musl, scratch-adjacent. For release stages.
#busybox: #dockerfileBlock & {
    base:   "busybox:musl"
    stage:  "runtime"
    // No mise, no lazybox; just the artifact.
}

```

Usage:

```cue
targets: {
    "build":    { dockerfile: bases.#nubox }
    "test":     { dockerfile: bases.#nubox }
    "release":  { dockerfile: bases.#busybox }
}
```

### Lazybox is a portable nushell substrate, not a toolchain

`bonisoft3/lazybox` is **not** a fat environment bundle. Its primary purpose is nushell in a single relocatable tarball; other utilities are secondary conveniences. Because lazybox is fully relocatable, the same `nu cache.nu hash-check` command runs:

- In the `#nubox` build stage (copied from `/usr/local`)
- In the `#staging` runtime stage (overlay)
- On a developer's Linux laptop (extracted to `~/.cache/lazybox`)
- On native Windows (extracted to `%LOCALAPPDATA%\lazybox`)
- In CI, air-gapped (pre-downloaded tarball)

The activator `mise x -- nu <script>` resolves the right nushell in every environment. Tool versions are pinned via `mise.lock` so the same commit reproduces bit-for-bit years later.

### Why leap, not wolfi, for `#nubox`

Wolfi is rolling. Leap has a 12-18 month lifecycle per release, making "latest" a meaningful intent when paired with the lock file. Build reproducibility benefits from a base where `@sha256:...` moves rarely enough that a human notices via the lock diff. Wolfi is still fine for `test` / `ci` stages where we tolerate digest churn.

## File layout and include mechanisms

Bayt emits per-target files into a hidden `.bayt/` directory. User-visible files (`Taskfile.yml`, `compose.yaml`, `skaffold.yaml`) use each format's native include mechanism to pull them in. `.bayt/` is committed but not hand-edited; `lint` enforces this.

```
services/api/
├── bayt.cue                         # hand-written, the only source of truth
├── bases.lock.cue                   # generated by pin-bases.nu
├── .bayt/                           # generated, committed, never edited
│   ├── targets/
│   │   ├── build.json               # portable action manifest (input to cache.nu)
│   │   ├── test.json
│   │   ├── integrate.json
│   │   └── release.json
│   ├── stamps/                      # git-ignored; L0 hash stamps
│   │   └── build.stamp
│   ├── Taskfile.build.yaml          # included by ../Taskfile.yml
│   ├── Taskfile.test.yaml
│   ├── Taskfile.integrate.yaml
│   ├── Taskfile.release.yaml
│   ├── compose.launch.yaml          # included by ../compose.yaml
│   ├── compose.integrate.yaml
│   ├── compose.release.yaml
│   ├── build.Dockerfile             # one Dockerfile per target with dockerfile block
│   ├── test.Dockerfile
│   ├── integrate.Dockerfile
│   ├── release.Dockerfile
│   └── skaffold.release.yaml        # required by ../skaffold.yaml
├── Taskfile.yml                     # hand-written; just includes .bayt/Taskfile.*.yaml
├── compose.yaml                     # hand-written; just includes .bayt/compose.*.yaml
├── skaffold.yaml                    # hand-written; just `requires:` .bayt/skaffold.*.yaml
├── .vscode/tasks.json               # merged contribution; lint-enforced
└── ...
```

Include mechanisms per format:

```yaml
# Taskfile.yml (hand-written, one-line stub per target)
version: '3'
includes:
  build:     ./.bayt/Taskfile.build.yaml
  test:      ./.bayt/Taskfile.test.yaml
  integrate: ./.bayt/Taskfile.integrate.yaml
  release:   ./.bayt/Taskfile.release.yaml
```

```yaml
# compose.yaml (hand-written; compose v2.20+ `include:`)
include:
  - ./.bayt/compose.launch.yaml
  - ./.bayt/compose.integrate.yaml
  - ./.bayt/compose.release.yaml
```

```yaml
# skaffold.yaml (hand-written; skaffold `requires:`)
apiVersion: skaffold/v4beta11
kind: Config
requires:
  - path: ./.bayt/skaffold.release.yaml
```

### When there's no include mechanism: copy-paste with lint enforcement

`.vscode/tasks.json` has no include, and `docker-bake.hcl` has a limited `target "<name>" {}` merge. For these:

- The generator computes the full merged content and writes it to the target file.
- `lint-bayt.nu` diffs the file against the freshly-generated content and fails if they differ.
- A hook runs on save to regenerate in dev.

Copy-paste is fine. Three similar lines beats a premature abstraction. Lint guarantees the hand-editable file matches the generated one.

### Relocatability

All paths inside `.bayt/*` are relative to the project's `dir`. Copybara can move a whole project (including its `.bayt/`) to a different monorepo root without rewriting anything. Cross-project deps still work because CUE imports are resolved at generation time, then relative-ized in the emission.

## Verb library

Ten canonical verbs — exactly the verb set already declared in `plugins/sayt/config.cue` (`setup`, `doctor`, `build`, `test`, `launch`, `integrate`, `release`, `verify`, `generate`, `lint`). Each is a partial `#target` fragment that a stack or project unifies in. They define default `deps`, which output blocks activate, and the default `cmd."builtin"` body.

```cue
// plugins/sayt/verbs.cue
package bayt

// setup: toolchain install. Runs once; never cached.
#setup: {
    name: "setup"
    deps: []
    outs: []
    taskfile: { run: "when_changed", extraSources: [".mise.toml", ".mise.lock"] }
    cmd: "builtin": do: "mise install"
}

// doctor: environment check. No outputs; always runs.
#doctor: {
    name: "doctor"
    deps: []
    outs: []
    taskfile: { run: "always" }
    vscode: group: { kind: "none" }
}

// build: the primary artifact producer.
#build: {
    name: "build"
    deps: *[#setup] | [...]
    taskfile: {}
    dockerfile: {}
    vscode: group: { kind: "build", isDefault: true }
}

// test: unit tests. Produces fixed reports for cacheability.
#test: {
    name: "test"
    deps: *[#build] | [...]
    outs: *["build/test-results/**/*.xml"] | [...string]
    taskfile: {}
    vscode: group: { kind: "test", isDefault: true }
}

// launch: dev-loop container. HMR-enabled.
#launch: {
    name: "launch"
    deps: *[#build] | [...]
    outs: []
    compose: {
        runtime: {}
        develop: watch: [...]  // populated by stack
    }
    dockerfile: {}
}

// integrate: docker-compose integration tests. Often needs dind + secrets.
#integrate: {
    name: "integrate"
    deps: *[#build] | [...]
    outs: *["build/test-results-int/**/*.xml"] | [...string]
    dockerfile: { secrets: ["host.env"] }
    compose: {}
    cmd: "builtin": dockerfile: inject: secrets: [{id: "docker_host", var: contents: "DOCKER_HOST"}]
}

// release: the shippable image. Typically #busybox base.
#release: {
    name: "release"
    deps: *[#build] | [...]
    outs: []
    dockerfile: bases.#busybox
    skaffold: {}
    bake: {}
}

// verify: e2e + load + screenshot tests. Run in preview (k8s).
#verify: {
    name: "verify"
    deps: *[#release] | [...]
    outs: *["build/verify-results/**/*"] | [...string]
    taskfile: {}
}

// generate: codegen. Outputs committed. Delegates to sayt's generate rulemap.
#generate: {
    name: "generate"
    deps: []
    outs: [...string]
    taskfile: {}
    cmd: "builtin": do: "nu sayt.nu generate"
}

// lint: static checks. Delegates to sayt's lint rulemap.
#lint: {
    name: "lint"
    deps: []
    outs: []
    taskfile: { run: "always" }
    cmd: "builtin": do: "nu sayt.nu lint"
}
```

Notes:

- **`cmd: "builtin"` is the default rule name** — matches `plugins/sayt/config.cue`'s `_builtinDo`/`_builtinUse` convention. Stacks and overrides address that rule directly.
- **Deps use CUE refs to other verb fragments** (`[#setup]`, `[#build]`), not strings. When a stack unifies both `#build` and `#test`, `#test.deps[0]` unifies with the project's actual `targets.build`.
- **Custom verbs** beyond these ten are allowed — `#target` takes any `name`. But the canonical ten should cover most services; prefer override to invention.
- **Verb naming is user-facing.** `just build` → `task build` → `vscode: run task: build`. One verb, many invocations.

## Stacks as language presets

Stacks are language presets. They unify verb fragments with language-specific `srcs`/`cmd`/`outs` and sensible defaults. A project picks one, overrides what's unique, and is done.

```cue
// plugins/sayt/stacks/gradle.cue
package gradle
import "github.com/bonisoft3/bayt/core:bayt"

#gradleProject: bayt.#project & {
    activate: *"mise x --" | string
    targets: {
        "setup":     bayt.#setup & {
            extraInputs: [".mise.toml", ".mise.lock", "gradle/libs.versions.toml"]
        }
        "doctor":    bayt.#doctor
        "build":     bayt.#build & {
            srcs: [
                "src/**/*.kt", "src/**/*.java", "src/**/*.sql",
                "build.gradle.kts", "settings.gradle.kts",
                "gradle/libs.versions.toml", "gradle.properties",
            ]
            outs: ["build/libs/**/*.jar", "build/classes/**/*.class"]
            cmd: "builtin": do: "./gradlew assemble"
            cmd: "builtin": windows: do: ".\\gradlew.bat assemble"
            cmd: "builtin": dockerfile: mounts: [
                {type: "cache", target: "/root/.gradle", sharing: "locked"},
            ]
        }
        "test":      bayt.#test & {
            cmd: "builtin": do: "./gradlew test"
            cmd: "builtin": windows: do: ".\\gradlew.bat test"
        }
        "integrate": bayt.#integrate & {
            cmd: "builtin": do: "./gradlew integrationTest --rerun"
        }
        "release":   bayt.#release & {
            cmd: "builtin": do: "./gradlew jibBuildTar"
        }
        "generate":  bayt.#generate
        "lint":      bayt.#lint
        "verify":    bayt.#verify
    }
}
```

```cue
// plugins/sayt/stacks/pnpm.cue
package pnpm
import "github.com/bonisoft3/bayt/core:bayt"

#pnpmProject: bayt.#project & {
    activate: *"mise x --" | string
    targets: {
        "setup": bayt.#setup & {
            extraInputs: [".mise.toml", ".mise.lock", "package.json", "pnpm-lock.yaml"]
            cmd: "builtin": do: "pnpm install --frozen-lockfile"
            cmd: "builtin": dockerfile: mounts: [
                {type: "cache", target: "/root/.local/share/pnpm/store"},
            ]
        }
        "build": bayt.#build & {
            srcs: ["**/*.ts", "**/*.vue", "package.json", "pnpm-lock.yaml"]
            exclude: ["node_modules/**", ".nuxt/**", ".output/**"]
            outs: [".output/**/*"]
            cmd: "builtin": do: "pnpm build"
        }
        "test": bayt.#test & {
            cmd: "builtin": do: "pnpm test"
            outs: ["coverage/**/*", "test-results/**/*"]
        }
        "launch": bayt.#launch & {
            cmd: "builtin": do: "pnpm dev"
            compose: develop: watch: [
                {action: "sync",    path: "./",             target: "/app", ignore: ["node_modules", ".nuxt", ".output"]},
                {action: "rebuild", path: "./package.json", target: "/app/package.json"},
            ]
        }
        "release": bayt.#release & {
            cmd: "builtin": do: "pnpm build"
        }
        "integrate": bayt.#integrate & {
            cmd: "builtin": do: "pnpm test:int"
        }
        "verify":   bayt.#verify & { cmd: "builtin": do: "pnpm test:e2e" }
        "generate": bayt.#generate
        "lint":     bayt.#lint & { cmd: "builtin": do: "pnpm lint" }
        "doctor":   bayt.#doctor
    }
}
```

```cue
// plugins/sayt/stacks/sayt.cue — the self-hosted stack, shortest.
package sayt
import "github.com/bonisoft3/bayt/core:bayt"

#saytProject: bayt.#project & {
    activate: *"mise x --" | string
    targets: {
        "setup":     bayt.#setup     & { cmd: "builtin": do: "nu sayt.nu setup" }
        "doctor":    bayt.#doctor    & { cmd: "builtin": do: "nu sayt.nu doctor" }
        "build":     bayt.#build     & { cmd: "builtin": do: "nu sayt.nu build" }
        "test":      bayt.#test      & { cmd: "builtin": do: "nu sayt.nu test" }
        "launch":    bayt.#launch    & { cmd: "builtin": do: "nu sayt.nu launch" }
        "integrate": bayt.#integrate & { cmd: "builtin": do: "nu sayt.nu integrate" }
        "release":   bayt.#release   & { cmd: "builtin": do: "nu sayt.nu release" }
        "verify":    bayt.#verify    & { cmd: "builtin": do: "nu sayt.nu verify" }
        "generate":  bayt.#generate
        "lint":      bayt.#lint
    }
}
```

Principles:

- **Stacks are unification fragments, not classes.** No inheritance, no "extends". The project unifies them in, the verbs unify in, the target-level overrides unify in. Everything merges, order-independent.
- **Defaults use `*value | type`** so they're overridable without disjunction conflicts.
- **Stacks live in `plugins/sayt/stacks/<lang>.cue`** as separate CUE packages. Users import just the one they need.
