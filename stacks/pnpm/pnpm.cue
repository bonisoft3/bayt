// stacks/pnpm — pnpm/Node.js toolchain concept library.
//
// Pure pnpm concepts — no opinion about which sayt verb each maps
// to. Projects compose these with sayt verb fragments (or use the
// `sayt.pnpm` / `sayt.pnpmWorkspace` standard mappings in
// plugins/bayt/stacks/sayt) to land them on canonical bayt targets.
package pnpm

// =============================================================================
// Toolchain concept library.
// =============================================================================

// Shared cache mount for the pnpm download store.
_storeMount: {type: "cache", target: "/root/.local/share/pnpm/store", sharing: "locked"}

// pnpm.install — `pnpm install --frozen-lockfile` as a separate cmd
// alongside mise's toolchain install. Cmd-level srcs put the pnpm
// manifest files (project's package.json) in the COPY layer that
// directly feeds the pnpm-install RUN, so a `mise.install &
// pnpm.install` setup gives `mise install` and `pnpm install` their
// own independent BuildKit cache keys: editing .mise.toml leaves
// pnpm's node_modules layer cached, editing package.json leaves
// the toolchain layer cached. The pnpm cmd has no priority
// (default 0) so it sorts after mise.install (priority -1).
//
// Compose with mise.install — no manual srcs splice needed:
//
//   "setup": mise.install & pnpm.install
install: {
	cmd: "pnpm": {
		do: *"mise x -- pnpm install --frozen-lockfile" | string
		dockerfile: mounts: [_storeMount]
		// Concrete (not disjunction-default) — list disjunctions
		// inside the cmd map break MapToList's `if v != null` check.
		srcs: globs: projectFiles.globs
	}
}

// Per-subcommand fragments — one fragment per pnpm invocation we
// expose as a concept. Each wires the pnpm store cache mount on the
// builtin cmd. Defined as concrete fragments (not a parameterized
// helper) because parameter fields would leak into the target struct
// when unified.
build:   _exec & {_sub: "build"}
test:    _exec & {_sub: "test"}
dev:     _exec & {_sub: "dev"}
testInt: _exec & {_sub: "test:int"}
testE2E: _exec & {_sub: "test:e2e"}
lint:    _exec & {_sub: "lint"}

// _exec — internal template that the subcommand fragments above
// instantiate. Hidden so it doesn't pollute the package's public
// surface.
_exec: E={
	_sub: string
	cmd: "builtin": {
		do: *"mise x -- pnpm \(E._sub)" | string
		dockerfile: mounts: [_storeMount]
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

// pnpm.devWatch — compose `develop.watch` entries for pnpm's
// dev-server HMR loop. Sync the project tree (with the standard
// node_modules/.nuxt/.output ignores) and rebuild on lockfile or
// package.json edits.
devWatch: [
	{action: "sync", path: "./", target: "/app", ignore: ["node_modules", ".nuxt", ".output"]},
	{action: "rebuild", path:    "./package.json", target: "/app/package.json"},
	{action: "rebuild", path:    "./pnpm-lock.yaml", target: "/app/pnpm-lock.yaml"},
]

