// gen_bake.cue — the project's bake HCL. A `matrix` over the project's
// static federated target names names each target, so the emitted target
// merges with the federated compose target of the same name and applies
// its `tags` (= IMAGE) and `output` (the PUSH_IMAGE ternary). Everything
// else — context, dockerfile, args, cache — lives in compose's `x-bake`,
// so the HCL alone can't build; skaffold invokes it against the flattened
// compose with the target as a bare positional and IMAGE/PUSH_IMAGE from
// its env. Keep it positional: on Windows skaffold runs buildCommands
// through cmd.exe, which has no `VAR=x cmd` / `export`.
package bayt

import (
	"list"
	"strings"
)

#bakeGen: {
	project:      #project
	depManifests: {[string]: _}
	let _project = project
	let _depManifests = depManifests
	#bakeFrom
	_m: (#manifestGen & {project: _project, depManifests: _depManifests})
}

#bakeFrom: {
	project:      #project
	depManifests: {[string]: _}

	_m: _
	let _project = project
	let _files = _m.files

	// Release targets: `bake.image` names the registry ref, so the HCL is the
	// build recipe skaffold / goreleaser / depot bake with (whether they push
	// is the PUSH_IMAGE env var, not a generate-time decision). Plain `bake: {}`
	// (compose-x-bake-only cache wiring) has no image and is skipped — it wants
	// no skaffold buildCommand.
	_emit: {for n, t in _files if t.bake != _|_ if t.bake.image != _|_ {(n): t}}

	// Federated target names (<project.name>-<n>), sorted for a stable
	// matrix list. The HCL's matrix iterates these, so `name` is one of
	// them and the positional selects which target(s) build.
	_fedNames:   list.Sort([for n, _ in _emit {"\(_project.name)-\(n)"}], list.Ascending)
	_matrixList: strings.Join([for f in _fedNames {"\"\(f)\""}], ", ")

	// Every target that emits a compose service, i.e. everything bake can
	// name. Wider than _emit (which is release-image targets only).
	_svc: {for n, t in _files if t.dockerfile != _|_ {(n): t}}

	// The walk runs in compose SERVICE-name space: `depends_on` keys are
	// service names, and a service name is what a bake target is called.
	// Keys matching "<project.name>-<target>" are this project's; anything
	// else is a hand-authored overlay service, kept verbatim as a leaf (its
	// own edges are unknown). Naming one asserts nothing new — gen_compose
	// mirrors every depends_on key into `additional_contexts: target:<key>`.
	_rtEdges: {
		for n, _ in _svc {
			("\(_project.name)-\(n)"): [for k, _ in {
				if _project.targets[n].compose != _|_ {
					for dk, _ in _project.targets[n].compose.depends_on {(dk): true}
					if _project.targets[n].entrypoint != _|_ {
						for ek, _ in _project.targets[n].entrypoint.after {
							((_serviceName & {project: _project.name, target: ek}).out): true
						}
					}
				}
			} {k}]
		}
	}

	// Bounded frontier walk from integrate; a recursive per-node closure map
	// revisits diamond subgraphs per path. A dep with no entry in _rtEdges is an
	// overlay leaf: included in the frontier, never expanded further.
	_rtEntry: "\(_project.name)-integrate"
	_rtSteps: [
		if _svc["integrate"] != _|_ {{(_rtEntry): true}},
		if _svc["integrate"] == _|_ {{}},
		for i, _ in [for _, _ in _svc {1}] {
			{
				for k, _ in _rtSteps[i] {(k): true}
				for k, _ in _rtSteps[i] if _rtEdges[k] != _|_ for d in _rtEdges[k] {(d): true}
			}
		},
	]
	_rtGroupNames: list.Sort([for k, _ in _rtSteps[len(_rtSteps)-1] {k}], list.Ascending)

	_rtGroupList: strings.Join([for f in _rtGroupNames {"\"\(f)\""}], ", ")

	// Project HCL body. `matrix` over the static federated-name list names
	// each target; a bake positional picks which one builds. Carries only
	// what compose can't express: the IMAGE tag and the PUSH_IMAGE output
	// ternary. Written to <project.dir>/.bayt/bake.hcl by generate.nu,
	// only when a release target wants it.
	if len(_emit) > 0 {
		hcl: """
			variable "IMAGE" {
			  default = ""
			}
			variable "PUSH_IMAGE" {
			  default = "false"
			}

			target "release" {
			  matrix = { t = [\(_matrixList)] }
			  name   = t
			  tags   = [IMAGE]
			  output = PUSH_IMAGE == "true" ? ["type=registry"] : ["type=docker"]
			}

			"""
	}

	_depotGroupName: "depot-build"

	// The runtime closure as the `depot-build` group, written to
	// <project.dir>/.bayt/depot.hcl and baked by the depot build phase.
	// Its own file, never bake.hcl: that file's `target "release"` binds
	// tags/output onto every matrix member by name, so a caller wanting
	// only this selection would strip them (rationale in SPEC.md).
	if len(_rtGroupNames) > 0 {
		depotHcl: """
			group "\(_depotGroupName)" {
			  targets = [\(_rtGroupList)]
			}

			"""

	}
}
