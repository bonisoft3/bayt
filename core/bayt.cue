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
		// Structured wrap. When set, the RUN line gets `--mount=type=
		// secret,…` flags for each entry in `secrets`, and the cmd body
		// is wrapped in a /bin/sh -c '<setup>; trap <teardown> EXIT;
		// <cmd>' shell. Setup lines come from (in order):
		//   - each `secrets[].var.contents`/`.path` sugar (auto-emits
		//     `export <name>=…`)
		//   - `defaultSteps` (framework-supplied, keyed, ordered by
		//     priority — composable / overridable by key)
		//   - `steps` (project-leaf-additive plain list)
		// Teardown is a single combined trap firing the steps' `post`
		// lines in LIFO order, each protected with `${var:-}` guards in
		// the user's source.
		inject?: {
			secrets: [...{
				// Foreign-keyed to a compose `build.secrets[].id` on the
				// same target. The stack defines both halves; CUE does
				// not statically enforce (naming convention).
				id: string

				// Optional sugar — when set, emit a setup line at the
				// head of the wrap body. `contents` and `path` compose:
				// set both to extract the secret into an env var AND
				// place the secret content at a file path.
				var?: {
					// export <contents>="$(cat /run/secrets/<id>)" —
					// extract secret content into the named env var.
					contents?: string
					// Absolute path inside the sandbox where the secret
					// content should be written. Skipped silently when
					// the mounted secret is empty (compose env-source
					// unset). Mounting mode is preserved via `cp`.
					path?: string
				}

				// BuildKit --mount target= (literal absolute path). When
				// unset the secret appears at /run/secrets/<id>.
				target?: string
				// File mode for the mounted secret (e.g. "0600").
				mode?: string
			}]

			defaultSteps: *null | #MapAsList
			steps:        *[] | [...{pre: string, post?: string}]
		}

		mounts?:  [...#dockerfile.#mount]
		secrets?: [...string]
		network?: *"default" | "none" | "host"
	}

	// Inject mode wraps cmd.do as the last shell line of a `RUN
	// <<HEREDOC` body — Dockerfile's heredoc-RUN form is interpreted
	// by /bin/sh. cmd.do becomes an honest shell line only when
	// `shell: "sh"`; any other value silently misrepresents what
	// runs. Enforce at the schema level so authors can't declare
	// `shell: "exec"` (or "nu", "bash", etc.) alongside an inject
	// block without a clear CUE error.
	if dockerfile != _|_ && dockerfile.inject != _|_ {
		shell: "sh"
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

// Resolve a Bazel-style ref to its qualified compose-service name plus
// a view discriminator. Six ref shapes:
//
//   `:target`               same-project workdir COPY from the build stage
//   `proj:target`           cross-project workdir COPY from the build stage
//   `:target:srcs`          same-project, scratch image holding srcs only
//   `:target:outs`          same-project, scratch image holding outs only
//   `proj:target:srcs|outs` cross-project, same view discrimination
//   `:bayt` / `proj:bayt`   per-project scaffolding stage (the .bayt/ tree)
//
// Returns `name` (the qualified compose service) and `_kind` ∈
// {workdir, srcs, outs, bayt} so downstream emitters can dispatch on
// view without re-parsing.
#qualifyRef: {
	ref:  string
	proj: string
	let _parts = strings.Split(ref, ":")
	let _proj = [
		if _parts[0] == "" {proj},
		if _parts[0] != "" {_parts[0]},
	][0]
	let _target = _parts[1]
	// Third segment when present; `""` otherwise. The `if cond { body }`
	// branch isn't evaluated when cond is false, so `_parts[2]` stays
	// safe even when the ref has only two segments.
	let _suffix = [
		if len(_parts) >= 3 {_parts[2]},
		"",
	][0]
	_kind: [
		if _target == "bayt" {"bayt"},
		if _suffix == "srcs" {"srcs"},
		if _suffix == "outs" {"outs"},
		"workdir",
	][0]
	name: [
		if _kind == "bayt" {"\(_proj)-bayt"},
		if _kind == "srcs" {"\(_proj)-\(_target)_srcs"},
		if _kind == "outs" {"\(_proj)-\(_target)_outs"},
		"\(_proj)-\(_target)",
	][0]
}

#dockerfile: D={
	// _project — injected by #target so the `from: ref: ":<target>"`
	// shorthand can resolve same-project refs without the user passing
	// the project name explicitly.
	_project: string

	// #mount — BuildKit mount spec, discriminated by `type`. Nested
	// here because it's dockerfile-domain (BuildKit syntax) and
	// consumed only by emitters that touch dockerfile output: this
	// block's `mounts` and the per-cmd `#cmd.dockerfile.mounts`
	// decoration.
	//
	// The disjunction enforces per-type field shapes:
	//   - Cache mounts can't carry `id` or `sharing` — the emitter
	//     synthesises both per-target. Every other cache-mount mode
	//     has subtle problems; a per-target locked mount captures
	//     most of the benefit without hitting any:
	//       - `sharing=shared` lets concurrent RUNs touch the cache
	//         while buildkit is still using it for layer reuse,
	//         silently rebuilding layers on subsequent runs.
	//       - `sharing=private` hands every RUN a fresh empty cache;
	//         no reuse at all.
	//       - `sharing=locked` with the default id (the mount target
	//         path) serialises every parallel RUN that mounts the
	//         same path on one global lock, killing cold-build
	//         parallelism.
	//     Trade-off: each (project, target) keeps its own cache slot.
	//   - Secret/ssh mounts accept `id` (the secret/ssh-key name).
	#mount: {
		type:   "cache"
		target: string
		required: *false | bool
	} | {
		type:     "secret"
		target?:  string
		source?:  string
		id?:      string
		required: *false | bool
	} | {
		type:     "bind"
		target?:  string
		source?:  string
		required: *false | bool
	} | {
		type:     "ssh"
		target?:  string
		source?:  string
		id?:      string
		required: *false | bool
	} | {
		type:     "tmpfs"
		target?:  string
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
		name: string & !~"^scratch$"
	}) | close({
		// FROM is inheritance-only: the whole upstream stage filesystem
		// flows in. The `:srcs` / `:outs` views are scratch packaging
		// stages that you'd never want as a FROM base, so reject the
		// suffix at the schema level. `dockerfile.copy[].from.ref`
		// accepts all suffixes (curated COPYs are exactly the use case
		// for the narrow views).
		ref: string & !~":(srcs|outs)$"
		// Qualified alias: `<project>-<target>` rather than just
		// `<target>`. BuildKit silently collapses `FROM X AS Y` when
		// X==Y (the downstream stage steals the upstream's name), so
		// a same-target chain like `FROM setup AS setup` would lose
		// the chain entirely. Qualifying with project disambiguates.
		name: (#qualifyRef & {"ref": ref, proj: D._project}).name
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
	mounts: [...#mount]
	// Per-id secret source map, mirrors compose-spec `secrets.<id>`.
	// null → file at ${BAYT_<UPPER_ID>_FILE}; {environment: V} → bake
	// reads $V at compose-up time; {file: P} → explicit path.
	secrets: [Name=string]: *null | close({
		environment: string
	}) | close({
		file: string
	})

	extra_hosts: [...string]

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
	// from.name doubles as the additional_context key and the
	// `--from=<name>` reference in the COPY. Default value emitted
	// in additional_contexts is `docker-image://<name>`; `image:`
	// overrides that so one fixed key aliases a pinned digest
	// (bayt-runtime → docker-image://bonitao/bayt:…).
	copy: [...{
		from: *null | close({
			name:   string & !~"^scratch$"
			image?: string
		}) | close({
			ref:  string
			name: (#qualifyRef & {"ref": ref, proj: D._project}).name
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

	// incremental — when true (default), the per-target Taskfile entry
	// emits go-task's `status:` hook (fingerprint.nu stamp check),
	// `BAYTW` cache.nu wrapper for the cmds, and the `defer:`
	// update-stamp on success. The full work-avoidance loop.
	//
	// Set false for ephemeral / always-fresh tasks where stamp-based
	// skip is undesirable (e.g. doctor checks, regenerators that
	// derive from external state, runtime test commands where the
	// outer cache layer already gates execution).
	//
	// Orthogonal to dockerfile.incremental: this gates the Taskfile
	// shape, which fires the same machinery whether the task is
	// invoked from a Dockerfile RUN at build-time or from a compose
	// `command:` at runtime. The `bayt.incremental` capability turns
	// BOTH flags on plus adds the shared-storage cache mount for
	// cache.nu's local backend.
	incremental: *true | bool

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
	platforms: *[] | [...string]
	tags:      [...string]
	args: [string]: string
	// Buildx cache wiring. Same record feeds two emitters:
	//   - gen_bake.cue → `bake.<target>.hcl` cache-from / cache-to
	//   - gen_compose.cue → `compose.yaml` build.x-bake.{cache-from,cache-to}
	//
	// On a #target, only `from` / `to` are meaningful — they carry the
	// resolved per-target cache strings. The sugar inputs (`type`,
	// `scope`, `registry`) live at #project.bake.cache and are consumed
	// by the per-target loop, which composes `from` / `to` with the
	// target name baked into each scope key (so mode=max writers from
	// sibling targets can't clobber each other).
	//
	// Sugar by type (set at #project.bake.cache):
	//   - "gha":      requires `scope`.
	//   - "registry": requires `registry` + `scope`.
	//
	// Sugar and passthrough are mutually exclusive: when `type` is set,
	// `from` / `to` are constrained to `[]`. Mixing the two (e.g.
	// `type: "gha"` alongside `from: ["custom"]`) fails CUE unification
	// rather than silently dropping one side.
	cache: C={
		type?:     "gha" | "registry"
		scope?:    string
		registry?: string
		from:      [...string]
		to:        [...string]
		if C.type != _|_ {
			from: []
			to:   []
		}
	}
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

	// Project-level bake config. Same #bake schema as #target.bake;
	// the cache.from/to lists (whether typed directly or derived from
	// the type+scope[+ref] sugar) propagate down to every target with
	// {target} substituted to `<project>-<target>` so each target's
	// mode=max writer doesn't clobber its siblings. Optional —
	// non-release projects leave this unset.
	bake?: #bake

	// Targets. Map key becomes target.name; project name + dir are
	// propagated so cross-project dep refs can build relative paths.
	// `| null` lets a project opt out of a target inherited from a
	// stack umbrella — e.g. a library that uses `sayt.gradle` but
	// has no release/launch/verify writes `targets: "release": null`.
	// Emitters filter null entries when iterating.
	//
	// Reserved target-name patterns. The emitter synthesizes:
	//   `<proj>-bayt`           per project — scaffolding (.bayt/ tree)
	//   `<proj>-<target>_srcs`  per target — srcs scratch image
	//   `<proj>-<target>_outs`  per target — outs scratch image
	// Authoring a target whose name collides with any synthetic would
	// produce two services with the same qualified name (or two
	// .bayt/Dockerfile.<n> files at the same path). The regex rejects:
	//   - exact `bayt` (collides with the project synthetic)
	//   - anything ending in `_bayt`, `_srcs`, or `_outs`
	//     (collides with file-name + service-name pattern of synthetics)
	// Names with incidental endings (e.g. `playbayt`, `outside`) are
	// allowed — only the underscore-suffix forms are reserved.
	targets: [Name=string]: (#target & {
		name:    Name & !~"^bayt$|_(srcs|outs|bayt)$"
		project: P.name
		dir:     P.dir
		// Compose per-target cache strings with this target's name
		// baked into the scope key (mode=max writers from sibling
		// targets would otherwise clobber). Sugar at P.bake.cache
		// (type + scope [+ registry]) selects a backend recipe;
		// explicit P.bake.cache.from / to win when non-empty.
		if P.bake != _|_ {
			let _t = "\(P.name)-\(Name)"
			let _c = P.bake.cache
			bake: cache: {
				from: [
					if len(_c.from) > 0 {_c.from},
					if _c.type == _|_ {[]},
					if _c.type == "gha" {[
						"type=gha,scope=main-\(_t)",
						"type=gha,scope=\(_c.scope)-\(_t)",
					]},
					if _c.type == "registry" {[
						"type=registry,ref=\(_c.registry):\(_c.scope)-\(_t)",
					]},
				][0]
				to: [
					if len(_c.to) > 0 {_c.to},
					if _c.type == _|_ {[]},
					if _c.type == "gha" {[
						"type=gha,mode=max,scope=\(_c.scope)-\(_t)",
					]},
					if _c.type == "registry" {[
						"type=registry,ref=\(_c.registry):\(_c.scope)-\(_t),mode=min,image-manifest=true,oci-mediatypes=true",
					]},
				][0]
			}
		}
	}) | null
}

