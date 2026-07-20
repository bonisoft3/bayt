// stacks/pnpm — pnpm/Node.js toolchain concept library.
//
// Pure pnpm concepts — no opinion about which target each lands on.
// A project unifies these fragments into its bayt targets.
package pnpm

import "list"

// =============================================================================
// Toolchain concept library.
// =============================================================================

// Cache mount for pnpm's download store.
storeMount: {type: "cache", target: "/root/.local/share/pnpm/store", scope: "project"}

// installFlags — exported so consumer overrides of the install `do`
// (e.g. adding `--filter <pkg>...`) can't drift the flag set:
// --prefer-offline keeps the store mount non-load-bearing (network
// only on store misses); --package-import-method copy lands real
// file copies in the layer, not hardlinks into the mount.
installFlags: "--prefer-offline --frozen-lockfile --package-import-method copy"

// lockFiles — bracket-glob: workspace members have no project-local
// lockfile (theirs sits at the workspace root via workspaceroot:setup).
lockFiles: globs: ["[p]npm-lock.yaml"]

// pnpm.install — the dependency closure as a real layer. pnpm's CAS
// store (on the cache mount) is the opportunistic store and
// node_modules the exact filter-scoped materialization, so one RUN
// covers both. Do NOT add a `pnpm fetch` phase: fetch is unfiltered
// and materializes the whole workspace lockfile into the layer's
// virtual store. Cmd-level srcs key the layer on manifest +
// lockfile, independent of mise.install (priority -1, sorts first).
//
// Compose with mise.install — no manual srcs splice needed:
//
//   "setup": mise.install & pnpm.install
install: {
	cmd: "pnpm": {
		do: *"mise x -- pnpm install \(installFlags)" | string
		dockerfile: mounts: [storeMount]
		// Concrete (not disjunction-default) — list disjunctions
		// inside the cmd map break MapToList's `if v != null` check.
		srcs: globs: list.Concat([projectFiles.globs, lockFiles.globs])
	}
}

// Per-subcommand fragments — one fragment per pnpm invocation we
// expose as a concept. Each wires the pnpm store cache mount on the
// builtin cmd. Defined as concrete fragments (not a parameterized
// helper) because parameter fields would leak into the target struct
// when unified.
build:   _exec & {_sub: "build"}
test:    _exec & {_sub: "test"}
testInt: _exec & {_sub: "test:int"}
testE2E: _exec & {_sub: "test:e2e"}
lint:    _exec & {_sub: "lint"}

// pnpm.dev — runtime dev server for a launch target. Bakes `pnpm dev`
// into the Dockerfile CMD (build-time RUN would hang the builder).
// The renderer prepends the project's activate tokens, so pnpm here
// stays toolchain-agnostic. hmr.native: true — pnpm-managed
// frameworks (Next, Vite, Nuxt) handle file watching internally.
dev: {
	hmr: native: true
	dockerfile: cmd: ["pnpm", "dev"]
}

// _exec — internal template that the subcommand fragments above
// instantiate. Hidden so it doesn't pollute the package's public
// surface.
_exec: E={
	_sub: string
	cmd: "builtin": {
		do: *"mise x -- pnpm \(E._sub)" | string
		dockerfile: mounts: [storeMount]
	}
}

// pnpm.workspaceFiles — files that live at the workspace root and
// must be staged into every consumer project's container so pnpm's
// workspace-traversal install resolves correctly.
workspaceFiles: globs: [
	"pnpm-lock.yaml",
	"pnpm-workspace.yaml",
	"package.json",
]

// pnpm.projectFiles — files a per-project pnpm setup target stages.
projectFiles: globs: [
	"package.json",
]

// pnpm.srcs.build — whole-tree project sources for nuxt/vite-style
// builds (CSS/SCSS, public/, configs, JSON fixtures, i18n, images).
// Listing everything and excluding output/vendor dirs is simpler than
// enumerating allowed extensions; misses (`/assets/styles/global.css`)
// would only show up at build time.
srcsBuild: {
	globs: ["**/*"]
	exclude: [
		"node_modules/**",
		".nuxt/**",
		".output/**",
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

// pnpm.srcs.test — unit-test files only. Convention in this repo:
// `*.test.ts(x)` are unit tests selected by vitest.unit.config.ts;
// `*.spec.ts(x)` are integration tests selected by
// vitest.integration.config.ts. Splitting srcsTest from srcsIntegrate
// by suffix means a `.test.` edit doesn't invalidate the integrate
// stage and vice versa — same cache-iteration win the gradle stack
// gets from src/test/ vs src/it/. Main-source changes reach the test
// target via the build dep's Merkle chain.
srcsTest: {
	globs: [
		"**/*.test.ts",
		"**/*.test.tsx",
		"vitest.config.*",
		"vitest.unit.config.*",
	]
	exclude: [
		"node_modules/**",
		".nuxt/**",
		".output/**",
		"dist/**",
		"coverage/**",
	]
}

// pnpm.srcs.integrate — integration-test files only (`*.spec.ts(x)`).
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
		".nuxt/**",
		".output/**",
		"dist/**",
		"coverage/**",
	]
}

