// images.cue — container base-image presets producing dockerfile.from
// values. Each preset sets `dockerfile.from.name` to a pinned digest
// from `images.lock.cue`. Use a preset on a LEAF stage when you want
// a fresh `FROM <image>`; for chained stages use `dockerfile: from:
// ref: ":<target>"` (preset + ref shorthand don't compose — the
// schema's closed `from` arms reject the mix).
//
// Composition: derived presets extend a base by adding new keyed
// entries to its defaultPreamble. CUE map unification merges by key.
//
// Compose into a target's dockerfile block:
//
//   targets: "build":   dockerfile: nubox     // leap, includes lazybox
//   targets: "release": dockerfile: busybox   // musl runtime
//   targets: "dindbox": dockerfile: bayt.dind // docker:cli + socat + entrypoint
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
		name: *lock.images.leap | string
	})
	defaultPreamble: _lazyboxOverlay & {
		"mise-trusted":  {priority: -8, line: "ENV MISE_TRUSTED_CONFIG_PATHS=/monorepo"}
		"gnu-shell-utils": {priority: -7, line: "RUN zypper -n install findutils=4.10.0-160000.2.2 which=2.23-160000.2.2"}
	}
}

// dind — alpine docker:cli + buildx/compose plugins, with socat
// copied from alpine/socat. CLI-only (no daemon binaries) so the
// image stays small. Bakes the dindbox sidecar's entrypoint script
// under /usr/local/bin; see the script itself for its intent.
dind: {
	from: close({
		name: *lock.images.docker | string
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
		"dind-entrypoint": {priority: 3, line: #"""
			RUN <<DIND
			cat > /usr/local/bin/dind-entrypoint.sh <<'SCRIPT'
			#!/bin/sh
			# dind-entrypoint.sh — sidecar entrypoint. Bridges the
			# mounted /var/run/docker.sock to a published TCP port
			# (socat), discovers the literal IP host.docker.internal
			# resolves to on this host (cross-platform via a probe
			# container with --add-host=host-gateway), then reassigns
			# DOCKER_HOST to `tcp://<ip>:<port>` before execing CMD.
			# The final DOCKER_HOST value flows out via compose's
			# env-sourced `docker_host` secret to RUN sandboxes that
			# bake spawns from CMD.
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
			# Hydrate the host's buildx instance file from
			# $BUILDX_INSTANCE (verbatim file content) + the
			# BUILDX_BUILDER env. The compose service env carries
			# these via `${VAR:-}` interpolation so missing host env
			# degrades to empty — the guards below skip writing in
			# that case. Compose secrets aren't portable (file:
			# source breaks on missing path across hosts/inception,
			# environment: source errors when var is unset), so we
			# stick to plain env passthrough.
			if [ -n "${BUILDX_BUILDER:-}" ] && [ -n "${BUILDX_INSTANCE:-}" ]; then
			    mkdir -p /root/.docker/buildx/instances
			    printf '%s' "$BUILDX_INSTANCE" > "/root/.docker/buildx/instances/$BUILDX_BUILDER"
			fi
			if [ -n "${DOCKER_AUTH_CONFIG:-}" ]; then
			    mkdir -p /root/.docker
			    printf '%s' "$DOCKER_AUTH_CONFIG" > /root/.docker/config.json
			fi
			exec "$@"
			SCRIPT
			chmod +x /usr/local/bin/dind-entrypoint.sh
			DIND
			"""#}
	}
}

// busybox — minimal musl runner, scratch-adjacent. Use for release.
busybox: {
	from: close({
		name: *lock.images.busybox | string
	})
}

// scratch — explicit "no FROM" preset. Sets `from: null` so the
// emitter writes `FROM scratch AS <target>` with no additional_contexts
// entry. Compose this on bare targets that don't use an image preset.
scratch: {
	from: null
}
