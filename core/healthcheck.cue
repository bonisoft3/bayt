// healthcheck.cue — declarative healthcheck templates that compose into
// targets via CUE unification. Each template fragment:
//   - reads its inputs from `T.healthcheck.{...}` on the target
//   - sets `dockerfile.copy` entries for tool COPY-from
//   - sets `dockerfile.healthcheck` for the Dockerfile HEALTHCHECK directive
//   - sets `compose.healthcheck` for the compose-spec override (carries
//     start_interval, an extension that doesn't fit Dockerfile HEALTHCHECK)
//
// Tool selection avoids image introspection: Legacy HTTP and TCP checks
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

import (
	"list"
	"strings"
)

healthcheck: {
	// http — HTTP GET status check via microcheck httpcheck.
	#http: {
		// Which check this is, for gen_process_compose's host probe.
		template: "http"
		scheme:   *"http" | "https"
		host:     *"127.0.0.1" | string
		port?:    int & >0 & <65536
		path:     *"/" | string
		if port != _|_ {
			url: *"\(scheme)://\(host):\(port)\(path)" | string
		}
		url:            string
		authorization:  *null | string
		headers:        *[] | [...string]
		start_interval: *"200ms" | string
		interval:       *"1s" | string
		timeout:        *"5s" | string
		retries:        *30 | int
		start_period:   *"30s" | string
		...
	}
	http: {
		healthcheck: #http
		let _hc = healthcheck

		let _authHeader = [if _hc.authorization != null {
			let val = _hc.authorization
			let auth = [if strings.Contains(val, " ") {val}, "Bearer \(val)"][0]
			"Authorization: \(auth)"
		}]
		let _allHeaders = list.Concat([_authHeader, _hc.headers])
		let _headerArgs = [for h in _allHeaders for x in ["-H", h] {x}]
		let _cmd = list.Concat([["CMD", "httpcheck"], _headerArgs, [_hc.url]])

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
				test:         *_cmd | [...string]
				interval:     *_hc.interval | string
				timeout:      *_hc.timeout | string
				retries:      *_hc.retries | int
				start_period: *_hc.start_period | string
			}
		}
		compose: healthcheck: {
			test:           *_cmd | _
			interval:       *_hc.interval | string
			timeout:        *_hc.timeout | string
			retries:        *_hc.retries | int
			start_period:   *_hc.start_period | string
			start_interval: *_hc.start_interval | string
		}
	}

	// A GET whose final response headers carry exactly 200, without reading the body.
	#http200: {
		template: "http200"
		scheme:   *"http" | "https"
		host:     *"127.0.0.1" | string
		port:     int & >0 & <65536
		path:     *"/" | =~"^/"
		url:      "\(scheme)://\(host):\(port)\(path)"
		headers:  *{} | {[=~"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$" & !~"(?i)^(host|content-length|transfer-encoding|trailer|authorization|proxy-authorization|www-authenticate|cookie|cookie2)$"]: string & !~"[\\r\\n]"}
		let names = {for k, _ in headers {(strings.ToLower(k)): true}}
		_uniqueHeaders: (len(names) == len(headers)) & true
		start_interval: *"200ms" | string
		interval:       *"1s" | string
		// Native process-compose measures its deadline in whole seconds.
		timeout:      *"5s" | =~"^[1-9][0-9]*s$"
		retries:      *30 | int
		start_period: *"30s" | string
	}
	http200: {
		healthcheck: #http200
		let hc = healthcheck
		let prefix = "/usr/local/lib/bayt/http200"
		let args = list.Concat([
			["CMD", "\(prefix)/busybox", "sh", "-ec", #"export CURL_CA_BUNDLE="${SSL_CERT_FILE:-/usr/local/lib/bayt/http200/ca.pem}"; status=$("$@"); [ "$status" = 200 ] || { printf 'HTTP status %s, expected 200\n' "$status" >&2; exit 1; }"#, "http200", "\(prefix)/curl", "--disable", "--silent", "--show-error", "--head", "--request", "GET", "--location", "--max-redirs", "9", "--max-time", strings.TrimSuffix(hc.timeout, "s"), "--proto", "=http,https", "--proto-redir", "=http,https", "--output", "/dev/null", "--write-out", "%{http_code}"],
			[for k, v in hc.headers for a in ["--header", "\(k): \(v)"] {a}],
			[hc.url],
		])
		dockerfile: {
			defaultCopy: {
				"http200-curl":  {from: name: lock.images.lazybox, srcs: ["/lazybox/libexec/static-curl"], dst: "\(prefix)/curl", chmod: "755"}
				"http200-ca":    {from: name: lock.images.lazybox, srcs: ["/lazybox/share/ca-certificates/ca-certificates.crt"], dst: "\(prefix)/ca.pem"}
				"http200-shell": {from: name: lock.images.busybox, srcs: ["/bin/busybox"], dst: "\(prefix)/busybox", chmod: "755"}
			}
			healthcheck: {
				test:         *args | [...string]
				interval:     *hc.interval | string
				timeout:      *hc.timeout | string
				retries:      *hc.retries | int
				start_period: *hc.start_period | string
			}
		}
		compose: healthcheck: {
			test:           *[for a in args {strings.Replace(a, "$", "$$", -1)}] | _
			interval:       *hc.interval | string
			timeout:        *hc.timeout | string
			retries:        *hc.retries | int
			start_period:   *hc.start_period | string
			start_interval: *hc.start_interval | string
		}
	}

	// tcp — TCP port liveness via microcheck portcheck.
	#tcp: {
		// Which check this is, for gen_process_compose's host probe.
		template:       "tcp"
		port:           int
		start_interval: *"200ms" | string
		interval:       *"1s" | string
		timeout:        *"5s" | string
		retries:        *30 | int
		start_period:   *"30s" | string
		...
	}
	tcp: {
		healthcheck: #tcp
		let _hc = healthcheck

		dockerfile: {
			defaultCopy: portcheck: {
				from:  {name: lock.images.microcheck}
				srcs:  ["/bin/portcheck"]
				dst:   "/usr/local/bin/portcheck"
				chmod: "755"
			}
			healthcheck: {
				test:         *["CMD", "portcheck", "--port", "\(_hc.port)"] | [...string]
				interval:     *_hc.interval | string
				timeout:      *_hc.timeout | string
				retries:      *_hc.retries | int
				start_period: *_hc.start_period | string
			}
		}
		compose: healthcheck: {
			test:           *["CMD", "portcheck", "--port", "\(_hc.port)"] | _
			interval:       *_hc.interval | string
			timeout:        *_hc.timeout | string
			retries:        *_hc.retries | int
			start_period:   *_hc.start_period | string
			start_interval: *_hc.start_interval | string
		}
	}

	// postgres — pg_isready, in the postgres upstream image. Defaults
	// give postgres extra cold-start grace (5m) for a first boot's initdb
	// migrations. Inputs accept compose-spec shell-var defaults like
	// "${POSTGRES_DB:-appdb}" — passed through verbatim.
	#postgres: {
		// Which check this is, for gen_process_compose's host probe.
		template: "postgres"
		db:       *"postgres" | string
		user:     *"postgres" | string
		port:     *5432 | int
		host:     *"localhost" | string

		start_interval: *"200ms" | string
		interval:       *"1s" | string
		timeout:        *"5s" | string
		retries:        *30 | int
		start_period:   *"5m" | string
		...
	}
	postgres: {
		healthcheck: #postgres
		let _hc = healthcheck

		dockerfile: healthcheck: {
			test:         *["CMD", "pg_isready", "-h", _hc.host, "-p", "\(_hc.port)", "-d", _hc.db, "-U", _hc.user] | [...string]
			interval:     *_hc.interval | string
			timeout:      *_hc.timeout | string
			retries:      *_hc.retries | int
			start_period: *_hc.start_period | string
		}
		compose: healthcheck: {
			test:           *["CMD", "pg_isready", "-h", _hc.host, "-p", "\(_hc.port)", "-d", _hc.db, "-U", _hc.user] | _
			interval:       *_hc.interval | string
			timeout:        *_hc.timeout | string
			retries:        *_hc.retries | int
			start_period:   *_hc.start_period | string
			start_interval: *_hc.start_interval | string
		}
	}

	// redis — redis-cli, in the redis upstream image.
	#redis: {
		// Which check this is, for gen_process_compose's host probe.
		template:       "redis"
		start_interval: *"200ms" | string
		interval:       *"1s" | string
		timeout:        *"5s" | string
		retries:        *30 | int
		start_period:   *"30s" | string
		...
	}
	redis: {
		healthcheck: #redis
		let _hc = healthcheck

		dockerfile: healthcheck: {
			test:         *["CMD-SHELL", "redis-cli ping | grep PONG"] | [...string]
			interval:     *_hc.interval | string
			timeout:      *_hc.timeout | string
			retries:      *_hc.retries | int
			start_period: *_hc.start_period | string
		}
		compose: healthcheck: {
			test:           *["CMD-SHELL", "redis-cli ping | grep PONG"] | _
			interval:       *_hc.interval | string
			timeout:        *_hc.timeout | string
			retries:        *_hc.retries | int
			start_period:   *_hc.start_period | string
			start_interval: *_hc.start_interval | string
		}
	}

	// ollama — model-presence check (not just listener up). The default
	// listener answers HTTP before the model is ready, so dependent
	// services connect and time out on first inference. Default
	// start_period is 2m for cold model load.
	#ollama: {
		// Which check this is, for gen_process_compose's host probe.
		template: "ollama"
		model:    string

		start_interval: *"200ms" | string
		interval:       *"1s" | string
		timeout:        *"5s" | string
		retries:        *30 | int
		start_period:   *"120s" | string
		...
	}
	ollama: {
		healthcheck: #ollama
		let _hc = healthcheck

		dockerfile: healthcheck: {
			test:         *["CMD-SHELL", "ollama list | grep -q \(_hc.model)"] | [...string]
			interval:     *_hc.interval | string
			timeout:      *_hc.timeout | string
			retries:      *_hc.retries | int
			start_period: *_hc.start_period | string
		}
		compose: healthcheck: {
			test:           *["CMD-SHELL", "ollama list | grep -q \(_hc.model)"] | _
			interval:       *_hc.interval | string
			timeout:        *_hc.timeout | string
			retries:        *_hc.retries | int
			start_period:   *_hc.start_period | string
			start_interval: *_hc.start_interval | string
		}
	}
}
