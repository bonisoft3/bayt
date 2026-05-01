// docker_compose_check.cue — exercises #dockerComposeGen, the largest
// emitter (couples Dockerfile text and compose.yaml). Tests cover:
// minimal emission, dep chain wiring via additional_contexts, secrets
// flowing into both build and the top-level secrets stanza, targets
// without a dockerfile being skipped, and develop.watch passthrough.
package bayt

import "strings"

// --- D1: a single target with a dockerfile block. The federation root
// (compose.bayt.yaml) lists the per-target file as an include with
// `required: false`. The per-target file holds one fully-qualified
// service ("<project>-<target>") with the standard build block.
_d1: #project & {
	name: "d1"
	dir:  "d1"
	targets: {
		"build": {
			srcs: globs: ["src/**"]
			outs: globs: ["target/d1"]
			cmd: "builtin": do: "cargo build"
			dockerfile: busybox
		}
	}
}
_d1_dc: (#dockerComposeGen & {project: _d1, depManifests: {}})
_d1_dc: compose: bayt_root: include: [
	{path: "./compose.build.yaml", required: false},
]
_d1_dc: compose: files: build: services: "d1-build": build: context:    ".."
_d1_dc: compose: files: build: services: "d1-build": build: dockerfile: ".bayt/Dockerfile.build"
_d1_dc: compose: files: build: services: "d1-build": build: target:     "build"
// busybox preset → from.name lands as an additional_contexts entry.
_d1_dc: compose: files: build: services: "d1-build": build: additional_contexts: (lock.images.busybox): "docker-image://\(lock.images.busybox)"

// --- D2: dep chain — build depends on setup, both have dockerfile
// blocks. The build service gets `additional_contexts: { d2-setup:
// service:d2-setup }` so its Dockerfile can `COPY --from=d2-setup`.
_d2: #project & {
	name: "d2"
	dir:  "d2"
	targets: {
		"setup": {
			cmd: "builtin": do: "true"
			dockerfile: nubox
		}
		"build": {
			deps: [":setup"]
			srcs: globs: ["**"]
			cmd:  "builtin": do: "make"
			dockerfile: busybox
		}
	}
}
_d2_dc: (#dockerComposeGen & {project: _d2, depManifests: {}})
_d2_dc: compose: files: build: services: "d2-build": build: additional_contexts: "d2-setup": "service:d2-setup"

// --- D3: targets without a dockerfile block don't appear in the
// emitter output at all. A pure setup-only project produces an empty
// federation root and no per-target compose files.
_d3: #project & {
	name: "d3"
	dir:  "d3"
	targets: {
		"setup":  {cmd: "builtin": do: "true"}
		"doctor": {cmd: "builtin": do: "true"}
	}
}
_d3_dc: (#dockerComposeGen & {project: _d3, depManifests: {}})
_d3_dc: compose: files: {[_]: _|_}
_d3_dc: dockerfiles: {[_]: _|_}
// No targets → bayt_root has no `include` field (emitter only sets it
// when at least one entry exists).
_d3_dc: compose: bayt_root: {[!="services"]: _|_}

// --- D4: secrets flow through. A target with hostenv adds
// `secrets: ["host.env"]` on dockerfile, which becomes the BuildKit
// `--mount=type=secret` AND the per-file `secrets:` top-level stanza
// pointing at ${BAYT_HOST_ENV_FILE}.
_d4: #project & {
	name: "d4"
	dir:  "d4"
	targets: {
		"integrate": hostenv & {
			srcs: globs: ["**"]
			cmd:  "builtin": do: "run-integration"
			dockerfile: busybox
		}
	}
}
_d4_dc: (#dockerComposeGen & {project: _d4, depManifests: {}})
_d4_dc: compose: files: integrate: services: "d4-integrate": build: secrets: ["host.env"]
_d4_dc: compose: files: integrate: secrets: "host.env": file: "${BAYT_HOST_ENV_FILE}"

// --- D5: develop.watch from the compose block passes through to the
// per-target service block.
_d5: #project & {
	name: "d5"
	dir:  "d5"
	targets: {
		"launch": {
			cmd: "builtin": do: "pnpm dev"
			dockerfile: nubox
			compose: develop: watch: [
				{action: "sync", path: "./", target: "/app", ignore: ["node_modules"]},
			]
		}
	}
}
_d5_dc: (#dockerComposeGen & {project: _d5, depManifests: {}})
_d5_dc: compose: files: launch: services: "d5-launch": develop: watch: [
	{action: "sync", path: "./", target: "/app", ignore: ["node_modules"]},
]

// --- D6: the user root (compose.yaml) wires short alias services that
// `extends:` the qualified services in the per-target compose files.
// Lets users `docker compose up <target>` without typing the qualifier.
_d6_dc: (#dockerComposeGen & {project: _d1, depManifests: {}})
_d6_dc: compose: root: include: [{path: "./compose.bayt.yaml", required: false}]
_d6_dc: compose: root: services: build: extends: {
	file:    "./compose.build.yaml"
	service: "d1-build"
}

// --- D7: dockerfile.entrypoint emits an `ENTRYPOINT [...]` line in
// exec form. Empty list (the default) emits nothing — verified by
// _d1's Dockerfile body not containing ENTRYPOINT.
_d7: #project & {
	name: "d7"
	dir:  "d7"
	targets: {
		"release": {
			cmd: "builtin": do: "true"
			dockerfile: scratch & {
				entrypoint: ["java", "-cp", "@/app/jib-classpath-file", "Main"]
			}
		}
	}
}
_d7_dc: (#dockerComposeGen & {project: _d7, depManifests: {}})
// String containment check on the emitted Dockerfile body.
_d7_body: _d7_dc.dockerfiles.release
_d7_has_entrypoint: strings.Contains(_d7_body, #"ENTRYPOINT ["java", "-cp", "@/app/jib-classpath-file", "Main"]"#) & true

// --- D8: compose.runtime.healthcheck passes through verbatim to the
// per-target service block (bayt doesn't re-validate compose's
// healthcheck spec).
_d8: #project & {
	name: "d8"
	dir:  "d8"
	targets: {
		"launch": {
			cmd: "builtin": do: "envoy -c /etc/envoy.yaml"
			dockerfile: nubox
			compose: runtime: healthcheck: {
				test:     "curl http://localhost:18080/"
				interval: "40s"
				retries:  3
			}
		}
	}
}
_d8_dc: (#dockerComposeGen & {project: _d8, depManifests: {}})
_d8_dc: compose: files: launch: services: "d8-launch": healthcheck: {
	test:     "curl http://localhost:18080/"
	interval: "40s"
	retries:  3
}

// Public aggregator forces evaluation of the hidden _d* bindings.
Tests: docker_compose: {
	d1: _d1_dc
	d2: _d2_dc
	d3: _d3_dc
	d4: _d4_dc
	d5: _d5_dc
	d6: _d6_dc
	d7: _d7_dc
	d7_has_entrypoint: _d7_has_entrypoint
	d8: _d8_dc
}
