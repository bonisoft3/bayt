// bayt_smoke_check.cue — exercises the schema with a minimal project.
//
// Why "_check" not "_test": cue eval excludes *_test.cue files in
// non-test mode (silent skip). Until cue gets a stable test runner,
// validation tests live in _check.cue files which always evaluate.
package bayt

_smoke: #project & {
	name: "smoke"
	dir:  "plugins/sayt/smoke"
	targets: {
		"setup": {
			cmd: "builtin": do: "true"
		}
		"build": {
			deps: [":setup"]
			srcs: globs: ["**/*.rs"]
			outs: globs: ["target/release/smoke"]
			cmd: "builtin": do: "cargo build --release"
		}
		"test": {
			deps: [":build"]
			srcs: globs: ["**/*.rs"]
			cmd: {
				"pregen":    {priority: -10, do: "cargo check"}
				"builtin":   {do: "cargo test"}
				"postcheck": {priority: 10, do: "cargo clippy"}
			}
		}
		"integrate": {
			deps: [":build"]
			cmd: "builtin": {
				do: "nu run-integration.nu"
				dockerfile: mounts: [
					{type: "secret", id: "host.env", required: true},
				]
			}
		}
	}
}

// Resolved-value assertions — narrow because most output shapes
// (compose service names, taskfile root.includes, bake HCL, etc.)
// changed in the producer-controlled-exposure overhaul. Re-add specific
// assertions per emitter as they stabilize.
_smoke: targets: build: cmds: [
	{name: "builtin", shell: "nu", do: "cargo build --release", stop: false},
]
_smoke: targets: setup: name: "setup"
_smoke: targets: build: name: "build"
_smoke: activate: "mise x --"

// Public aggregator forces evaluation of the hidden _smoke binding.
// Without it, conflicts inside _smoke would silently pass cue eval.
Tests: bayt_smoke: _smoke
