// skaffold_vscode_bake_check.cue — exercises the three smaller emitters.
// Each only needs a handful of assertions beyond the broad coverage in
// docker_compose_check / emitter_check.
package bayt

// ============================================================================
// #skaffoldGen
// ============================================================================

// --- S1: profile-only emission. Per-target fragment carries
// metadata + a profiles list. No project-root file is emitted (no
// `root:` field) — cross-project graph composition lives in the
// user's hand-written <project>/skaffold.yaml.
_s1: #project & {
	name: "s1"
	dir:  "s1"
	targets: {
		"release": {
			dockerfile: nubox
			cmd: "builtin": do: "echo"
			skaffold: profiles: "bayt-build": {
				build: artifact: {
					image: "gcr.io/proj/s1"
					docker: dockerfile: ".bayt/release.Dockerfile"
				}
				build: platforms: ["linux/amd64"]
			}
		}
	}
}
_s1_sk: (#skaffoldGen & {project: _s1, depManifests: {}})
// Default sync, no manifests, no test/verify/portForward → those
// keys are omitted from the emitted profile entry. Image and
// dockerfile flow through as set; default context "../" lands.
_s1_sk: files: release: apiVersion: "skaffold/v4beta11"
_s1_sk: files: release: kind:       "Config"
_s1_sk: files: release: metadata: name: "s1-release"
_s1_sk: files: release: profiles: [{
	name: "bayt-build"
	build: {
		artifacts: [{
			image:   "gcr.io/proj/s1"
			context: "../"
			docker: dockerfile: ".bayt/release.Dockerfile"
		}]
		local: {useBuildkit: true, concurrency: 64}
		platforms: ["linux/amd64"]
	}
}]

// --- S2: a project with no skaffold-bearing targets emits no
// per-target files. The fileset is just empty.
_s2: #project & {
	name: "s2"
	dir:  "s2"
	targets: {
		"build": {
			dockerfile: nubox
			cmd: "builtin": do: "echo"
		}
	}
}
_s2_sk: (#skaffoldGen & {project: _s2, depManifests: {}})
_s2_sk: files: {[string]: _|_}

// ============================================================================
// #vscodeGen
// ============================================================================

// --- V1: build target → tasks.json entry. Cwd is workspace-relative.
// With a `taskfile` block on the target, the vscode entry routes
// through `task bayt:<n>` instead of invoking the cmd directly.
_v1: #project & {
	name: "v1"
	dir:  "guis/v1"
	targets: {
		"build": {
			dockerfile: nubox
			cmd: "builtin": do: "pnpm build"
			taskfile: {}
			vscode: group: {kind: "build", isDefault: true}
		}
	}
}
_v1_vs: (#vscodeGen & {project: _v1, depManifests: {}})
_v1_vs: files: build: version: "2.0.0"
_v1_vs: files: build: tasks: [{
	label:   "v1 build"
	type:    "shell"
	command: "task bayt:build"
	options: cwd: "${workspaceFolder}/guis/v1"
	group: {kind: "build", isDefault: true}
}]

// --- V2: only build/test get vscode entries. setup/release/integrate
// don't fit vscode's run/build menu and are filtered by gen_vscode.
_v2: #project & {
	name: "v2"
	dir:  "v2"
	targets: {
		"build":   {dockerfile: nubox, cmd: "builtin": do: "go build", vscode: group: {kind: "build", isDefault: true}}
		"test":    {dockerfile: nubox, cmd: "builtin": do: "go test", vscode: group: {kind: "test", isDefault: true}}
		"release": {dockerfile: nubox, cmd: "builtin": do: "echo", vscode: group: {kind: "none"}}
	}
}
_v2_vs: (#vscodeGen & {project: _v2, depManifests: {}})
_v2_vs: files: build: version: "2.0.0"
_v2_vs: files: test:  version: "2.0.0"
// release is filtered out — gen_vscode emits only build/test.
_v2_vs: files: {[!~"^(build|test)$"]: _|_}

// ============================================================================
// #bakeGen
// ============================================================================

// --- B1: release with a bake block emits a non-empty HCL string.
_bk1: #project & {
	name: "bk1"
	dir:  "bk1"
	targets: {
		"release": {
			dockerfile: nubox
			cmd: "builtin": do: "echo"
			bake: image: "gcr.io/proj/bk1"
		}
	}
}
_bk1_bk: (#bakeGen & {project: _bk1, depManifests: {}})
_bk1_bk: files: release: string

// --- B2: custom tags + args flow through into the HCL output. (No
// `image` here so `tags` is used directly instead of `[IMAGE]`.)
_bk2: #project & {
	name: "bk2"
	dir:  "bk2"
	targets: {
		"release": {
			dockerfile: nubox
			cmd: "builtin": do: "echo"
			bake: {
				tags: ["repo/bk2:latest", "repo/bk2:v1"]
				args: {FOO: "bar", BAZ: "qux"}
			}
		}
	}
}
_bk2_bk: (#bakeGen & {project: _bk2, depManifests: {}})
_bk2_bk: files: release: string

// Public aggregator forces evaluation of the hidden bindings.
Tests: skaffold_vscode_bake: {
	s1:  {project: _s1,  out: _s1_sk}
	s2:  {project: _s2,  out: _s2_sk}
	v1:  {project: _v1,  out: _v1_vs}
	v2:  {project: _v2,  out: _v2_vs}
	bk1: {project: _bk1, out: _bk1_bk}
	bk2: {project: _bk2, out: _bk2_bk}
}
