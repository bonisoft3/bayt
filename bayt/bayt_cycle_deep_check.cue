// bayt_cycle_deep_check.cue — deeper stress patterns beyond
// bayt_cycle_check.cue. Pushes on the less obvious cycle traps:
// long chains, defaults that touch every target, priority-tie
// stability, and renamed targets via map keys.
package bayt

// --- C14: defaults touching env + srcs propagate into every target
// without introducing cycles, even though every target unifies the
// same defaults struct.
_cycle_c14: #project & {
	name: "c14"
	dir:  "test/c14"
	defaults: {
		activate: "devbox run --"
		env: {
			RUSTFLAGS:  "-C opt-level=2"
			CARGO_HOME: "/root/.cargo"
		}
		srcs: globs: [".mise.lock", "rust-toolchain.toml"]
	}
	targets: {
		"setup": {cmd: "builtin": do: "true"}
		"build": {cmd: "builtin": do: "cargo build"}
		"test":  {cmd: "builtin": do: "cargo test"}
	}
}
_cycle_c14: targets: build: env: RUSTFLAGS:    "-C opt-level=2"
_cycle_c14: targets: test:  env: CARGO_HOME:   "/root/.cargo"
_cycle_c14: targets: test:  srcs: globs:       [".mise.lock", "rust-toolchain.toml"]

// --- C15: 10-level deep dep chain. Forces CUE to resolve transitive
// deps at depth in one unification pass.
_cycle_c15: #project & {
	name: "c15"
	dir:  "test/c15"
	targets: {
		"t0": {srcs: globs: ["t0/**"], cmd: "builtin": do: "true"}
		"t1": {srcs: globs: ["t1/**"], deps: [":t0"], cmd: "builtin": do: "true"}
		"t2": {srcs: globs: ["t2/**"], deps: [":t1"], cmd: "builtin": do: "true"}
		"t3": {srcs: globs: ["t3/**"], deps: [":t2"], cmd: "builtin": do: "true"}
		"t4": {srcs: globs: ["t4/**"], deps: [":t3"], cmd: "builtin": do: "true"}
		"t5": {srcs: globs: ["t5/**"], deps: [":t4"], cmd: "builtin": do: "true"}
		"t6": {srcs: globs: ["t6/**"], deps: [":t5"], cmd: "builtin": do: "true"}
		"t7": {srcs: globs: ["t7/**"], deps: [":t6"], cmd: "builtin": do: "true"}
		"t8": {srcs: globs: ["t8/**"], deps: [":t7"], cmd: "builtin": do: "true"}
		"t9": {srcs: globs: ["t9/**"], deps: [":t8"], cmd: "builtin": do: "true"}
	}
}

// --- C16: priority-tie stability in #MapToList. Eight rules all at
// priority 0 must resolve in alphabetical order by name.
_cycle_c16: #project & {
	name: "c16"
	dir:  "test/c16"
	targets: {
		"build": {
			cmd: {
				"aa":      {do: "aa"}
				"bb":      {do: "bb"}
				"cc":      {do: "cc"}
				"dd":      {do: "dd"}
				"ee":      {do: "ee"}
				"builtin": {do: "builtin-body"}
				"zz":      {do: "zz"}
				"yy":      {do: "yy"}
			}
		}
	}
}
_cycle_c16: targets: build: cmds: [
	{name: "aa",      shell: "nu", do: "aa",           stop: false, ...},
	{name: "bb",      shell: "nu", do: "bb",           stop: false, ...},
	{name: "builtin", shell: "nu", do: "builtin-body", stop: false, ...},
	{name: "cc",      shell: "nu", do: "cc",           stop: false, ...},
	{name: "dd",      shell: "nu", do: "dd",           stop: false, ...},
	{name: "ee",      shell: "nu", do: "ee",           stop: false, ...},
	{name: "yy",      shell: "nu", do: "yy",           stop: false, ...},
	{name: "zz",      shell: "nu", do: "zz",           stop: false, ...},
]

// --- C17: fragment-on-fragment in defaults. Three layered structs
// (gradle base + jvm base + mise base) compose without conflict and
// each contribution lands on every target.
_c17_gradleBase: {
	cmd: "builtin": dockerfile: mounts: [
		{type: "cache", target: "/root/.gradle", sharing: "locked"},
	]
}
_c17_jvmBase: {
	env: JAVA_OPTS: "-Xmx2g"
}
_c17_miseBase: {
	env: MISE_TRUSTED_CONFIG_PATHS: "/monorepo"
}
_cycle_c17: #project & {
	name: "c17"
	dir:  "test/c17"
	defaults: _c17_gradleBase & _c17_jvmBase & _c17_miseBase
	targets: {
		"build": {
			srcs: globs: ["src/**/*.kt"]
			cmd: "builtin": do: "./gradlew build"
		}
	}
}
_cycle_c17: targets: build: env: JAVA_OPTS:                 "-Xmx2g"
_cycle_c17: targets: build: env: MISE_TRUSTED_CONFIG_PATHS: "/monorepo"
_cycle_c17: targets: build: cmd: "builtin": dockerfile: mounts: [
	{type: "cache", target: "/root/.gradle", sharing: "locked"},
]

// --- C18: dep strings to the same name resolve consistently across
// targets. `:setup` from build, `:build` from deploy.
_cycle_c18: #project & {
	name: "c18"
	dir:  "test/c18"
	targets: {
		"setup": {cmd: "builtin": do: "true"}
		"build": {
			deps: [":setup"]
			srcs: globs: ["**/*.go"]
			cmd: "builtin": do: "go build"
		}
		"deploy": {
			deps: [":build"]
			cmd: "builtin": do: "deploy"
		}
	}
}
_cycle_c18: targets: deploy: deps: [":build"]

// --- C19: empty cmd rulemap — cmds resolves to an empty list. Every
// target still participates in the merkle chain via the manifest itself
// (a no-cmd target's hash covers its srcs/outs/deps).
_cycle_c19: #project & {
	name: "c19"
	dir:  "test/c19"
	targets: {
		"empty": {
			deps: []
			outs: globs: []
			// cmd left as the default empty map.
		}
	}
}
_cycle_c19: targets: empty: cmds: []

// --- C20: target-key binds the target name. Map keys override any
// `name:` field that might otherwise be set by a fragment, so a
// "renamed" build target gets the map key as its identity.
_cycle_c20: #project & {
	name: "c20"
	dir:  "test/c20"
	targets: {
		"alternate-build": {cmd: "builtin": do: "true"}
		"extra-test":      {cmd: "builtin": do: "pytest -v"}
		"hot-launch":      {cmd: "builtin": do: "true"}
	}
}
_cycle_c20: targets: "alternate-build": name: "alternate-build"
_cycle_c20: targets: "extra-test":      name: "extra-test"
_cycle_c20: targets: "hot-launch":      name: "hot-launch"

// Public aggregator forces evaluation of the hidden bindings.
Tests: cycle_deep: {
	c14: _cycle_c14
	c15: _cycle_c15
	c16: _cycle_c16
	c17: _cycle_c17
	c18: _cycle_c18
	c19: _cycle_c19
	c20: _cycle_c20
}
