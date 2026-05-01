// emitter_check.cue — exercises #manifestGen, the canonical emitter
// every other gen_*.cue reads from. Bare bayt schema (no sayt verb
// fragments) so this stays a pure-bayt check.
package bayt

// --- E1: smallest project. projectManifest carries the identity triple,
// per-target manifests carry srcs/outs/deps/cmds in normalized form.
_e1: #project & {
	name: "e1"
	dir:  "plugins/sayt/e1"
	targets: {
		"setup": {cmd: "builtin": do: "true"}
		"build": {
			deps: [":setup"]
			srcs: globs: ["**/*.rs"]
			outs: globs: ["target/release/e1"]
			cmd: "builtin": do: "cargo build --release"
		}
		"test": {
			deps: [":build"]
			srcs: globs: ["**/*.rs"]
			cmd: "builtin": do: "cargo test"
		}
		"release": {
			deps: [":build"]
			cmd: "builtin": do: "echo release"
		}
	}
}
_e1_m: (#manifestGen & {project: _e1, depManifests: {}})
_e1_m: projectManifest: name:     "e1"
_e1_m: projectManifest: dir:      "plugins/sayt/e1"
_e1_m: projectManifest: activate: "mise x --"
_e1_m: files: build: name:    "build"
_e1_m: files: build: project: "e1"
_e1_m: files: build: srcs: globs: ["**/*.rs"]
_e1_m: files: build: outs: globs: ["target/release/e1"]
// Same-project `:setup` ref is normalized to the bare name "setup".
_e1_m: files: build: deps: ["setup"]
_e1_m: files: build: cmds: [
	{name: "builtin", shell: "nu", do: "cargo build --release", stop: false, ...},
]

// --- E2: multiple same-project deps preserve order in the manifest.
_e2: #project & {
	name: "e2"
	dir:  "e2"
	targets: {
		"setup": {cmd: "builtin": do: "true"}
		"build": {
			deps: [":setup"]
			cmd: "builtin": do: "echo build"
		}
		"test": {
			deps: [":build", ":setup"]
			cmd: "builtin": do: "echo test"
		}
	}
}
_e2_m: (#manifestGen & {project: _e2, depManifests: {}})
_e2_m: files: build: deps: ["setup"]
_e2_m: files: test:  deps: ["build", "setup"]

// --- E3: transitiveDeps walks the same-project chain. test → build →
// setup ⇒ test.transitiveDeps = [build, setup].
_e3: #project & {
	name: "e3"
	dir:  "e3"
	targets: {
		"setup": {cmd: "builtin": do: "true"}
		"build": {
			deps: [":setup"]
			cmd: "builtin": do: "echo build"
		}
		"test": {
			deps: [":build"]
			cmd: "builtin": do: "echo test"
		}
	}
}
_e3_m: (#manifestGen & {project: _e3, depManifests: {}})
_e3_m: files: test: transitiveDeps: ["build", "setup"]

// --- E4: bare target with no output blocks — manifest still emitted,
// but the optional output keys (taskfile, dockerfile, ...) are absent.
_e4: #project & {
	name: "e4"
	dir:  "e4"
	targets: {
		"bare": {
			srcs: globs: ["x"]
			cmd: "builtin": do: "echo bare"
		}
	}
}
_e4_m: (#manifestGen & {project: _e4, depManifests: {}})
_e4_m: files: bare: srcs: globs: ["x"]
_e4_m: files: bare: project: "e4"
_e4_m: files: bare: {[!~"^(name|project|dir|activate|srcs|outs|env|visibility|deps|transitiveDeps|transitiveCrossDeps|chainedDeps|cmds|cache)$"]: _|_}

// --- E5: project-level activate propagates into every target's manifest.
_e5: #project & {
	name:     "e5"
	dir:      "e5"
	activate: "devbox run --"
	targets: {
		"setup": {cmd: "builtin": do: "true"}
		"build": {cmd: "builtin": do: "echo"}
	}
}
_e5_m: (#manifestGen & {project: _e5, depManifests: {}})
_e5_m: files: build: activate: "devbox run --"
_e5_m: files: setup: activate: "devbox run --"

// --- E6: ten bare targets — projectManifest.targets enumerates all
// non-null keys, in declaration order.
_e6: #project & {
	name: "e6"
	dir:  "e6"
	targets: {
		"setup":     {cmd: "builtin": do: "true"}
		"doctor":    {cmd: "builtin": do: "true"}
		"build":     {cmd: "builtin": do: "true"}
		"test":      {cmd: "builtin": do: "true"}
		"launch":    {cmd: "builtin": do: "true"}
		"integrate": {cmd: "builtin": do: "true"}
		"release":   {cmd: "builtin": do: "true"}
		"verify":    {cmd: "builtin": do: "true"}
		"generate":  {cmd: "builtin": do: "true"}
		"lint":      {cmd: "builtin": do: "true"}
	}
}
_e6_m: (#manifestGen & {project: _e6, depManifests: {}})
_e6_m: projectManifest: targets: [
	"setup", "doctor", "build", "test", "launch",
	"integrate", "release", "verify", "generate", "lint",
]

// --- E7: a project that opts out of an inherited target via `null`
// gets it filtered from projectManifest.targets and from files.
_e7: #project & {
	name: "e7"
	dir:  "e7"
	targets: {
		"build":   {cmd: "builtin": do: "true"}
		"release": null
	}
}
_e7_m: (#manifestGen & {project: _e7, depManifests: {}})
_e7_m: projectManifest: targets: ["build"]
_e7_m: files: {[!="build"]: _|_}

// Public aggregator forces evaluation of the hidden _e* bindings.
Tests: emitter: {
	e1: _e1_m
	e2: _e2_m
	e3: _e3_m
	e4: _e4_m
	e5: _e5_m
	e6: _e6_m
	e7: _e7_m
}
