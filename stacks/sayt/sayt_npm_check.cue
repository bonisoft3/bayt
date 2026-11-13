// sayt_npm_check.cue — dogfood check for sayt.npm consumers.
package sayt

import (
	"strings"

	"github.com/bonisoft3/bayt/core:bayt"
	Npm "github.com/bonisoft3/bayt/stacks/npm"
)

// --- N1: Minimal vite app on the stock mapping.
_n1: npm & {
	name: "spa"
	dir:  "guis/spa"
	targets: "launch": dockerfile: expose: [3000]
}

_n1: activate: "mise x --"
_n1: targets: setup: cmd: "npm": {
	do: "mise x -- npm ci --prefer-offline --no-audit --no-fund"
	dockerfile: mounts: [{type: "cache", target: "/root/.npm"}]
	srcs: globs:        ["package.json", "[.]npmrc", "[p]ackage-lock.json"]
}
_n1: targets: build: {
	cmd: "builtin": do: "npm run build"
	srcs: defaultGlobs: "**/*": glob:              "**/*"
	srcs: defaultExclude: "node_modules/**": glob: "node_modules/**"
	outs: globs: ["dist/**/*"]
}
_n1: targets: launch: hmr: tools: ["package.json", "package-lock.json"]

// Pin the exported flag set — consumer overrides interpolate it.
_npmInstallFlagsPin: Npm.installFlags & "--prefer-offline --no-audit --no-fund"

// --- N2: The defaults sayt.pnpm pins are replaceable here: an explicit
// source list, a CMD with pass-through flags.
_n2: npm & {
	name: "web"
	dir:  "guis/web"
	targets: {
		"setup": dockerfile: bayt.nubox
		// The whole-tree default nulled, an explicit list in its place.
		"build": srcs: {
			defaultGlobs: "**/*": null
			globs: ["src/**/*", "index.html"]
		}
		"launch": dockerfile: {
			from: ref: ":setup"
			cmd:    ["npm", "run", "dev", "--", "--host", "0.0.0.0"]
			expose: [3000]
		}
		"integrate": null
		"release":   null
		"verify":    null
	}
}

_n2: targets: build: srcs: globs: ["src/**/*", "index.html"]

_n2_render: bayt.#render & {project: _n2, depManifests: {}}
_n2_setup:  true & strings.Contains(_n2_render.docker.dockerfiles.setup, "--mount=type=cache,target=/root/.npm")
_n2_launch: true & strings.Contains(_n2_render.docker.dockerfiles.launch, #""npm", "run", "dev", "--", "--host", "0.0.0.0"]"#)
_n2: targets: build: outs: globs: ["dist/**/*"]
_n2: targets: test: outs: globs:  ["coverage/**/*", "test-results/**/*"]

// --- N3: A leaf's outs replace the default rather than appending.
_n3: npm & {
	name: "n3"
	dir:  "guis/n3"
	targets: test: outs: globs: ["coverage/**/*"]
}

_n3: targets: test: outs: globs: ["coverage/**/*"]

// --- N4: A leaf exclude adds to the defaults; it does not drop the
// default globs (a struct-level default would have fallen to `_`).
_n4: npm & {
	name: "n4"
	dir:  "guis/n4"
	targets: build: srcs: exclude: ["generated/**"]
}

_n4: targets: build: srcs: defaultGlobs: "**/*": glob:              "**/*"
_n4: targets: build: srcs: defaultExclude: "node_modules/**": glob: "node_modules/**"
_n4: targets: build: srcs: exclude: ["generated/**"]
