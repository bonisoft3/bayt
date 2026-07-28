// stacks/bun — bun/Node.js toolchain concept library.
//
// Pure bun concepts — no opinion about which target each lands on.
// A project unifies these fragments into its bayt targets.
package bun

import "list"

// =============================================================================
// Toolchain concept library.
// =============================================================================

// Cache mount for bun's global install cache. `scope: "global"`:
// shared across projects (bun's own model — the cache is
// content-addressable by package+version and written atomically, so
// concurrent access is safe). The layer's node_modules is a real
// materialization: the cache mount is a separate device, so bun's
// same-fs hardlink optimization can't reach it and falls back to
// copying files into the layer (no `--backend=copyfile` needed).
storeMount: {type: "cache", target: "/root/.bun/install/cache", scope: "global"}

// installFlags — exported so consumer overrides of the install `do`
// (e.g. adding `--filter <pkg>`) can't drift the flag set:
// --frozen-lockfile keeps bun.lock authoritative (fails on drift, no
// network resolution); --ignore-scripts defers lifecycle scripts
// (postinstall font fetches, codegen) — they need source that isn't
// in the deps layer and run downstream instead.
installFlags: "--frozen-lockfile --ignore-scripts"

// lockFiles — bracket-glob: workspace members have no project-local
// lockfile (theirs sits at the workspace root). `bun.lock` is bun's
// text lockfile (1.2+); the legacy binary `bun.lockb` is not used here.
lockFiles: globs: ["[b]un.lock"]

// bun.install — the dependency closure as a real layer. bun's global
// cache (on the cache mount) is the opportunistic store and
// node_modules the exact materialization, so one RUN covers both. Do
// NOT split off a separate resolve/fetch phase: bun install already
// materializes only the current closure from the cache in one pass.
// Cmd-level srcs key the layer on manifest + lockfile, independent of
// mise.install (priority -1, sorts first).
//
// Compose with mise.install — no manual srcs splice needed:
//
//   "setup": mise.install & bun.install
install: {
	cmd: "bun": {
		do: *"mise x -- bun install \(installFlags)" | string
		dockerfile: mounts: [storeMount]
		// Concrete (not disjunction-default) — list disjunctions
		// inside the cmd map break MapToList's `if v != null` check.
		srcs: globs: list.Concat([projectFiles.globs, lockFiles.globs])
	}
}

// Per-subcommand fragments — one fragment per bun invocation we
// expose as a concept. Each wires the bun cache mount on the builtin
// cmd. Defined as concrete fragments (not a parameterized helper)
// because parameter fields would leak into the target struct when
// unified.
build:   _exec & {_sub: "build"}
test:    _exec & {_sub: "test"}
testInt: _exec & {_sub: "test:int"}
testE2E: _exec & {_sub: "test:e2e"}

// bun.dev — runtime dev server for a launch target. Bakes `bun run dev`
// into the Dockerfile CMD (build-time RUN would hang the builder).
// The renderer prepends the project's activate tokens, so bun here
// stays toolchain-agnostic. hmr.native: true — bun-managed frameworks
// (Vite, TanStack Start) handle file watching internally.
dev: {
	hmr: native: true
	dockerfile: cmd: ["bun", "run", "dev"]
}

// _exec — internal template that the subcommand fragments above
// instantiate. Hidden so it doesn't pollute the package's public
// surface. `bun run <script>` (not bare `bun <script>`): a bare
// subcommand resolves to bun's builtins (`bun build` is the bundler,
// `bun test` its native runner), not the package.json script.
_exec: E={
	_sub: string
	cmd: "builtin": {
		do: *"bun run \(E._sub)" | string
		dockerfile: mounts: [storeMount]
	}
}

// bun.workspaceFiles — files that live at the workspace root and must
// be staged into every consumer project's container so bun's
// workspace-traversal install resolves correctly. Bun declares
// workspaces in package.json's `workspaces` field — no separate
// workspace manifest (unlike pnpm's pnpm-workspace.yaml).
workspaceFiles: globs: [
	"bun.lock",
	"package.json",
]

// bun.projectFiles — files a per-project bun setup target stages.
projectFiles: globs: [
	"package.json",
]

// bun.srcs.build — whole-tree project sources for vite-style builds
// (CSS/SCSS, public/, configs, JSON fixtures, i18n, images). Listing
// everything and excluding output/vendor dirs is simpler than
// enumerating allowed extensions; misses (`/assets/styles/global.css`)
// would only show up at build time.
srcsBuild: {
	globs: ["**/*"]
	exclude: [
		"node_modules/**",
		"dist/**",
		"coverage/**",
		".bayt/**",
		".task/**",
		".git/**",
		// Tests reach build via the Merkle chain, not as srcs.
		// Excluding here keeps build's cache key from invalidating
		// on test-only edits.
		"**/*.test.*",
		"**/*.spec.*",
		"tests/**",
	]
}

// bun.srcs.test — unit-test files only. Convention in this repo:
// `*.test.ts(x)` are unit tests selected by vitest.config.ts;
// `*.spec.ts(x)` are integration tests. Splitting srcsTest from
// srcsIntegrate by suffix means a `.test.` edit doesn't invalidate the
// integrate stage and vice versa — same cache-iteration win the gradle
// stack gets from src/test/ vs src/it/. Main-source changes reach the
// test target via the build dep's Merkle chain.
srcsTest: {
	globs: [
		"**/*.test.ts",
		"**/*.test.tsx",
		"vitest.config.*",
		"vitest.unit.config.*",
	]
	exclude: [
		"node_modules/**",
		"dist/**",
		"coverage/**",
	]
}

// bun.srcs.integrate — integration-test files only (`*.spec.ts(x)`).
// Plus the integration vitest config and the base vitest config
// (integration configs typically `mergeConfig(vitestConfig, ...)` so
// the base is a real input).
srcsIntegrate: {
	globs: [
		"**/*.spec.ts",
		"**/*.spec.tsx",
		"tests/**/*",
		"vitest.config.*",
		"vitest.integration.config.*",
	]
	exclude: [
		"node_modules/**",
		"dist/**",
		"coverage/**",
	]
}
