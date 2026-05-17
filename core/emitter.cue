// emitter.cue — top-level aggregator. Single entry point for the
// nushell writer (generate-bayt.nu): #render unifies every gen_*.cue
// generator into one value so `cue export` produces a complete bundle
// the script walks 1:1 onto disk. Each gen_*.cue file owns its own
// output format; this file just composes them.
package bayt

#render: G={
	project:      #project
	depManifests: {[string]: _}

	manifest: (#manifestGen & {"project":      G.project, "depManifests": G.depManifests})
	taskfile: (#taskfileGen & {"project":      G.project, "depManifests": G.depManifests})
	docker:   (#dockerComposeGen & {"project": G.project, "depManifests": G.depManifests})
	skaffold: (#skaffoldGen & {"project":      G.project, "depManifests": G.depManifests})
	vscode:   (#vscodeGen & {"project":        G.project, "depManifests": G.depManifests})
	bake:     (#bakeGen & {"project":          G.project, "depManifests": G.depManifests})
}
