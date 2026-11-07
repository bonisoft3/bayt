package bayt

_hmrExample: #hmr & {
	code: ["src/**/*"]
	configs: ["config/app.yaml"]
	assets: ["public/**"]
	tools: ["package.json"]
	docs: ["docs/**"]
	reactions: {
		code: "restart"
		configs: command: ["server", "reload"]
		assets: "none"
	}
}
_hmrComposeCheck: (#hmrCompose & {hmr: _hmrExample, workdir: "/app"}).watch
_hmrComposeCheck: [
	{action: "sync+restart", path: "../src", target: "/app/src"},
	{action: "sync+exec", path: "../config/app.yaml", target: "/app/config/app.yaml", exec: command: ["server", "reload"]},
	{action: "sync", path: "../public", target: "/app/public"},
	{action: "rebuild", path: "../package.json"},
]
_hmrLegacy: #hmr & {code: ["src"], configs: ["config"], assets: ["assets"], tools: [], docs: []}
_hmrLegacyCompose: (#hmrCompose & {hmr: _hmrLegacy, workdir: "/app"}).watch
_hmrLegacyCompose: [
	{action: "sync", path: "../src", target: "/app/src"},
	{action: "sync", path: "../config", target: "/app/config"},
	{action: "sync+restart", path: "../assets", target: "/app/assets"},
]
Tests: hmr: [_hmrComposeCheck, _hmrLegacyCompose]
