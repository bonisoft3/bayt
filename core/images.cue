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
// mise shim under /root/.local/share/lazybox/.
//
// Installs GNU findutils + which (absent in leap 16.0's slim base);
// gradle's gradlew probes for both at startup and dies otherwise. No
// `zypper clean -a` — chained re-runs are no-ops ("Nothing to do");
// clearing the metadata cache would make them fail with "no provider".
nubox: {
	// `from` is bound to the leaf disjunct, so `bayt.nubox & {from: ref: ...}`
	// fails CUE evaluation. Chained-FROM consumers don't compose the
	// preset; they set `dockerfile: from: ref:` directly.
	from: close({
		name:    *lock.images.leap | string
		context: *"docker-image://\(name)" | string
	})
	defaultPreamble: _lazyboxOverlay & {
		"mise-trusted":  {priority: -8, line: "ENV MISE_TRUSTED_CONFIG_PATHS=/monorepo"}
		"gnu-shell-utils": {priority: -7, line: "RUN zypper -n install findutils=4.10.0-160000.2.2 which=2.23-160000.2.2"}
	}
}

// dind — alpine docker:cli + buildx/compose plugins, with socat
// copied from alpine/socat. CLI-only (no daemon binaries) so the
// image stays small. Bakes two convenience scripts under
// /usr/local/bin; see the scripts themselves for their intent.
dind: {
	from: close({
		name:    *lock.images.docker | string
		context: *"docker-image://\(name)" | string
	})
	copy: [
		{
			from: {name: lock.images.alpine_socat}
			srcs: ["/usr/bin/socat1"]
			dst:  "/usr/local/bin/socat"
		},
		{
			from: {name: lock.images.alpine_socat}
			srcs: ["/usr/lib/libreadline.so.8", "/usr/lib/libncursesw.so.6"]
			dst:  "/usr/lib/"
		},
	]
	defaultPreamble: {
		"dind-scripts": {priority: 3, line: #"""
			RUN <<DIND
			cat > /usr/local/bin/dind.sh <<'SCRIPT'
			#!/bin/sh
			# dind.sh — RUN-side wrap. Reads the docker_host secret
			# mounted at /run/secrets/docker_host and re-exports it
			# as DOCKER_HOST so testcontainers / docker CLI in the
			# wrapped command reach the dindbox-bridged daemon.
			set -e
			export DOCKER_HOST="$(cat /run/secrets/docker_host)"
			exec "$@"
			SCRIPT
			cat > /usr/local/bin/dind-entrypoint.sh <<'SCRIPT'
			#!/bin/sh
			# dind-entrypoint.sh — sidecar entrypoint. Bridges the
			# mounted /var/run/docker.sock to a published TCP port
			# (socat), discovers the literal IP host.docker.internal
			# resolves to on this host (cross-platform via a probe
			# container with --add-host=host-gateway), then exports
			# DOCKER_HOST and BAYT_DOCKER_HOST before execing CMD.
			# DOCKER_HOST is the local docker CLI's target;
			# BAYT_DOCKER_HOST is the env-sourced secret value piped
			# through to RUN sandboxes that bake spawns from CMD.
			set -e
			export DOCKER_HOST=unix:///var/run/docker.sock
			socat -d0 TCP-LISTEN:2375,fork,reuseaddr UNIX-CONNECT:/var/run/docker.sock &
			socat -u OPEN:/dev/null TCP:127.0.0.1:2375,retry=100,interval=0.05 >/dev/null 2>&1
			HOST_PORT=$(docker inspect "$HOSTNAME" --format '{{(index (index .NetworkSettings.Ports "2375/tcp") 0).HostPort}}')
			[ -n "$HOST_PORT" ] || { echo "dind-entrypoint: no host port for $HOSTNAME" >&2; exit 1; }
			HOST_IP=$(docker run --rm --add-host=host.docker.internal:host-gateway \#(lock.images.busybox) \
			    awk '/host\.docker\.internal/ {printf "%s", $1; exit}' /etc/hosts)
			[ -n "$HOST_IP" ] || { echo "dind-entrypoint: failed to probe host IP" >&2; exit 1; }
			export DOCKER_HOST="tcp://${HOST_IP}:${HOST_PORT}"
			export BAYT_DOCKER_HOST="$DOCKER_HOST"
			exec "$@"
			SCRIPT
			chmod +x /usr/local/bin/dind.sh /usr/local/bin/dind-entrypoint.sh
			DIND
			"""#}
	}
}

// busybox — minimal musl runner, scratch-adjacent. Use for release.
busybox: {
	from: close({
		name:    *lock.images.busybox | string
		context: *"docker-image://\(name)" | string
	})
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
	from: close({
		name:    *lock.images.docker | string
		context: *"docker-image://\(name)" | string
	})
}

// scratch — explicit "no FROM" preset. Sets `from: null` so the
// emitter writes `FROM scratch AS <target>` with no additional_contexts
// entry. Compose this on bare targets that don't use an image preset.
scratch: {
	from: null
}
