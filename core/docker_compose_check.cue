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
// The federation root (compose.bayt.yaml) is a flat list of every local
// fragment (user targets, then _srcs, then _outs, then _bayt) plus
// cross-project federation roots (none here). The per-target closures are
// emitted as compose.<n>.closure.yaml siblings, not unioned in here.
_d1_dc: compose: bayt_root: include: [
	{path: "./compose.build.yaml", required: false},
	{path: "./compose.build_srcs.yaml", required: false},
	{path: "./compose.build_outs.yaml", required: false},
	{path: "./compose._bayt.yaml", required: false},
]
_d1_dc: compose: files: build: services: "d1-build": build: context:    ".."
_d1_dc: compose: files: build: services: "d1-build": build: dockerfile: ".bayt/Dockerfile.build"
_d1_dc: compose: files: build: services: "d1-build": build: target:     "build"
// Depless target → no include (only services:).
_d1_dc: compose: files: build: {[!="services"]: _|_}

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
// Per-target files are fragments — services only, no include. Standalone
// loadability lives in the sibling per-target closure (compose.<n>.closure.yaml).
_d2_dc: compose: files: build: {[!="services"]: _|_}
_d2_dc: compose: files: setup: {[!="services"]: _|_}
// compose.build.closure.yaml: build's own fragment + the closure of each
// dep its service references (here just the same-project setup), recursive
// so setup.closure pulls setup's own deps. Resolves standalone, no
// federation root.
_d2_dc: compose: files: "build.closure": include: [
	{path: "./compose.build.yaml", required: false},
	{path: "./compose.setup.closure.yaml", required: false},
]

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

// --- D4: secrets flow through. A target declaring `secrets: <id>:
// null` on dockerfile gets both the BuildKit `--mount=type=secret`
// (via the cmd's mounts list) AND the per-file `secrets:` top-level
// stanza with the default file source `${BAYT_<UPPER_ID>_FILE}`.
_d4: #project & {
	name: "d4"
	dir:  "d4"
	targets: {
		"integrate": {
			srcs: globs: ["**"]
			cmd: "builtin": {
				do: "run-integration"
				dockerfile: mounts: [
					{type: "secret", id: "creds", required: true},
				]
			}
			dockerfile: busybox & {
				secrets: "creds": null
			}
		}
	}
}
_d4_dc: (#dockerComposeGen & {project: _d4, depManifests: {}})
_d4_dc: compose: files: integrate: services: "d4-integrate": build: secrets: ["creds"]
_d4_dc: compose: files: integrate: secrets: creds: file: "${BAYT_CREDS_FILE}"

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
			compose: healthcheck: {
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

// --- D9: synthetic-stage emission. Each target with non-empty
// srcs.globs spawns `<n>_srcs` (FROM scratch + COPY srcs from host);
// each with non-empty outs.globs spawns `<n>_outs` (FROM scratch +
// COPY --from=<n> outs). Per-project `_bayt` synthetic always emitted
// when at least one dockerfile target exists. Containment-checked on
// the rendered Dockerfile bodies — exact-string equality is brittle
// across glob orderings.
_d9_srcs_body:   _d1_dc.dockerfiles.build_srcs
_d9_outs_body:   _d1_dc.dockerfiles.build_outs
_d9_bayt_body:   _d1_dc.dockerfiles._bayt
_d9_srcs_stage:  strings.Contains(_d9_srcs_body, "FROM scratch AS build_srcs") & true
_d9_outs_stage:  strings.Contains(_d9_outs_body, "FROM scratch AS build_outs") & true
_d9_outs_from:   strings.Contains(_d9_outs_body, "COPY --from=d1-build") & true
_d9_bayt_stage:  strings.Contains(_d9_bayt_body, "FROM scratch AS bayt") & true
_d9_bayt_scope:  strings.Contains(_d9_bayt_body, ".bayt/** Taskfile.yml compose.yaml") & true
// Synthetic per-target files are fragments too (no include).
_d1_dc: compose: files: build_outs: {[!="services"]: _|_}
_d1_dc: compose: files: build_srcs: {[!="services"]: _|_}
_d1_dc: compose: files: "_bayt": {[!="services"]: _|_}

// --- D10: `:bayt` ref consumer. A target depending on `:bayt` (the
// project-level synthetic) gets a bulk-COPY `--from=<proj>-bayt
// --link /monorepo /monorepo` in its Dockerfile — distinct from the
// per-glob workdir COPY emitted for plain `:foo` refs. The compose
// service for the consumer wires `<proj>-bayt` in
// additional_contexts so the FROM ref resolves.
_d10: #project & {
	name: "d10"
	dir:  "d10"
	targets: {
		"ci": {
			deps: [":bayt"]
			cmd: "builtin": do: "true"
			dockerfile: busybox
		}
	}
}
_d10_dc: (#dockerComposeGen & {project: _d10, depManifests: {}})
// Bulk-copy pattern: /monorepo /monorepo, no --parents, no glob filter.
_d10_ci_body: _d10_dc.dockerfiles.ci
_d10_ci_has_bulk_copy: strings.Contains(_d10_ci_body, "COPY --from=d10-bayt --link /monorepo /monorepo") & true
// Additional context wires the bayt synthetic.
_d10_dc: compose: files: ci: services: "d10-ci": build: additional_contexts: "d10-bayt": "service:d10-bayt"

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
	d9_srcs_stage:  _d9_srcs_stage
	d9_outs_stage:  _d9_outs_stage
	d9_outs_from:   _d9_outs_from
	d9_bayt_stage:  _d9_bayt_stage
	d9_bayt_scope:  _d9_bayt_scope
	d10:            _d10_dc
	d10_has_bulk_copy: _d10_ci_has_bulk_copy
}
