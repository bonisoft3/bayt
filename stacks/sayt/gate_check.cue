package sayt

_gateEmpty: (gate & {targets: {}}).files["say.yaml"].say & {}
_gateSelected: gate & {targets: {
	lint: {taskfile: {}}
	test: null
	build: {}
}}
_gateLint: _gateSelected.files["say.yaml"].say.lint.rulemap.builtin.cmds & [{use: "./bayt-task.nu", do: "bayt-task lint"}]
_gateNoTest:  (_gateSelected.files["say.yaml"].say.test == _|_) & true
_gateNoBuild: (_gateSelected.files["say.yaml"].say.build == _|_) & true
