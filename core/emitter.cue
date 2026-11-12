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

#render: {
	project:      #project
	depManifests: {[string]: _}
	// Workspace-root-relative dir of the bayt checkout ("" = consumer
	// mode: bare `bayt`/`sayt` tokens resolved via PATH). Injected by
	// generate.nu's pass-2 expression — cue tags don't propagate into
	// imported packages (cue-lang/cue#1530).
	runtime: *"" | string
	// The consuming repo's CUE module path, injected the same way.
	module: *"" | string
	let _project = project
	let _depManifests = depManifests
	let _runtime = runtime
	let _mod = module
	project: _module: _mod

	passthrough: (#passthroughFrom & {project: _project})
	manifest:    (#manifestGen & {project: _project, depManifests: _depManifests})
	let _manifest = manifest
	taskfile:       (#taskfileFrom & {_m: _manifest, project: _project, depManifests: _depManifests, runtime: _runtime})
	docker:         (#dockerComposeFrom & {_m: _manifest, project: _project, depManifests: _depManifests})
	skaffold:       (#skaffoldFrom & {_m: _manifest, project: _project, depManifests: _depManifests})
	vscode:         (#vscodeFrom & {_m: _manifest, project: _project, depManifests: _depManifests})
	bake:           (#bakeFrom & {_m: _manifest, project: _project, depManifests: _depManifests})
	processCompose: (#processComposeFrom & {_m: _manifest, project: _project, depManifests: _depManifests, runtime: _runtime})
}
