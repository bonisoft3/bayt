// capabilities_check.cue — exercises capability fragments. Each
// capability is a plain struct value the user unifies into a target;
// these checks verify the wiring lands in the right output blocks
// (cmd mounts, dockerfile.secrets, dockerfile.incremental) and that
// orthogonal capabilities compose without conflict.
package bayt

// --- CAP1: hostenv wires the secret on cmd-level mounts AND
// dockerfile.secrets. Both ends are needed: cmd-level for the
// BuildKit `RUN --mount=type=secret`, dockerfile.secrets for the
// federated compose `secrets:` block.
_cap1: #project & {
	name: "cap1"
	dir:  "test/cap1"
	targets: {
		"integrate": hostenv & {
			dockerfile: nubox
			cmd: "builtin": do: "./gradlew integrationTest"
		}
	}
}
_cap1: targets: integrate: cmd: "builtin": dockerfile: mounts: [
	{type: "secret", id: "host.env", required: true},
]
_cap1: targets: integrate: dockerfile: secrets: ["host.env"]

// --- CAP2: hostenv composes with user-supplied wrap + compose runtime
// extras (the dind.sh dogfood pattern documented in capabilities.cue).
_cap2: #project & {
	name: "cap2"
	dir:  "test/cap2"
	targets: {
		"integrate": hostenv & {
			dockerfile: nubox
			cmd: "builtin": {
				do: "./gradlew integrationTest"
				dockerfile: wrap: "/monorepo/plugins/devserver/dind.sh"
			}
			compose: runtime: {
				entrypoint:   ["/monorepo/plugins/devserver/dind.sh"]
				network_mode: "host"
				volumes: [
					"/var/run/docker.sock:/var/run/docker.sock",
				]
			}
		}
	}
}
_cap2: targets: integrate: cmd: "builtin": dockerfile: wrap: "/monorepo/plugins/devserver/dind.sh"
_cap2: targets: integrate: compose: runtime: network_mode:    "host"
_cap2: targets: integrate: dockerfile: secrets:               ["host.env"]

// --- CAP3: incremental flips the dockerfile.incremental flag. The
// emitter rewrites the RUN line to `task <name>:<name>` and stages
// .bayt/ into the image (see gen_compose.cue).
_cap3: #project & {
	name: "cap3"
	dir:  "test/cap3"
	targets: {
		"build": incremental & {
			dockerfile: nubox
			cmd: "builtin": do: "./gradlew assemble"
		}
	}
}
_cap3: targets: build: dockerfile: incremental: true

// --- CAP4: incremental + hostenv compose without conflict — different
// output blocks (incremental → dockerfile.incremental, hostenv →
// dockerfile.secrets + cmd mounts).
_cap4: #project & {
	name: "cap4"
	dir:  "test/cap4"
	targets: {
		"integrate": hostenv & incremental & {
			dockerfile: nubox
			cmd: "builtin": do: "./gradlew integrationTest"
		}
	}
}
_cap4: targets: integrate: dockerfile: incremental: true
_cap4: targets: integrate: dockerfile: secrets:     ["host.env"]
_cap4: targets: integrate: cmd: "builtin": dockerfile: mounts: [
	{type: "secret", id: "host.env", required: true},
]

// Public aggregator forces evaluation of the hidden _cap* bindings.
Tests: capabilities: {
	cap1: _cap1
	cap2: _cap2
	cap3: _cap3
	cap4: _cap4
}
