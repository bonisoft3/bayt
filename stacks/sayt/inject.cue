// stacks/sayt/inject — shared inject helper for ci-style targets that
// run an inner docker / docker-bake / docker-compose stack against a
// host-provided daemon. Pair with the `bayt.dindbox` image preset.
//
// Architecture summary (matches the host-side `dind.nu env-file --socat
// --builder sayt-builder` contract):
//
//   Host                                      Sandbox (RUN inside ci)
//   ────                                      ───────────────────────
//   socat publishes /var/run/docker.sock      DOCKER_HOST   = tcp://… (env-sourced)
//   as tcp://<host-ip>:<port>                 BUILDX_BUILDER= sayt-builder
//   buildx instance file pre-sed'd            BUILDX_INSTANCE → placed at
//   to use the same TCP endpoint              /root/.docker/buildx/instances/sayt-builder
//   docker auth json                          docker_config → /root/.docker/config.json
//   compose service `secrets:`                socat -d0 UNIX-LISTEN:/var/run/docker.sock
//   declarations: env-sourced from            forks to bridge any client that
//   the four host env vars above              ignores $DOCKER_HOST (testcontainers et al.)
//
// What unifying `sayt.inject` into a #target adds:
//
//   1. target-level dockerfile.secrets — four compose-spec env-sourced
//      secrets so the consumer's compose graph carries the values from
//      the GHA action / local-dev shell into the build sandbox.
//   2. cmd."builtin".dockerfile.inject:
//        - secrets list: same four, mounted as --mount=type=secret.
//        - var sugar: contents → export env var; path → guarded
//          mkdir+cp from /run/secrets/<id> to the canonical docker
//          client path (no in-sandbox sed; host pre-rewrote BUILDX_INSTANCE
//          Endpoint already).
//        - defaultSteps.unix-socket-forward: starts socat creating
//          /var/run/docker.sock → $DOCKER_HOST (tcp), so testcontainers
//          and other clients that default to the unix socket find a
//          working daemon. No-op when the socket already exists.
//
// What the consumer still provides (sayt.inject is one piece,
// not a complete target):
//   - dockerfile.from (typically `bayt.dindbox` preset for the lean
//     docker:cli + socat image, or `ref: ":dindbox"` to chain off a
//     project-local target with that preset).
//   - cmd."builtin".shell + cmd."builtin".do — the actual inner invocation
//     (e.g. /usr/local/bin/inner-bake.sh or a direct `docker buildx bake`).
//   - dockerfile.preamble for whatever inner-* shell scripts the cmd.do
//     references, deps, srcs/outs.
package sayt

inject: {
	// BUILDX_BAKE_ENTITLEMENTS_FS=0 disables bake's filesystem-entitlement
	// block — required when an inner-bake's compose graph has
	// additional_contexts pointing outside the compose file's dir
	// (cross-project deps under /monorepo/*). COMPOSE_BAKE=true routes
	// `docker compose --build` through `docker buildx bake` against
	// $BUILDX_BUILDER so x-bake.cache-from / cache-to declarations are
	// honored; without it compose silently falls back to the local daemon
	// driver and rebuilds cold.
	env: {
		BUILDX_BAKE_ENTITLEMENTS_FS: "0"
		COMPOSE_BAKE:                "true"
	}

	// Compose service-level secret sources. Env-sourced uniformly: each
	// secret reads from the named env var on the host invoking compose
	// (the GHA action's $GITHUB_ENV exports, or a local `set -a; . <(nu
	// dind.nu env-file --socat --builder sayt-builder); set +a` shell).
	// No `file:` source anywhere — env vars travel cleanly across
	// host/CI/inception boundaries without tempfile path interpolation.
	// docker_host sources from DOCKER_HOST_TCP rather than DOCKER_HOST so
	// the outer bake CLI's daemon connection isn't hijacked to a tcp
	// endpoint that's unreachable from the macOS host (Docker Desktop's
	// VM-internal IP). Inside the sandbox, var.contents below extracts
	// the value back into the canonical $DOCKER_HOST for the inner
	// docker tooling. Outer process keeps its default daemon socket;
	// sandbox sees the bridged endpoint.
	// ci-style targets spawn an inner `docker compose up integrate`
	// whose graph references bayt-runtime, resolved as a path-context
	// against the outer ci stage's filesystem. The outer stage needs
	// bayt's runtime tree there for that resolution to succeed.
	dockerfile: baytRuntime: true
	dockerfile: secrets: {
		docker_host:               environment: "DOCKER_HOST_TCP"
		buildx_builder:            environment: "BUILDX_BUILDER"
		buildx_instance:           environment: "BUILDX_INSTANCE"
		docker_config:             environment: "DOCKER_AUTH_CONFIG"
		// testcontainers_host — propagated so consumers that compose-up
		// downstream test services (e.g. tracker integrate) can read
		// $TESTCONTAINERS_HOST_OVERRIDE in their service env and tell
		// the testcontainers Java client which host address routes to
		// the spawned containers. dind.nu's `env-file --socat` derives
		// the value from a host-gateway probe; the GHA action's
		// inline equivalent does the same.
		testcontainers_host:       environment: "TESTCONTAINERS_HOST_OVERRIDE"
	}

	// Cmd-level inject: mounts + setup body around the cmd.do invocation.
	// docker_host + buildx_builder are extracted into env vars (consumers
	// like buildx + docker CLI read $DOCKER_HOST / $BUILDX_BUILDER
	// directly). buildx_instance + docker_config are written to their
	// canonical client paths so the in-sandbox CLI sees them as if the
	// user had run `docker buildx create` + `docker login` locally.
	cmd: "builtin": dockerfile: inject: {
		secrets: [
			{id: "docker_host",         var: contents: "DOCKER_HOST"},
			{id: "buildx_builder",      var: contents: "BUILDX_BUILDER"},
			{id: "testcontainers_host", var: contents: "TESTCONTAINERS_HOST_OVERRIDE"},
			// $BUILDX_BUILDER is expanded by the heredoc shell at RUN
			// time — gets the value just exported above via var.contents.
			// Don't hardcode "sayt-builder": GHA setup-buildx-action
			// without an explicit `name:` generates a random builder
			// name (`builder-<uuid>`), which BUILDX_BUILDER then carries.
			// 0600 matches the canonical ~/.docker/config.json +
			// ~/.docker/buildx/instances/<name> permissions. var.path
			// emission uses `cp -p` so the mount mode propagates verbatim.
			{id: "buildx_instance", var: path:     "/root/.docker/buildx/instances/$BUILDX_BUILDER", mode: "0600"},
			{id: "docker_config",   var: path:     "/root/.docker/config.json",                      mode: "0600"},
		]
		defaultSteps: "unix-socket-forward": {
			priority: 10
			pre: """
				if [ -n "$DOCKER_HOST" ] && [ ! -e /var/run/docker.sock ]; then
				  ulimit -n 1048576 2>/dev/null || true
				  addr=${DOCKER_HOST#tcp://}
				  [ -n "$addr" ] || { echo "dindbox: DOCKER_HOST=$DOCKER_HOST has no tcp:// address" >&2; exit 1; }
				  socat -d0 UNIX-LISTEN:/var/run/docker.sock,fork,backlog=1024,reuseaddr "TCP:$addr" &
				  SOCAT_PID=$!
				  trap 'kill $SOCAT_PID 2>/dev/null || true' EXIT INT TERM
				  socat -u OPEN:/dev/null UNIX-CONNECT:/var/run/docker.sock,retry=20,interval=0.2 >/dev/null 2>&1 \\
				    || { echo "dindbox: socat bridge to /var/run/docker.sock not ready" >&2; exit 1; }
				fi
				"""
		}
	}
}
