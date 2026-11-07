package bayt

import (
	"list"
	"strings"
)

#hmrReaction: "none" | "native" | "restart" | {command: [string, ...string]}
#hmr: {
	native: *false | bool
	code: [...string]
	configs: [...string]
	assets: [...string]
	tools: [...string]
	docs: [...string]
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

#hmrCompose: H={
	hmr:          #hmr
	workdir:      string
	sourcePrefix: *"../" | string
	_reactions: {
		for category, default in {code: "native", configs: "native", assets: "restart"} {
			(category): [if H.hmr.reactions != _|_ if H.hmr.reactions[category] != _|_ {H.hmr.reactions[category]}, default][0]
		}
	}
	watch: list.Concat([
		for category in ["code", "configs", "assets"] {
			[for g in H.hmr[category] {
				let glob = g
				let b = (_hmrBase & {g: glob}).out
				let r = H._reactions[category]
				path:   "\(H.sourcePrefix)\(b)"
				target: "\(H.workdir)/\(b)"
				initial_sync: true
				if r == "native" || r == "none" {action: "sync"}
				if r == "restart" {action: "sync+restart"}
				if r.command != _|_ {action: "sync+exec", exec: command: r.command}
			}]
		},
		[for g in H.hmr.tools { let glob = g, {action: "rebuild", path: "\(H.sourcePrefix)\((_hmrBase & {g: glob}).out)"}}],
	])
}
