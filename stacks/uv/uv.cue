// stacks/uv — Python/uv toolchain concept library.
//
// Pure uv concepts — no opinion about which target each lands on. A
// project unifies these fragments into its bayt targets.
//
// uv owns the environment, mise owns the interpreter. Every fragment
// carries `toolEnv` so that split holds wherever the fragment lands.
package uv

// uv's cache is content-addressed and safe under concurrent access, so
// one store is shared builder-wide — the same call pnpm's store makes.
// It accretes every version ever downloaded rather than converging on
// the current lock, which is why it is a mount and not a layer.
cacheMount: {type: "cache", target: "/root/.cache/uv", scope: "global"}

// The project environment uv syncs into (uv's own default). Exported
// because the state gate and any consumer path into the venv have to
// agree on it.
venvDir: ".venv"

// UV_LINK_MODE=copy: uv hardlinks out of its cache by default, and a
// hardlink into a cache mount is not a file in the layer.
// UV_PYTHON_DOWNLOADS=never: mise owns the interpreter — without this uv
// quietly fetches a second one whenever the versions disagree.
//
// Exported because a target that composes no fragment from here still
// runs uv, and a COPY carries no ENV, so it must state the split itself.
toolEnv: {
	UV_LINK_MODE:        "copy"
	UV_PYTHON_DOWNLOADS: "never"
}

// Both flag sets are interpolated into the `do` defaults below, and each
// `do` carries a `=~` guard on its load-bearing flag. The guard, not the
// interpolation, is what holds: a `do` is `*"…" | string`, so a consumer
// override selects the open arm and a bare restatement can never fail.
// Respelling a command is still allowed; dropping the flag is not.
//
// --locked, not --frozen: both refuse to re-resolve, but --frozen also
// accepts a uv.lock that has fallen behind pyproject.toml — it exits 0
// having installed nothing, and the miss resurfaces as an ImportError
// far from the edit that caused it. --locked makes staleness an error.
//
// --no-install-project: dependencies only, so the layer keys on the
// lockfile and app-source churn cannot invalidate it. The project
// package is never installed as a result — see `sync`.
syncFlags: "--locked --no-install-project"

// runFlags — every in-stage invocation goes through `uv run --no-sync`.
// A bare `uv run` re-reads the lockfile and installs the project,
// undoing the deps/app split that keeps the sync layer stable.
runFlags: "--no-sync"

// projectFile — pyproject.toml has to reach every stage that shells out
// through `uv run`, not just the sync: uv locates the project (and thus
// the venv, and thus --no-sync's meaning) by walking up for this file.
// Without it uv warns "--no-sync has no effect when used outside of a
// project" and resolves the interpreter by luck.
projectFile: "pyproject.toml"

// Framework-side `defaultExclude`, so the plain `exclude` stays free for
// whatever a leaf adds — the two positions compose instead of colliding.
//
// BOTH __pycache__ spellings are required: `**/x/**` leaves the empty
// dir entries in the fileset, `**/x` prunes the dir.
_pycacheExclude: {
	"uv-pycache-dir": {glob: "**/__pycache__"}
	"uv-pycache-tree": {glob: "**/__pycache__/**"}
}

// sync — the dependency closure as a real image layer (the `deps`
// target), reachable by runtime containers and cold builders.
//
// One RUN, not two: uv materializes straight into a project-local .venv,
// so there is no shared-proxy phase to re-resolve against the way
// stacks/go needs one (go's mount IS the modcache it builds from).
//
// `--no-install-project` means the project package is never installed
// here, and every later stage runs `--no-sync`, so it is never installed
// downstream either. The app's own modules resolve by path, not through
// the venv — wiring that path (pytest's `pythonpath`, or a layout the
// interpreter's CWD already covers) belongs to the consumer.
sync: {
	env: toolEnv
	// The manifest and the lockfile key this target, and the target is
	// where they have to sit: the host status gate hashes target srcs, so
	// declaring them only on the cmd leaves them out of the gate's hash
	// and a re-lock reports "up to date" while every later
	// `uv run --no-sync` keeps using the venv from before it.
	srcs: defaultGlobs: {
		"uv-project": {glob: projectFile}
		"uv-lock": {glob: "uv.lock"}
	}
	cmd: "uv": {
		do: (*"uv sync \(syncFlags)" | string) & =~"--no-install-project"
		dockerfile: mounts: [cacheMount]
	}
	// No `outs`: the venv is presence-gated, never CAS payload. It is
	// not relocatable in either direction — its own path is baked into
	// pyvenv.cfg and console-script shebangs, and .venv/bin/python is an
	// absolute symlink to the mise-owned interpreter that pyvenv.cfg's
	// `home` names too. The host CAS could not carry it regardless: it
	// stores {path, size, sha256} per file and drops symlinks, restoring
	// a venv with no interpreter. Stages reach it by FROM-chaining,
	// which preserves them; the host re-syncs from uv's own cache.
	//
	// A wiped .venv must fail the status skip. The pattern names a file
	// inside the dist-info rather than the dist-info itself: the
	// fingerprint probe tests a globbed pattern with `glob --no-dir`, so
	// a directory-only pattern is never found present and the skip would
	// never fire. Not pyvenv.cfg either — an interpreter wrapper
	// recreates that before the gate reads it, whereas installed
	// metadata only exists after a real sync.
	state: globs: ["\(venvDir)/lib/*/site-packages/*.dist-info/METADATA"]
}

// bytecode — precompile site-packages at sync time. OFF by default, and
// it should stay off unless the workload is short-lived: the win only
// exists where site-packages is unwritable or ephemeral, since a
// long-lived container with a writable rootfs compiles once itself and
// reaches the same steady state. The cost is paid every build and every
// pull. Measured on services/news (23 packages, fastapi + uvicorn):
// first import 0.33s unwritable and uncompiled against 0.15s
// precompiled, for +15MB on an 18MB venv. Weigh it per service — a
// heavier dependency set moves both halves.
bytecode: env: UV_COMPILE_BYTECODE: "1"

// build — `compileall`. Python has no link step; compileall is the
// nearest thing to a compile, failing on syntax errors and leaving the
// bytecode the runtime would otherwise generate on first import.
//
// This and the two suites below take their directory and produce an
// `out`, the shape distros/#install already uses. The directory reaches
// the glob and the command that walks it from one place, so a project on
// another tree states it once rather than overriding two fields that
// must agree — and disagreement between them fails at runtime, never
// here. A definition rather than a field on the target: `#target` is
// closed, and a package-level constant would be shared by every uv
// project at once.
//
// Each entry stays `| null` for a project with no such tree at all. A
// concrete entry (as every other stack writes) cannot be deleted: `null`
// unified with a struct is a conflict, not a removal.
#build: {
	srcDir: *"src" | string
	out: {
		env: toolEnv
		srcs: {
			defaultGlobs: {
				"uv-project": {glob: projectFile}
				"uv-src": *{glob: "\(srcDir)/**/*"} | null
			}
			defaultExclude: _pycacheExclude
		}
		// No `outs`. Per PEP 3147 a __pycache__/*.pyc is importable only
		// with its .py beside it, so — unlike stacks/go, where build outs
		// IS the artifact — the bytecode is not an interface any consumer
		// can deploy. Declaring it would invite `deps: [":build:outs"]` on
		// a release target and ship an image whose modules cannot be
		// imported; a python release carries the source tree.
		cmd: "builtin": do: (*"uv run \(runFlags) python -m compileall -q \(srcDir)" | string) & =~"--no-sync"
	}
}

// The stock layout, for a project that wants it.
build: (#build).out

// Unit and integration suites split by directory, the convention this
// stack imposes: `tests/unit` answers to the ide-layer `test` verb and
// runs on the host, `tests/integration` to `integrate` and runs in the
// container. Splitting the srcs by subtree is what keeps an
// integration-only edit from re-keying the unit stage — the same
// cache-iteration win stacks/gradle gets from src/test vs src/it.
//
// Globbed `**/*` rather than `**/*.py` so a non-python fixture
// re-fingerprints too.
#test: {
	srcDir:  *"src" | string
	unitDir: *"tests/unit" | string
	out: {
		env: toolEnv
		srcs: {
			defaultGlobs: {
				"uv-project": {glob: projectFile}
				"uv-src": *{glob: "\(srcDir)/**/*"} | null
				"uv-unit": *{glob: "\(unitDir)/**/*"} | null
			}
			defaultExclude: _pycacheExclude
		}
		cmd: "builtin": do: (*"uv run \(runFlags) python -m pytest \(unitDir) -q" | string) & =~"--no-sync"
	}
}

test: (#test).out

#integrationTest: {
	integrationDir: *"tests/integration" | string
	out: {
		env: toolEnv
		srcs: {
			defaultGlobs: {
				"uv-project": {glob: projectFile}
				"uv-integration": *{glob: "\(integrationDir)/**/*"} | null
			}
			defaultExclude: _pycacheExclude
		}
		cmd: "builtin": do: (*"uv run \(runFlags) python -m pytest \(integrationDir) -q" | string) & =~"--no-sync"
	}
}

integrationTest: (#integrationTest).out

// No `run` fragment: python has no conventional entrypoint the way
// `go run .` is conventional, so a launch target's command belongs to
// the leaf.
