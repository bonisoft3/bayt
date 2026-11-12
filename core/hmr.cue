package bayt

import (
	"list"
	"strings"
)

#hmrReaction: "none" | "native" | "restart" | {command: [string, ...string]}
#hmr: {
	native:  *false | bool
	code:    [...string]
	configs: [...string]
	assets:  [...string]
	tools:   [...string]
	docs:    [...string]
	reactions?: {
		code?:    #hmrReaction
		configs?: #hmrReaction
		assets?:  #hmrReaction
	}
}

_hmrBase: {
	g: string
	out: [
		if strings.HasSuffix(g, "/**/*") {strings.TrimSuffix(g, "/**/*")},
		if strings.HasSuffix(g, "/**") {strings.TrimSuffix(g, "/**")},
		if strings.HasSuffix(g, "/*") {strings.TrimSuffix(g, "/*")},
		g,
	][0]
}

#hmrCompose: {
	hmr:          #hmr
	workdir:      string
	sourcePrefix: *"../" | string
	let _hmr = hmr
	let _workdir = workdir
	let _sourcePrefix = sourcePrefix
	_reactions: {
		for category, default in {code: "native", configs: "native", assets: "restart"} {
			(category): [if _hmr.reactions != _|_ if _hmr.reactions[category] != _|_ {_hmr.reactions[category]}, default][0]
		}
	}
	let _rx = _reactions
	watch: list.Concat([
		for category in ["code", "configs", "assets"] {
			[for g in _hmr[category] {
				let glob = g
				let b = (_hmrBase & {g: glob}).out
				let r = _rx[category]
				path:         "\(_sourcePrefix)\(b)"
				target:       "\(_workdir)/\(b)"
				initial_sync: true
				if r == "native" || r == "none" {action: "sync"}
				if r == "restart" {action: "sync+restart"}
				if r.command != _|_ {action: "sync+exec", exec: command: r.command}
			}]
		},
		[for g in _hmr.tools {let glob = g, {action: "rebuild", path: "\(_sourcePrefix)\((_hmrBase & {g: glob}).out)"}}],
	])
}
