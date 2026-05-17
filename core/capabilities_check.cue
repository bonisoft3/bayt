// capabilities_check.cue — exercises capability fragments. Each
// capability is a plain struct value the user unifies into a target;
// these checks verify the wiring lands in the right output blocks
// (cmd mounts, dockerfile.secrets, dockerfile.incremental) and that
// orthogonal capabilities compose without conflict.
package bayt

// --- CAP1: a target declaring a build-time secret wires both ends:
// cmd-level `mounts` for the BuildKit `RUN --mount=type=secret` AND
// `dockerfile.secrets` for the federated compose `secrets:` block.
_cap1: #project & {
	name: "cap1"
	dir:  "test/cap1"
	targets: {
		"integrate": {
			dockerfile: nubox & {
				secrets: "creds": null
			}
			cmd: "builtin": {
				do: "./gradlew integrationTest"
				dockerfile: mounts: [
					{type: "secret", id: "creds", required: true},
				]
			}
		}
	}
}
_cap1: targets: integrate: cmd: "builtin": dockerfile: mounts: [
	{type: "secret", id: "creds", required: true},
]
_cap1: targets: integrate: dockerfile: secrets: "creds": null

// --- CAP2: a build-time secret composes with a cmd `wrap` and
// compose runtime extras (volumes, network_mode) without conflict.
_cap2: #project & {
	name: "cap2"
	dir:  "test/cap2"
	targets: {
		"integrate": {
			dockerfile: nubox & {
				secrets: "creds": null
			}
			cmd: "builtin": {
				do: "./gradlew integrationTest"
				dockerfile: {
					wrap: "/monorepo/scripts/wrap.sh"
					mounts: [
						{type: "secret", id: "creds", required: true},
					]
				}
			}
			compose: {
				entrypoint:   ["/monorepo/scripts/wrap.sh"]
				network_mode: "host"
				volumes: [
					"/var/run/docker.sock:/var/run/docker.sock",
				]
			}
		}
	}
}
_cap2: targets: integrate: cmd: "builtin": dockerfile: wrap: "/monorepo/scripts/wrap.sh"
_cap2: targets: integrate: compose: network_mode: "host"
_cap2: targets: integrate: dockerfile: secrets: "creds": null

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

// --- CAP4: incremental composes with an explicit secret declaration
// without conflict — different output blocks (incremental →
// dockerfile.incremental, secret → dockerfile.secrets + cmd mounts).
_cap4: #project & {
	name: "cap4"
	dir:  "test/cap4"
	targets: {
		"integrate": incremental & {
			dockerfile: nubox & {
				secrets: "creds": null
			}
			cmd: "builtin": {
				do: "./gradlew integrationTest"
				dockerfile: mounts: [
					{type: "secret", id: "creds", required: true},
				]
			}
		}
	}
}
_cap4: targets: integrate: dockerfile: incremental: true
_cap4: targets: integrate: dockerfile: secrets: "creds": null
_cap4: targets: integrate: cmd: "builtin": dockerfile: mounts: [
	{type: "secret", id: "creds", required: true},
]

// Public aggregator forces evaluation of the hidden _cap* bindings.
Tests: capabilities: {
	cap1: _cap1
	cap2: _cap2
	cap3: _cap3
	cap4: _cap4
}
