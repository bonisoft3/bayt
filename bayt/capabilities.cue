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

// hostenv — target reads the `host.env` secret at build time via a
// BuildKit secret mount, and federates the secret in compose.
//
// This is bayt's level of abstraction: secret infrastructure. How the
// secret gets CONSUMED (a `dind.sh` that sources it, an `aws-cli` that
// reads env vars from it, a custom script, etc.) is user territory —
// compose with the capability in user bayt.cue:
//
//     "integrate": bayt.hostenv & {
//         // Wrap with sayt's dind.sh (which sources host.env internally).
//         cmd: "builtin": dockerfile: wrap: "/monorepo/plugins/devserver/dind.sh"
//         compose: runtime: {
//             entrypoint: ["/monorepo/plugins/devserver/dind.sh"]
//             volumes: [
//                 "//var/run/docker.sock:/var/run/docker.sock",
//                 "${HOME:-~}/.skaffold/cache:/root/.skaffold/cache",
//             ]
//             network_mode: "host"
//         }
//     }
//
// The `dind.sh` path is a sayt concept (plugins/devserver/dind.sh),
// not bayt's — bayt only provides the secret plumbing here.
hostenv: {
	cmd: "builtin": dockerfile: mounts: [
		{type: "secret", id: "host.env", required: true},
	]
	dockerfile: secrets: ["host.env"]
}

// incremental — run the target's cmds via `task <n>:<n>` inside the
// Docker build, so go-task's fingerprint.nu `status:` hook short-
// circuits re-runs when srcs haven't changed.
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
// Wiring (applied by docker_compose_gen when dockerfile.incremental
// is true):
//   - RUN line is replaced with `task <name>:<name>` (target + cmd
//     mounts still apply — gradle cache, secrets, etc.).
//   - The whole .bayt/ directory is COPY'd into the image so task
//     resolves Taskfiles and fingerprint.nu resolves target manifests.
//   - No cache mount for .task/ — stamps live in the image layer, so
//     cross-stage propagation works naturally via COPY --from.
//
// Usage:
//   targets: "build": bayt.incremental & { ... }
incremental: {
	dockerfile: incremental: true
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
