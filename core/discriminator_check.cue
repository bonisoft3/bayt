// discriminator_check.cue — a project's discriminator rides every manifest
// that names the project, so its dependents can key it.
package bayt

_disc1: #project & {
	name:          "d1"
	dir:           "apps/d1"
	discriminator: "k4wz"
	targets: build: {cmd: "builtin": do: "true"}
}
_disc1_m: (#manifestGen & {project: _disc1, depManifests: {}})
_disc1_m: files: build: discriminator: "k4wz"

Tests: discriminator: d1: _disc1_m
