// images_check.cue — exercises images.cue presets + lock-table
// resolution. Verifies each preset sets `from` correctly, that `context`
// defaults from `name`, and that presets unify into a target's
// `dockerfile` block without conflicting with the schema disjunction.
package bayt

// --- I1: Each preset's `from.name` resolves through the lock table.
_i1_nubox:   nubox & {from: name: lock.images.leap}
_i1_busybox: busybox & {from: name: lock.images.busybox}
_i1_docker:  docker & {from: name: lock.images.docker}

// --- I2: `context` defaults to `docker-image://<name>` for plain image
// presets (the {name, context} disjunction arm).
_i2_nubox: nubox
_i2_nubox: from: context: "docker-image://\(lock.images.leap)"

// --- I3: scratch sets from=null; the emitter writes `FROM scratch`
// without an additional_contexts entry.
_i3_scratch: scratch
_i3_scratch: from: null

// --- I4: dind extends nubox — same `from`, defaultPreamble adds two
// keyed entries (socat install + docker --help smoke). Composition is
// by key-merge through #MapAsList; CUE list unification was the
// original blocker (length-strict) and isn't on the path anymore.
_i4_dind: dind
_i4_dind: from: nubox.from
// dind's effective preamble (#MapToList output) = nubox's 3 + 2 extra.
_i4_lens: {
	nubox: len((#MapToList & {in: nubox.defaultPreamble}).out)
	dind:  len((#MapToList & {in: dind.defaultPreamble}).out)
}
_i4_lens: dind: _i4_lens.nubox + 2

// --- I5: staging extends busybox's `from`, layers a lazybox overlay
// preamble. Used for ops shells in running pods.
_i5_staging: staging
_i5_staging: from: busybox.from
_i5_staging: from: name: lock.images.busybox

// --- I6: presets unify into a target's dockerfile block. Project-level
// composition: each leaf target picks a preset (or chains via from.ref).
_i6_probe: #project & {
	name: "i6"
	dir:  "test/i6"
	targets: {
		"build":   {dockerfile: nubox}
		"release": {dockerfile: busybox}
		"ops":     {dockerfile: staging}
	}
}
_i6_probe: targets: build:   dockerfile: from: name: lock.images.leap
_i6_probe: targets: release: dockerfile: from: name: lock.images.busybox
_i6_probe: targets: ops:     dockerfile: from: name: lock.images.busybox

// Public aggregator forces evaluation of the hidden _i* bindings.
Tests: images: {
	i1: {nubox: _i1_nubox, busybox: _i1_busybox, docker: _i1_docker}
	i2: _i2_nubox
	i3: _i3_scratch
	i4: {lens: _i4_lens, dind: _i4_dind}
	i5: _i5_staging
	i6: _i6_probe
}
