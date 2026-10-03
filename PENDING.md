---
type: metric
title: Pending
description: What is argued but not built in bayt, one entry per unbuilt piece.
---

# Pending

What is argued but not built. A line leaves when it lands, or when a dated
record under `docs/decisions/` refuses it.

- **Taskfile `<name>:watch`.** A pseudo-task that re-runs the target on source
  change through go-task's `watch: true`, giving the host loop what compose
  `develop.watch` (emitted from `hmr`) already gives the container loop.
- **`entrypoint.after` deriving `deps`.** A container's wait must be one of its
  `deps` today, or generation fails; mecha's `#Runtime` adds them by hand.
  `deps` is a concrete user list a dozen generators read, so derived edges need
  a manifest-level merge rather than unification.
- **`bayt watch`.** Re-run the generator when `bayt.cue`, `images.lock.cue` or an
  imported CUE file changes, so an edit regenerates `.bayt/*` and a running task
  picks up the change; today you run `sayt generate` by hand.
- **`bayt-schema.json`.** A JSON schema of `#target` for IDE and CUE-plugin
  consumption, so a typo surfaces as "field not allowed" in the editor rather
  than at generation.
- **`bayt lint`.** Validate a `bayt.cue` against the schema and suggest fixes;
  CUE's unification errors are dense.
- **A Claude Code plugin.** bayt would ship as a Claude Code plugin with three
  skills: `bayt-target` (writing a `bayt.cue`), `bayt-stack` (authoring a
  language stack) and `bayt-debug` (fingerprint mismatches, missing-src errors,
  cross-project stamps).
