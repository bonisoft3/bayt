// emitter.cue — top-level aggregator. Single entry point for the
// nushell writer (generate-bayt.nu): #render unifies every gen_*.cue
// generator into one value so `cue export` produces a complete bundle
// the script walks 1:1 onto disk. Each gen_*.cue file owns its own
// output format; this file just composes them.
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
	taskfile: (#taskfileGen & {"project":      G.project, "depManifests": G.depManifests, "runtime": G.runtime})
	docker:   (#dockerComposeGen & {"project": G.project, "depManifests": G.depManifests})
	skaffold: (#skaffoldGen & {"project":      G.project, "depManifests": G.depManifests})
	vscode:   (#vscodeGen & {"project":        G.project, "depManifests": G.depManifests})
	bake:     (#bakeGen & {"project":          G.project, "depManifests": G.depManifests})
}
