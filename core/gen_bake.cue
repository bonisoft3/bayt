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

#bakeGen: G={
	project: #project
	depManifests:   {[string]: _}

	_m: (#manifestGen & {project: G.project, depManifests: G.depManifests})

	// Release targets: `bake.image` names the registry ref, so the HCL is the
	// build recipe skaffold / goreleaser / depot bake with (whether they push
	// is the PUSH_IMAGE env var, not a generate-time decision). Plain `bake: {}`
	// (compose-x-bake-only cache wiring) has no image and is skipped — it wants
	// no skaffold buildCommand.
	_emit: {for n, t in G._m.files if t.bake != _|_ if t.bake.image != _|_ {(n): t}}

	// Federated target names (<project.name>-<n>), sorted for a stable
	// matrix list. The HCL's matrix iterates these, so `name` is one of
	// them and the positional selects which target(s) build.
	_fedNames: list.Sort([for n, _ in _emit {"\(G.project.name)-\(n)"}], list.Ascending)
	_matrixList: strings.Join([for f in _fedNames {"\"\(f)\""}], ", ")

	// Every target that emits a compose service, i.e. everything bake can
	// name. Wider than _emit (which is release-image targets only).
	_svc: {for n, t in G._m.files if t.dockerfile != _|_ {(n): t}}

	// The walk runs in compose SERVICE-name space: `depends_on` keys are
	// service names, and a service name is what a bake target is called.
	// Keys matching "<project.name>-<target>" are this project's; anything
	// else is a hand-authored overlay service, kept verbatim as a leaf (its
	// own edges are unknown). Naming one asserts nothing new — gen_compose
	// mirrors every depends_on key into `additional_contexts: target:<key>`.
	_rtEdges: {
		for n, _ in _svc {
			("\(G.project.name)-\(n)"): [
				for k, _ in [
					if G.project.targets[n].compose != _|_ {G.project.targets[n].compose.depends_on},
					{},
				][0] {k},
			]
		}
	}

	// _rtClosure — self + transitive runtime deps, recursive over this map
	// (staged induction; depends_on is a DAG, so it terminates). A dep with
	// no entry of its own is an overlay leaf: contribute the name, stop.
	_rtClosure: {
		for s, deps in _rtEdges {
			(s): (_uniqStrings & {in: list.Concat([
				[s],
				list.FlattenN([for d in deps {[
					if _rtClosure[d] != _|_ {_rtClosure[d]},
					[d],
				][0]}], 1),
			])}).out
		}
	}

	// The bake group: the integrate service plus its transitive runtime
	// deps. Emitted only when the project has an integrate service to
	// root the walk.
	_rtEntry: "\(G.project.name)-integrate"
	_rtGroupNames: [
		if _svc["integrate"] != _|_ {list.Sort(_rtClosure[_rtEntry], list.Ascending)},
		[],
	][0]

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

	// The runtime closure as the `depot-build` group, written to
	// <project.dir>/.bayt/depot.hcl and baked by the depot build phase.
	// Its own file, never bake.hcl: that file's `target "release"` binds
	// tags/output onto every matrix member by name, so a caller wanting
	// only this selection would strip them (rationale in DESIGN.md).
	if len(_rtGroupNames) > 0 {
		depotHcl: """
			group "depot-build" {
			  targets = [\(_rtGroupList)]
			}

			"""
	}
}
