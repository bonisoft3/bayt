// capabilities.cue — cross-cutting target capabilities that touch
// multiple output blocks at once. Same pattern as the image presets
// in images.cue: plain struct values the user unifies into a target.
//
// Keep these narrow and orthogonal. A capability should describe
// "turn on X for this target" and show up in exactly the places that
// would need manual wiring. Capabilities should stay at the
// *abstraction* level bayt can express (secrets, mounts, env,
// volumes) — concrete implementations (script paths like dind.sh)
// belong to the layer that owns them (typically sayt, or the user's
// own bayt.cue).
package bayt

// incremental — full opt-in to the layered work-avoidance pipeline:
// build-time RUN invokes `task bayt:<n>`, Taskfile emits the status-
// hook + cache.nu wrap machinery, and a `/root/.cache/bayt` BuildKit
// cache mount provisions shared storage for cache.nu's local backend.
//
// Splits into two orthogonal flags + one shared-storage detail:
//
//   - `dockerfile.incremental: true` — Dockerfile collapses per-cmd
//     RUNs into one `RUN ["task", "bayt:<t.name>"]`. BuildKit's layer
//     cache reuses the whole RUN when inputs are unchanged; the
//     target-name/task-name coupling makes the cmd address stable
//     across host and in-container invocations. Useful even without
//     the Taskfile machinery — the layer cache alone is a real win.
//
//   - `taskfile.incremental: true` — Taskfile emits `status:` hook
//     (fingerprint.nu stamp check), `BAYTW` cache.nu wrapper, and
//     `defer:` update-stamp. The in-task work-avoidance loop. Fires
//     wherever the task is invoked from — build-time RUN OR runtime
//     compose `command:`. Useful in isolation for projects running
//     entirely outside docker.
//
//   - Shared storage (this capability's expanded role): adds a
//     BuildKit cache mount at `/root/.cache/bayt`, which is where
//     cache.nu's local backend keeps its content-addressable store.
//     Without it cache.nu can still run (in-task short-circuit via
//     stamp), but content-based reuse on cache miss is ephemeral.
//     For cross-machine reuse use cache.nu's network backend
//     (BAYT_CACHE_URL / BAYT_CACHE_REGISTRY) instead.
//
// Layered benefit vs. BuildKit's layer cache alone:
//   - BuildKit layer cache: skips the whole RUN if the layer's
//     deterministic inputs (COPY'd files + prior layers) are unchanged.
//   - fingerprint.nu status hook: when BuildKit's layer cache hits the
//     RUN but the tool's own up-to-date check is slow (gradle daemon
//     warm-up is 2-4s), task's stamp-based check is ~50ms and skips
//     the slow tool invocation entirely.
//   - Cross-stage Merkle: a downstream stage (integrate) COPYs the
//     full workdir of its dep stage (build) via `COPY --from=<dep>`,
//     which includes the dep's `.task/bayt/` directory. When
//     downstream runs `task integrate:integrate`, task's dep chain
//     walks :setup:setup and :build:build; both find their stamps
//     already on disk (from the upstream COPY) and skip. The
//     downstream stage runs only its own cmd.
//
// Usage:
//   targets: "build": bayt.incremental & { ... }
incremental: {
	dockerfile: incremental: true
	taskfile:   incremental: true
	// In-task work-avoidance calls bayt-runtime (cache run, fingerprint).
	// The copy entry's `image:` override aliases the fixed
	// `bayt-runtime` additional_contexts key to the pinned digest;
	// ENV PATH lands via preamble.
	dockerfile: copy: [{
		from: {name: "bayt", image: lock.images.bayt}
		srcs: ["runtime"]
		dst: "/monorepo/plugins/bayt/runtime"
	}]
	dockerfile: defaultPreamble: "bayt-path": {
		priority: -5
		line:     "ENV PATH=/monorepo/plugins/bayt/runtime:${PATH}"
	}
}

// cache — capabilities for the per-target cache.nu wrap. Each is
// orthogonal opt-in; combine as needed.
//
//   bayt.cache.full    — on EXACT cache hit, skip cmd entirely.
//                        Trades cmd-side validation for raw speed.
//                        Use when the cmd's even-no-op startup cost
//                        dominates (gradle daemon, kotlinc warmup).
//
//   bayt.cache.similar — on cache MISS, look for a similar cached
//                        entry (weighted intersection over inputs +
//                        user/branch/day) and restore as warm state
//                        before running cmd. cmd's incremental
//                        engine handles the delta. Safe whenever
//                        the cmd validates its inputs (gradle,
//                        cargo, vitest, go all do).
//
// Stacks bake these in for the verbs that benefit (e.g. sayt's
// gradle stack composes `cache.full` onto assemble + integrationTest;
// `cache.similar` is opt-in per project until real workloads validate
// the warm-restore win). Project-leaf opt-in:
//
//   targets: "build": bayt.cache.full & bayt.cache.similar & { ... }
cache: {
	full:    {cache: full: true}
	similar: {cache: similar: true}
}
