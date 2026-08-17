// copy_federation_check.cue — guards what a cross-project copy.from.ref
// pulls in: the producer (and its transitive dirs) into crossProjectDirs,
// the producer's closure into upClosure, and never a _targetCrossDeps edge
// (which would duplicate the COPY).
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

// CF2: crossProjectDirs reaches the federation root but not the per-verb
// closure, which is what `sayt launch` and `compose -f
// compose.<verb>.closure.yaml` load. Without the producer's closure there,
// compose rejects the file: `service "bayt" declares unknown service "…"`.
_cf2: #project & {
	name: "cf2"
	dir:  "apps/cf2"
	targets: {
		"launch": {
			compose: up: true
			dockerfile: scratch & {
				copy: [{from: {ref: "dbx:setup:outs"}, srcs: ["/x"], dst: "/x"}]
			}
			cmd: "builtin": do: "true"
		}
	}
}
_cf2_m: (#manifestGen & {project: _cf2, depManifests: {
	"dbx:setup:outs": {
		dir:  "infra/dbx"
		name: "setup_outs"
		transitiveCrossDeps: []
		upClosure: ["infra/dbx/.bayt/compose.setup.yaml"]
	}
}})
_cf2_m: _upClosure: launch: [
	"apps/cf2/.bayt/compose.launch.yaml",
	"infra/dbx/.bayt/compose.setup.yaml",
]
_cf2_m: _targetCrossDeps: launch: []

// Public aggregator forces evaluation of the hidden _cf* bindings.
Tests: copyFederation: {
	cf1: _cf1_m
	cf2: _cf2_m
}
