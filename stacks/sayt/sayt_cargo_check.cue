// sayt_cargo_check.cue — dogfood check for sayt.cargo consumers.
package sayt

import Cargo "github.com/bonisoft3/bayt/stacks/cargo"

_c1: cargo & {
	name: "boxer"
	dir:  "services/boxer"
	targets: {
		"build": outs: globs: ["target/debug/boxer"]
	}
}

_c1: activate: "mise x --"

_c1: targets: deps: {
	srcs: defaultGlobs: {
		"cargo-project": glob: "Cargo.toml"
		"cargo-lock": glob:    "Cargo.lock"
	}
	cmd: "cargo": dockerfile: mounts: [
		Cargo.registryMount,
		Cargo.gitMount,
		Cargo.crateStore,
	]
	dockerfile: from: ref: ":setup"
}

_c1: targets: build: {
	deps: [":setup", ":deps"]
	dockerfile: from: ref: ":deps"
	srcs: {
		globs: []
		defaultGlobs: {
			"cargo-project": glob: "Cargo.toml"
			"cargo-lock": glob:    "Cargo.lock"
			"cargo-src": glob:     "src/**/*"
		}
		defaultExclude: {
			"cargo-target-dir": glob:  "target"
			"cargo-target-tree": glob: "target/**"
		}
	}
	cmd: "builtin": dockerfile: mounts: [Cargo.registryMount, Cargo.gitMount]
}

_c1: targets: test: {
	dockerfile: from: ref: ":build"
	cmd: "builtin": dockerfile: mounts: [Cargo.registryMount, Cargo.gitMount]
}

_c1: targets: integrate: {
	dockerfile: from: ref: ":build"
	srcs: defaultGlobs: {
		"cargo-project": glob:     "Cargo.toml"
		"cargo-lock": glob:        "Cargo.lock"
		"cargo-integration": glob: "tests/**/*"
	}
	cmd: "builtin": dockerfile: mounts: [Cargo.registryMount, Cargo.gitMount]
}
