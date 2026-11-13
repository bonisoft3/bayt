// stacks/npm — npm/Node.js toolchain concept library.
//
// Pure npm concepts — no opinion about which target each lands on.
// A project unifies these fragments into its bayt targets.
package npm

import "list"

// =============================================================================
// Toolchain concept library.
// =============================================================================

// Cache mount for npm's download cache (~/.npm/_cacache). `scope:
// "global"`: shared across projects (npm's own model — cacache is
// content-addressable and writes entries atomically, so concurrent
// access is safe). npm copies out of the cache, never links, so the
// layer's node_modules is a real materialization.
storeMount: {type: "cache", target: "/root/.npm", scope: "global"}

// installFlags — exported so consumer overrides of the install `do`
// (e.g. adding `--workspace <pkg>`) can't drift the flag set:
// --prefer-offline keeps the cache mount non-load-bearing (network
// only on cache misses); --no-audit / --no-fund skip the registry
// round-trips that change nothing in the layer. `npm ci` itself is
// the lockfile guard: it fails on a package.json / package-lock.json
// drift instead of re-resolving.
installFlags: "--prefer-offline --no-audit --no-fund"

// lockFiles — bracket-glob: workspace members have no project-local
// lockfile (theirs sits at the workspace root).
lockFiles: globs: ["[p]ackage-lock.json"]

// npm.install — the dependency closure as a real layer. npm's cache
// (on the cache mount) is the opportunistic store and node_modules
// the exact materialization, so one RUN covers both. `npm ci`, not
// `npm install`: it installs exactly the lockfile and starts from an
// empty node_modules. Lifecycle scripts run, as under stacks/pnpm:
// dependencies' own install scripts (native builds) need to, and
// --ignore-scripts would skip them too. The project's own
// (pre|post)install and prepare also run, in a layer that carries only
// the manifests; a project whose scripts need its sources respells
// `do` with --ignore-scripts and runs them in a later target. Cmd-level srcs key the layer on manifest +
// lockfile, independent of mise.install (priority -1, sorts first).
//
// Compose with mise.install — no manual srcs splice needed:
//
//   "setup": mise.install & npm.install
install: {
	cmd: "npm": {
		do: *"mise x -- npm ci \(installFlags)" | string
		dockerfile: mounts: [storeMount]
		// Concrete (not disjunction-default) — list disjunctions
		// inside the cmd map break MapToList's `if v != null` check.
		srcs: globs: list.Concat([projectFiles.globs, lockFiles.globs])
	}
}

// Per-subcommand fragments — one fragment per npm script we expose
// as a concept. Each wires the npm cache mount on the builtin cmd.
// Defined as concrete fragments (not a parameterized helper) because
// parameter fields would leak into the target struct when unified.
build: _exec & {_sub: "build"}
test: _exec & {_sub: "test"} & {
	env: CI: *"true" | string
}
testInt: _exec & {_sub: "test:int"} & {
	env: CI: *"true" | string
}
testE2E: _exec & {_sub: "test:e2e"} & {
	env: CI: *"true" | string
}

// npm.dev — runtime dev server for a launch target. Bakes `npm run
// dev` into the Dockerfile CMD (build-time RUN would hang the
// builder). The renderer prepends the project's activate tokens, so
// npm here stays toolchain-agnostic. hmr.native: true — npm-managed
// frameworks (Vite, Next, Nuxt) handle file watching internally.
// The CMD is a default: a dev server usually needs flags passed
// through (`npm run dev -- --host 0.0.0.0`).
dev: {
	hmr: native:     true
	dockerfile: cmd: *["npm", "run", "dev"] | [...string]
}

// _exec — internal template that the subcommand fragments above
// instantiate. Hidden so it doesn't pollute the package's public
// surface. `npm run <script>` for every script: only a few
// (test, start) have bare `npm <script>` aliases.
_exec: {
	_sub: string
	cmd: "builtin": {
		do: *"npm run \(_sub)" | string
		dockerfile: mounts: [storeMount]
	}
}

// npm.workspaceFiles — files that live at the workspace root and must
// be staged into every consumer project's container so npm's
// workspace-traversal install resolves correctly. npm declares
// workspaces in package.json's `workspaces` field — no separate
// workspace manifest (unlike pnpm's pnpm-workspace.yaml).
workspaceFiles: globs: [
	"package-lock.json",
	"package.json",
	"[.]npmrc",
]

// npm.projectFiles — files a per-project npm setup target stages.
// .npmrc is bracket-globbed: optional, but when present it changes
// what `npm ci` resolves against (registry, auth scopes, peer-deps
// policy).
projectFiles: globs: [
	"package.json",
	"[.]npmrc",
]

// npm.srcs.build — whole-tree project sources for vite-style builds
// (CSS/SCSS, public/, configs, JSON fixtures, i18n, images). Listing
// everything and excluding output/vendor dirs is simpler than
// enumerating allowed extensions; misses (`/assets/styles/global.css`)
// would only show up at build time.
srcsBuild: {
	globs: ["**/*"]
	exclude: [
		"node_modules/**",
		".nuxt/**",
		".output/**",
		"dist/**",
		"out/**",
		"*.tsbuildinfo",
		"**/*.tsbuildinfo",
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

// npm.srcs.test — unit-test files only, on the same vitest convention
// as stacks/pnpm: `*.test.ts(x)` are unit tests, `*.spec.ts(x)`
// integration tests. Splitting srcsTest from srcsIntegrate by suffix
// means a `.test.` edit doesn't invalidate the integrate stage and
// vice versa. Main-source changes reach the test target via the build
// dep's Merkle chain.
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
		"out/**",
		"*.tsbuildinfo",
		"**/*.tsbuildinfo",
		"coverage/**",
	]
}

// npm.srcs.integrate — integration-test files only (`*.spec.ts(x)`).
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
		"out/**",
		"*.tsbuildinfo",
		"**/*.tsbuildinfo",
		"coverage/**",
	]
}
