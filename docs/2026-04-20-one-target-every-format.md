# One target, every format

The claim bayt rests on, and the principles that follow from it.

## Thesis

Build configuration today is smeared across 5–7 hand-maintained files per service (`Dockerfile.cue`, `compose.yaml`, `skaffold.yaml`, `.vscode/tasks.json`, `.mise.toml`, `Taskfile.yaml`). Each re-declares the same inputs, outputs, and dependencies in its own idiom. A change to source layout needs 5 edits; a new cache mount needs 3. The files drift, and caching becomes whatever BuildKit happens to infer.

Bayt collapses this into one typed declaration per target. The target describes a portable action (srcs, outs, deps, cmd, env) plus optional per-output blocks (`dockerfile`, `compose`, `taskfile`, `skaffold`, `vscode`, `bake`) carrying only the format-specific bits that can't be derived. Presence of a block means "emit this output format." Absence means "this target doesn't project into that format." CUE unification lets blocks be declared far from the target and merged at evaluation — so a stack can contribute defaults, a verb can contribute a fragment, and the project can override one field, without any of them knowing about the others.

The generator is pure CUE. The runtime (`cache.nu`, `pin-bases.nu`, file globbing, hashing) is nushell — everything with side effects lives there. Three cache tiers (L0 hash stamps, L1/L2 bazel-remote, BuildKit layers) compose orthogonally. Base images follow package.json-style split: version intent (tags) in `bayt.cue`, version lock (digests) in `bases.lock.cue`, refreshed by an impure `pin-bases.nu`. Lazybox provides a portable nushell substrate — not a fat toolchain — so the same commands run in containers, on CI, and on native Windows.

Dogfood line counts targeting minimal boilerplate: api ≈25 lines, web ≈12, sayt ≈3 non-boilerplate. All composition is via CUE unification and the rulemap pattern from `plugins/sayt/config.cue`. No string-keyed indirection, no `inherits:` (order-dependence), no cycle traps (per `plugins/sayt/docker.cue`'s index-based dedupe).

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
