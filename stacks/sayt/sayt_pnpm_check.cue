// sayt_pnpm_check.cue — dogfood check for sayt.pnpm consumers.
package sayt

import Pnpm "github.com/bonisoft3/bayt/stacks/pnpm"

// --- P1: Minimal web consumer.
_p1: pnpm & {
	name: "web"
	dir:  "guis/web"
	targets: {
		"release": skaffold: profiles: "bayt-build": build: artifact: image: "gcr.io/proj/web"
		"launch": dockerfile: expose: [3000]
	}
}

_p1: activate: "mise x --"
_p1: targets: setup: cmd: "builtin": do:   "pnpm install --frozen-lockfile"
_p1: targets: build: cmd: "builtin": do:   "pnpm build"

// Install shape: single materializing RUN, store cache mount, keyed
// on manifest + (optional) project-local lockfile.
_p1: targets: setup: cmd: "pnpm": {
	dockerfile: mounts: [{type: "cache", target: "/root/.local/share/pnpm/store"}]
	srcs: globs: ["package.json", "[p]npm-lock.yaml"]
}

// Pin the exported flag set — consumer overrides interpolate it, so a
// drift here silently strips the two-store semantics everywhere.
// Concrete & concrete: unification fails the whole package on mismatch.
_installFlagsPin: Pnpm.installFlags & "--prefer-offline --frozen-lockfile --package-import-method copy"

// --- P2: HMR watch entries from the stack survive overrides.
_p2: pnpm & {
	name: "p2"
	dir:  "guis/p2"
	targets: {
		"launch": {
			compose: develop: watch: [
				{action: "sync",    path: "./",               target: "/app",               ignore: ["node_modules", ".nuxt", ".output"]},
				{action: "rebuild", path: "./package.json",   target: "/app/package.json",   ignore: []},
				{action: "rebuild", path: "./pnpm-lock.yaml", target: "/app/pnpm-lock.yaml", ignore: []},
			]
		}
	}
}

_p2: targets: launch: compose: develop: watch: [
	{action: "sync", path:    "./", target:               "/app", ignore:               ["node_modules", ".nuxt", ".output"]},
	{action: "rebuild", path: "./package.json", target:   "/app/package.json", ignore:   []},
	{action: "rebuild", path: "./pnpm-lock.yaml", target: "/app/pnpm-lock.yaml", ignore: []},
]
