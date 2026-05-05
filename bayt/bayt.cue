// Package bayt is the CUE DSL for cross-format build targets.
// See docs/plans/2026-03-10-bazel-dsl-design.md for the full design.
//
// A #target describes a build unit: portable action (srcs/outs/deps/cmd)
// plus optional output-file-named blocks (dockerfile, compose, taskfile,
// skaffold, vscode, bake). Presence of a block = "emit this format".
//
// Composition uses CUE unification and the rulemap pattern from config.cue
// (#MapAsList / #MapToList). No string-keyed indirection, no inherits:.
package bayt

import "strings"

// #MapAsList / #MapToList live in mapaslist.cue.
// _uniqStrings (and other list comprehensions) live in listutils.cue.

// =============================================================================
// #cmd — a single command rule in the rulemap on #target.cmd.
//
// Two decoration axes:
//   - OS:             cmd.windows / cmd.linux / cmd.darwin  (picked at runtime)
//   - output-format:  cmd.dockerfile / cmd.vscode (picked at emission
//                     time by the corresponding generator)
//
// Far-away unification: a dockerfile block can decorate a cmd by setting
//   cmd: "builtin": dockerfile: mounts: [...]
// without the cmd itself knowing about the dockerfile block.
// =============================================================================

// Shells we know about. Closed disjunction (no open `string` arm) so a
// typo in a stack or project bayt.cue fails CUE evaluation rather than
// silently flowing through. Add a shell here when a real consumer
// needs it; we'd rather grow the list explicitly than open the schema.
// Covers: bare exec (no shell wrap, whitespace-tokenized argv), POSIX
// family (sh/bash/dash/ash), modern *nix shells (zsh/fish), the
// Windows pair (powershell legacy 5.x + pwsh 7+), cmd, and nushell
// (bayt's own runtime shell, mise-installed cross-platform).
//
// "exec" is the right choice for cmds that are a single program
// invocation with args (most build commands fit). For cmds with shell
// features — pipes, redirects, glob expansion, env-var interpolation,
// `&&` chains — pick a concrete shell.
#shell: *"exec" | "nu" | "sh" | "bash" | "dash" | "ash" | "zsh" | "fish" | "powershell" | "pwsh" | "cmd"

#cmd: {
	name:     string
	priority: *0 | int
	shell:    #shell
	do:       string
	stop:     *false | bool

	// Per-cmd srcs — additive to the enclosing target's srcs. Same
	// {globs, defaultGlobs, exclude, defaultExclude} shape as
	// #target.srcs but defaults to empty, so the simple case (one
	// fileset per target) doesn't surface this layer.
	//
	// Effective cmd srcs (what fingerprint.nu hashes) = target.srcs ∪
	// cmd.srcs. Use when one target has multiple cmds with diverging
	// inputs — e.g. pnpm setup runs `mise install` (.mise.toml,
	// mise.lock) and then `pnpm install` (package.json,
	// pnpm-lock.yaml); per-cmd srcs let editing package.json
	// invalidate just the pnpm cmd's stamp instead of the whole
	// target's.
	srcs: {
		globs:          *[] | [...string]
		defaultGlobs:   *null | #MapAsList
		exclude:        *[] | [...string]
		defaultExclude: *null | #MapAsList
	}

	// OS axis — each variant fully overrides do/shell. Same closed
	// `#shell` set as the top-level field; uniform treatment across
	// every OS variant.
	windows?: {do?: string, shell?: #shell}
	linux?:   {do?: string, shell?: #shell}
	darwin?:  {do?: string, shell?: #shell}

	// Output-format axis — decorations applied only when emitting that format.
	dockerfile?: {
		wrap?:    string
		mounts?:  [...#dockerfile.#mount]
		secrets?: [...string]
		network?: *"default" | "none" | "host"
	}
	vscode?: {
		windows?: {
			command?: string
		}
	}
}

// noop — a #cmd that does no real work but emits a real RUN/cmd line
// in every format. Use when a target needs a step in the chain (e.g.
// to anchor a stamp, hold a place in the dep graph, or carry an
// epilogue COPY) but has no actual command to run. Bare-exec form
// across the board: `/bin/true` on Linux/macOS, `where /q where` on
// Windows (where.exe is always at C:\Windows\System32\where.exe; the
// /q flag suppresses output; looking for `where` itself reflexively
// signals "this is a noop" in the source).
//
// Distinct from `cmd: <name>: null`, which drops the cmd from the
// rulemap entirely — emitter writes nothing. Use null when there's
// genuinely nothing to do; use noop when the chain needs a marker.
noop: #cmd & {
	do:    "true"
	shell: "exec"
	windows: {
		do:    "where /q where"
		shell: "exec"
	}
}

// =============================================================================
// Output-file-named blocks — presence means "emit this format".
// Kept narrow; each carries only what cannot be derived from the portable
// action. Deps/srcs/outs live on #target, not here.
// =============================================================================

#dockerfile: D={
	// _project — injected by #target so the `from: ref: ":<target>"`
	// shorthand can resolve same-project refs without the user passing
	// the project name explicitly.
	_project: string

	// #mount — BuildKit mount spec, nested here because it's
	// dockerfile-domain (BuildKit syntax) and consumed only by emitters
	// that touch dockerfile output: this block's `mounts` and the
	// per-cmd `#cmd.dockerfile.mounts` decoration.
	#mount: {
		type:     "cache" | "secret" | "bind" | "ssh" | "tmpfs"
		target?:  string
		source?:  string
		id?:      string
		sharing?: *"locked" | "shared" | "private"
		// Defaulted so emitters can interpolate without a _|_ check.
		required: *false | bool
	}

	// Field order intentionally mirrors Dockerfile statement order so
	// the CUE struct reads top-to-bottom the same way the emitted
	// Dockerfile does:
	//
	//   FROM <from.name> AS <target>    ← from
	//   WORKDIR <workdir>                ← workdir
	//   <preamble lines>                 ← preamble (lazybox COPY, ENVs, etc.)
	//   COPY --from=<dep> ...            ← (emitter-driven from deps + outs)
	//   RUN ... <cmd>                    ← (emitter-driven from t.cmds)
	//   <epilogue lines>                 ← epilogue
	//   EXPOSE <port> ...                ← expose
	//
	// Build-time-only fields (mounts, secrets) sit alongside the RUN
	// machinery; `incremental` is internal and lives at the bottom.

	// FROM source as a structured additional_contexts entry. Three
	// arms of the disjunction:
	//
	//   null              — emit `FROM scratch AS <target>`. No
	//                       additional_contexts entry. (Docker's parser
	//                       treats `scratch` as a keyword that bypasses
	//                       the context resolver, so `from.name ==
	//                       "scratch"` is rejected on the canonical arm.)
	//
	//   {name, context}   — canonical form. Emits
	//                       `additional_contexts: <name>: <context>`
	//                       then `FROM <name> AS <target>`. `context`
	//                       defaults to `docker-image://<name>`, so the
	//                       common image-FROM case is one line:
	//                         from: name: lock.images.leap
	//
	//   {ref}             — Bazel-style target ref shorthand:
	//                         ":target"          → same-project target
	//                         "project:target"   → cross-project target
	//                       Resolves to {name: "<target>", context:
	//                       "service:<project>-<target>"}; the schema
	//                       fills in _project for the same-project arm.
	//
	// `bayt-runtime` is auto-injected by the emitter when
	// `dockerfile.incremental` is true. If user code picks the same
	// name with a different context, CUE's struct unification of
	// additional_contexts catches the collision — no explicit
	// reservation needed.
	//
	// The two struct arms are CLOSED so mixing them (e.g. an image
	// preset that already sets `name` unified with a user's `{ref:}`
	// override) errors with "no disjunction arm matches" rather than
	// silently picking one. Use ref-arm shorthand on bare targets;
	// FROM-chaining off another bayt target inherits the upstream
	// stage's filesystem and ENVs, so layering a preset on top is
	// neither needed nor expressible.
	from: null | close({
		name:    string & !~"^scratch$"
		context: *"docker-image://\(name)" | string
	}) | close({
		ref: string
		let _parts = strings.Split(ref, ":")
		let _proj = [
			if _parts[0] == "" {D._project},
			if _parts[0] != "" {_parts[0]},
		][0]
		// Qualified alias: `<project>-<target>` rather than just
		// `<target>`. BuildKit silently collapses `FROM X AS Y` when
		// X==Y (the downstream stage steals the upstream's name), so a
		// same-target chain like `FROM setup AS setup` would lose the
		// chain entirely. Qualifying with project disambiguates.
		name:    "\(_proj)-\(_parts[1])"
		context: "service:\(_proj)-\(_parts[1])"
	})

	// WORKDIR. Defaults to /monorepo/<projectDir> in the emitter.
	workdir?: string

	// Lines emitted between the base-image setup (FROM + WORKDIR +
	// COPY-from from `dockerfile.copy`) and the project's source COPYs.
	// preamble runs after the base image is fully assembled and before
	// any user code lands, so RUN steps here can rely on COPY-from
	// sources being on PATH/disk (e.g. warming lazybox stubs with
	// `RUN <tool> --version > /dev/null`). The verbatim escape hatch
	// for stage setup (ENVs, package installs, smoke tests). Use
	// `epilogue` for lines after the cmd RUN.
	//
	// Same two-position pattern as `srcs.globs` / `srcs.defaultGlobs`:
	//
	//   preamble        — project-leaf-additive plain list, appended
	//                     after the framework's contribution.
	//   defaultPreamble — framework/preset's #MapAsList, keyed so
	//                     multiple stacks (image preset + dind overlay
	//                     + project add-on) compose by key rather than
	//                     positional list-unification (which is
	//                     length-strict and rejects extension).
	//
	// Element shape is `{name, line: string}` (name auto-derives from
	// the map key). Manifest emits the merged list as
	// `defaultPreamble values + preamble`.
	preamble:        [...string]
	defaultPreamble: *null | #MapAsList

	// Build-time mounts (BuildKit `--mount=type=cache,...`) and
	// secrets (BuildKit `--mount=type=secret,...`). Attached to RUN
	// lines per cmd rulemap.
	mounts:  [...#mount]
	secrets: [...string]

	// Lines emitted after the cmd RUN, before EXPOSE.
	epilogue: [...string]

	// Structured COPY directives. Maps directly to Dockerfile COPY
	// grammar; emitted after the primary FROM, before user preamble.
	//
	// `from` reuses the same shape as the stage's primary `from`:
	// either an external image ref (`name`) or a bayt target ref
	// (`ref`, with `:<target>` or `<project>:<target>` syntax). When
	// `from.ref` is set, the emitter also adds a compose
	// additional_contexts entry so bake resolves the cross-target
	// reference. When `from` is unset, it's an in-context COPY from
	// the build context.
	//
	// `--link` defaults on (BuildKit overlay copies are almost always
	// desirable: faster cache, less invalidation cascade). Other
	// BuildKit flags map directly: --chmod, --chown, --parents,
	// --exclude.
	copy: [...{
		from: *null | close({
			name:    string & !~"^scratch$"
			context: "docker-image://\(name)"
		}) | close({
			ref: string
			let _parts = strings.Split(ref, ":")
			let _proj = [
				if _parts[0] == "" {D._project},
				if _parts[0] != "" {_parts[0]},
			][0]
			name:    "\(_proj)-\(_parts[1])"
			context: "service:\(_proj)-\(_parts[1])"
		})
		srcs:    [...string]
		dst:     string
		chmod?:  string
		chown?:  string
		link:    *true  | bool
		parents: *false | bool
		exclude: [...string]
	}]

	// Structured HEALTHCHECK directive. Maps directly to Dockerfile
	// HEALTHCHECK grammar. `test` follows compose-spec convention:
	//   ["NONE"]                       — disable inherited HEALTHCHECK
	//   ["CMD", arg, ...]              — exec form
	//   ["CMD-SHELL", "shell string"]  — shell form
	// Bayt also emits the same data into compose's healthcheck override
	// (with the additional `start_interval` compose-spec extension), so
	// the directive applies in both `docker run` and `docker compose up`.
	//
	// Authored either directly or via the `bayt.healthcheck.<template>`
	// fragments (http, tcp, postgres, redis, ollama) which set this
	// field plus dockerfile.copy + compose.healthcheck in one
	// declaration.
	//
	// `*null` default makes the field always-defined for guarded reads
	// in the gen pass (matches the `from` pattern).
	healthcheck: *null | close({
		test:          [...string]
		interval?:     string
		timeout?:      string
		retries?:      int
		start_period?: string
	})

	// Ports the runtime listens on. EXPOSE in the Dockerfile.
	expose: [...int]

	// ENTRYPOINT exec form (`ENTRYPOINT ["bin", "arg1", ...]`). Empty
	// list ⇒ no ENTRYPOINT instruction emitted. Required for
	// production images (Cloud Run, k8s) where the platform reads the
	// image's baked-in entrypoint. Distinct from `compose.runtime.entrypoint`,
	// which overrides the image's entrypoint per-service at run time.
	//
	// Mirrors Dockerfile's two-form support:
	//   null         → no ENTRYPOINT instruction (image inherits from
	//                  FROM / scratch). Default.
	//   [...string]  → exec form: ENTRYPOINT ["a", "b", "c"]. Preferred
	//                  for production images — runs without a shell.
	//                  Args go through naive `"arg"` quoting; embedded `"`
	//                  is not escaped (ship a script if you need that).
	//   string       → shell form: ENTRYPOINT cmd args... Wraps the value
	//                  in `/bin/sh -c` at runtime. Convenient for env-
	//                  var substitution but loses signal forwarding.
	entrypoint: *null | [...string] | string

	// Incremental builds: when true, the RUN line invokes
	// `task <n>:<n>` instead of the cmd rulemap directly. go-task's
	// status: hook + fingerprint.nu then provide content-addressed
	// work avoidance INSIDE the container, in addition to BuildKit's
	// layer cache. Stamps persist via a BuildKit cache mount on
	// .task/. Taskfiles are COPY'd into the image automatically.
	// Enable via the `bayt.incremental` capability (capabilities.cue).
	incremental: *false | bool

	// Dockerfile CMD instruction. Same three-form schema as `entrypoint`
	// above. Distinct from `compose.command` (service-level runtime
	// override). Docker's standard ENTRYPOINT/CMD combination applies.
	//   null         → no CMD instruction. Default.
	//   [...string]  → exec form: CMD ["a", "b", "c"].
	//   string       → shell form: wraps in `/bin/sh -c` at runtime.
	cmd: *null | [...string] | string
}

#compose: {
	// #watch — develop.watch entry. Compose-domain (sync/rebuild action
	// vocab is compose-specific), so nested here rather than top-level.
	#watch: {
		action: "sync" | "sync+restart" | "rebuild"
		path:   string
		target: string
		// Optional — compose rejects `ignore: []` on rebuild entries.
		// Either pass a non-empty list or omit.
		ignore?: [...string]
	}

	service?: string

	build?: {
		target?:             string
		dockerfile?:         string
		additional_contexts: [dep=string]: string
		secrets:             [...string]
		args: [string]:      string
	}
	// Compose-spec passthrough — fields here are emitted verbatim onto
	// the compose service. Shape mirrors the actual compose-spec service
	// schema (no synthetic `runtime:` wrapper) so authoring matches the
	// generated YAML.
	image?: string
	// Same `null | list | string` shape as docker-compose's spec —
	// list = exec form (no shell wrapping), string = shell form
	// (`/bin/sh -c …`), null explicitly clears the image's baked-in
	// value. Omit the field entirely to inherit it.
	command?:    null | [...string] | string
	entrypoint?: null | [...string] | string
	environment:  [string]: string
	ports:        [...string]
	volumes:      [...string]
	// Compose-spec long form: map keyed by service name with per-dep
	// config (typically `{condition: "service_healthy"}`). Bayt
	// passes this through verbatim and auto-mirrors keys as
	// additional_contexts entries (see gen_compose.cue) so consumers
	// don't have to write the build-tree mirror by hand.
	depends_on:   {[string]: _}
	network_mode?: string
	healthcheck?: {...}
	develop?: {
		watch: [...#watch]
	}
}

#taskfile: {
	task?:   string
	run:     *"when_changed" | "once" | "always"
	silent:  *false | bool
	desc?:   string

	preconditions: [...{sh: string, msg?: string}]

	// `sources:` / `generates:` intentionally NOT exposed here. go-task
	// uses them for its own checksum-based change detection, but bayt
	// handles change detection through fingerprint.nu reading srcs/outs
	// from the per-target manifest. Carrying both is redundant at best
	// and lets the two pictures drift at worst. The schema is a closed
	// definition, so naming `sources:` / `generates:` (or the previous
	// `extraSources:` / `extraGenerates:`) anywhere up the unification
	// chain fails CUE evaluation.
}

// #skaffold — profile-only emission shape. Per-target skaffold fragment
// emitted to .bayt/<target>.skaffold.yaml carries ONLY apiVersion +
// kind + metadata at the base level. Everything else (artifact, sync,
// manifests, test, verify, portForward) lives inside named profiles.
//
// Why profiles-only: skaffold's `requires:` is purely additive — a
// parent that includes a fragment can activate child profiles by name
// but cannot patch or override the child's base content. With image,
// platforms, push policy, etc. in base, every parent gets them
// unconditionally. With those decisions in profiles, parents pick.
//
// Activation: profiles auto-fire via skaffold's built-in `activation:`
// rules (command/kubeContext/env). stacks/sayt picks names + activation
// rules; bayt-the-schema doesn't interpret either.
#skaffold: {
	// Map keyed by skaffold profile name. Emitted as an ordered list
	// (alphabetical by key) at gen time; profile order doesn't affect
	// skaffold semantics. Null entries are filtered out so a project
	// that wants to opt out of a stack-supplied profile says
	// `skaffold: profiles: "<name>": null`.
	profiles: [Name=string]: (#skaffoldProfile & {name: Name}) | null
}

#skaffoldProfile: {
	name: string
	// Auto-activation rules. Empty list = explicit-only (`-p <name>`
	// CLI or `activeProfiles:` propagation from a parent require).
	//
	// command — closed enum of skaffold's CLI verbs. Add a value here
	//   when a real consumer needs it; the typo-loud trade is the
	//   same as #shell.
	// kubeContext — Go regexp matched against the active kube-context
	//   name (e.g. "kind-iris" or "gke_.*-prod-.*"). CUE doesn't
	//   compile regexps so we just constrain the shape: non-empty.
	// env — "VAR=value" or "VAR=<regex>" per skaffold's spec; one
	//   single rule per entry. Constrained to that shape.
	activation: *[] | [...{
		command?:     "dev" | "run" | "build" | "test" | "debug" | "deploy" | "render" | "apply"
		kubeContext?: string & !=""
		env?:         =~"^[A-Za-z_][A-Za-z0-9_]*=.+$"
	}]

	// Build artifact. One per profile — multi-image needs come from
	// emitting multiple profiles or wrapping bake in a custom build.
	build: {
		artifact: #skaffoldArtifact
		local: {
			useBuildkit: *true | bool
			concurrency: *64 | int
			push:        *false | bool
		}
		// Build platforms list. Empty = let docker daemon pick its
		// native target (the right default for `skaffold dev`); pin
		// explicitly for release profiles targeting a fixed runtime.
		platforms: *[] | [..."linux/amd64" | "linux/arm64" | "linux/arm/v7" | "linux/arm/v6" | "linux/386" | "linux/ppc64le" | "linux/s390x" | "linux/riscv64"]
		// tagPolicy controls the image tag skaffold computes. When
		// unset, skaffold defaults to `gitCommit: {variant: Tags}`,
		// which uses `git describe --tags`. On a monorepo with
		// prefixed tags (services/tracker/v…) that yields a tag
		// containing slashes that skaffold then normalizes,
		// generating a noisy WARN. Profiles that care should pick a
		// tag policy explicitly. Common picks:
		//   gitCommit:  {variant: AbbrevCommitSha}  (7-char hash)
		//   sha256:     {}                          (content-addressable)
		//   inputDigest: {}                         (build-input hash)
		// Schema is loose (any struct) — skaffold validates the shape.
		tagPolicy?: {...}
	}

	manifests: kustomize?: paths: [...string]
	test:        *[] | [...]
	verify:      *[] | [...]
	portForward: *[] | [...]
}

// #skaffoldArtifact — one of three build modes. CUE doesn't enforce
// mutual exclusion across optional fields (would need closed-struct
// disjunction gymnastics); the gen_skaffold.cue emitter validates
// exactly-one-set at emit time.
//
//   docker — build via .bayt/<n>.Dockerfile.
//   custom — arbitrary buildCommand string. Use for tools skaffold
//            doesn't speak natively (jib via gradle, ko, …).
//   bake   — sugar for `custom`. The emitter expands {file, target}
//            into `docker buildx bake -f <file> <target>`.
#skaffoldArtifact: {
	// image — registry ref the artifact builds. Optional so a stack can
	// seed activation + dockerfile defaults without forcing every
	// project that composes the verb fragment to declare a skaffold
	// image. The emitter skips a profile entirely when image is unset
	// or empty — it's the project's opt-in lever for cluster-side dev.
	image?:  string
	// Skaffold resolves `context` relative to its INVOCATION cwd
	// (sayt verbs invoke from the project root), not the config-file
	// location. Default `.` lands customBuild's cwd at the project
	// root — what consumers expect for `-f .bayt/<config>` paths and
	// project-relative `docker compose config`. Targets needing a
	// different context (e.g. workspace root) override per-target.
	context: *"." | string
	sync: {
		manual: *[] | [...{src: string, dest: string}]
		auto:   *false | bool
	}
	docker?: {dockerfile: string}
	custom?: {buildCommand: string}
	bake?:   {file: string, target: string}
}

#vscode: {
	label?:       string
	group?:       {kind: "build" | "test" | "none", isDefault?: bool}
	detail?:      string
	dependsOn:    [...string]
	dependsOrder: *"sequence" | "parallel"
}

#bake: {
	// Registry image; becomes `variable "IMAGE" { default = ... }` so the
	// skaffold custom-command contract can override via $IMAGE env var.
	image?: string
	// Toggle push-to-registry vs load-to-daemon. Becomes `variable
	// "PUSH_IMAGE" { default = ... }`; emitter writes the conditional
	// `output = PUSH_IMAGE == "true" ? ["type=registry"] : ["type=docker"]`.
	// Skaffold / CI override via env. Default false.
	push: *false | bool
	// Optional GHA cache scope. Non-empty enables `cache-from` / `cache-to`
	// referencing the CACHE_SCOPE variable plus a hard-coded `main` scope.
	cacheScope?: string
	platforms: *["linux/amd64", "linux/arm64"] | [...string]
	tags:      [...string]
	args: [string]: string
	cacheFrom: [...string]
	cacheTo:   [...string]
}

// =============================================================================
// #target — the build unit.
//
// Identity (name, project) is bound by the enclosing #project. Everything
// else is either the portable action or an optional output-file block.
// =============================================================================

#target: {
	// Bound by the enclosing #project.targets map key.
	name: string

	// Injected by #project — the project's name and dir. Emitters
	// read these on cross-project dep refs (when dep.project differs
	// from the consuming project's) to compute the relative include
	// path. The string-typed field `project` doesn't collide with the
	// schema definition `#project` because `#`-prefix names live in a
	// separate namespace.
	project: string
	dir:     string

	// --- Portable action (format-agnostic) ---
	// srcs — input files that invalidate this target. globs+exclude both
	// project-relative (no `..` escapes — files outside the project dir
	// belong to a workspace-root project, reached via cross-project deps).
	//
	// Two-position composition for additive lists:
	//
	//   - `globs` / `exclude` (plain `[...string]`) — the user-side
	//     position. Leaves typically write a small list here. Replaces
	//     whatever a stack has set; ergonomic for the common case.
	//
	//   - `defaultGlobs` / `defaultExclude` (`*null | #MapAsList`) —
	//     the framework-side position. Stacks register named entries
	//     here so other stacks (or layered conventions) can compose,
	//     modify, or null-delete by key without positional list-
	//     unification gymnastics. Each entry is `{glob: string,
	//     priority?: int}`.
	//
	// The manifest emits the merged list (defaultGlobs values + globs)
	// as `srcs.globs`; downstream emitters see only the resolved form.
	//
	// outs — files this target exposes to consumers. Same shape as srcs.
	// For cross-project consumers via `deps:`, only outs are COPYed (the
	// declared interface). For same-project chain via `dockerfile.from`,
	// the entire stage filesystem flows in (outs irrelevant). For
	// out-of-tree side effects (toolchain installs at /root/.local/...),
	// use `dockerfile.from` to inherit the producer stage.
	srcs: {
		globs:          [...string]
		defaultGlobs:   *null | #MapAsList
		exclude:        *[] | [...string]
		defaultExclude: *null | #MapAsList
	}
	outs: {
		globs:   [...string]
		exclude: *[] | [...string]
	}

	// visibility — who is allowed to consume this target.
	//   "internal" (default) — only same-project verbs may reference this
	//     via `deps:` or `dockerfile.from:`. Generation errors if a
	//     cross-project bayt.cue tries to depend on it.
	//   "public" — any project may reference this via `deps:` or
	//     `dockerfile.from:`. The target's compose service joins the
	//     federation graph published to consumers.
	// Note: same-project consumers can always reach internal targets;
	// visibility only governs cross-project access.
	visibility: *"internal" | "public"

	// Toolchain activator. Default comes from the enclosing #project.activate;
	// per-target override rare. Emitters read project.activate directly.
	activate?: string

	// Shorthand: `do: "cmd"` on a target desugars into the full form
	// `cmd: "builtin": do: "cmd"`. Keeps the common case (a single
	// shell command, no OS variants, no dockerfile wrapping) terse
	// while leaving the full cmd rulemap available for layered cases
	// like `cmd: "builtin": { do: ..., windows: {...}, dockerfile: {...} }`.
	// Mirrors sayt.cue's `say.<verb>.do` convention.
	do?: string
	if do != _|_ {
		cmd: "builtin": "do": do
	}

	cmd: [Name=string]: #cmd & {name: Name} | null
	env: [string]: string

	// Deps as Bazel-style target refs:
	//   ":<target>"          — same-project target (leading `:`)
	//   "<project>:<target>" — cross-project target (project is the
	//                          producer's #project.name; defaults from
	//                          dir via slash→underscore).
	// The nushell runtime builds a project_index (project_name → dir)
	// up front, resolves cross-project refs to manifest JSON, and
	// injects them via `_deps` before the second CUE export pass.
	deps: [...string]

	// --- Output-file-named blocks (all optional) ---
	// dockerfile gets `_project` injected so its `from: ref: ...`
	// shorthand can resolve same-project refs without the user passing
	// the project name explicitly.
	dockerfile?: #dockerfile & {_project: project}
	compose?:    #compose
	taskfile?:   #taskfile
	skaffold?:   #skaffold
	vscode?:     #vscode
	bake?:       #bake

	// healthcheck — parameter holder for the bayt.healthcheck.<template>
	// fragments. The fragments unify into the target, reading their
	// inputs from this field and setting dockerfile.copy +
	// dockerfile.healthcheck + compose.healthcheck. Open-typed because
	// each template defines its own input schema.
	healthcheck?: _

	// hmr — destination-side classification of srcs entries for the
	// dev loop. Each kind maps to a compose.develop.watch action:
	//   code    → sync (framework HMR if `native: true`, else watchexec --restart)
	//   configs → sync + SIGHUP (watchexec wraps cmd to signal-reload)
	//   assets  → sync+restart (compose-managed full container restart)
	//   tools   → rebuild (compose-managed image rebuild)
	//   docs    → ignored everywhere (no sync, no rebuild)
	// `native` is set by the stack (Pnpm.dev sets it to true since Vite/Next
	// handle their own watching internally). When false, bayt wraps the
	// launch cmd in nested watchexec layers for code-restart and configs-
	// SIGHUP. The watchexec binary comes from lazybox via the standard
	// nubox overlay (no extra dockerfile.copy needed for nubox-based stages).
	hmr?: {
		native:  *false | bool
		code:    [...string]
		configs: [...string]
		assets:  [...string]
		tools:   [...string]
		docs:    [...string]
	}

	// Resolved cmd list (priority-sorted, nulls removed).
	cmds: (#MapToList & {in: cmd}).out

	// cache — content-addressable cache.nu wrap behavior. Two
	// orthogonal opt-in flags; defaults to "exact-match only, run
	// cmd on hit" (the safest, least-effective shape).
	//
	//   full (default false) — on EXACT match, skip cmd entirely.
	//     The cache is treated as a complete reproduction of the
	//     cmd's effect. Reserved for cmds whose even-no-op startup
	//     cost is intolerable (gradle's daemon roundtrip is the
	//     canonical case). Trades cmd-side correctness checking
	//     for raw speed.
	//
	//   similar (default false) — on EXACT-match miss, look for the
	//     "closest" cached entry (weighted intersection over inputs
	//     + user/branch/day metadata) and restore its outs as a
	//     warm starting state before running cmd. Cache becomes a
	//     starting point, not a final answer; cmd's incremental
	//     engine (gradle's UP-TO-DATE walk, cargo's fingerprinting)
	//     does the work delta. Safe when the cmd validates restored
	//     state — true for every modern build tool.
	//
	// Use bayt.cache.full / bayt.cache.similar capabilities to set.
	cache: {
		full:    *false | bool
		similar: *false | bool
	}
}

// =============================================================================
// #project — a named group of targets sharing toolchain activation.
// =============================================================================

#project: P={
	// Relative to monorepo root; copybara-friendly. Primary identity
	// — `name` defaults from `dir` via slash→underscore (with the
	// empty-dir workspace-root case mapping to "workspaceroot",
	// matching what generate-bayt.nu prints). Override only when the
	// project's conventional name diverges from its directory.
	dir:  string
	name: *[
		if dir == "" {"workspaceroot"},
		if dir != "" {strings.Replace(dir, "/", "_", -1)},
	][0] | string

	// Toolchain activator; prefixes every emitted command. Emitters read
	// it from here; targets don't carry it unless they need to override.
	activate: *"mise x --" | string

	// Optional target-level defaults unified into every target.
	defaults?: #target


	// Targets. Map key becomes target.name; project name + dir are
	// propagated so cross-project dep refs can build relative paths.
	// `| null` lets a project opt out of a target inherited from a
	// stack umbrella — e.g. a library that uses `sayt.gradle` but
	// has no release/launch/verify writes `targets: "release": null`.
	// Emitters filter null entries when iterating.
	targets: [Name=string]: (#target & {
		name:    Name
		project: P.name
		dir:     P.dir
		if P.defaults != _|_ {P.defaults}
	}) | null
}
