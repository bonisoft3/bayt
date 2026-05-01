// bayt_cycle_check.cue — stress test for CUE cycle detection and deep
// unification. CUE cycle errors often only surface with many levels or
// width of composition. This file intentionally stacks challenging
// patterns to flush them out before building emitters on top of the
// schema. If `cue eval` passes, we're safe.
//
// Patterns exercised:
//   C1.  Deep dep chain via Bazel-style `:dep` strings.
//   C2.  Diamond deps (two paths to the same target).
//   C3.  Project defaults + per-target overrides at depth.
//   C4.  Rulemap composition: multiple stacks layering into cmd.
//   C5.  Far-away cmd.dockerfile decoration across overrides.
//   C6.  Lists-of-values (compose.develop.watch) with many entries.
//   C7.  Many same-project deps in one list.
//   C8.  Many bare targets in one project.
//   C9.  Deep fan-in — one hub depended on by many leaves.
//   C10. Nullable rulemap entry — a layered fragment deletes a rule.
package bayt

// --- C1: deep dep chain. Each target depends on the previous one via
// `:<target>` ref. Stresses transitive-dep resolution at depth.
_cycle_c1: #project & {
	name: "c1"
	dir:  "test/c1"
	targets: {
		"setup":     {cmd: "builtin": do: "true"}
		"build":     {deps: [":setup"], cmd: "builtin": do: "true"}
		"test":      {deps: [":build"], cmd: "builtin": do: "true"}
		"integrate": {deps: [":build"], cmd: "builtin": do: "true"}
		"release":   {deps: [":build"], cmd: "builtin": do: "true"}
		"verify":    {deps: [":release"], cmd: "builtin": do: "true"}
	}
}

// --- C2: diamond — two paths to the same target.
//   test → build → setup
//   integrate → build → setup
_cycle_c2: #project & {
	name: "c2"
	dir:  "test/c2"
	targets: {
		"setup":     {cmd: "builtin": do: "true"}
		"build":     {deps: [":setup"], cmd: "builtin": do: "true"}
		"test":      {deps: [":build"], cmd: "builtin": do: "true"}
		"integrate": {deps: [":build"], cmd: "builtin": do: "true"}
	}
}

// --- C3: project defaults unified into every target. defaults supplies
// env + a shared cache mount; each target overrides `do`.
_cycle_c3: #project & {
	name: "c3"
	dir:  "test/c3"
	defaults: {
		env: {COMMON_FLAG: "1"}
		cmd: "builtin": dockerfile: mounts: [
			{type: "cache", target: "/root/.cache", sharing: "locked"},
		]
	}
	targets: {
		"setup":   {cmd: "builtin": do: "true"}
		"build":   {cmd: "builtin": do: "cargo build"}
		"test":    {cmd: "builtin": do: "cargo test"}
		"release": {cmd: "builtin": do: "cargo build --release"}
	}
}

// --- C4: rulemap composition at multiple layers. Two layered fragments
// + a project-level addition; all four resolve in priority order.
_c4_layer1: {
	cmd: {
		"pregen":  {priority: -10, do: "pregen.nu"}
		"builtin": {do:                "build.nu"}
	}
}
_c4_layer2: {
	cmd: "postcheck": {priority: 10, do: "postcheck.nu"}
}
_cycle_c4: #project & {
	name: "c4"
	dir:  "test/c4"
	targets: {
		"build": _c4_layer1 & _c4_layer2 & {
			cmd: "finalize": {priority: 20, do: "finalize.nu"}
		}
	}
}
// Resolved cmd order: pregen (-10), builtin (0), postcheck (10),
// finalize (20). #MapToList strips the priority field from its output;
// the order itself is the assertion.
_cycle_c4: targets: build: cmds: [
	{name: "pregen",    shell: "nu", do: "pregen.nu",    stop: false, ...},
	{name: "builtin",   shell: "nu", do: "build.nu",     stop: false, ...},
	{name: "postcheck", shell: "nu", do: "postcheck.nu", stop: false, ...},
	{name: "finalize",  shell: "nu", do: "finalize.nu",  stop: false, ...},
]

// --- C5: far-away cmd.dockerfile decoration across multiple targets.
// CUE must unify mounts lists by value across overrides.
_cycle_c5: #project & {
	name: "c5"
	dir:  "test/c5"
	targets: {
		"build": {
			cmd: "builtin": {
				do: "./gradlew assemble"
				dockerfile: mounts: [
					{type: "cache", target: "/root/.gradle", sharing: "locked"},
				]
			}
		}
		"integrate": {
			cmd: "builtin": {
				do: "./gradlew integrationTest --rerun"
				dockerfile: {
					wrap: "dind.sh"
					mounts: [
						{type: "secret", id:    "host.env", required: true},
						{type: "cache",  target: "/root/.gradle", sharing: "locked"},
					]
				}
			}
		}
	}
}

// --- C6: lists of value-carrying entries (compose.develop.watch). Real
// projects carry 4-8 entries per target; stress list unification.
_cycle_c6: #project & {
	name: "c6"
	dir:  "test/c6"
	targets: {
		"launch": {
			cmd: "builtin": do: "pnpm dev"
			compose: develop: watch: [
				{action: "sync",         path: "./src",            target: "/app/src",            ignore: ["node_modules"]},
				{action: "sync",         path: "./public",         target: "/app/public",         ignore: []},
				{action: "sync+restart", path: "./nuxt.config.ts", target: "/app/nuxt.config.ts", ignore: []},
				{action: "rebuild",      path: "./package.json",   target: "/app/package.json",   ignore: []},
				{action: "rebuild",      path: "./pnpm-lock.yaml", target: "/app/pnpm-lock.yaml", ignore: []},
				{action: "sync",         path: "./plugins",        target: "/app/plugins",        ignore: []},
				{action: "sync",         path: "./components",     target: "/app/components",     ignore: []},
				{action: "sync",         path: "./pages",          target: "/app/pages",          ignore: []},
			]
		}
	}
}

// --- C7: many same-project deps in one list.
_cycle_c7: #project & {
	name: "c7"
	dir:  "test/c7"
	targets: {
		"setup":   {cmd: "builtin": do: "true"}
		"build":   {deps: [":setup"], cmd: "builtin": do: "true"}
		"test":    {deps: [":build"], cmd: "builtin": do: "true"}
		"release": {deps: [":build", ":test"], cmd: "builtin": do: "true"}
	}
}

// --- C8: ten bare targets in one project — all canonical sayt verbs.
_cycle_c8: #project & {
	name: "c8"
	dir:  "test/c8"
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

// --- C9: deep fan-in — one hub target depended on by many leaves.
_cycle_c9: #project & {
	name: "c9"
	dir:  "test/c9"
	targets: {
		"hub":   {srcs: globs: ["hub/**"], cmd: "builtin": do: "true"}
		"leaf1": {deps: [":hub"], cmd: "builtin": do: "test1"}
		"leaf2": {deps: [":hub"], cmd: "builtin": do: "test2"}
		"leaf3": {deps: [":hub"], cmd: "builtin": do: "test3"}
		"leaf4": {deps: [":hub"], cmd: "builtin": do: "test4"}
		"leaf5": {deps: [":hub"], cmd: "builtin": do: "test5"}
		"leaf6": {deps: [":hub"], cmd: "builtin": do: "test6"}
	}
}

// --- C10: nullable rulemap entry — a layered fragment nulls out a rule.
_cycle_c10: #project & {
	name: "c10"
	dir:  "test/c10"
	targets: {
		"build": {
			cmd: {
				"legacy":  {priority: -5, do: "legacy-step"}
				"builtin": {do:               "real-build"}
			}
		}
		"build-min": {
			cmd: {
				"legacy":  null
				"builtin": {do: "real-build"}
			}
		}
	}
}
_cycle_c10: targets: "build-min": cmds: [
	{name: "builtin", shell: "nu", do: "real-build", stop: false, ...},
]

// Public aggregator forces evaluation of all hidden bindings.
Tests: cycle: {
	c1:  _cycle_c1
	c2:  _cycle_c2
	c3:  _cycle_c3
	c4:  _cycle_c4
	c5:  _cycle_c5
	c6:  _cycle_c6
	c7:  _cycle_c7
	c8:  _cycle_c8
	c9:  _cycle_c9
	c10: _cycle_c10
}
