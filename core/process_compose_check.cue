package bayt

import (
	"list"
	"strings"
)

// One cluster in every projection: a database, a gateway on a host toolchain
// the image lacks, and a check that waits on the gateway.
_proc_project: #project & {
	name:     "native"
	dir:      "apps/native"
	activate: ""
	targets: {
		database: healthcheck.postgres & {
			healthcheck: db: "app"
			expose: pg: port: 5432
			// The image's own wrapper does initdb and drops root; lifted, it is
			// the entrypoint on both sides.
			entrypoint: do: "docker-entrypoint.sh postgres"
			dockerfile: from: name: "postgres:18"
			compose: {}
		}
		crud: healthcheck.http & {
			healthcheck: url: "http://127.0.0.1:3001/ready"
			expose: {
				// Pinned where people type it; run mode still moves it.
				http: {port: 3000, env: "PGRST_SERVER_PORT", host: 3300}
				admin: {port: 3001, env: "PGRST_ADMIN_SERVER_PORT"}
			}
			entrypoint: {
				do: "postgrest"
				env: {
					PGRST_DB_URI: "postgres://u:p@database:5432/app"
					// A whole value naming a peer is a host; a word inside one is not.
					DB_HOST: "database"
					DB_NOTE: "database migrations ran"
					// A dotted hostname ending in a target's name is not the peer.
					MIRROR: "mirror.database:5432"
					// Under a key naming no host, a target's name is just a word.
					DB_NAME: "database"
					// A process names its own ports on loopback; they move too.
					SELF: "http://localhost:3000/rpc"
					// An image tag and a password are not addresses.
					CACHE_IMAGE: "database:18-alpine"
					// ...not even on a port the peer exposes.
					PG_IMAGE: "database:5432-alpine"
					DB_ADDR:  "database"
					// An address inside parentheses, as Go's MySQL DSN writes one.
					GO_DSN: "u:p@tcp(database:5432)/app"
					// A key ending in letters that spell a host is not a host key.
					OBSERVER:  "database"
					ADMIN_DSN: "postgres://database:1234@127.0.0.1:5432/app"
				}
				after: database: "healthy"
			}
			deps: [":database:outs"]
			"process-compose": {
				activate:    "mise x postgrest@14 --"
				working_dir: "backend"
			}
			dockerfile: from: name: "postgrest/postgrest:v12"
			compose: {}
			taskfile: {}
		}
		// A process with work of its own: its build still runs as a go-task
		// dep of whatever waits on it.
		worker: {
			taskfile: {}
			cmd: builtin: do: "go build -o bin/worker"
			// An image tag in a command is not an address either.
			entrypoint: do: "./bin/worker --image database:18"
		}
		// Valid compose a host parser would refuse, on a target that never runs
		// on the host.
		door: healthcheck.http & {
			healthcheck: {url: "http://[::1]:8080/health", interval: "1m30s"}
			dockerfile: from: name: "caddy:2"
		}
		// Built incrementally: the image runs its build, `default`, which is
		// never a supervisor.
		inc: {
			taskfile: {}
			entrypoint: do: "./bin/inc"
			dockerfile: {
				from: name: "alpine:3"
				incremental: true
			}
		}
		// Containers each have their own network: two on port 80 is no clash,
		// and a process only its image runs meets none of the host's checks.
		web: {
			expose: http: port: 80
			entrypoint: {do: "nginx", host: false}
			dockerfile: from: name: "nginx:1"
			compose: {}
		}
		api: {
			expose: http: port: 80
			entrypoint: {do: "nginx", host: false}
			dockerfile: from: name: "nginx:1"
			compose: {}
		}
		// A Dockerfile entrypoint equal to the sugar's is one process, emitted once.
		pinned: {
			entrypoint: do: "postgrest"
			dockerfile: {
				from: name: "postgrest/postgrest:v12"
				entrypoint: ["postgrest"]
			}
		}
		integrate: {
			taskfile: {}
			deps: [":crud", ":worker"]
			entrypoint: {
				do:    "deno run check.ts ${CRUD_URL}"
				shell: "sh"
				env: {
					CRUD_URL: "http://native-crud:3000/x"
					// A host and its port key, both naming crud, whose port moves.
					CRUD_HOST: "crud"
					CRUD_PORT: "3000"
				}
				after: crud: "healthy"
			}
		}
	}
}

_proc_ref: {
	// No `env` to carry it: the port keeps its number on the host.
	pg:   "5432"
	http: "${CRUD_HTTP_PORT:-3300}"
	admin: (_hostPort & {project: "native", target: "crud", name: "admin", port: {port: 3001, env: "X"}}).out
}

// One instance for every assertion: each costs a full evaluation.
_proc_gen: #processComposeGen & {project: _proc_project, depManifests: {}}
_proc: _proc_gen.file.processes

// The host runs the host toolchain, names every port by its variable, and
// reaches peers on loopback under both spellings compose resolves.
_proc: crud: {
	entrypoint: ["mise", "x", "postgrest@14", "--", "postgrest"]
	working_dir: "backend"
	environment: [
		"ADMIN_DSN=postgres://database:1234@127.0.0.1:5432/app",
		"CACHE_IMAGE=database:18-alpine",
		"DB_ADDR=127.0.0.1",
		"DB_HOST=127.0.0.1",
		"DB_NAME=database",
		"DB_NOTE=database migrations ran",
		"GO_DSN=u:p@tcp(127.0.0.1:5432)/app",
		"MIRROR=mirror.database:5432",
		"OBSERVER=database",
		"PGRST_ADMIN_SERVER_PORT=\(_proc_ref.admin)",
		"PGRST_DB_URI=postgres://u:p@127.0.0.1:\(_proc_ref.pg)/app",
		"PGRST_SERVER_PORT=\(_proc_ref.http)",
		"PG_IMAGE=database:5432-alpine",
		"SELF=http://localhost:\(_proc_ref.http)/rpc",
	]
	depends_on: close({
		database: condition:         "process_healthy"
		"crud:build": condition:     "process_completed_successfully"
		"bayt:httpcheck": condition: "process_completed_successfully"
	})
	availability: exit_on_skipped: true
	readiness_probe: {
		exec: command: "\(_microcheckHost) httpcheck http://127.0.0.1:\(_proc_ref.admin)/ready"
		period_seconds: 1
		// 30 retries plus the 30s start window at 1s.
		failure_threshold: 60
	}
}
_proc: database: readiness_probe: exec: command: "pg_isready -h localhost -p \(_proc_ref.pg) -d app -U postgres"
_proc: integrate: {
	// The process's own shell expands its variables, not process-compose.
	entrypoint: ["sh", "-c", "deno run check.ts $${CRUD_URL}"]
	environment: [
		"CRUD_HOST=127.0.0.1",
		"CRUD_PORT=\(_proc_ref.http)",
		"CRUD_URL=http://127.0.0.1:\(_proc_ref.http)/x",
	]
}

// The build stays the `default` task dependents reach, and no other task
// exists: the stack runs it as a one-shot its process waits on, beside the
// microcheck install its probe needs.
_proc_tf: (#taskfileGen & {project: _proc_project, depManifests: {}}).files.integrate.tasks
_proc_tf: default: deps: ["::bayt:crud", "::bayt:worker"]
_proc_tf: {[!~"^default$"]: _|_}
_proc_file: _proc_gen.file
_proc_file: {ordered_shutdown: true, environment: ["MISE_LOCKED=0"]}
_proc: "integrate:build": entrypoint: ["task", "-t", ".bayt/Taskfile.yml", "bayt:integrate"]
_proc: "bayt:httpcheck": entrypoint: ["bayt", "microcheck", "httpcheck", "--help"]
_proc: integrate: depends_on: close({
	crud: condition:              "process_healthy"
	"integrate:build": condition: "process_completed_successfully"
})

// A container's process starts from what its image baked in, never under the
// project's toolchain prefix a runtime image cannot run.
_proc_container: (_containerArgv & {t: {activate: "mise x --", entrypoint: {do: "postgres", shell: "exec"}}}).out
_proc_container: ["postgres"]

_proc_pinned: strings.Count(_proc_docker.dockerfiles.pinned, "ENTRYPOINT") & 1

// The entrypoint's waits are edges of bake's runtime walk too.
_proc_bake: list.Contains((#bakeGen & {project: _proc_project, depManifests: {}})._rtEdges["native-crud"], "native-database") & true

_proc_inc: strings.Contains(_proc_docker.dockerfiles.inc, "\"bayt:inc\"]") & true

// The toolchain wraps the shell, so every command of a compound `do` runs
// under it, not only the first.
_proc_argv: (_argv & {do: "a; b", shell: "sh", activate: "mise x --"}).out
_proc_argv: ["mise", "x", "--", "sh", "-c", "a; b"]

// Go's composite durations, rounded up and never below a second.
_proc_seconds: [for d in ["1m30s", "1.5s", "200ms", "0s", "0"] {(_seconds & {in: d}).out}]
_proc_seconds: [90, 2, 1, 1, 1]

// The container keeps canonical ports and the image's toolchain, and waits
// on its peer by service name.
_proc_docker: #dockerComposeGen & {project: _proc_project, depManifests: {}}
_proc_dockerfile:        _proc_docker.dockerfiles.crud
_proc_dockerfile_ep:     strings.Contains(_proc_dockerfile, "ENTRYPOINT [\"postgrest\"]") & true
_proc_dockerfile_expose: strings.Contains(_proc_dockerfile, "EXPOSE 3000\nEXPOSE 3001") & true
_proc_bayt_scope:        strings.Contains(_proc_dockerfile, ".bayt/process-compose.yaml") & true
_proc_docker: compose: files: crud: services: "native-crud": {
	environment: {
		PGRST_DB_URI:            "postgres://u:p@database:5432/app"
		DB_HOST:                 "database"
		DB_NOTE:                 "database migrations ran"
		MIRROR:                  "mirror.database:5432"
		DB_NAME:                 "database"
		SELF:                    "http://localhost:3000/rpc"
		CACHE_IMAGE:             "database:18-alpine"
		PG_IMAGE:                "database:5432-alpine"
		DB_ADDR:                 "database"
		GO_DSN:                  "u:p@tcp(database:5432)/app"
		OBSERVER:                "database"
		ADMIN_DSN:               "postgres://database:1234@127.0.0.1:5432/app"
		PGRST_SERVER_PORT:       "3000"
		PGRST_ADMIN_SERVER_PORT: "3001"
	}
	depends_on: "native-database": {condition: "service_healthy", restart: true}
}

// A target without an image takes a template's check alone, and the host
// probe is derived from it.
_proc_bare_checks: healthcheck
_proc_bare_project: #project & {
	name:     "bare"
	dir:      "apps/bare"
	activate: ""
	targets: gpu: {
		expose: api: port: 11434
		healthcheck: _proc_bare_checks.#http & {url: "http://localhost:11434/api/tags"}
		entrypoint: do:                 "ollama serve"
		"process-compose": working_dir: "models"
	}
}
_proc_bare: (#processComposeGen & {project: _proc_bare_project, depManifests: {}}).file.processes.gpu
_proc_bare: readiness_probe: exec: command: "\(_microcheckHost) httpcheck http://localhost:11434/api/tags"
_proc_bare_image: len((#dockerComposeGen & {project: _proc_bare_project, depManifests: {}}).dockerfiles) & 0

// In-tree, bayt is spelled from where each command runs: the one-shot from the
// project directory, a probe from its process's working_dir.
_proc_rt: (#processComposeGen & {project: _proc_bare_project, depManifests: {}, runtime: "plugins/bayt"}).file.processes
_proc_rt: "bayt:httpcheck": entrypoint: ["mise", "tool-stub", "../../plugins/bayt/runtime/nu.toml", "../../plugins/bayt/runtime/bayt.nu", "microcheck", "httpcheck", "--help"]
_proc_rt: gpu: readiness_probe: exec: command: "mise tool-stub ../../../plugins/bayt/runtime/nu.toml ../../../plugins/bayt/runtime/bayt.nu microcheck httpcheck http://localhost:11434/api/tags"

Tests: process_compose: {
	host:    _proc
	task:    _proc_tf
	file:    _proc_file
	runtime: _proc_rt
	seconds: _proc_seconds
	argv:    _proc_argv
	container: [_proc_container, _proc_inc, _proc_pinned, _proc_bake]
	door: _proc_docker.dockerfiles.door
	dockerfile: [_proc_dockerfile_ep, _proc_dockerfile_expose, _proc_bayt_scope]
	compose: _proc_docker.compose.files.crud.services."native-crud"
	bare: [_proc_bare, _proc_bare_image]
}
