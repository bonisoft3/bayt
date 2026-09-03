// sayt_uv_check.cue — dogfood check for sayt.uv consumers.
//
// Only concrete fields are asserted here: restating a `do` can never
// fail, for the reason stacks/uv gives at its flag constants.
package sayt

import Uv "github.com/bonisoft3/bayt/stacks/uv"

// --- U1: Minimal python consumer.
_u1: uv & {
	name: "rpa"
	dir:  "services/rpa"
	targets: {
		"launch": dockerfile: expose: [8000]
	}
}

_u1: activate: "mise x --"

// Sync shape: one materializing RUN against the shared uv cache, keyed
// on manifest + lockfile only.
//
// `outs` stays empty. Re-declaring the venv there would hand the host
// CAS a tree of symlinks it silently drops, and the restored venv —
// interpreter missing — still satisfies the state gate below, so the
// re-sync that would repair it never runs.
_u1: targets: deps: {
	cmd: "uv": {
		dockerfile: mounts: [{type: "cache", target: "/root/.cache/uv", scope: "global"}]
		srcs: globs: ["pyproject.toml", "uv.lock"]
	}
	outs: globs: []
}

// The env split is load-bearing, not cosmetic: copy makes the venv a
// real layer instead of hardlinks into the mount, and never makes a
// second interpreter fail loudly instead of appearing silently.
_u1: targets: deps: env: {
	UV_LINK_MODE:        "copy"
	UV_PYTHON_DOWNLOADS: "never"
}

// Bytecode precompilation is a per-service call (stacks/uv weighs it at
// `bytecode`), so the stack must not default it on.
_u1: targets: deps: env: UV_COMPILE_BYTECODE?: _|_

// Pin the exported flag sets. Concrete & concrete, so editing either
// constant fails the whole package. This guards the constants only —
// what stops a consumer from respelling a command without them is the
// `=~` guard on each `do` in stacks/uv, asserted by _u3 below.
_syncFlagsPin: Uv.syncFlags & "--locked --no-install-project"
_runFlagsPin:  Uv.runFlags & "--no-sync"

// --- U2: build stays keyed on src/ alone, so a test edit cannot
// invalidate it.
_u2: uv & {
	name: "u2"
	dir:  "services/u2"
}

// Framework-side position, so `globs` stays empty and available to the
// leaf: a flat-layout consumer must be able to replace src/ without a
// positional conflict.
_u2: targets: build: {
	srcs: {
		globs: []
		defaultGlobs: {
			"uv-project": {glob: "pyproject.toml"}
			"uv-src": {glob: "src/**/*"}
		}
		defaultExclude: {
			"uv-pycache-dir": {glob: "**/__pycache__"}
			"uv-pycache-tree": {glob: "**/__pycache__/**"}
		}
	}
}

// Unit and integration suites are disjoint subtrees: the unit stage
// must not carry tests/integration in its key.
_u2: targets: test: srcs: defaultGlobs: {
	"uv-project": {glob: "pyproject.toml"}
	"uv-src": {glob: "src/**/*"}
	"uv-unit": {glob: "tests/unit/**/*"}
}
_u2: targets: integrate: srcs: defaultGlobs: {
	"uv-project": {glob: "pyproject.toml"}
	"uv-integration": {glob: "tests/integration/**/*"}
}

// --- U3: a leaf that wires nothing still reaches the venv on both
// layers — the task edge from the raised `_depsDefault`, and the FROM
// chain in the container. Asserting the defaults is what keeps it off
// the leaf: lose either and `uv run --no-sync` invents an empty venv
// and exits 0, so the breakage lands at import time with no CUE error
// anywhere.
_u3: uv & {
	name: "u3"
	dir:  "services/u3"
}

_u3: targets: build: {
	deps: [":setup", ":deps"]
	dockerfile: from: ref: ":deps"
}

// A respelled command keeps evaluating as long as it keeps the flag —
// the guard constrains the flag, not the phrasing. Dropping
// --no-install-project here is what fails the package.
_u3: targets: deps: cmd: "uv": do: "uv sync --locked --no-install-project --extra dev"

// A flat-layout consumer narrows src/ from the leaf position, which is
// only possible because the stack left `globs` alone, and drops the
// src/ key it does not use — deletable because the entry is `| null`.
_u3: targets: build: srcs: {
	globs: ["u3pkg/**/*"]
	defaultGlobs: "uv-src": null
}
