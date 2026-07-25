// gen_bake.cue — the project's bake HCL. A `matrix` over the project's
// static federated target names names each target, so the emitted target
// merges with the federated compose target of the same name and applies
// its `tags` (= IMAGE) and `output` (the PUSH_IMAGE ternary). Everything
// else — context, dockerfile, args, cache — lives in compose's `x-bake`,
// so the HCL alone can't build; skaffold invokes it against the flattened
// compose (or the pre-flattened depot.yaml) with the target as a bare
// positional and IMAGE/PUSH_IMAGE from its env. Keep it positional: on
// Windows skaffold runs buildCommands through cmd.exe, which has no
// `VAR=x cmd` / `export`.
package bayt

import (
	"list"
	"strings"
)

#bakeGen: G={
	project: #project
	depManifests:   {[string]: _}

	_m: (#manifestGen & {project: G.project, depManifests: G.depManifests})

	// Release targets that declare a real image binding. Plain `bake: {}`
	// (compose-x-bake-only cache wiring) has no image and is skipped — it
	// wants no skaffold buildCommand.
	_emit: {for n, t in G._m.files if t.bake != _|_ if t.bake.image != _|_ {(n): t}}

	// Federated target names (<project.name>-<n>), sorted for a stable
	// matrix list. The HCL's matrix iterates these, so `name` is one of
	// them and the positional selects which target(s) build.
	_fedNames: list.Sort([for n, _ in _emit {"\(G.project.name)-\(n)"}], list.Ascending)
	_matrixList: strings.Join([for f in _fedNames {"\"\(f)\""}], ", ")

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
}
