package bayt

_http200Project: #project & {
	name:     "status"
	dir:      "apps/status"
	activate: ""
	targets: {
		ok: healthcheck.http200 & {
			dockerfile: from: null
			healthcheck: {port: 8000, path: "/health", headers: {"X-Health-Token": "Bearer token"}}
			expose: api:    {port: 8000, host: 8400, env: "PORT"}
			entrypoint: do: "server"
		}
		timed: healthcheck.http200 & {
			dockerfile: from:  null
			healthcheck: port: 8001
			entrypoint: do:    "server"
			"process-compose": readiness_probe: period_seconds: 5
		}
		exec: healthcheck.http200 & {
			dockerfile: from:  null
			healthcheck: port: 8002
			entrypoint: do:    "server"
			"process-compose": readiness_probe: exec: command: "bayt microcheck portcheck --port 8002"
		}
		native: healthcheck.http & {
			dockerfile: from:  null
			healthcheck: port: 8003
			entrypoint: do:    "server"
			"process-compose": readiness_probe: http_get: {host: "127.0.0.1", port: "8003", path: "/up"}
		}
		partial: healthcheck.http200 & {
			dockerfile: from:  null
			healthcheck: port: 8004
			entrypoint: do:    "server"
			"process-compose": readiness_probe: http_get: path: "/up"
		}
		live: healthcheck.http200 & {
			dockerfile: from:  null
			healthcheck: port: 8005
			entrypoint: do:    "server"
			"process-compose": liveness_probe: exec: command: "bayt microcheck httpcheck http://localhost:8005/"
		}
	}
}
_http200Procs: (#processComposeGen & {project: _http200Project, depManifests: {}}).file.processes
_http200Procs: ok: readiness_probe: http_get: close({scheme: "http", host: "127.0.0.1", port: "${OK_API_PORT:-8400}", path: "/health", status_code: 200, headers: "X-Health-Token": "Bearer token"})
// A timing-only override must retain the check, or process-compose refuses startup.
_http200Procs: timed: readiness_probe: close({http_get: {scheme: "http", host: "127.0.0.1", port: "8001", path: "/", status_code: 200}, period_seconds: 5, timeout_seconds: 5, failure_threshold: 60})
_http200Procs: partial: readiness_probe: http_get: close({scheme: "http", host: "127.0.0.1", port: "8004", path: "/up", status_code: 200})
_http200Kinds: {for n in ["ok", "timed", "exec", "native", "partial", "live"] {(n): [for k, _ in _http200Procs[n].readiness_probe if k == "exec" || k == "http_get" {k}]}}
_http200Kinds: {ok: ["http_get"], timed: ["http_get"], exec: ["exec"], native: ["http_get"], partial: ["http_get"], live: ["http_get"]}
_http200Deps:  {for n in ["ok", "native", "exec", "live"] {(n): [if _http200Procs[n].depends_on != _|_ for k, _ in _http200Procs[n].depends_on {k}]}}
_http200Procs: "bayt:httpcheck": entrypoint: ["bayt", "microcheck", "httpcheck", "--help"]
_http200Procs: "bayt:portcheck": entrypoint: ["bayt", "microcheck", "portcheck", "--help"]
_http200Deps: {ok: [], native: [], exec: ["bayt:portcheck"], live: ["bayt:httpcheck"]}
Tests: http200: [_http200Procs, _http200Kinds, _http200Deps]
