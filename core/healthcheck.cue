// healthcheck.cue — declarative healthcheck templates that compose into
// targets via CUE unification. Each template fragment:
//   - reads its inputs from `T.healthcheck.{...}` on the target
//   - sets `dockerfile.copy` entries for tool COPY-from
//   - sets `dockerfile.healthcheck` for the Dockerfile HEALTHCHECK directive
//   - sets `compose.healthcheck` for the compose-spec override (carries
//     start_interval, an extension that doesn't fit Dockerfile HEALTHCHECK)
//
// Tool selection avoids image introspection: HTTP and TCP needs always
// COPY from microcheck (tiny static binaries). Service-specific
// templates trust the upstream image's bundled tool. Defaults follow
// "probe aggressively, fail leniently": fast steady interval (1s),
// generous retries (30) so transients don't trip unhealthy. Per-service
// override only when needed — postgres/ollama bump start_period for
// slow cold-starts.
//
// Authoring (user composes via &):
//
//   targets: "release-proxy": sayt.release & bayt.healthcheck.http & {
//     dockerfile: from: name: "caddy:..."
//     healthcheck: { url: "http://127.0.0.1:8081/health" }
//   }
//
// A target without an image takes the check alone, which the host probe
// is derived from:
//
//   targets: ollama: {healthcheck: bayt.healthcheck.#http & {url: "..."}}
//
// Override defaults inline:
//
//   ... & bayt.healthcheck.postgres & {
//     healthcheck: {
//       db:           "${POSTGRES_DB:-appdb}"
//       start_period: "10m"
//     }
//   }
package bayt

healthcheck: {
	// http — HTTP GET status check via microcheck httpcheck.
	#http: {
		// Which check this is, for gen_process_compose's host probe.
		template: "http"
		url: string
		start_interval: *"200ms" | string
		interval:       *"1s"    | string
		timeout:        *"5s"    | string
		retries:        *30      | int
		start_period:   *"30s"   | string
		...
	}
	http: T={
		healthcheck: #http

		dockerfile: {
			// defaultCopy, not copy, so a consumer's own `copy` coexists —
			// see #dockerfile.copy.
			defaultCopy: httpcheck: {
				from:  {name: lock.images.microcheck}
				srcs:  ["/bin/httpcheck"]
				dst:   "/usr/local/bin/httpcheck"
				chmod: "755"
			}
			healthcheck: {
				test:         ["CMD", "httpcheck", T.healthcheck.url]
				interval:     T.healthcheck.interval
				timeout:      T.healthcheck.timeout
				retries:      T.healthcheck.retries
				start_period: T.healthcheck.start_period
			}
		}
		compose: healthcheck: {
			test:           ["CMD", "httpcheck", T.healthcheck.url]
			interval:       T.healthcheck.interval
			timeout:        T.healthcheck.timeout
			retries:        T.healthcheck.retries
			start_period:   T.healthcheck.start_period
			start_interval: T.healthcheck.start_interval
		}
	}

	// tcp — TCP port liveness via microcheck portcheck.
	#tcp: {
		// Which check this is, for gen_process_compose's host probe.
		template: "tcp"
		port: int
		start_interval: *"200ms" | string
		interval:       *"1s"    | string
		timeout:        *"5s"    | string
		retries:        *30      | int
		start_period:   *"30s"   | string
		...
	}
	tcp: T={
		healthcheck: #tcp

		dockerfile: {
			defaultCopy: portcheck: {
				from:  {name: lock.images.microcheck}
				srcs:  ["/bin/portcheck"]
				dst:   "/usr/local/bin/portcheck"
				chmod: "755"
			}
			healthcheck: {
				test:         ["CMD", "portcheck", "--port", "\(T.healthcheck.port)"]
				interval:     T.healthcheck.interval
				timeout:      T.healthcheck.timeout
				retries:      T.healthcheck.retries
				start_period: T.healthcheck.start_period
			}
		}
		compose: healthcheck: {
			test:           ["CMD", "portcheck", "--port", "\(T.healthcheck.port)"]
			interval:       T.healthcheck.interval
			timeout:        T.healthcheck.timeout
			retries:        T.healthcheck.retries
			start_period:   T.healthcheck.start_period
			start_interval: T.healthcheck.start_interval
		}
	}

	// postgres — pg_isready, in the postgres upstream image. Defaults
	// give postgres extra cold-start grace (5m) for a first boot's initdb
	// migrations. Inputs accept compose-spec shell-var defaults like
	// "${POSTGRES_DB:-appdb}" — passed through verbatim.
	#postgres: {
		// Which check this is, for gen_process_compose's host probe.
		template: "postgres"
		db:    *"postgres"  | string
		user:  *"postgres"  | string
		port:  *5432        | int
		host:  *"localhost" | string

		start_interval: *"200ms" | string
		interval:       *"1s"    | string
		timeout:        *"5s"    | string
		retries:        *30      | int
		start_period:   *"5m"    | string
		...
	}
	postgres: T={
		healthcheck: #postgres

		dockerfile: healthcheck: {
			test:         ["CMD", "pg_isready", "-h", T.healthcheck.host, "-p", "\(T.healthcheck.port)", "-d", T.healthcheck.db, "-U", T.healthcheck.user]
			interval:     T.healthcheck.interval
			timeout:      T.healthcheck.timeout
			retries:      T.healthcheck.retries
			start_period: T.healthcheck.start_period
		}
		compose: healthcheck: {
			test:           ["CMD", "pg_isready", "-h", T.healthcheck.host, "-p", "\(T.healthcheck.port)", "-d", T.healthcheck.db, "-U", T.healthcheck.user]
			interval:       T.healthcheck.interval
			timeout:        T.healthcheck.timeout
			retries:        T.healthcheck.retries
			start_period:   T.healthcheck.start_period
			start_interval: T.healthcheck.start_interval
		}
	}

	// redis — redis-cli, in the redis upstream image.
	#redis: {
		// Which check this is, for gen_process_compose's host probe.
		template: "redis"
		start_interval: *"200ms" | string
		interval:       *"1s"    | string
		timeout:        *"5s"    | string
		retries:        *30      | int
		start_period:   *"30s"   | string
		...
	}
	redis: T={
		healthcheck: #redis

		dockerfile: healthcheck: {
			test:         ["CMD-SHELL", "redis-cli ping | grep PONG"]
			interval:     T.healthcheck.interval
			timeout:      T.healthcheck.timeout
			retries:      T.healthcheck.retries
			start_period: T.healthcheck.start_period
		}
		compose: healthcheck: {
			test:           ["CMD-SHELL", "redis-cli ping | grep PONG"]
			interval:       T.healthcheck.interval
			timeout:        T.healthcheck.timeout
			retries:        T.healthcheck.retries
			start_period:   T.healthcheck.start_period
			start_interval: T.healthcheck.start_interval
		}
	}

	// ollama — model-presence check (not just listener up). The default
	// listener answers HTTP before the model is ready, so dependent
	// services connect and time out on first inference. Default
	// start_period is 2m for cold model load.
	#ollama: {
		// Which check this is, for gen_process_compose's host probe.
		template: "ollama"
		model: string

		start_interval: *"200ms" | string
		interval:       *"1s"    | string
		timeout:        *"5s"    | string
		retries:        *30      | int
		start_period:   *"120s"  | string
		...
	}
	ollama: T={
		healthcheck: #ollama

		dockerfile: healthcheck: {
			test:         ["CMD-SHELL", "ollama list | grep -q \(T.healthcheck.model)"]
			interval:     T.healthcheck.interval
			timeout:      T.healthcheck.timeout
			retries:      T.healthcheck.retries
			start_period: T.healthcheck.start_period
		}
		compose: healthcheck: {
			test:           ["CMD-SHELL", "ollama list | grep -q \(T.healthcheck.model)"]
			interval:       T.healthcheck.interval
			timeout:        T.healthcheck.timeout
			retries:        T.healthcheck.retries
			start_period:   T.healthcheck.start_period
			start_interval: T.healthcheck.start_interval
		}
	}
}
