// stacks/sayt — sayt's verb conventions, expressed as a bayt stack.
//
// bayt is target-vocabulary-agnostic: a #project is a map of named
// targets with deps, srcs, outs, and output blocks. Sayt imposes
// the convention that projects expose ten canonical verbs (setup,
// doctor, build, test, launch, integrate, release, verify,
// generate, lint) with a fixed dep DAG and a few output-shape
// agreements.
//
// Sayt lives under bayt/stacks/ alongside the toolchain concept
// libraries (gradle, pnpm, mise) — it's "just another stack" from
// bayt's perspective. The sayt RUNTIME (plugins/sayt/, the nushell
// scripts and config.cue) doesn't depend on bayt at all; the
// runtime invokes generate-bayt.nu via .say.yaml's `generate`
// rulemap, and that's the only point where the two layers meet.
//
// This file exports two things:
//
//   1. The 10 verb fragments (sayt.setup, sayt.build, ...). Plain
//      struct values that project bayt.cue files unify into their
//      target map alongside toolchain-concept fragments from other
//      stacks. Sayt-side fields only — NO toolchain assumptions.
//
//   2. The standard sayt-verb mappings for common toolchain combos:
//      sayt.gradle, sayt.pnpm, sayt.pnpmWorkspace. These are
//      complete bayt.#project shapes that wire the 10 verbs to a
//      specific toolchain stack — useful for projects that follow
//      the standard mapping. Projects with atypical mappings
//      compose the verb fragments + concept fragments directly
//      (see services/tracker-tx).
//
// Usage — atypical project (composes concepts directly):
//
//   package my_service
//   import (
//       bayt "bonisoft.org/plugins/bayt/bayt"
//       sayt "bonisoft.org/plugins/bayt/stacks/sayt"
//       mise "bonisoft.org/plugins/bayt/stacks/mise"
//   )
//
//   _proj: bayt.#project & {
//       dir: "services/my-service"
//       targets: {
//           "setup":   sayt.setup   & Mise.install
//           "build":   sayt.build   & Mise.exec & {cmd: do: "go build"}
//           ...
//       }
//   }
//
// Usage — standard-mapping project:
//
//   package my_service
//   import sayt "bonisoft.org/plugins/bayt/stacks/sayt"
//
//   _proj: sayt.gradle & {
//       dir: "services/my-service"
//       targets: "release": skaffold: image: "gcr.io/proj/my-service"
//   }
package sayt

import (
	"list"

	"bonisoft.org/plugins/bayt/bayt"
	// Capitalized aliases for the toolchain-stack imports so the
	// lowercase `gradle:` / `pnpm:` umbrella exports below don't
	// shadow them.
	Gradle "bonisoft.org/plugins/bayt/stacks/gradle"
	Mise   "bonisoft.org/plugins/bayt/stacks/mise"
	Pnpm   "bonisoft.org/plugins/bayt/stacks/pnpm"
)

// setup — toolchain install. Runs once when .mise.lock changes.
// `dockerfile: {}` so setup gets its own Dockerfile stage when srcs
// are declared — downstream targets inherit setup's installed
// toolchain via FROM-chain or COPY --from=<project>-setup.
setup: {
	deps: *[] | [...string]
	taskfile: run: "when_changed"
	dockerfile: {}
}

// doctor — environment check. No outputs, runs on demand.
doctor: {
	deps: *[] | [...string]
	taskfile: run: "always"
	vscode: group: kind: "none"
}

// build — primary artifact producer. Toolchain stack supplies the
// command and srcs.
build: {
	deps: *[":setup"] | [...string]
	taskfile: {}
	dockerfile: {}
	vscode: group: {kind: "build", isDefault: true}
}

// test — unit tests. Convention: produce JUnit-style XML at the
// stack's chosen path (gradle: build/test-results/...; pnpm:
// test-results/...). Toolchain stack sets outs.globs accordingly.
test: {
	deps: *[":build"] | [...string]
	taskfile: {}
	vscode: group: {kind: "test", isDefault: true}
}

// launch — dev-loop container. HMR-enabled where the toolchain
// supports it (compose develop.watch).
launch: {
	deps: *[":build"] | [...string]
	compose: runtime: {}
	dockerfile: {}
	// bayt-dev profile auto-fires on `skaffold dev`. Projects opt
	// into cluster-side dev by including .bayt/skaffold.launch.yaml
	// from their own <project>/skaffold.yaml. Image identity lives
	// in the project's bayt.cue (project-local concern); the stack
	// just seeds the activation rule + dockerfile path that all
	// launch targets share.
	//
	// tagPolicy.gitCommit.variant: AbbrevCommitSha sidesteps
	// skaffold's default Tags variant, which uses `git describe
	// --tags` and on this monorepo returns the full prefixed tag
	// (services/tracker/v…). Skaffold then normalizes `/` to `_` and
	// warns about the substitution. AbbrevCommitSha (7-char commit
	// hash) is deterministic, monorepo-tag-agnostic, and fine for
	// dev-loop image tags.
	skaffold: profiles: "bayt-dev": {
		activation: [{command: "dev"}]
		build: {
			artifact: docker: dockerfile: ".bayt/Dockerfile.launch"
			tagPolicy: gitCommit: variant: "AbbrevCommitSha"
		}
	}
}

// integrate — docker-compose integration tests. Often dind +
// secrets. Default wrap is dind.sh (sayt-owned script that bridges
// DOCKER_HOST → /var/run/docker.sock and sources host.env).
// taskfile: {} so bayt can emit Taskfile.integrate.yaml — needed
// when projects opt into bayt.incremental for the in-container
// task chain to short-circuit on stamps.
integrate: {
	deps: *[":build"] | [...string]
	taskfile: {}
	compose: {}
	dockerfile: secrets: *["host.env"] | [...string]
	cmd: "builtin": dockerfile: wrap: *"dind.sh" | string
}

// release — shippable image. Bake produces the registry-bound image;
// skaffold's bayt-{build,run} profiles wrap it for skaffold's two
// release-adjacent CLI commands:
//
//   bayt-build — auto-fires on `skaffold build`. Used by goreleaser's
//                hooks (verify pass with --push=false, then publish
//                with default push). No deploy semantics — just the
//                image build pipeline.
//   bayt-run   — auto-fires on `skaffold run`. Same artifact, plus
//                manifests + test/verify hooks for cluster-side
//                deploy. Forward-looking: production deploys still
//                go through Crossplane today, so projects that don't
//                use `skaffold run` opt out via `bayt-run: null`.
//
// Projects share build artifact configs between the two via a hidden
// `_releaseBuild:` field on the target; see services/tracker for the
// pattern.
release: {
	deps: *[":build"] | [...string]
	dockerfile: {}
	// Each profile is `*(struct) | null` so projects can opt out via
	// `skaffold: profiles: "<name>": null`. Without the disjunction
	// default, a project's null would clash with the struct
	// activation rule and fail unification.
	//
	// tagPolicy.gitCommit.variant: AbbrevCommitSha avoids the same
	// monorepo-tag warning bayt-dev avoids (skaffold's default
	// `gitCommit: {variant: Tags}` uses `git describe --tags` →
	// returns `services/tracker/v…` → skaffold normalizes `/` to
	// `_` and warns). For release invocations driven by goreleaser,
	// the explicit `--tag={{ .Version }}` CLI flag overrides this
	// policy anyway. AbbrevCommitSha just covers the manual
	// `skaffold build` path that's used for verification today.
	skaffold: profiles: {
		"bayt-build": *{
			activation: [{command: "build"}]
			build: tagPolicy: gitCommit: variant: "AbbrevCommitSha"
		} | null
		"bayt-run": *{
			activation: [{command: "run"}]
			build: tagPolicy: gitCommit: variant: "AbbrevCommitSha"
		} | null
	}
	bake: {}
}

// verify — e2e + load + screenshot tests, run in preview (k8s).
verify: {
	deps: *[":release"] | [...string]
	outs: globs: ["build/verify-results/**/*"]
	taskfile: {}
}

// generate — codegen; outputs committed.
generate: {
	deps: *[] | [...string]
	taskfile: {}
}

// lint — static checks. Always runs (no cache); fast enough that
// short-circuiting doesn't pay.
lint: {
	deps: *[] | [...string]
	taskfile: run: "always"
}

// =============================================================================
// Standard sayt-verb mappings — bayt.#project shapes that wire the
// verb fragments above to a specific toolchain stack.
//
// Use the umbrella matching your toolchain combo for the standard
// 5-line project setup. Compose verb + concept fragments directly
// (see services/tracker-tx) when the standard mapping doesn't fit.
// =============================================================================

// sayt.gradle — pure-gradle project using mise as the toolchain
// executor. Project-local sources only — composite-build root files
// (root build.gradle.kts / settings.gradle.kts / gradle.properties /
// gradle/libs.versions.toml) belong to a separate workspace-root
// project that consumers wire in via `setup.deps:`.
gradle: bayt.#project & {
	activate: *"mise x --" | string

	// Each target value is wrapped `*(...) | null` so a consuming
	// project can opt out by writing `targets: "<verb>": null` (e.g.
	// libraries that aren't deployed standalone null out release).
	// Without the disjunction default, the user's `null` would
	// conflict with the inherited concrete struct.
	targets: {
		"setup": *(Mise.install & {
			// target.srcs = gradle setup files (build.gradle.kts,
			// gradle wrapper, etc.) — these are baseline for any cmd
			// in this target. Mise's manifest files (.mise.toml,
			// mise.lock) live on its cmd-level srcs and land in their
			// own COPY just before the mise-install RUN.
			srcs: globs: Gradle.setupSrcs.globs
			// Outs unions target.srcs + mise's installFiles (the
			// effective set the stage stages) so cross-project
			// consumers depending on `:setup` get every file mise
			// install needed plus everything gradle build will. Stamp
			// piggybacks for the fingerprint Merkle short-circuit.
			// Whole-tree `**/*` here would balloon BuildKit's per-COPY
			// cache key.
			outs: globs: list.Concat([Gradle.setupSrcs.globs, Mise.installFiles.globs, [".task/bayt/setup.hash"]])
			taskfile:   setup.taskfile
			dockerfile: bayt.nubox
		}) | null
		"doctor": *(doctor & Mise.doctor) | null
		// build defaults to bayt.incremental so the Dockerfile RUN
		// invokes `task build:build`, which walks :setup:setup inside
		// the stage and installs the toolchain fresh via mise. Without
		// this, cross-stage COPY brings the workdir but not
		// /root/.local/share/mise/ where mise put the tools — direct
		// `mise x -- ./gradlew assemble` would then fail to find java.
		// Consumers can opt out with `dockerfile: incremental: false`.
		"build": *(build & Mise.exec & Gradle.assemble & bayt.incremental & {
			dockerfile: from: ref: ":setup"
		}) | null
		"test": *(test & Mise.exec & Gradle.test) | null
		"launch": *(launch & Mise.exec & Gradle.run & {
			dockerfile: bayt.nubox
		}) | null
		// integrate defaults `dockerfile.from.ref: ":build"` — the
		// canonical FROM-chain for gradle projects. Brings in the
		// build stage's compiled classes + .task/bayt/build.hash so
		// the in-container task chain short-circuits. Projects that
		// need a different base (e.g. a busybox receipt stage) can
		// override at the project level — CUE unification can add to
		// the existing ref-arm but can't switch arms, so a project
		// wanting `from: name: "busybox"` needs to nullify and rebuild
		// the integrate target rather than just merge.
		//
		// preamble (socat install + docker --help warmup) lives at the
		// project level — dind is project-specific (only services that
		// hit the docker socket from inside the test). For tracker the
		// install routes through `setup`'s preamble and reaches
		// integrate via the FROM-chain; no preamble default here.
		"integrate": *(integrate & Mise.exec & Gradle.integrationTest & {
			dockerfile: from: ref: ":build"
		}) | null
		// Release default = JibRelease (FROM-scratch deployable image
		// holding jib's pre-baked layers). The leaf provides the
		// upstream chain (release-artifact runs jibBuildTar via
		// GradleRelease, release-layers extracts the tarball) and the
		// scratch image's ENTRYPOINT/ENV/epilogue COPY.
		//
		// Sibling arm = GradleRelease for non-image gradle releases
		// (publish a JAR, ship a distTar, etc.). The leaf picks the
		// task and outs; bayt just emits a regular RUN-the-task stage.
		// CUE picks the arm by structural fit (JibRelease's
		// `dockerfile.from: null` distinguishes from the GradleRelease
		// arm's gradle cmd + per-task outs).
		"release": *(release & Mise.exec & Gradle.JibRelease) | (release & Mise.exec & Gradle.GradleRelease) | null
		"verify":   *(verify   & Mise.exec & Gradle.check) | null
		"generate": *(generate & {cmd: "builtin": do: *"nu sayt.nu generate" | string}) | null
		"lint":     *(lint     & {cmd: "builtin": do: *"nu sayt.nu lint" | string}) | null
	}
}

// sayt.pnpm — per-project Pnpm. Project-local sources only;
// workspace-root files (pnpm-lock.yaml, etc.) belong to a separate
// workspace-root project (see `sayt.pnpmWorkspace`) that consumers
// wire in via `setup.deps: ["workspaceroot:setup"]`.
pnpm: bayt.#project & {
	activate: *"mise x --" | string

	// Each target is `*(...) | null` so consumers can opt out via
	// `targets: "<verb>": null` (see sayt.gradle for the rationale).
	targets: {
		"setup": *(Mise.install & Pnpm.install & {
			// Empty activate so each cmd controls its own prefix:
			// Mise.install runs `mise install` directly (no
			// `mise x --` wrap — `mise install` is mise's own CLI),
			// while pnpm install wraps via `mise x --` to resolve
			// the pnpm binary mise just installed.
			activate: ""
			// target.srcs is empty: mise's files live on its cmd's
			// srcs, pnpm's project package.json on its cmd's srcs.
			// Each cmd's COPY lands just before its RUN so editing
			// package.json doesn't bust the mise-install layer.
			// SHARP_IGNORE_GLOBAL_LIBVIPS=1: sharp 0.32.x (transitively
			// pulled by ipx, nuxt-image, etc.) detects homebrew/apt
			// libvips and tries to rebuild against it, triggering a
			// node-gyp compile that usually fails in dev environments.
			// Forcing the bundled libvips makes prebuild-install pick
			// the napi-v7 binary that works on any modern node.
			env: SHARP_IGNORE_GLOBAL_LIBVIPS: "1"
			// Nubox base so downstream targets can
			// COPY --from=<project>-setup to inherit the pnpm store
			// + node tools mise installed.
			dockerfile: bayt.nubox
			taskfile: setup.taskfile
		}) | null
		"doctor": *(doctor & Mise.doctor) | null
		"build": *(build & Mise.exec & Pnpm.build & {
			srcs: Pnpm.srcsBuild
			outs: globs: [".output/**/*"]
			// Chain build off setup so the pnpm/node toolchain (in
			// /root/.local/) and .task/bayt/setup.hash flow in via
			// FROM. Avoids re-running `pnpm install` and re-fingerprinting
			// setup inside the build stage's task chain.
			dockerfile: from: ref: ":setup"
		}) | null
		"test": *(test & Mise.exec & Pnpm.test & {
			srcs: Pnpm.srcsTest
			outs: globs: [
				"coverage/**/*",
				"test-results/**/*",
			]
		}) | null
		"launch": *(launch & Mise.exec & Pnpm.dev & {
			dockerfile: bayt.nubox
			compose: develop: watch: Pnpm.devWatch
		}) | null
		"integrate": *(integrate & Mise.exec & Pnpm.testInt & {
			srcs: Pnpm.srcsIntegrate
			// Chain integrate off build (inherits .task/bayt/build.hash
			// + the already-built artifacts via FROM, so the in-container
			// task chain's `::bayt:build` dep short-circuits).
			dockerfile: from: ref: ":build"
		}) | null
		"release": *(release & Mise.exec & {
			// Chain release off build so the artifact (.output/) and
			// node toolchain are present without re-running
			// `pnpm build`. Inherits build's base (nubox/leap), which
			// is larger than ideal for production — projects that want
			// a minimal runtime image (e.g. node:slim + COPY .output)
			// override `dockerfile.from` per-target. Default cmd is
			// `true` (no-op): release is a packaging step whose RUN
			// command varies per service.
			cmd: "builtin": do: *"true" | string
			dockerfile: from: ref: ":build"
		}) | null
		"verify":   *(verify   & Mise.exec & Pnpm.testE2E) | null
		"generate": *(generate & {cmd: "builtin": do: *"nu sayt.nu generate" | string}) | null
		"lint":     *(lint     & Mise.exec & Pnpm.lint) | null
	}
}

// sayt.pnpmWorkspace — the monorepo-root project that owns
// workspace-level pnpm state (pnpm-lock.yaml, pnpm-workspace.yaml,
// root package.json, root .mise.toml) plus a few cross-stack
// workspace files (gradle's libs.versions.toml, devserver's
// dind.sh) that consumers depend on.
pnpmWorkspace: bayt.#project & {
	// No activate prefix — workspace-root is a pure files-declarer
	// project. Its setup target runs `true` (no-op); wrapping that
	// in `mise x --` would resolve the ambient toolchain and blow up
	// PATH for no benefit (and on macOS with a large PATH, execvP
	// fails with "path too long" before it even runs).
	// Concrete (not `*"" | string`) so the default doesn't compete
	// with bayt.#project's `*"mise x --" | string` during unification.
	activate: ""
	dir:      *"" | string

	targets: {
		// wsroot is a pure files-declarer; it doesn't run Mise.install
		// (no toolchain provisioning). Compose sayt.setup for the
		// taskfile config and stage the files directly.
		"setup": P=setup & {
			activate: ""
			srcs: globs: list.Concat([
				[".mise.toml", "mise.lock"],
				Pnpm.workspaceFiles.globs,
				[
					// JVM composite builds resolve catalog plugin via
					// ../../gradle/libs.versions.toml from depth-2
					// projects. Stage it here so JVM projects can
					// depend on workspaceroot:setup to get
					// /monorepo/gradle/libs.versions.toml in their
					// container.
					"gradle/libs.versions.toml",
					// dind.sh (Docker-in-Docker bootstrap) must be
					// present in any integrate container that wraps
					// its RUN with it. Staging it here means it
					// arrives via `COPY --from=workspaceroot-setup`
					// without an extra explicit dep on a devserver
					// project.
					"plugins/devserver/dind.sh",
				],
			])
			// Outs = srcs (so consumers get the exact files staged
			// here) + .task/bayt/setup.hash (so consumers'
			// fingerprint Merkle chain reads wsroot's stamp).
			// Whole-tree `**/*` here would pull the entire monorepo
			// into every consumer's stage, invalidating BuildKit's
			// per-COPY cache on any unrelated repo edit — a major
			// cache-blast-radius regression.
			outs: globs: list.Concat([P.srcs.globs, [".task/bayt/setup.hash"]])
			env: SHARP_IGNORE_GLOBAL_LIBVIPS: "1"
			dockerfile: bayt.nubox
			// No-op — the consumer's setup stage owns the real
			// `pnpm install`. This target exists to stage the
			// workspace files into /monorepo/ (so the consumer's
			// pnpm install finds them via its workspace traversal)
			// and to act as the shared cache key: any change to
			// pnpm-lock.yaml or pnpm-workspace.yaml invalidates
			// every consumer.
			cmd: "builtin": do: *"true" | string
		}
	}
}
