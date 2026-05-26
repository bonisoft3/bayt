// images_check.cue — exercises images.cue presets + lock-table
// resolution. Verifies each preset sets `from` correctly and unifies
// into a target's `dockerfile` block without conflicting with the
// schema disjunction.
package bayt

// --- I1: Each preset's `from.name` resolves through the lock table.
_i1_nubox:   nubox & {from: name: lock.images.leap}
_i1_busybox: busybox & {from: name: lock.images.busybox}
_i1_dind:    dind & {from: name: lock.images.docker}

// --- I3: scratch sets from=null; the emitter writes `FROM scratch`
// without an additional_contexts entry.
_i3_scratch: scratch
_i3_scratch: from: null

// --- I4: dind's defaultPreamble has the dind-entrypoint entry.
_i4_dind_preamble: len((#MapToList & {in: dind.defaultPreamble}).out) & 1

// --- I6: presets unify into a target's dockerfile block. Project-level
// composition: each leaf target picks a preset (or chains via from.ref).
_i6_probe: #project & {
	name: "i6"
	dir:  "test/i6"
	targets: {
		"build":   {dockerfile: nubox}
		"release": {dockerfile: busybox}
	}
}
_i6_probe: targets: build:   dockerfile: from: name: lock.images.leap
_i6_probe: targets: release: dockerfile: from: name: lock.images.busybox

// Public aggregator forces evaluation of the hidden _i* bindings.
Tests: images: {
	i1: {nubox: _i1_nubox, busybox: _i1_busybox, dind: _i1_dind}
	i3: _i3_scratch
	i4: _i4_dind_preamble
	i6: _i6_probe
}
