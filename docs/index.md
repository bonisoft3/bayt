# bayt

# Entry points

* [bayt](../README.md) - concept: What bayt is, how to install it and declare a first target, and how it connects to sayt, the cache backends and CI.
* [The bayt target, specified](../SPEC.md) - reference: What a bayt.cue may contain beyond its field list — #cmd and its override levels, refs and views, runtime bring-up, transitive walking — and the cache that keys on it.
* [Contributing to bayt](../CONTRIBUTING.md) - howto: The layout of plugins/bayt, why the runtime emission has its shape, and what validates a change to the generator.
* [Pending](../PENDING.md) - metric: What is argued but not built in bayt, one entry per unbuilt piece.

# Archive

* [Target projection](archive/2026-04-20-one-target-every-format.md) - decision, superseded: The thesis bayt rests on — one typed declaration per target, projected into every tool's file — and its first design principles.
* [The pure/impure split](archive/2026-04-20-the-pure-impure-split.md) - decision, done: CUE generates and nushell runs; the boundary is the emitted per-target manifest.
* [Cache layers](archive/2026-04-20-three-tier-cache.md) - decision, done: A Merkle-chained stamp gates whether a command runs, a content-addressed cache whether its work is reused, BuildKit its layers, and a tool's own cache composes with all three.
* [Project onboarding](archive/2026-04-20-what-onboarding-taught.md) - decision, superseded: Three projects put on bayt, and what each cost against its hand-maintained files.
* [Core target schema](archive/2026-09-09-spec-core-schema.md) - decision, superseded: The first normative target shape — list-typed srcs, extraInputs, closed output blocks, bases.lock.cue, a verb library and per-language projects.
* [Cache check before deps](archive/2026-09-21-a-hit-skips-its-deps.md) - decision, done: A cache.full target is checked in its task's `if:`, before go-task runs its deps, so an exact hit restores the target and skips its whole subgraph.
* [Bazel comparison](archive/2026-09-27-why-not-bazel.md) - decision, done: Bayt subsumes the toolchain at package-sized targets instead of inverting it into sandboxed micro-actions, and keeps native host runs beside OCI isolation.
