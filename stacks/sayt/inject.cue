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
//   as tcp://<gateway-ip>:<port>              BUILDX_BUILDER= sayt-builder
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

import "github.com/bonisoft3/bayt/core:bayt"

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
	// against the outer ci stage's filesystem. The outer stage gets
	// bayt's runtime tree through this copy entry — `image:` overrides
	// the additional_contexts value so the fixed `bayt-runtime` key
	// resolves to the pinned digest.
	dockerfile: defaultPreamble: {
		"bayt-runtime": {priority: -6, copy: {
			from: {name: "bayt", image: bayt.lock.images.bayt}
			srcs: ["runtime"]
			dst: "/monorepo/plugins/bayt/runtime"
		}}
		"bayt-path": {priority: -5, line: "ENV PATH=/monorepo/plugins/bayt/runtime:${PATH}"}
	}
	dockerfile: secrets: {
		docker_host:               environment: "DOCKER_HOST_TCP"
		buildx_builder:            environment: "BUILDX_BUILDER"
		buildx_instance:           environment: "BUILDX_INSTANCE"
		docker_config:             environment: "DOCKER_AUTH_CONFIG"
		// testcontainers_host — the host address that routes to spawned
		// containers' published ports. The docker gateway address works
		// from every sandbox topology (host-netns and bridged builders
		// alike), so dind.nu derives it host-side via its gateway-ip
		// probe when the caller doesn't set one.
		testcontainers_host:       environment: "TESTCONTAINERS_HOST_OVERRIDE"
		// cache_scope + cache_scope_fallback — pre-composed scope
		// identifiers. Dumb transport: the host decides the inner's
		// builder when it injects BUILDX_INSTANCE, so the host
		// composes the matching scope (sayt's integrate.nu). Never
		// derive these in-sandbox.
		cache_scope:               environment: "CACHE_SCOPE"
		cache_scope_fallback:      environment: "CACHE_SCOPE_FALLBACK"
		// sayt_buildkit_syntax — external dockerfile frontend pin; the
		// inner bake applies it via the BUILDKIT_SYNTAX build-arg.
		// Empty → the builder's built-in frontend.
		sayt_buildkit_syntax:      environment: "BUILDKIT_SYNTAX"
		// SAYT_NO_CACHE — when truthy, propagates `--no-cache` to the
		// inner bake (suppresses both cache-from import and cache-to
		// export). Set by integrate.nu --no-cache. Useful for forcing
		// cold builds when chasing chain-ID drift or poisoned cache
		// entries.
		sayt_no_cache:             environment: "SAYT_NO_CACHE"
		// bayt_image_tag / bayt_pull_policy — the host decides image
		// tag and pull policy; the inner compose interpolates the same
		// refs the warmup pushed. Empty → latest, build.
		bayt_image_tag:            environment: "BAYT_IMAGE_TAG"
		bayt_pull_policy:          environment: "BAYT_PULL_POLICY"
		// SAYT_NO_CACHE_FROM / SAYT_NO_CACHE_TO — when truthy, the inner
		// bake skips cache import (--set "*.cache-from=") / export (--set
		// "*.cache-to="). Set by integrate.nu --no-cache-from / --no-cache-to:
		// single-writer cache discipline — the warmup writes, every other bake
		// reads; or skip reads when a stale/unauthed cache must be bypassed.
		sayt_no_cache_from:        environment: "SAYT_NO_CACHE_FROM"
		sayt_no_cache_to:          environment: "SAYT_NO_CACHE_TO"
		// depot_token / depot_project_id — credentials for the inner bake's
		// depot path. Build secrets (not ENV) so the token never lands in a layer.
		depot_token:               environment: "DEPOT_TOKEN"
		depot_project_id:          environment: "DEPOT_PROJECT_ID"
		depot_org_id:              environment: "DEPOT_ORG_ID"
		// depot_disable_otel — integrate.nu sets DEPOT_DISABLE_OTEL=1; injected
		// here so the inner `depot bake` doesn't abort on the OTEL schema clash
		// from the trace-context vars depot's builder puts in RUN steps.
		depot_disable_otel:        environment: "DEPOT_DISABLE_OTEL"
		// actions_results_url / actions_runtime_token — url + token for
		// buildkit's `gha` cache backend, which reads them from the
		// environment unless its attrs carry them. Only a workflow context
		// populates them; without them the backend addresses the
		// decommissioned cache service v1. Secrets rather than ENV so the
		// per-run token stays out of layers and out of RUN cache keys.
		actions_results_url:       environment: "ACTIONS_RESULTS_URL"
		actions_runtime_token:     environment: "ACTIONS_RUNTIME_TOKEN"
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
			{id: "cache_scope",          var: contents: "CACHE_SCOPE"},
			{id: "cache_scope_fallback", var: contents: "CACHE_SCOPE_FALLBACK"},
			{id: "sayt_buildkit_syntax", var: contents: "BUILDKIT_SYNTAX"},
			{id: "sayt_no_cache",        var: contents: "SAYT_NO_CACHE"},
			{id: "bayt_image_tag",       var: contents: "BAYT_IMAGE_TAG"},
			{id: "bayt_pull_policy",     var: contents: "BAYT_PULL_POLICY"},
			{id: "sayt_no_cache_from",   var: contents: "SAYT_NO_CACHE_FROM"},
			{id: "sayt_no_cache_to",     var: contents: "SAYT_NO_CACHE_TO"},
			{id: "depot_token",          var: contents: "DEPOT_TOKEN"},
			{id: "depot_project_id",     var: contents: "DEPOT_PROJECT_ID"},
			{id: "depot_org_id",         var: contents: "DEPOT_ORG_ID"},
			{id: "depot_disable_otel",   var: contents: "DEPOT_DISABLE_OTEL"},
			{id: "actions_results_url",  var: contents: "ACTIONS_RESULTS_URL"},
			{id: "actions_runtime_token", var: contents: "ACTIONS_RUNTIME_TOKEN"},
			// Keep the instance as contents and install it in a guarded pre-step.
			// The static secret list keeps this RUN cache-compatible with every
			// capability set, while empty builder credentials remain a no-op.
			{id: "buildx_instance", var: contents: "BUILDX_INSTANCE"},
			// path writes config.json for this CLI; contents re-exports
			// DOCKER_AUTH_CONFIG so a nested compose-up re-derives the creds.
			{id: "docker_config",   var: {contents: "DOCKER_AUTH_CONFIG", path: "/root/.docker/config.json"}, mode: "0600"},
		]
		defaultSteps: "unix-socket-forward": {
			priority: 10
			pre: """
				if [ -n "$DOCKER_HOST" ] && [ ! -e /var/run/docker.sock ]; then
				  ulimit -n 1048576 2>/dev/null || true
				  addr=${DOCKER_HOST#tcp://}
				  [ -n "$addr" ] || { echo "dindbox: DOCKER_HOST=$DOCKER_HOST has no tcp:// address" >&2; exit 1; }
				  socat -d0 UNIX-LISTEN:/var/run/docker.sock,fork,backlog=1024,reuseaddr "TCP:$addr,keepalive,keepidle=30,keepintvl=15,keepcnt=4" &
				  SOCAT_PID=$!
				  trap 'kill $SOCAT_PID 2>/dev/null || true' EXIT INT TERM
				  socat -u OPEN:/dev/null UNIX-CONNECT:/var/run/docker.sock,retry=20,interval=0.2 >/dev/null 2>&1 \\
				    || { echo "dindbox: socat bridge to /var/run/docker.sock not ready" >&2; exit 1; }
				fi
				"""
		}
		defaultSteps: "buildx-instance": {
			priority: 11
			pre: """
				if [ -n "$BUILDX_BUILDER" ] && [ -n "$BUILDX_INSTANCE" ]; then
				  install -d -m 0700 /root/.docker/buildx/instances
				  printf '%s' "$BUILDX_INSTANCE" > "/root/.docker/buildx/instances/$BUILDX_BUILDER"
				  chmod 0600 "/root/.docker/buildx/instances/$BUILDX_BUILDER"
				fi
				"""
		}
	}
}
