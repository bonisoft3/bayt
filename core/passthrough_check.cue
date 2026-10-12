package bayt

_passthrough: #project & {
	name: "passthrough"
	dir:  "."
	files: "say.yaml": {say: lint: do: "task lint"}
	targets: lint: {files: "settings.json": {enabled: true}}
}
_passthroughRendered: #passthroughFrom & {project: _passthrough}
_passthroughRendered: files: [
	{name: "say.yaml", data: {say: lint: do: "task lint"}},
	{name: "settings.lint.json", data: {enabled: true}},
]
_passthroughEmpty: (#passthroughFrom & {project: {name: "empty", dir: "."}}).files & []
