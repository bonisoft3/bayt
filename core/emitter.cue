// emitter.cue — top-level aggregator. Single entry point for the
// nushell writer (generate.nu): #render unifies every gen_*.cue
// generator into one value so `cue export` produces a complete bundle
// the script walks 1:1 onto disk. Each gen_*.cue file owns its own
// output format; this file just composes them.
//
// Each generator is a `#<x>From` body over a given manifest `_m`, so the
// render derives the manifest once; `#<x>Gen` wraps it with its own
// #manifestGen for the per-format checks. `_m` is hidden, so only this
// package can supply it; nothing else constrains it, because any further
// conjunct on `_m` copies the shared manifest into every generator.
package bayt

#render: G={
	project:      #project
	depManifests: {[string]: _}
	// Workspace-root-relative dir of the bayt checkout ("" = consumer
	// mode: bare `bayt`/`sayt` tokens resolved via PATH). Injected by
	// generate.nu's pass-2 expression — cue tags don't propagate into
	// imported packages (cue-lang/cue#1530).
	runtime: *"" | string

	manifest: (#manifestGen & {"project":      G.project, "depManifests": G.depManifests})
	taskfile: (#taskfileFrom & {_m: G.manifest, "project":      G.project, "depManifests": G.depManifests, "runtime": G.runtime})
	docker:   (#dockerComposeFrom & {_m: G.manifest, "project": G.project, "depManifests": G.depManifests})
	skaffold: (#skaffoldFrom & {_m: G.manifest, "project":      G.project, "depManifests": G.depManifests})
	vscode:   (#vscodeFrom & {_m: G.manifest, "project":        G.project, "depManifests": G.depManifests})
	bake:     (#bakeFrom & {_m: G.manifest, "project":          G.project, "depManifests": G.depManifests})
	processCompose: (#processComposeFrom & {_m: G.manifest, "project": G.project, "depManifests": G.depManifests, "runtime": G.runtime})
}
