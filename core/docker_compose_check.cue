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
// parent fragment plus cross-project federation roots (none here);
// closures are sibling files, not unioned here.
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
// Per-target files are fragments — services only, no include. Only
// compose.up targets get closure files (D18); other loads go through
// the federation root.
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

// --- D9: synthetic-stage emission. `<n>_srcs`, `<n>_outs`, and
// `<n>_bayt` (each a clamped busybox `_ctxs` stage flattened into FROM
// scratch) are stages in Dockerfile.<n>. Containment-checked — exact
// equality is brittle across glob orderings.
_d9_srcs_body:   _d1_dc.dockerfiles.build
_d9_outs_body:   _d1_dc.dockerfiles.build
_d9_bayt_body:   _d1_dc.dockerfiles.build
_d9_srcs_stage:  strings.Contains(_d9_srcs_body, "FROM scratch AS build_srcs") & true
_d9_outs_stage:  strings.Contains(_d9_outs_body, "FROM scratch AS build_outs") & true
_d9_outs_from:   strings.Contains(_d9_outs_body, "COPY --from=d1-build") & true
// The clamp stage guards `_outs` digest stability: without it, build-time
// mtimes on the copied outs float the digest per build.
_d9_outs_clamp:  strings.Contains(_d9_outs_body, "AS build_outs_ctxs") & true
_d9_bayt_stage:  strings.Contains(_d9_bayt_body, "FROM scratch AS build_bayt") & true
// Scaffolding scope is the target's OWN files + the membership-stable
// roots — never a sibling target's taskfile/manifest (cache honesty).
_d9_bayt_scope:  strings.Contains(_d9_bayt_body, "COPY --parents .bayt/compose.build.yaml .bayt/Dockerfile.build .bayt/bayt.build.json .bayt/Taskfile.yml .bayt/Taskfile.bayt.yml ./") & true
// Synthetic services all live in the parent fragment.
_d9_srcs_svc: _d1_dc.compose.files.build.services."d1-build_srcs".build.target & "build_srcs"
_d9_outs_svc: _d1_dc.compose.files.build.services."d1-build_outs".build.target & "build_outs"
_d9_bayt_svc: _d1_dc.compose.files.build.services."d1-build_bayt".build.target & "build_bayt"

// --- D10: `:x:bayt` ref consumer. A target depending on a
// scaffolding synth gets a bulk-COPY `--from=<proj>-<x>_bayt --link
// /monorepo /monorepo` in its Dockerfile — distinct from the per-glob
// workdir COPY emitted for plain `:foo` refs. The consumer's service
// wires the synth in additional_contexts, and the synth's own stage
// chains its deps' `_bayt` synths (self-contained transitive
// scaffolding).
_d10: #project & {
	name: "d10"
	dir:  "d10"
	targets: {
		"setup": {
			cmd: "builtin": do: "true"
			dockerfile: nubox
		}
		"integrate": {
			deps: [":setup"]
			srcs: globs: ["tests/**"]
			cmd: "builtin": do: "true"
			dockerfile: busybox
		}
		"ci": {
			deps: [":integrate:bayt"]
			cmd: "builtin": do: "true"
			dockerfile: busybox
		}
	}
}
_d10_dc: (#dockerComposeGen & {project: _d10, depManifests: {}})
// Bulk-copy pattern: /monorepo /monorepo, no --parents, no glob filter.
_d10_ci_body: _d10_dc.dockerfiles.ci
_d10_ci_has_bulk_copy: strings.Contains(_d10_ci_body, "COPY --from=d10-integrate_bayt --link /monorepo /monorepo") & true
// Additional context wires the scaffolding synth on the consumer…
_d10_dc: compose: files: ci: services: "d10-ci": build: additional_contexts: "d10-integrate_bayt": "service:d10-integrate_bayt"
// …and the synth itself chains its dep's `_bayt` (setup) — stage COPY
// plus the matching context on the synth service.
_d10_int_body: _d10_dc.dockerfiles.integrate
_d10_chain_copy: strings.Contains(_d10_int_body, "COPY --from=d10-setup_bayt /monorepo /monorepo") & true
_d10_dc: compose: files: integrate: services: "d10-integrate_bayt": build: additional_contexts: "d10-setup_bayt": "service:d10-setup_bayt"

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
_d11_bayt_from: _d11_dc.compose.files.build.services."d11-build_bayt".build."x-bake"."cache-from"
_d11_bayt_from: [
	"type=registry,ref=reg.example/p:sc-${CACHE_SCOPE:-unscoped}-d11-build_bayt",
	"type=registry,ref=reg.example/p:sc-${CACHE_SCOPE_FALLBACK:-unscoped}-d11-build_bayt",
]
_d11_bayt_to: _d11_dc.compose.files.build.services."d11-build_bayt".build."x-bake"."cache-to"
_d11_bayt_to: ["type=registry,ref=reg.example/p:sc-${CACHE_SCOPE:-unscoped}-d11-build_bayt,mode=max,image-manifest=true,oci-mediatypes=true,compression=zstd,compression-level=3"]

// cache-to mode: max for every synthetic — each flattens an unmodelled
// `_ctxs` intermediate (_srcs, _outs, _bayt) whose result mode=min drops.
_d11_srcs_to: _d11_dc.compose.files.build.services."d11-build_srcs".build."x-bake"."cache-to"
_d11_srcs_to: ["type=registry,ref=reg.example/p:sc-${CACHE_SCOPE:-unscoped}-d11-build_srcs,mode=max,image-manifest=true,oci-mediatypes=true,compression=zstd,compression-level=3"]
_d11_outs_to: _d11_dc.compose.files.build.services."d11-build_outs".build."x-bake"."cache-to"
_d11_outs_to: ["type=registry,ref=reg.example/p:sc-${CACHE_SCOPE:-unscoped}-d11-build_outs,mode=max,image-manifest=true,oci-mediatypes=true,compression=zstd,compression-level=3"]


// --- D12: a `:x:outs` dep on a target with empty outs.globs copies
// nothing: _outsEmit never emits the `<x>_outs` service, so an ungated
// COPY or `service:<x>_outs` context would dangle (compose/bake error).
// Same-project refs are also pre-filtered by _allEmit in _targetDeps;
// for cross-project entries (transitiveCrossDeps, not pre-filtered) the
// _depEdge gate is the only guard.
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

// --- D13: plain dep edges bulk-COPY the dep's workdir — every dep,
// regardless of what either end ships. The `:outs` interface shape is
// opt-in via an explicit `:x:outs` ref (D17), never inferred. Also the
// scale-gate feeder for D16/D18: launch runs (compose.up), build/setup
// are build stages.
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
			deps: [":build", ":setup"]
			cmd: "builtin": do: "./dist/app"
			dockerfile: busybox
			compose: up: true
		}
		// A plain runtime service: a compose block, neither up nor manual —
		// the shape of the release-* infra siblings. Must run on bare `up`
		// (no scale field). D16 pins it.
		"serve": {
			cmd: "builtin": do: "./serve"
			dockerfile: busybox
			compose: {}
		}
	}
}
_d13_dc: (#dockerComposeGen & {project: _d13, depManifests: {}})
_d13_body: _d13_dc.dockerfiles.launch
// Both deps bulk-COPY their workdir; neither renders in the `:outs` shape.
_d13_build_bulk: strings.Contains(_d13_body, "COPY --from=d13-build --link") & true
_d13_setup_bulk: strings.Contains(_d13_body, "COPY --from=d13-setup --link") & true
_d13_no_outs:    strings.Contains(_d13_body, "d13-build_outs") & false
// Contexts point at the deps themselves, not an `_outs` synth.
_d13_dc: compose: files: launch: services: "d13-launch": build: additional_contexts: {"d13-build": "service:d13-build", "d13-setup": "service:d13-setup"}

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

// --- D16: bare-`up` selection. A target runs iff it declares a compose
// block AND isn't manual (launch, the release-* siblings); build-graph
// stages and synthetics (_srcs/_outs/bayt) carry `scale: 0` — in the model
// (so `service:` contexts resolve, which profiles would break) but no
// container. Reuses _d13: launch has `compose.up`, serve is a plain runtime
// service (compose block, no up/manual), build/setup are stages.
_d16_build_scale: _d13_dc.compose.files.build.services."d13-build".scale & 0
_d16_setup_scale: _d13_dc.compose.files.setup.services."d13-setup".scale & 0
_d16_srcs_scale:  _d13_dc.compose.files.build.services."d13-build_srcs".scale & 0
_d16_outs_scale:  _d13_dc.compose.files.build.services."d13-build_outs".scale & 0
_d16_bayt_scale:  _d13_dc.compose.files.build.services."d13-build_bayt".scale & 0
// A compose-block target that is neither `up` nor `manual` runs at compose's
// default replica count (no scale field) — the release-* infra shape. Both
// launch (compose.up) and serve (bare compose block) qualify.
_d13_dc: compose: files: launch: services: "d13-launch": {["scale"]: _|_}
_d13_dc: compose: files: serve: services: "d13-serve": {["scale"]: _|_}
// A `manual` compose target (integrate: a by-name harness) is scale: 0 AND
// carries no profile on the base — present in a profile-less `config` (so
// `service:` contexts resolve) but off the bare-`up` stack. The profile
// lives only on the root alias, at scale 1, so `docker compose up harness`
// still runs it. The unprofiled-base assertion is load-bearing: profiling
// the base would drop it from `config`, dangling every context edge.
_d16_harness_scale: _d17_dc.compose.files.harness.services."d17-harness".scale & 0
_d17_dc: compose: files: harness: services: "d17-harness": {["profiles"]: _|_}
_d16_harness_alias: _d17_dc.compose.root.services.harness.scale & 1
_d16_harness_aprof: _d17_dc.compose.root.services.harness.profiles & ["harness"]

// --- D17: closure files exist ONLY for `compose.up` targets —
// others and synthetics get none (the harness is up: its closure is
// asserted in D18; D16 uses it for scale gating).
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
		// By-name harness: `manual` closure entry — D16 asserts its
		// profile gating and alias re-arm; D18 its closure.
		"harness": {
			deps: [":producer"]
			srcs: globs: ["tests/**"]
			cmd: "builtin": do: "run-tests"
			dockerfile: busybox
			compose: {up: true, manual: true}
		}
	}
	compose: includes: ["compose.overlay.yaml"]
}
_d17_dc: (#dockerComposeGen & {project: _d17, depManifests: {}})
// An explicit `:producer:outs` ref renders the glob COPY from the _outs
// synth (the plain-ref bulk COPY is D13).
_d17_outs: strings.Contains(_d17_dc.dockerfiles.consumer, "COPY --from=d17-producer_outs --parents /monorepo/d17/dist/lib /") & true
_d17_dc: compose: files: {["consumer.closure"]: _|_}
_d17_dc: compose: files: {["producer_srcs.closure"]: _|_}
_d17_dc: compose: files: {["producer_outs.closure"]: _|_}
_d17_dc: compose: files: {["_bayt.closure"]: _|_}

// --- D18: up closures. `compose.up` targets get
// compose.<n>.closure.yaml — a FLAT include of the manifest's
// upClosure (own + transitive fragments; the recursion happened
// at generate time in gen_bayt) plus #project.compose.includes, with an
// inline ungated short-name alias at scale 1 so `docker compose -f
// <closure> up <n>` works with no user root, federation root, or
// --profile flag. Non-up targets get none (D2/D17 assert absence).
_d18_launch_inc: _d13_dc.compose.files."launch.closure".include
_d18_launch_inc: [
	{path: "../../d13/.bayt/compose.launch.yaml", required: false},
	{path: "../../d13/.bayt/compose.build.yaml", required: false},
	{path: "../../d13/.bayt/compose.setup.yaml", required: false},
]
// The inline alias is the RESERVED `bayt` name (static across
// projects; never collides with overlay-defined short aliases).
_d18_launch_alias: _d13_dc.compose.files."launch.closure".services."bayt"
_d18_launch_alias: {
	extends: {file: "./compose.launch.yaml", service: "d13-launch"}
	scale: 1
}
_d13_dc: compose: files: "launch.closure": services: {["launch"]: _|_}
// Overlay project: the fragment set widens to the union of every
// local target's closure (overlay services reference fragments by
// hand-alias names bayt can't resolve, so exact reachability is
// opaque); the overlay itself appends last, relative to .bayt/.
_d18_harness_inc: _d17_dc.compose.files."harness.closure".include
_d18_harness_inc: [
	{path: "../../d17/.bayt/compose.producer.yaml", required: false},
	{path: "../../d17/.bayt/compose.consumer.yaml", required: false},
	{path: "../../d17/.bayt/compose.harness.yaml", required: false},
	{path: "../compose.overlay.yaml", required: false},
]

// --- D19: dockerfile.copy is additive — a defaultCopy entry and a
// consumer's own copy both render (framework first) instead of conflicting.
_d19: #project & {
	name: "d19"
	dir:  "d19"
	targets: {
		"launch": {
			cmd: "builtin": do: "serve"
			dockerfile: busybox & {
				defaultCopy: tool: {from: {name: "toolimg"}, srcs: ["/bin/tool"], dst: "/usr/local/bin/tool", chmod: "755"}
				copy: [{srcs: ["model.bin"], dst: "/model.bin"}]
			}
		}
	}
}
_d19_dc:   (#dockerComposeGen & {project: _d19, depManifests: {}})
_d19_body: _d19_dc.dockerfiles.launch
_d19_has_tool:  strings.Contains(_d19_body, "/usr/local/bin/tool") & true
_d19_has_model: strings.Contains(_d19_body, "/model.bin") & true

// --- D20: the image-only cross-project edge. A producer that ships an
// image (launch/release: `outs: globs: []`) is deppable through its empty
// `:outs` view, and that edge federates and orders without copying: the
// producer's fragments reach the consumer's closure — so `up --no-build`
// resolves its service — while nothing COPYs a runtime image that has no
// /monorepo/<dir> to give. The plain-ref alternative is D13's bulk COPY.
_d20: #project & {
	name: "d20"
	dir:  "d20"
	targets: {
		"integrate": {
			deps: ["img:launch:outs"]
			srcs: globs: ["tests/**"]
			cmd:  "builtin": do: "true"
			dockerfile: busybox
			compose: {up: true, manual: true}
		}
	}
}
_d20_dc: (#dockerComposeGen & {project: _d20, depManifests: {
	"img:launch:outs": {
		name:       "launch_outs"
		project:    "img"
		dir:        "img"
		visibility: "public"
		outs: {globs: [], exclude: []}
		transitiveCrossDeps: []
		upClosure: ["img/.bayt/compose.launch.yaml", "img/.bayt/compose.build.yaml"]
	}
}})
_d20_body: _d20_dc.dockerfiles.integrate
// Neither the unemitted `_outs` synth nor the runtime image is copied.
// The trailing space is load-bearing: the consumer's own `_bayt` synth
// does chain the producer's `img-launch_bayt`, which is scaffolding.
_d20_no_outs_copy: strings.Contains(_d20_body, "img-launch_outs") & false
_d20_no_bulk_copy: strings.Contains(_d20_body, "COPY --from=img-launch ") & false
_d20_dc: compose: files: integrate: services: "d20-integrate": build: {["additional_contexts"]: {["img-launch_outs"]: _|_}}
// The federation half: the producer's own closure, verbatim from its
// manifest, joins the consumer's include list.
_d20_inc: _d20_dc.compose.files."integrate.closure".include
_d20_inc: [
	{path: "../../d20/.bayt/compose.integrate.yaml", required: false},
	{path: "../../img/.bayt/compose.launch.yaml", required: false},
	{path: "../../img/.bayt/compose.build.yaml", required: false},
]

// --- D21: a `:x:bayt` copy ref names the scaffolding synth, not the
// build stage. #qualifyRef discriminates on the view suffix; a suffix it
// has no case for falls through to the workdir name, so the COPY reads
// the build stage and the wrongness is silent — nothing dangles, the
// image just isn't the one asked for. The FROM-ref side is closed the
// other way: the schema rejects every view suffix
// (tests/_negative_from_view).
_d21: #project & {
	name: "d21"
	dir:  "d21"
	targets: {
		"setup": {
			cmd: "builtin": do: "true"
			dockerfile: nubox
		}
		"consumer": {
			cmd: "builtin": do: "true"
			dockerfile: busybox & {
				copy: [{from: {ref: ":setup:bayt"}, srcs: ["/monorepo/d21/.bayt"], dst: "/scaffold"}]
			}
		}
	}
}
_d21_dc:   (#dockerComposeGen & {project: _d21, depManifests: {}})
_d21_body: _d21_dc.dockerfiles.consumer
_d21_copy: strings.Contains(_d21_body, "COPY --from=d21-setup_bayt /monorepo/d21/.bayt /scaffold") & true
// The context that COPY needs is wired to the synth service, not d21-setup.
_d21_dc: compose: files: consumer: services: "d21-consumer": build: additional_contexts: "d21-setup_bayt": "service:d21-setup_bayt"

// --- D22: a copy-only `from.ref` earns closure membership. Miss this
// and the closure is unparseable — `service "X" declares unknown
// service "Y"` — in every consumer that includes the referencing
// service, not in the project that declared the edge.
_d22: #project & {
	name: "d22"
	dir:  "d22"
	targets: {
		"blobs": {
			cmd: "builtin": do: "true"
			dockerfile: busybox
		}
		"app": {
			// No `deps: [":blobs"]`: the copy is the only declaration.
			cmd: "builtin": do: "true"
			compose: up: true
			dockerfile: busybox & {
				copy: [{from: {ref: ":blobs"}, srcs: ["/opt/blobs"], dst: "/opt/blobs"}]
			}
		}
	}
}
_d22_dc: (#dockerComposeGen & {project: _d22, depManifests: {}})
_d22_dc: compose: files: app: services: "d22-app": build: additional_contexts: "d22-blobs": "service:d22-blobs"
// The definition the reference resolves against travels with it.
_d22_inc: _d22_dc.compose.files."app.closure".include
_d22_inc: [
	{path: "../../d22/.bayt/compose.app.yaml", required: false},
	{path: "../../d22/.bayt/compose.blobs.yaml", required: false},
]
// Membership must not become a dep edge: that also emits the
// dependency's workdir COPY, which the consumer never asked for.
_d22_no_bulk: strings.Contains(_d22_dc.dockerfiles.app, "COPY --from=d22-blobs /monorepo") & false

// Public aggregator forces evaluation of the hidden _d* bindings.
Tests: docker_compose: {
	d22:          _d22_dc
	d22_inc:      _d22_inc
	d22_no_bulk:  _d22_no_bulk
	d19_tool:  _d19_has_tool
	d19_model: _d19_has_model
	d23_linked:           _d23_linked
	d23_rename_plain:     _d23_rename_plain
	d23_incontext_plain:  _d23_incontext_plain
	d23_parents_plain:    _d23_parents_plain
	d23_optout_plain:     _d23_optout_plain
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
	d10_chain_copy:    _d10_chain_copy
	d11_parent_from:   _d11_parent_from
	d11_srcs_from:     _d11_srcs_from
	d11_outs_from:     _d11_outs_from
	d11_bayt_from:     _d11_bayt_from
	d11_bayt_to:       _d11_bayt_to
	d11_srcs_to:       _d11_srcs_to
	d11_outs_to:       _d11_outs_to
	d12:               _d12_dc
	d12_no_copy:       _d12_no_copy
	d13:               _d13_dc
	d13_build_bulk:    _d13_build_bulk
	d13_setup_bulk:    _d13_setup_bulk
	d13_no_outs:       _d13_no_outs
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
	d16_harness_aprof: _d16_harness_aprof
	d17:               _d17_dc
	d17_outs:          _d17_outs
	d18_launch_inc:    _d18_launch_inc
	d18_launch_alias:  _d18_launch_alias
	d18_harness_inc:   _d18_harness_inc
	d20:               _d20_dc
	d20_no_outs_copy:  _d20_no_outs_copy
	d20_no_bulk_copy:  _d20_no_bulk_copy
	d20_inc:           _d20_inc
}

// --- D23: `_copyLine`'s `--link` predicate, pinned shape by shape. See
// that function for why the flag belongs on one shape only; what matters
// here is that the flag reaches no compose field, so a widened predicate
// would surface as a reproducibility failure in an integration test rather
// than as anything a unit suite could see.
//
// Spelled out rather than derived from one another: unification conflicts
// on an override, so `base & {from: null}` is an error, not a variant.

// The only shape that gets the flag.
_d23_linked: (_copyLine & {c: {
	link: true, from: {name: "img"}, parents: false, srcs: ["/bin/busybox"], dst: "/bin/busybox", exclude: []
}}).out & "COPY --link --from=img /bin/busybox /bin/busybox"

// The three that do not. Asserting the whole line,
// not the absence of "--link": a flag that moved would pass a contains
// check against a substring that no longer appears in that position.
_d23_rename_plain: (_copyLine & {c: {
	link: true, from: {name: "img"}, parents: false, srcs: ["/bin/busybox"], dst: "/usr/bin/busybox", exclude: []
}}).out & "COPY --from=img /bin/busybox /usr/bin/busybox"

_d23_incontext_plain: (_copyLine & {c: {
	link: true, from: null, parents: false, srcs: ["busybox"], dst: "/bin/busybox", exclude: []
}}).out & "COPY busybox /bin/busybox"

_d23_parents_plain: (_copyLine & {c: {
	link: true, from: {name: "img"}, parents: true, srcs: ["/bin/busybox"], dst: "/bin/busybox", exclude: []
}}).out & "COPY --parents --from=img /bin/busybox /bin/busybox"

// `link: false` on the one eligible shape: the flag goes away.
_d23_optout_plain: (_copyLine & {c: {
	link: false, from: {name: "img"}, parents: false, srcs: ["/bin/busybox"], dst: "/bin/busybox", exclude: []
}}).out & "COPY --from=img /bin/busybox /bin/busybox"
