// copy_federation_check.cue — guards gen_bayt _copyFedDirs: a cross-project
// copy.from.ref federates the producer (and its transitive dirs) into
// crossProjectDirs, and never into _targetCrossDeps (which would duplicate the
// COPY).
package bayt

// CF1: build COPYs from a cross-project synthetic (dbx:setup:outs), and dbx
// itself federates a further project (dep2). Both dirs must land in
// crossProjectDirs; neither may appear as a _targetCrossDeps edge.
_cf1: #project & {
	name: "cf1"
	dir:  "apps/cf1"
	targets: {
		"build": {
			dockerfile: scratch & {
				copy: [{from: {ref: "dbx:setup:outs"}, srcs: ["/x"], dst: "/x"}]
			}
			cmd: "builtin": do: "true"
		}
	}
}
// _copyFedDirs reads only dir + transitiveCrossDeps off the ref's manifest.
_cf1_m: (#manifestGen & {project: _cf1, depManifests: {
	"dbx:setup:outs": {
		dir: "infra/dbx"
		transitiveCrossDeps: [{dir: "infra/dep2"}]
	}
}})
// Positive: producer dir + its transitive dir both federate.
_cf1_m: projectManifest: crossProjectDirs: ["infra/dbx", "infra/dep2"]
// Negative: the copy ref must NOT create a dep edge (no duplicate bulk COPY).
_cf1_m: _targetCrossDeps: build: []

// Public aggregator forces evaluation of the hidden _cf* bindings.
Tests: copyFederation: {
	cf1: _cf1_m
}
