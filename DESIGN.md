# Bayt: a CUE DSL for cross-format build targets

**Goal:** One CUE declaration per build target generates `Taskfile.yaml`, `Dockerfile`, `compose.yaml`, `skaffold.yaml`, `.vscode/tasks.json`, and `docker-bake.hcl` — with fine-grained caching, `COPY --link` everywhere possible, and work avoidance across every format.

**Tech stack:** CUE (schema + DAG + emission), nushell (impure runtime: file reads, hashing, side effects), Docker BuildKit (container caching), buchgr/bazel-remote or ORAS (cross-machine content-addressable cache), Taskfile (local runner), Skaffold (k8s orchestration).

> **Status:** the schema, all six emitters (manifest / Taskfile / Dockerfile+compose / skaffold / vscode / bake), the runtime (`fingerprint.nu`, `cache.nu`, `generate-bayt.nu`), and four onboarded projects (services/tracker, services/tracker-tx, services/boxer, guis/web) are in tree and exercised by the test suites. Sections marked "design sketch" or appearing under [Open questions](#open-questions) are the remaining unimplemented bits.

---

## Thesis

Build configuration today is smeared across 5–7 hand-maintained files per service (`Dockerfile.cue`, `compose.yaml`, `skaffold.yaml`, `.vscode/tasks.json`, `.mise.toml`, `Taskfile.yaml`). Each re-declares the same inputs, outputs, and dependencies in its own idiom. A change to source layout needs 5 edits; a new cache mount needs 3. The files drift, and caching becomes whatever BuildKit happens to infer.

Bayt collapses this into one typed declaration per target. The target describes a portable action (srcs, outs, deps, cmd, env) plus optional per-output blocks (`dockerfile`, `compose`, `taskfile`, `skaffold`, `vscode`, `bake`) carrying only the format-specific bits that can't be derived. Presence of a block means "emit this output format." Absence means "this target doesn't project into that format." CUE unification lets blocks be declared far from the target and merged at evaluation — so a stack can contribute defaults, a verb can contribute a fragment, and the project can override one field, without any of them knowing about the others.

The generator is pure CUE. The runtime (`cache.nu`, `pin-bases.nu`, file globbing, hashing) is nushell — everything with side effects lives there. Three cache tiers (L0 hash stamps, L1/L2 bazel-remote, BuildKit layers) compose orthogonally. Base images follow package.json-style split: version intent (tags) in `bayt.cue`, version lock (digests) in `bases.lock.cue`, refreshed by an impure `pin-bases.nu`. Lazybox provides a portable nushell substrate — not a fat toolchain — so the same commands run in containers, on CI, and on native Windows.

Dogfood line counts targeting minimal boilerplate: tracker ≈25 lines, web ≈12, sayt ≈3 non-boilerplate. All composition is via CUE unification and the rulemap pattern from `plugins/sayt/config.cue`. No string-keyed indirection, no `inherits:` (order-dependence), no cycle traps (per `plugins/sayt/docker.cue`'s index-based dedupe).

---

## Table of contents

1. [Design principles](#design-principles)
2. [Core schema: `#target`](#core-schema-target)
3. [`#cmd`: rulemap + two decoration axes](#cmd-rulemap--two-decoration-axes)
4. [Output blocks](#output-blocks)
5. [Deps as a single concept](#deps-as-a-single-concept)
6. [Pure / impure split](#pure--impure-split)
7. [Three-tier cache model](#three-tier-cache-model)
8. [Version intent vs version lock](#version-intent-vs-version-lock)
9. [Base image presets](#base-image-presets)
10. [File layout and include mechanisms](#file-layout-and-include-mechanisms)
11. [Verb library](#verb-library)
12. [Stacks as language presets](#stacks-as-language-presets)
13. [Dogfood](#dogfood)
14. [Open questions](#open-questions)

---

## Design principles

Seven cross-cutting concerns that must be solved together, not independently:

| Concern | What it solves | How bayt handles it |
|---|---|---|
| **Inputs / outputs** | What files a target reads and produces | `srcs`, `outs`, `exclude`, `extraInputs` on `#target`. Drives cache keys, COPY layers, Taskfile fingerprints, `--mount` decisions. |
| **Dependencies** | Execution ordering and data flow | `deps: [...string]` at the target level. Format-agnostic. Each generator translates: Dockerfile `COPY --from=<dep> --link`, compose `additional_contexts`, Taskfile `deps`, skaffold `requires`, vscode `dependsOn`. |
| **Activation** | Toolchain PATH/env setup (mise, devbox, nix) | `activate: *"mise x --" \| string` on `#project`. Prefixes every generated command. One knob; switch tool managers without touching targets. |
| **Caching** | Skip work when inputs haven't changed | L0 (`cache.nu` hash-stamp, in go-task `status:`), L1/L2 (bazel-remote), BuildKit layers. Orthogonal. Cache key = hash(srcs) ⊕ hash(`.mise.lock`) ⊕ hash(dep outputs). |
| **Multi-format emission** | Same target → Taskfile + Dockerfile + compose + skaffold + vscode + bake | Optional output-file-named blocks. Presence = emit. CUE unification lets declarations be "far away" and merged at evaluation. |
| **Composition** | Eliminate cross-target and cross-project repetition | Rulemap pattern (`#MapAsList` / `#MapToList` from `plugins/sayt/config.cue`) with priority-sorted named entries. Stacks contribute fragments; projects override via unification. |
| **Hermeticity** | Reproducible builds from machine to CI to prod | Progressive: `activate` wrapper (local approximation) → containerized verbs (`launch`, `integrate`) → preview (`release`, `verify`) → repo-wide (`generate`, `lint`). |

Non-negotiable rules:

- **No strings for refs.** Deps resolve through CUE field refs, not string lookups. Order-independent, type-checked, cycle-detected by CUE.
- **No `inherits:`.** CUE is order-independent; inheritance chains break unification. Stacks are fragments unified in, not parents inherited from.
- **No cycle traps.** Follow `plugins/sayt/docker.cue`'s index-based dedupe: when an element carries another element by value, dedupe by scalar key (e.g., `a.image.as`) with a lookback index, never by recursive structural equality.
- **CUE for pure, nushell for impure.** Schema, DAG, priority sort, emission bytes: CUE. File reads, hash exec, digest pinning, cache HTTP, git state: nushell. No exceptions.
- **Relocatability.** Copybara-compatible. All paths relative to project root (`dir`); no absolute references to the monorepo root leak into `.bayt/` outputs.
- **Copy-paste is fine when no include mechanism exists.** Lint enforces drift. Three similar lines beats a premature abstraction.

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
        wrap?:    string                // "dind.sh", "unshare -n", etc.
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
- vscode — emits the top-level `command` plus `windows: { command: ... }` override (matches `services/tracker/.vscode/tasks.json` pattern).
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
    image:    string             // e.g. "gcr.io/trash-362115/services.tracker"
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

Cross-project deps (a target in project A depends on a target in project B) use CUE imports:

```cue
import xproto "bonisoft.org/libraries/xproto"

#tracker: targets: "build": deps: [xproto.#x.targets.generate]
```

The generator resolves the imported reference to its emitted artifact path, relative-ized to the consuming project's `dir`. Copybara compatibility requires paths stay relative — no `/monorepo/absolute/path` leakage.

## Pure / impure split

CUE handles everything without side effects. Nushell handles everything with side effects. Drawing the boundary cleanly is what keeps the system testable, hashable, and relocatable.

**Pure (CUE):**

- Schema definitions (`#target`, `#cmd`, output blocks)
- DAG construction from `deps:`
- Priority sort for rulemaps (`#MapAsList` → `#MapToList`)
- Emission of bytes (Dockerfile text, YAML for compose/skaffold/taskfile, JSON for vscode/target-manifests, HCL for bake)
- Hash recipe shapes (which files feed which hash, as declarations)

**Impure (nushell):**

```
plugins/bayt/runtime/cache.nu         # L0: hash-check (Taskfile status:) + hash-stamp (post-cmd)
                                      # L1/L2: HTTP GET/PUT to bazel-remote AC endpoint
plugins/bayt/runtime/pin-bases.nu     # refresh bases.lock.cue digests via skopeo/docker manifest
plugins/bayt/runtime/generate-bayt.nu # run CUE, write .bayt/ files, git-stage hidden dir
plugins/bayt/runtime/lint-bayt.nu     # verify project.name matches dir, copy-paste hasn't drifted
```

Rules of thumb:

- **Never shell out from CUE**, even via `tool/exec`. That's the impure bit; it belongs in the runtime layer. CUE evaluation must be deterministic and sandboxable.
- **Never compute hashes in CUE.** Hashes need real file contents. CUE doesn't read the filesystem (outside `tool/file`, which we avoid for the same reason).
- **The boundary is the emitted `.bayt/targets/<n>.json`.** CUE emits a JSON manifest per target describing its portable action. `cache.nu` reads that JSON plus the globbed files to compute hashes. This makes the CUE layer cache-stable (manifest is deterministic) and the nushell layer replaceable (swap `cache.nu` backends without touching CUE).

The generator pipeline:

```
bayt.cue ──cue export──► .bayt/targets/<name>.json ──generate-bayt.nu──► .bayt/<name>.Dockerfile
                                                                        .bayt/compose.<name>.yaml
                                                                        .bayt/Taskfile.<name>.yaml
                                                                        .bayt/skaffold.<name>.yaml
                                                                        (merged) .vscode/tasks.json
                                                                        (merged) docker-bake.hcl
```

`cue export` is pure. `generate-bayt.nu` writes files and git-stages them.

## Three-tier cache model

Three layers that compose orthogonally. Each has a different scope, different speed, and a different failure mode. BuildKit's layer cache is a fourth dimension that runs in parallel inside Docker.

| Layer | Engine | Cache key | Scope | Speed |
|---|---|---|---|---|
| **L0: hash-stamp** | `fingerprint.nu hash-check` via go-task `status:` | SHA-256 of (platform-key ∪ srcs ∪ direct-dep stamps), Merkle-chained. platform-key = kernel + arch + libc flavor (musl/glibc) | Same worktree | ~50 ms |
| **L1/L2: cache.nu** | local-FS (default) / buchgr/bazel-remote / ORAS — selected by env | Same hash as L0 | Local FS: same machine. bazel-remote/ORAS: cross-machine, shared with CI. | Local FS: ms. Remote: network-bound |
| **BuildKit layers** | Docker BuildKit content-addressed store | Layer input hashes (Dockerfile slice + COPY'd bytes) | Per-host + registry if configured | — |

### L0: hash-stamp

Pure nushell. Called from go-task's `status:` hook.

```yaml
# .bayt/Taskfile.build.yaml (generated)
tasks:
  default:
    deps:
      - ::bayt:setup
    status:
      - mise x -- nu {{.TASKFILE_DIR}}/../../../plugins/bayt/runtime/fingerprint.nu hash-check --manifest {{.TASKFILE_DIR}}/bayt.build.json
    cmds:
      - defer: '{{if not .EXIT_CODE}}mise x -- nu {{.TASKFILE_DIR}}/../../../plugins/bayt/runtime/fingerprint.nu hash-stamp --manifest {{.TASKFILE_DIR}}/bayt.build.json{{end}}'
      - mise x -- nu {{.TASKFILE_DIR}}/../../../plugins/bayt/runtime/cache.nu run --manifest {{.TASKFILE_DIR}}/bayt.build.json --full -- mise x -- ./gradlew assemble
```

The status line is intentionally minimal — every input the hash depends on lives in `.bayt/bayt.<n>.json`, including:

- `srcs.globs` / `srcs.exclude` — direct content inputs (globs / exclusions).
- `outs.globs` — what hash-check additionally probes for existence (cheap `generates:` substitute; missing outs force a rerun, letting cache.nu refetch instead of rebuilding).
- `chainedDeps` — `[{name, project, dir}]` for each direct dep that itself produces a stamp. fingerprint.nu folds each dep's `.task/bayt/<n>.hash` file into the input set.

**Merkle chain semantics.** Hashing a dep's stamp file (rather than the dep's srcs) is what makes invalidation propagate transitively in O(direct deps) per status check:

```
stamp(T) = hash(platform-key ∪ manifest(T) ∪ srcs(T) ∪ {content-of stamp(d) for d in directDeps(T)})
```

Because go-task processes deps strictly before evaluating the parent's `status:`, each dep's stamp file on disk is fresh by the time it's read. A change to any leaf bubbles up one layer at a time: the leaf's stamp flips, the next layer's hash sees the new bytes, that layer's stamp flips, and so on. No recursive walk in CUE or nushell — the chain is constructed by go-task's natural dep-first execution order. The same key recipe powers cache.nu's L1/L2 lookups, so local and remote cache decisions stay coherent.

**Path math** (relative `../` traversal for cross-project chained deps) lives in fingerprint.nu, not CUE — nushell's `path` library handles separators correctly and avoids CUE's brittle string concat. CUE only emits the raw `{name, projectDir}` tuple per chained dep.

`hash-stamp` runs as the tail of `cmds:` and atomically writes the new stamp (tmp + rename). hash-check fails fast on missing literal files or git-hash-object errors — no silent fallbacks, so a misconfigured srcs list surfaces immediately rather than poisoning the cache.

Works in containers, Windows, air-gapped CI — no dependencies beyond nushell + git.

### L1 / L2: cache.nu

`cache.nu run --manifest <path> [--full] [--similar] -- <cmd>` wraps every Taskfile cmd. The bayt emitter inserts the wrap automatically — projects don't write the invocation themselves; the per-target capabilities `bayt.cache.full` / `bayt.cache.similar` toggle the flags.

```
1. Resolve the manifest, compute hash (same algorithm as L0).
2. backend-get hash  →  EXACT hit: restore outs to declared paths.
3. If --full and EXACT hit: exit 0 (trust the restored outs, don't run cmd).
4. If --similar and EXACT miss: pick the closest cached entry (weighted
   intersection over inputs + user/branch/day) and restore as warm state.
5. Otherwise run cmd; gradle/cargo/vitest see warm outputs and no-op fast.
6. On miss + cmd success: backend-put outputs.
```

Backend selected by env (first match wins):
- `BAYT_CACHE_URL` → buchgr/bazel-remote HTTP, hits/puts on `/ac/<hash>`. Server must run with `--disable_http_ac_validation` to accept our archive bytes (we don't speak REAPI ActionResult protobufs). bazel-remote chains to S3/GCS/Azure or proxies to depot.dev / BuildBuddy via its own flags — cross-machine + remote-storage live at the bazel-remote layer.
- `BAYT_CACHE_REGISTRY` → ORAS OCI registry. Each entry tagged `<project>-<target>-<hash[0:16]>`. Registry's GC policy (untagged-image cleanup) handles eviction.
- (default) → local FS at `BAYT_CACHE_DIR` (XDG-aware default: `$XDG_CACHE_HOME/bayt` or `~/.cache/bayt`), sharded by 2-char hash prefix. Atomic publish via tempdir + rename. mtime LRU GC at end of every `generate-bayt.nu` run, budget set by `BAYT_CACHE_MAX_SIZE`.

`bayt.cache.full` per-target capability trades correctness-checking-by-cmd for raw speed: on EXACT hit, skip cmd entirely. The gradle stack opts into this for `assemble` and `integrationTest` because the daemon cold-start is too costly to pay on every cache hit. Sibling capability `bayt.cache.similar` opts into warm-restore on EXACT miss (closest entry by weighted intersection over inputs + user/branch/day) — opt-in per project until real workloads validate the win.

Errors that recover (warn + treat as miss): backend GET failure, manifest unresolvable. Errors that die (no swallowing): backend PUT failure, missing oras CLI when ORAS is configured, GC failure.

Cache key is input-only: `hash(platform-key ∪ srcs ∪ direct-dep stamps)`. Toolchain version changes invalidate naturally because `.mise.toml` and `mise.lock` flow through the workspace-root setup target's outs into every consumer's hash.

### BuildKit: orthogonal

Docker builds use BuildKit's content-addressed layer cache. `COPY --link` means layer ordering doesn't matter for cache independence — changing srcs for target B doesn't invalidate layers for target A. Cache mounts (`--mount=type=cache`) persist tool caches (Gradle `~/.gradle`, pnpm `~/.pnpm`, Go `~/.cache/go-build`) across builds. Registry cache (`cacheFrom` / `cacheTo` in the bake block) shares layers cross-machine.

### Composition

L0 gates whether the command runs at all. L1/L2 gate whether the command's work gets reused across worktrees or machines. BuildKit gates whether individual Docker layers get rebuilt. Each is independent; enabling or disabling any one doesn't affect the others.

Failure modes are distinct: L0 false-negative (stamps invalidated unnecessarily) costs one command run. L1/L2 miss costs network + one command run. BuildKit miss costs a layer rebuild.

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

// #staging — runner + lazybox overlay. For ops shells in running pods.
#staging: #dockerfileBlock & {
    base:  "busybox:musl"
    stage: "runtime"
    preamble: [
        "COPY --from=bonisoft3/lazybox /lazybox /usr/local",
    ]
}
```

Usage:

```cue
targets: {
    "build":    { dockerfile: bases.#nubox }
    "test":     { dockerfile: bases.#nubox }
    "release":  { dockerfile: bases.#busybox }
    "staging":  { dockerfile: bases.#staging }
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
services/tracker/
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
    cmd: "builtin": dockerfile: { wrap: "dind.sh" }
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
import "bonisoft.org/plugins/bayt/bayt"

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
import "bonisoft.org/plugins/bayt/bayt"

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
import "bonisoft.org/plugins/bayt/bayt"

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

## Dogfood

Three concrete examples. Targets in order of increasing overrides.

### `plugins/sayt/bayt.cue` — ~3 non-boilerplate lines

Sayt self-hosts on the most opinionated stack. Everything defaults.

```cue
package sayt
import saytstack "bonisoft.org/plugins/bayt/stacks/saytstack"

#sayt: saytstack.#saytProject & {
    dir:  "plugins/sayt"
    name: "sayt"
}

// Emitters.
taskfiles:  (bayt.#emitTaskfiles  & {project: #sayt}).out
dockerfiles: (bayt.#emitDockerfiles & {project: #sayt}).out
composes:   (bayt.#emitComposes   & {project: #sayt}).out
skaffolds:  (bayt.#emitSkaffolds  & {project: #sayt}).out
```

### `guis/web/bayt.cue` — ~12 lines

Web adds a k8s image name and an expose for `launch`.

```cue
package web
import pnpm "bonisoft.org/plugins/bayt/stacks/pnpm"

#web: pnpm.#pnpmProject & {
    dir:  "guis/web"
    name: "web"

    targets: {
        "release": {
            skaffold:   image:  "gcr.io/trash-362115/guis.web"
            dockerfile: expose: [8080]
        }
        "launch":    dockerfile: expose: [3000]
        "integrate": dockerfile: secrets: ["host.env"]
    }
}
```

### `services/tracker/bayt.cue` — ~25 lines

Tracker adds cross-project deps (xproto generation, libstoml config) and secret-mounted integration.

```cue
package tracker
import (
    gradle "bonisoft.org/plugins/bayt/stacks/gradle"
    xproto "bonisoft.org/libraries/xproto"
    pbt    "bonisoft.org/libraries/pbtables"
    logs   "bonisoft.org/libraries/logs"
    ltoml  "bonisoft.org/libraries/libstoml"
    mn     "bonisoft.org/libraries/micronaut"
    jvm    "bonisoft.org/plugins/jvm"
)

#tracker: gradle.#gradleProject & {
    dir:  "services/tracker"
    name: "tracker"

    targets: {
        "build": deps: [
            xproto.#x.targets.generate,
            pbt.#p.targets.generate,
            ltoml.#l.targets.build,
            logs.#l.targets.build,
            mn.#m.targets.build,
            jvm.#j.targets.build,
        ]

        "integrate": {
            // Integration tests need docker-in-docker plus a host.env secret.
            cmd: "builtin": dockerfile: {
                wrap: "dind.sh"
                mounts: [{type: "secret", id: "host.env", required: true}]
            }
            dockerfile: secrets: ["host.env"]
        }

        "release": {
            skaffold: image: "gcr.io/trash-362115/services.tracker"
            // Swap to scratch base + java entrypoint for jib.
            dockerfile: stage: "scratch"
        }
    }
}
```

### Target file count comparison

Each service emits ~8 files from one hand-written bayt.cue:

| Project | Before (hand-maintained) | After (bayt.cue + .bayt/) |
|---|---|---|
| services/tracker | 5 files, ~320 lines | 1 file (25 lines) + 8 generated |
| guis/web | 5 files, ~240 lines | 1 file (12 lines) + 8 generated |
| plugins/sayt | 4 files, ~180 lines | 1 file (3 lines) + 8 generated |

## Open questions

Open items not yet implemented. The list shrunk substantially as the implementation landed; what remains is genuinely future work, not undecided design.

### HMR emission

Compose `develop.watch`, Skaffold `sync.manual`, and Taskfile `--watch` have overlapping but distinct capabilities. Design sketch:

- `develop: watch: [...]` lives on `#composeBlock`.
- Skaffold block mirrors with `sync.manual: [...]` generated from the compose watch entries (same path/target schema).
- Taskfile gets a `<name>:watch` pseudo-task that re-runs on source changes using go-task's `watch: true`.
- Nest where possible: compose's HMR is natively layered inside `skaffold dev`.

### Non-file outputs (e.g., deploy actions, network calls)

`release` → `skaffold run` pushes to a registry; `verify` → runs against a live preview. Neither produces a local file. The cache key is still input-based, but the side effect (`kubectl apply`, HTTP POST) is what matters. These run unconditionally when invoked — idempotency is the contract, not caching.

### Watch mode across generators

`bayt watch` (impure, nushell) would re-run the generator on `bayt.cue` / `images.lock.cue` / imported CUE file changes. Combined with Taskfile's own watch: edit target → `.bayt/*` regenerates → running task picks up the change → rebuild triggers via Taskfile `sources:`. Chained HMR. Not yet built; today users invoke `just sayt generate` manually after editing bayt.cue.

### `bayt.cue` authoring ergonomics

CUE's error messages on unification conflicts are dense. Mitigations on the table:

1. Close schemas (`close({...})`) aggressively so typos surface as "field not allowed" rather than silent drift. Partially in place.
2. Ship `plugins/bayt/bayt-schema.json` for IDE/vscode CUE plugin consumption. Not yet.
3. `bayt lint` (impure) validates the `bayt.cue` against the schema and offers suggestions. Not yet.

## Decisions made (was open, now resolved)

- **Cross-project dep resolution.** Bazel-style refs (`:target` same-project, `project:target` cross-project) replaced the CUE-import shape. The emitted manifest carries `chainedDeps: [{name, project, dir}]`; nushell does the path math at runtime.
- **Non-artifact targets.** Stacks emit canonical reports where they exist (gradle's JUnit XML at `build/test-results/test/**/*.xml`, etc.). Targets with empty outs cache normally — the merkle-chain tracks "did we already run this on this input?" via the stamp file alone.
- **Secrets flow.** `dockerfile.secrets: ["host.env"]` on a target generates `--mount=type=secret,id=host.env,required=true` on the RUN line. The compose service declares the secret as `file: ${BAYT_HOST_ENV_FILE}`; integrate.nu's dind-vrun creates the temp file at runtime.
- **Content-addressable store choice.** Three backends (local-FS / buchgr/bazel-remote / ORAS) selected by env. cache.nu stays agnostic.
- **Migration path.** Five projects on bayt today (services/{tracker,tracker-tx,boxer}, guis/web, plus the cross-project lib/plugin chain). Per-project incremental adoption proven; no big-bang cutover needed.
