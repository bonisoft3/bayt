// images.cue — container base-image presets producing dockerfile.from
// values. Each preset sets `dockerfile.from.name` as a field-level
// disjunction default; `context` auto-derives from the schema's
// `*"docker-image://\(name)" | string` default. Use a preset on a
// LEAF stage when you want a fresh `FROM <image>`; for chained stages
// use `dockerfile: from: ref: ":<target>"` (preset + ref shorthand
// don't compose, see below).
//
// Image references are pulled from images.lock.cue's `lock.images.<alias>`
// table — single source of truth for the registry+tag+digest tuple.
//
// Composition: derived presets (e.g. `dind`) extend a base preset by
// adding new keyed entries to its defaultPreamble. CUE map unification
// merges by key, so no list.Concat dance:
//
//   dind: nubox & {
//     defaultPreamble: {
//       "socat-install": {line: "RUN ..."}
//     }
//   }
//
// Compose into a target's dockerfile block:
//
//   targets: "build":   dockerfile: nubox     // leap, includes lazybox
//   targets: "release": dockerfile: busybox   // musl runtime
//   targets: "ops":     dockerfile: staging   // busybox + lazybox overlay
//
// Image presets are for LEAF stages only — when you want a fresh
// FROM <image>. Chained stages (FROM another bayt target via
// `dockerfile: from: ref: ":<target>"`) inherit the upstream stage's
// filesystem and ENVs, so layering a preset on top is unnecessary.
// The schema rejects `nubox & {from: ref: ...}` — combining an image
// preset's canonical from with a ref-arm shorthand is a no-op
// overlay at best and silently masks the chain intent at worst.
package bayt

// _lazyboxOverlay — defaultPreamble fragment that COPYs lazybox into
// the image and prepends its bin dirs to PATH. Shared by nubox (full
// dev environment) and staging (ops-shell-on-busybox), so a lazybox
// version bump here flows to both presets without drift.
_lazyboxOverlay: {
	"lazybox-copy": {priority: -10, line: "COPY --from=\(lock.images.lazybox) /lazybox/ /root/.local/share/lazybox/"}
	"path-env":     {priority:  -9, line: "ENV PATH=/root/.local/bin:/root/.local/share/lazybox/bin:$PATH"}
}

// nubox — leap-based, includes lazybox + mise + nushell. Use for
// build / test / integrate. Lazybox self-bootstraps with posix sh
// as the only dep — it ships busybox, static-curl, ca-certs, and a
// mise shim under /root/.local/share/lazybox/. No zypper/apk/curl
// installs needed.
nubox: {
	from: name: *lock.images.leap | string
	defaultPreamble: _lazyboxOverlay & {
		"mise-trusted": {priority: -8, line: "ENV MISE_TRUSTED_CONFIG_PATHS=/monorepo"}
	}
}

// dind — nubox + socat + docker smoke. socat bridges DOCKER_HOST
// (TCP) → /var/run/docker.sock when the host daemon is remote (e.g.
// Docker Desktop on Mac). The `docker --help` invocation is a smoke
// test that the docker CLI is reachable and loads the buildx/compose
// plugins eagerly (they're loaded once per CLI process, so a single
// --help warms all three).
//
// Composition is by key-merge through #MapAsList — nubox's three
// entries flow through unchanged, and dind contributes its own two.
// No list-length juggling, no field-copy dance: priorities (>0)
// place dind's lines after nubox's at #MapToList sort time.
dind: nubox & {
	defaultPreamble: {
		"socat-install": {priority: 10, line: "RUN zypper -n install socat"}
		"docker-smoke":  {priority: 11, line: "RUN docker --help"}
	}
}

// busybox — minimal musl runner, scratch-adjacent. Use for release.
busybox: {
	from: name: *lock.images.busybox | string
}

// staging — busybox + lazybox overlay for ops shells in running pods.
staging: {
	from:            busybox.from
	defaultPreamble: _lazyboxOverlay
}

// docker — official docker image (Alpine), CLI + buildx + compose
// plugins included. Use for CI stages that shell out to docker without
// needing a local daemon. Stages that need a daemon should use `dind`
// + dind.sh.
docker: {
	from: name: *lock.images.docker | string
}

// scratch — explicit "no FROM" preset. Sets `from: null` so the
// emitter writes `FROM scratch AS <target>` with no additional_contexts
// entry. Compose this on bare targets that don't use an image preset.
scratch: {
	from: null
}
