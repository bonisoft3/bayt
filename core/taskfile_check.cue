// taskfile_check.cue — exercises #taskfileGen on top of the manifest.
// Two emitted Taskfiles per project: .bayt/Taskfile.bayt.yml
// (`bayt_root`) lists per-target file includes plus cross-project dep
// includes; .bayt/Taskfile.yml (`root`) is the launch shim for
// bayt-initiated `task -t` calls. The project-root Taskfile.yml is
// user-authored (never emitted) and hooks in via a single `bayt:`
// include. Each per-target file holds a `default:` task (single-cmd
// targets) or a wrapper + N internal cmd-tasks (multi-cmd).
package bayt

// --- T1: smallest project. bayt_root lists per-target files; each
// file's `default:` task wraps the cmd in the defer-EXIT_CODE pattern
// that writes the stamp only on success. `optional: true` on every
// include is load-bearing: Docker stages COPY only their own target's
// fragment and must not crash on missing siblings or dep projects.
_t1: #project & {
	name: "t1"
	dir:  "t1"
	targets: {
		"setup": {taskfile: {}, cmd: "builtin": do: "true"}
		"build": {
			taskfile: {}
			deps: [":setup"]
			srcs: globs: ["**/*.rs"]
			outs: globs: ["target/release/t1"]
			cmd: "builtin": do: "cargo build --release"
		}
	}
}
_t1_tf: (#taskfileGen & {project: _t1, depManifests: {}})
_t1_tf: root: version: "3"
_t1_tf: root: includes: bayt: {
	taskfile: "./Taskfile.bayt.yml"
	dir:      "../"
	optional: true
}
_t1_tf: bayt_root: version: "3"
_t1_tf: bayt_root: includes: setup: {
	taskfile: "./Taskfile.setup.yaml"
	dir:      "../"
	optional: true
}
_t1_tf: bayt_root: includes: build: {
	taskfile: "./Taskfile.build.yaml"
	dir:      "../"
	optional: true
}
_t1_tf: files: build: version: "3"
_t1_tf: files: build: tasks: default: {
	deps: ["::bayt:setup"]
	// BAYTW invokes the `bayt` CLI (cache subcommand) + activate suffix;
	// the cmd line reads as `{{.BAYTW}} <do>`. Defer is last so source
	// order matches the task-exit firing order.
	vars: BAYTW: =~"^bayt cache run --manifest .*bayt\\.build\\.json.* -- mise x --$"
	cmds: [
		"{{.BAYTW}} cargo build --release",
		{defer: =~"^{{if not .EXIT_CODE}}bayt fingerprint .* --update-stamp{{end}}$"},
	]
}

// --- T2: targets without a taskfile block are omitted from both the
// bayt_root includes map AND the per-target files. Only `build` shows
// up here; `release` (no taskfile) is filtered.
_t2: #project & {
	name: "t2"
	dir:  "t2"
	targets: {
		"setup": {taskfile: {}, cmd: "builtin": do: "true"}
		"build": {taskfile: {}, cmd: "builtin": do: "cargo build"}
		"release": {cmd: "builtin": do: "cargo build --release"}
	}
}
_t2_tf: (#taskfileGen & {project: _t2, depManifests: {}})
_t2_tf: bayt_root: includes: {[!~"^(setup|build)$"]: _|_}
_t2_tf: files: {[!~"^(setup|build)$"]: _|_}

// --- T3: multi-cmd target → wrapper `default:` + one internal task per
// cmd, chained via deps in priority order. Wrapper has `deps: [<last>]`,
// internal tasks have `internal: true` and per-cmd `generates:`.
_t3: #project & {
	name: "t3"
	dir:  "t3"
	targets: {
		"build": {
			taskfile: {}
			cmd: {
				"pregen":    {priority: -10, do: "gen-code.nu"}
				"builtin":   {do:                "go build"}
				"postcheck": {priority: 10, do: "govet"}
			}
		}
	}
}
_t3_tf: (#taskfileGen & {project: _t3, depManifests: {}})
_t3_tf: files: build: tasks: default: deps: ["postcheck"]
_t3_tf: files: build: tasks: pregen:    internal: true
_t3_tf: files: build: tasks: builtin:   internal: true
_t3_tf: files: build: tasks: postcheck: internal: true
// Each internal task chains on the previous; the first has no intra-task dep.
_t3_tf: files: build: tasks: builtin: deps:   ["pregen"]
_t3_tf: files: build: tasks: postcheck: deps: ["builtin"]
// Per-cmd generates path under .task/bayt/.
_t3_tf: files: build: tasks: pregen: generates: [".task/bayt/build.pregen.hash"]
_t3_tf: files: build: tasks: pregen: vars: BAYTW: =~"^bayt cache run --manifest .*bayt\\.build\\.json --cmd pregen.* -- mise x --$"
_t3_tf: files: build: tasks: pregen: cmds: [
	"{{.BAYTW}} gen-code.nu",
	{defer: =~"^{{if not .EXIT_CODE}}bayt fingerprint --manifest .* --cmd pregen --stamp-file .*build\\.pregen\\.hash --update-stamp{{end}}$"},
]

// --- T4: env map flows through onto the emitted task.
_t4: #project & {
	name: "t4"
	dir:  "t4"
	targets: {
		"build": {
			taskfile: {}
			env: {
				GOFLAGS:   "-trimpath"
				JAVA_OPTS: "-Xmx2g"
			}
			cmd: "builtin": do: "go build"
		}
	}
}
_t4_tf: (#taskfileGen & {project: _t4, depManifests: {}})
_t4_tf: files: build: tasks: default: env: {
	GOFLAGS:   "-trimpath"
	JAVA_OPTS: "-Xmx2g"
}

// --- T5: `run: always` on the taskfile block becomes `run: always`
// on the emitted default task (used by doctor / lint to bypass the
// status-hook short-circuit).
_t5: #project & {
	name: "t5"
	dir:  "t5"
	targets: {
		"doctor": {
			taskfile: run: "always"
			cmd: "builtin": do: "true"
		}
	}
}
_t5_tf: (#taskfileGen & {project: _t5, depManifests: {}})
_t5_tf: files: doctor: tasks: default: run: "always"

// --- T6: custom activate propagates into the cmd line.
_t6: #project & {
	name:     "t6"
	dir:      "t6"
	activate: "devbox run --"
	targets: {
		"build": {taskfile: {}, cmd: "builtin": do: "cargo build"}
	}
}
_t6_tf: (#taskfileGen & {project: _t6, depManifests: {}})
_t6_tf: files: build: tasks: default: vars: BAYTW: =~"^bayt cache run --manifest .*bayt\\.build\\.json.* -- devbox run --$"
_t6_tf: files: build: tasks: default: cmds: [
	"{{.BAYTW}} cargo build",
	{defer: string},
]

// --- T7: a project with no taskfile-bearing target emits a bayt_root
// with version only — no `includes` field (the emitter only sets it
// when the local includes map has at least one entry).
_t7: #project & {
	name: "t7"
	dir:  "t7"
	targets: {
		"release": {cmd: "builtin": do: "echo"}
	}
}
_t7_tf: (#taskfileGen & {project: _t7, depManifests: {}})
_t7_tf: bayt_root: version: "3"
_t7_tf: bayt_root: {[!="version"]: _|_}

// --- T8: a cmd with a windows override lowers into per-OS `platforms:`
// branches — windows gets the pwsh override, linux/darwin the base do.
// BAYTW stays OS-invariant; the `pwsh -c` wrap rides the windows line.
_t8: #project & {
	name: "t8"
	dir:  "t8"
	targets: {
		"build": {
			taskfile: {}
			cmd: "builtin": {
				do: "./gradlew assemble"
				windows: {do: ".\\gradlew.bat assemble", shell: "pwsh"}
			}
		}
	}
}
_t8_tf: (#taskfileGen & {project: _t8, depManifests: {}})
_t8_tf: files: build: tasks: default: vars: BAYTW: =~"-- mise x --$"
_t8_tf: files: build: tasks: default: cmds: [
	{cmd: =~"^\\{\\{\\.BAYTW\\}\\} pwsh -c \".*gradlew.bat assemble\"$", platforms: ["windows"]},
	{cmd: =~"^\\{\\{\\.BAYTW\\}\\} ./gradlew assemble$", platforms: ["linux"]},
	{cmd: =~"^\\{\\{\\.BAYTW\\}\\} ./gradlew assemble$", platforms: ["darwin"]},
	{defer: string},
]

// --- T9: a RAW (non-incremental taskfile) cmd with a windows override
// branches by OS too — same shape, but bw: "" so no BAYTW cache wrap and
// no defer stamp. Pins that the raw path honors OS axes as well.
_t9: #project & {
	name: "t9"
	dir:  "t9"
	targets: {
		"doctor": {
			taskfile: incremental: false
			cmd: "builtin": {
				do: "check.sh"
				windows: {do: "check.ps1", shell: "pwsh"}
			}
		}
	}
}
_t9_tf: (#taskfileGen & {project: _t9, depManifests: {}})
_t9_tf: files: doctor: tasks: default: cmds: [
	{cmd: "pwsh -c \"check.ps1\"", platforms: ["windows"]},
	{cmd: "check.sh", platforms: ["linux"]},
	{cmd: "check.sh", platforms: ["darwin"]},
]

// Public aggregator forces evaluation of the hidden _t* bindings.
Tests: taskfile: {
	t1: _t1_tf
	t2: _t2_tf
	t3: _t3_tf
	t4: _t4_tf
	t5: _t5_tf
	t6: _t6_tf
	t7: _t7_tf
	t8: _t8_tf
	t9: _t9_tf
}
