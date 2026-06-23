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
//   targets: "build":   dockerfile: nubox       // leap, includes lazybox
//   targets: "release": dockerfile: busybox     // musl runtime
//   targets: "dindbox": dockerfile: bayt.dindbox // docker:cli + socat
//
// docker-in-docker targets pair `dindbox` (the image preset) with
// `sayt.dindboxInject` (the inject helper) — the preset provides the
// FROM base + socat binary; the inject body does the in-sandbox env
// extraction, file placement, and unix-socket forwarding.
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

// dindbox — lean docker:cli + socat binary. No entrypoint script,
// no defaultPreamble. Pair with `sayt.dindboxInject` on the consuming
// ci target: that helper mounts host-supplied compose secrets
// (docker_host, buildx_builder, buildx_instance, docker_config) and
// emits the in-sandbox setup body (env extraction, file placement,
// unix-socket forwarder for clients that ignore $DOCKER_HOST).
//
// socat binary ships in the image because some clients (testcontainers)
// bypass $DOCKER_HOST and look for /var/run/docker.sock — the
// in-sandbox socat creates that bridge at RUN time.
dindbox: {
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
		// jq — used by the ci build phase to derive the runtime closure
		// (integrate's transitive depends_on) from `docker compose config`,
		// so the bake pushes exactly the services the run pulls. Static
		// binary from the scratch jqlang/jq image, lives at /jq.
		{
			from: {name: lock.images.jq}
			srcs: ["/jq"]
			dst:  "/usr/local/bin/jq"
		},
	]
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
