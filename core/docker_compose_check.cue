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
// parent fragment plus cross-project federation roots (none here). The bayt
// service is inline in bayt_root.services; closures are sibling files, not
// unioned here.
_d1_dc: compose: bayt_root: include: [
	{path: "./compose.build.yaml", required: false},
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
// loads go through the federation root (flat, complete); no per-target
// closure files exist (recursive closures re-parse per include path —
// compose-go's ApplyInclude has no dedup — and blow up with graph depth).
_d2_dc: compose: files: build: {[!="services"]: _|_}
_d2_dc: compose: files: setup: {[!="services"]: _|_}
_d2_dc: compose: files: {["build.closure"]: _|_}
_d2_dc: compose: files: {["setup.closure"]: _|_}

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
// Each alias is profile-gated under its own name — bare `up` skips it
// (no duplicate next to the qualified service), naming it auto-activates
// the profile. A build-graph alias inherits the base's scale 0 (nothing
// to run); compose-block aliases re-arm with scale 1 (see D16).
_d6_dc: (#dockerComposeGen & {project: _d1, depManifests: {}})
_d6_dc: compose: root: include: [{path: "./compose.bayt.yaml", required: false}]
_d6_dc: compose: root: services: build: extends: {
	file:    "./compose.build.yaml"
	service: "d1-build"
}
_d6_dc: compose: root: services: build: profiles: ["build"]
_d6_dc: compose: root: services: build: {["scale"]: _|_}

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

// --- D9: synthetic-stage emission. `<n>_srcs` and `<n>_outs` (each a
// clamped busybox `_ctxs` stage flattened into FROM scratch) are stages in
// Dockerfile.<n>; the per-project `bayt` synthetic is Dockerfile.bayt
// (emitted when ≥1 dockerfile target exists). Containment-checked — exact
// equality is brittle across glob orderings.
_d9_srcs_body:   _d1_dc.dockerfiles.build
_d9_outs_body:   _d1_dc.dockerfiles.build
_d9_bayt_body:   _d1_dc.dockerfiles.bayt
_d9_srcs_stage:  strings.Contains(_d9_srcs_body, "FROM scratch AS build_srcs") & true
_d9_outs_stage:  strings.Contains(_d9_outs_body, "FROM scratch AS build_outs") & true
_d9_outs_from:   strings.Contains(_d9_outs_body, "COPY --from=d1-build") & true
// The clamp stage guards `_outs` digest stability: without it, build-time
// mtimes on the copied outs float the digest per build.
_d9_outs_clamp:  strings.Contains(_d9_outs_body, "AS build_outs_ctxs") & true
_d9_bayt_stage:  strings.Contains(_d9_bayt_body, "FROM scratch AS bayt") & true
_d9_bayt_scope:  strings.Contains(_d9_bayt_body, "COPY --parents .bayt/**") & true
// Synthetic services live in the parent fragment; the bayt service in the
// federation root.
_d9_srcs_svc: _d1_dc.compose.files.build.services."d1-build_srcs".build.target & "build_srcs"
_d9_outs_svc: _d1_dc.compose.files.build.services."d1-build_outs".build.target & "build_outs"
_d9_bayt_svc: _d1_dc.compose.bayt_root.services."d1-bayt".build.target & "bayt"

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

// --- D11: synthetic _srcs / _outs inherit the parent target's
// cache-from / cache-to from #project.bake.cache (registry sugar),
// re-scoped to their own suffixed tag (`build_srcs` / `build_outs`) so
// they memoize separately instead of clobbering the parent `build` key.
// Selecting the emitted list forces a "field not found" error if no
// x-bake was emitted; the literal unification then pins the exact refs.
_d11: #project & {
	name: "d11"
	dir:  "d11"
	bake: cache: {type: "registry", registry: "reg.example/p", scope: "sc"}
	targets: {
		"build": {
			srcs: globs: ["src/**"]
			outs: globs: ["target/d11"]
			cmd: "builtin": do: "cargo build"
			dockerfile: busybox
		}
	}
}
_d11_dc: (#dockerComposeGen & {project: _d11, depManifests: {}})

// Parent target keeps the bare `-build` tag.
_d11_parent_from: _d11_dc.compose.files.build.services."d11-build".build."x-bake"."cache-from"
_d11_parent_from: [
	"type=registry,ref=reg.example/p:sc-${CACHE_SCOPE:-unscoped}-build",
	"type=registry,ref=reg.example/p:sc-${CACHE_SCOPE_FALLBACK:-unscoped}-build",
]

// Each synthetic's x-bake cache tag is keyed by its project-qualified service
// name (`d11-build_srcs`), so synthetics under a cache scope shared across
// projects each get a distinct tag. Synthetic services live in the PARENT
// fragment (files.build) and the bayt service in bayt_root — a selector on a
// nonexistent file key (e.g. files.build_srcs) is merely incomplete, which
// `cue eval` tolerates, so it would assert nothing.
_d11_srcs_from: _d11_dc.compose.files.build.services."d11-build_srcs".build."x-bake"."cache-from"
_d11_srcs_from: [
	"type=registry,ref=reg.example/p:sc-${CACHE_SCOPE:-unscoped}-d11-build_srcs",
	"type=registry,ref=reg.example/p:sc-${CACHE_SCOPE_FALLBACK:-unscoped}-d11-build_srcs",
]
_d11_outs_from: _d11_dc.compose.files.build.services."d11-build_outs".build."x-bake"."cache-from"
_d11_outs_from: [
	"type=registry,ref=reg.example/p:sc-${CACHE_SCOPE:-unscoped}-d11-build_outs",
	"type=registry,ref=reg.example/p:sc-${CACHE_SCOPE_FALLBACK:-unscoped}-d11-build_outs",
]
_d11_bayt_from: _d11_dc.compose.bayt_root.services."d11-bayt".build."x-bake"."cache-from"
_d11_bayt_from: [
	"type=registry,ref=reg.example/p:sc-${CACHE_SCOPE:-unscoped}-d11-bayt",
	"type=registry,ref=reg.example/p:sc-${CACHE_SCOPE_FALLBACK:-unscoped}-d11-bayt",
]

// cache-to mode: max for every synthetic — each flattens an unmodelled
// `_ctxs` intermediate (_srcs, _outs, _bayt) whose result mode=min drops.
_d11_srcs_to: _d11_dc.compose.files.build.services."d11-build_srcs".build."x-bake"."cache-to"
_d11_srcs_to: ["type=registry,ref=reg.example/p:sc-${CACHE_SCOPE:-unscoped}-d11-build_srcs,mode=max,image-manifest=true,oci-mediatypes=true"]
_d11_outs_to: _d11_dc.compose.files.build.services."d11-build_outs".build."x-bake"."cache-to"
_d11_outs_to: ["type=registry,ref=reg.example/p:sc-${CACHE_SCOPE:-unscoped}-d11-build_outs,mode=max,image-manifest=true,oci-mediatypes=true"]
_d11_bayt_to: _d11_dc.compose.bayt_root.services."d11-bayt".build."x-bake"."cache-to"
_d11_bayt_to: ["type=registry,ref=reg.example/p:sc-${CACHE_SCOPE:-unscoped}-d11-bayt,mode=max,image-manifest=true,oci-mediatypes=true"]

// --- D12: a `:x:outs` dep on a target with empty outs.globs is inert
// everywhere: _outsEmit never emits the `<x>_outs` service, so an
// ungated COPY or `service:<x>_outs` context would dangle (compose/bake
// error). Same-project refs are also pre-filtered by _allEmit in
// _targetDeps; for cross-project entries (transitiveCrossDeps, not
// pre-filtered) the _depEdge gate is the only guard.
_d12: #project & {
	name: "d12"
	dir:  "d12"
	targets: {
		"producer": {
			srcs: globs: ["src/**"]
			cmd: "builtin": do: "make"
			dockerfile: busybox
		}
		"consumer": {
			deps: [":producer:outs"]
			srcs: globs: ["**"]
			cmd:  "builtin": do: "make"
			dockerfile: busybox
		}
	}
}
_d12_dc: (#dockerComposeGen & {project: _d12, depManifests: {}})
// No producer_outs compose file (empty outs.globs → _outsEmit skips it).
_d12_dc: compose: files: {["producer_outs"]: _|_}
// Consumer Dockerfile carries no dep COPY for the inert ref.
_d12_no_copy: strings.Contains(_d12_dc.dockerfiles.consumer, "d12-producer_outs") & false
// Consumer service carries no dangling additional_contexts entry.
_d12_dc: compose: files: consumer: services: "d12-consumer": build: {["additional_contexts"]: {["d12-producer_outs"]: _|_}}

// --- D13: runtime-class consumer. Plain dep edges INTO a runtime
// target carry the dep's declared interface (the `:outs` shape from
// the dep's `_outs` synth), never its workdir tree; empty-outs deps
// contribute nothing — no COPY and no additional_contexts entry.
_d13: #project & {
	name: "d13"
	dir:  "d13"
	targets: {
		"build": {
			srcs: globs: ["src/**"]
			outs: globs: ["dist/app"]
			cmd: "builtin": do: "make"
			dockerfile: busybox
		}
		"setup": {
			cmd: "builtin": do: "true"
			dockerfile: nubox
		}
		"launch": {
			class: "runtime"
			deps: [":build", ":setup"]
			cmd: "builtin": do: "./dist/app"
			dockerfile: busybox
			compose: {}
		}
	}
}
_d13_dc: (#dockerComposeGen & {project: _d13, depManifests: {}})
_d13_body: _d13_dc.dockerfiles.launch
// build's interface flows outs-shaped from the clamped _outs synth…
_d13_outs_copy: strings.Contains(_d13_body, "COPY --from=d13-build_outs --parents /monorepo/d13/dist/app /") & true
// …never as a bulk workdir COPY of the build stage.
_d13_no_bulk: strings.Contains(_d13_body, "COPY --from=d13-build --link") & false
// The empty-outs setup dep contributes nothing at all.
_d13_no_setup: strings.Contains(_d13_body, "d13-setup") & false
// Context points at the _outs synth; neither the bulk service nor the
// empty-outs dep appears.
_d13_dc: compose: files: launch: services: "d13-launch": build: additional_contexts: "d13-build_outs": "service:d13-build_outs"
_d13_dc: compose: files: launch: services: "d13-launch": build: {["additional_contexts"]: {["d13-build"]: _|_, ["d13-setup"]: _|_}}

// --- D14: runtime-class dep. A build-class consumer depping a no-outs
// launch bulk-copies nothing (a launch's output is its image, not
// files) but keeps the additional_contexts edge so the bake graph
// produces the image before a run phase pulls it.
_d14: #project & {
	name: "d14"
	dir:  "d14"
	targets: {
		"launch": {
			class: "runtime"
			cmd: "builtin": do: "serve"
			dockerfile: nubox
			compose: {}
		}
		"integrate": {
			deps: [":launch"]
			srcs: globs: ["tests/**"]
			cmd: "builtin": do: "run-tests"
			dockerfile: busybox
		}
	}
}
_d14_dc: (#dockerComposeGen & {project: _d14, depManifests: {}})
_d14_body: _d14_dc.dockerfiles.integrate
_d14_no_copy: strings.Contains(_d14_body, "COPY --from=d14-launch") & false
_d14_dc: compose: files: integrate: services: "d14-integrate": build: additional_contexts: "d14-launch": "service:d14-launch"

// --- D15: dockerfile.add — pinned ADD stanzas. Remote emits
// `ADD --checksum=…` (with `--unpack` only when set); local emits a
// plain ADD. Lines land after the preamble.
_d15: #project & {
	name: "d15"
	dir:  "d15"
	targets: {
		"release": {
			cmd: "builtin": do: "true"
			dockerfile: busybox & {
				add: [
					{url: "https://example.com/model.gguf", sha256: "2e8040ceae7815abe0dcb3540b9995eaa1fa0d2ca9e797d0a635ae4433c68c2d", dest: "/app/models/model.gguf"},
					{url: "https://example.com/data.tar.gz", sha256: "95e3a3a2adeacd1b8dd704743c71eec8343dde472d3efe71101a62570c47cbbd", dest: "/data/", unpack: true},
					{src: "vendor/tools.tar.gz", dest: "/opt/tools/"},
				]
			}
		}
	}
}
_d15_dc: (#dockerComposeGen & {project: _d15, depManifests: {}})
_d15_body: _d15_dc.dockerfiles.release
_d15_remote: strings.Contains(_d15_body, "ADD --checksum=sha256:2e8040ceae7815abe0dcb3540b9995eaa1fa0d2ca9e797d0a635ae4433c68c2d https://example.com/model.gguf /app/models/model.gguf") & true
_d15_unpack: strings.Contains(_d15_body, "ADD --checksum=sha256:95e3a3a2adeacd1b8dd704743c71eec8343dde472d3efe71101a62570c47cbbd --unpack=true https://example.com/data.tar.gz /data/") & true
_d15_local:  strings.Contains(_d15_body, "ADD vendor/tools.tar.gz /opt/tools/") & true

// --- D16: bare-`up` runtime selection. Only class-runtime targets
// with a compose block (the app stack: launch, release-* siblings)
// run bare; build-graph stages and synthetics (_srcs/_outs/bayt)
// carry `scale: 0` — in the model (so `service:` contexts resolve,
// which profiles would break) but no container. Reuses _d13: launch
// is class runtime with `compose: {}`, build/setup are build-class.
_d16_build_scale: _d13_dc.compose.files.build.services."d13-build".scale & 0
_d16_setup_scale: _d13_dc.compose.files.setup.services."d13-setup".scale & 0
_d16_srcs_scale:  _d13_dc.compose.files.build.services."d13-build_srcs".scale & 0
_d16_outs_scale:  _d13_dc.compose.files.build.services."d13-build_outs".scale & 0
_d16_bayt_scale:  _d13_dc.compose.bayt_root.services."d13-bayt".scale & 0
// The runtime stack stays at compose's default replica count so a
// bare `up` starts it.
_d13_dc: compose: files: launch: services: "d13-launch": {["scale"]: _|_}
// A compose-block target that is NOT class runtime (integrate: a
// by-name harness) is zeroed too — bare `up` must not run tests.
// Its root alias re-arms it: scale 1 + the auto-activating profile,
// so `docker compose up harness` works unchanged (the qualified
// base stays down; only the alias runs).
_d16_harness_scale: _d17_dc.compose.files.harness.services."d17-harness".scale & 0
_d16_harness_alias: _d17_dc.compose.root.services.harness.scale & 1
_d16_harness_prof:  _d17_dc.compose.root.services.harness.profiles & ["harness"]

// --- D17: no closure files for any target shape — user targets,
// synthetics, or the harness (D16 uses it for scale gating). The
// fragment set plus the federation root is the whole compose surface.
_d17: #project & {
	name: "d17"
	dir:  "d17"
	targets: {
		"producer": {
			srcs: globs: ["src/**"]
			outs: globs: ["dist/lib"]
			cmd: "builtin": do: "make"
			dockerfile: busybox
		}
		"consumer": {
			deps: [":producer", ":producer:outs"]
			srcs: globs: ["**"]
			cmd:  "builtin": do: "make"
			dockerfile: busybox
		}
		// By-name harness: compose block, default (build) class — D16
		// asserts its scale gating and alias re-arm.
		"harness": {
			srcs: globs: ["tests/**"]
			cmd: "builtin": do: "run-tests"
			dockerfile: busybox
			compose: {}
		}
	}
}
_d17_dc: (#dockerComposeGen & {project: _d17, depManifests: {}})
_d17_dc: compose: files: {["consumer.closure"]: _|_}
_d17_dc: compose: files: {["producer_srcs.closure"]: _|_}
_d17_dc: compose: files: {["producer_outs.closure"]: _|_}
_d17_dc: compose: files: {["_bayt.closure"]: _|_}

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
	d9_outs_clamp:  _d9_outs_clamp
	d9_bayt_stage:  _d9_bayt_stage
	d9_bayt_scope:  _d9_bayt_scope
	d10:            _d10_dc
	d10_has_bulk_copy: _d10_ci_has_bulk_copy
	d11_parent_from:   _d11_parent_from
	d11_srcs_from:     _d11_srcs_from
	d11_outs_from:     _d11_outs_from
	d11_bayt_from:     _d11_bayt_from
	d11_srcs_to:       _d11_srcs_to
	d11_outs_to:       _d11_outs_to
	d11_bayt_to:       _d11_bayt_to
	d12:               _d12_dc
	d12_no_copy:       _d12_no_copy
	d13:               _d13_dc
	d13_outs_copy:     _d13_outs_copy
	d13_no_bulk:       _d13_no_bulk
	d13_no_setup:      _d13_no_setup
	d14:               _d14_dc
	d14_no_copy:       _d14_no_copy
	d15:               _d15_dc
	d15_remote:        _d15_remote
	d15_unpack:        _d15_unpack
	d15_local:         _d15_local
	d16_build_scale:   _d16_build_scale
	d16_setup_scale:   _d16_setup_scale
	d16_srcs_scale:    _d16_srcs_scale
	d16_outs_scale:    _d16_outs_scale
	d16_bayt_scale:    _d16_bayt_scale
	d16_harness_scale: _d16_harness_scale
	d16_harness_alias: _d16_harness_alias
	d16_harness_prof:  _d16_harness_prof
	d17:               _d17_dc
}
