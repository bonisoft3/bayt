// gen_skaffold.cue — emits per-target skaffold fragments.
//
// Output:
//   files: target-name → .bayt/<n>.skaffold.yaml body. Profiles-only
//          shape: base = apiVersion + kind + metadata; everything
//          else lives under named profiles. Activation rules on each
//          profile decide when it auto-fires.
//
// No project-root skaffold.yaml is emitted. Cross-project graph
// composition (the `requires:` chain that `skaffold dev` resolves
// through) is user-owned: the user writes <project>/skaffold.yaml
// by hand and `requires:` whichever .bayt/<n>.skaffold.yaml fragments
// matter to them. Same shape as compose's federated includes — bayt
// emits the building blocks, humans assemble.
package bayt

import (
	"list"
)

#skaffoldGen: {
	project:      #project
	depManifests: {[string]: _}
	let _project = project
	let _depManifests = depManifests
	#skaffoldFrom
	_m: (#manifestGen & {project: _project, depManifests: _depManifests})
}

#skaffoldFrom: {
	project:      #project
	depManifests: {[string]: _}

	_m: _

	// Only targets that declared a skaffold block. Empty profile
	// dictionaries still emit a fragment with apiVersion+kind+metadata
	// — useful as a no-op anchor for the user's project skaffold.yaml
	// to require even if no profiles are declared yet.
	_emit: {for n, t in _m.files if t.skaffold != _|_ {(n): t}}

	// Helper: render one profile's body. Activation, build artifact,
	// manifests, test/verify/portForward arrays. The artifact's bake
	// sugar expands here.
	_renderProfile: {
		t:    _
		name: string
		// p == t.skaffold.profiles[name]
		p:   _
		out: {...}
		let _name = name
		let _p = p
		out: {
			name: _name
			if len(_p.activation) > 0 {
				activation: _p.activation
			}
			let _a = _p.build.artifact

			// bake sugar → the bare-positional bake invocation; `target` is
			// the federated compose name. See gen_bake.cue for the form and
			// why it stays positional.
			let _bakeBuildCommand = [
				if _a.bake != _|_ {"docker compose config | docker buildx bake --allow=fs.read=../.. -f- -f .bayt/bake.hcl \(_a.bake.target)"},
				"",
			][0]
			build: {
				artifacts: [{
					image:   _a.image
					context: _a.context
					if _a.docker != _|_ {
						docker: dockerfile: _a.docker.dockerfile
					}
					if _a.custom != _|_ {
						custom: buildCommand: _a.custom.buildCommand
					}
					if _a.bake != _|_ {
						custom: buildCommand: _bakeBuildCommand
					}
					if _a.sync.auto {
						sync: auto: true
					}
					if len(_a.sync.manual) > 0 {
						sync: manual: _a.sync.manual
					}
				}]
				local: {
					useBuildkit: _p.build.local.useBuildkit
					concurrency: _p.build.local.concurrency
					if _p.build.local.push {
						push: true
					}
				}
				if len(_p.build.platforms) > 0 {
					platforms: _p.build.platforms
				}
				if _p.build.tagPolicy != _|_ {
					tagPolicy: _p.build.tagPolicy
				}
			}
			if _p.manifests.kustomize != _|_ {
				manifests: kustomize: paths: _p.manifests.kustomize.paths
			}
			if len(_p.test) > 0 {
				test: _p.test
			}
			if len(_p.verify) > 0 {
				verify: _p.verify
			}
			if len(_p.portForward) > 0 {
				portForward: _p.portForward
			}
		}
	}

	// Per-target skaffold files. Base content = apiVersion + kind +
	// metadata only (skaffold's required fields). All build/sync/
	// manifest/test/verify content moves into named profiles, so a
	// parent that `requires:` this fragment without activating any
	// profile gets nothing from the build graph — the right default
	// for a graph-additive include model.
	//
	// Profiles are filtered before emission:
	//   - null entries → opt-out (project explicitly nulled the
	//     stack-supplied profile).
	//   - missing `build.artifact.image` → opt-in lever for stack
	//     scaffolds. stacks/sayt seeds activation + dockerfile defaults
	//     for `bayt-dev` / `bayt-build` / `bayt-run`; only projects
	//     that set image actually get the profile emitted.
	files: {
		for n, t in _emit {
			let _activeProfiles = [
				for k, p in t.skaffold.profiles
				if p != null
				if p.build.artifact.image != _|_
				if p.build.artifact.image != "" {
					k
				},
			]
			let _names = list.Sort(_activeProfiles, list.Ascending)

			// Skip the file emission entirely if no profile survives
			// the filter — there's nothing useful to include.
			if len(_names) > 0 {
				(n): {
					apiVersion: "skaffold/v4beta11"
					kind:       "Config"
					metadata: name: "\(t.project)-\(n)"
					profiles: [for nm in _names {
						(_renderProfile & {"t": t, "name": nm, p: t.skaffold.profiles[nm]}).out
					}]
				}
			}
		}
	}
}
