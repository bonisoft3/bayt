// cache_tag_check — the cache-tag budget.
//
// A `bake.cache.scope` long enough to squeeze the tag's segment below the hash
// width would crash generation inside strings.SliceRunes, from an error naming
// neither the project, the scope, nor the budget. Bounding both names leaves no
// such failure to assert against, so what these pin is the bound: its
// arithmetic, its idempotence, and the 128-char tag it fits under.
//
// In package bayt because the budget constants are hidden.
package bayt

import "strings"

// The arithmetic the constants encode, restated so a change to one of them that
// does not fit Docker's 128-char tag fails here rather than in a registry.
_ct_budget:    _cacheTagBudget & 62
_ct_hash:      _cacheTagHash & 16
_ct_scope_max: _cacheScopeMax & 44

// A scope within the cap is returned unchanged, so every project generating
// today keeps the tags it has: the bound is not a cache bust.
_ct_short: (#cacheTagScope & {in: "iris-bake-cache-v14"}).out & "iris-bake-cache-v14"

// 44 is the last untouched length.
_ct_at_cap: (#cacheTagScope & {in: strings.Repeat("a", 44)}).out & strings.Repeat("a", 44)

// Over the cap, deterministically.
_ct_long_in:  "aaaaaaaaaa-bbbbbbbbbb-cccccccccc-bake-cache-333"
_ct_long_out: (#cacheTagScope & {in: _ct_long_in}).out & "aaaaaaaaaa-bbbbbbbbbb-ccccc-50be3cfe432d9405"

// Idempotent: the bound is a fixed point. That is what lets the scope and the
// segment be bounded at separate sites without agreeing on who applies it first.
_ct_idem: (#cacheTagScope & {in: _ct_long_out}).out & _ct_long_out

_ct_seg: (#cacheTagSeg & {in: "some-project-unit-test", scope: _ct_long_in}).out & "s-ba5aecb3de71d779"

// 45 is the band the cap excludes: unbounded it leaves a segment 17 chars, one
// short of a hash plus separator plus a readable char, and the segment degrades
// to a bare hash behind a leading dash. Spelled at the boundary, since 44 and 45
// are what divide the intended collapse from the degraded one.
_ct_band45_in:  "aaaaaaaaaa-bbbbbbbbbb-cccccccccc-bake-cache-3"
_ct_band45_len: len(_ct_band45_in) & 45
_ct_band45_seg: (#cacheTagSeg & {in: "some-project-unit-test", scope: _ct_band45_in}).out & "s-ba5aecb3de71d779"

// The ceiling the cap holds: worst case is scope + "-" + 64 + "-" + segment.
// Exactly 128 means the budget is spent, not overrun.
_ct_worst_tag: (len(_ct_long_out) + 1 + 64 + 1 + len(_ct_seg)) & 128

// --- End to end. The scope is over the cap and the target name is over what
// the bounded scope leaves, so both collapse. Selecting the emitted lists forces
// a "field not found" if no x-bake was emitted; the literals pin the refs.
_ct_proj: #project & {
	name: "ct"
	dir:  "ct"
	bake: cache: {type: "registry", registry: "reg.example/p", scope: _ct_long_in}
	targets: {
		"some-project-unit-test": {
			srcs: globs: ["src/**"]
			outs: globs: ["target/ct"]
			cmd: "builtin": do: "cargo build"
			dockerfile: busybox
		}
		// Shares 21 chars of prefix with its sibling, so both collapse to the
		// same readable char: only the hash of the full name keeps their cache
		// manifests apart.
		"some-project-unit-tests-too": {
			srcs: globs: ["src/**"]
			cmd: "builtin": do: "cargo build"
			dockerfile: busybox
		}
	}
}
_ct_dc: (#dockerComposeGen & {project: _ct_proj, depManifests: {}})

// `targets` is a pattern constraint, so a mistyped key below would resolve to
// the template and leave its assertion incomplete — which `cue eval` tolerates.
// Pinning the key set is what turns that silence into a failure.
_ct_n1:   "some-project-unit-test"
_ct_n2:   "some-project-unit-tests-too"
_ct_keys: [for k, _ in _ct_proj.targets {k}] & [_ct_n1, _ct_n2]

// Per-target refs: the target name is bounded like any other segment.
_ct_target_from: _ct_proj.targets[_ct_n1].bake.cache.from
_ct_target_from: [
	"type=registry,ref=reg.example/p:aaaaaaaaaa-bbbbbbbbbb-ccccc-50be3cfe432d9405-${CACHE_SCOPE:-unscoped}-s-ba5aecb3de71d779",
	"type=registry,ref=reg.example/p:aaaaaaaaaa-bbbbbbbbbb-ccccc-50be3cfe432d9405-${CACHE_SCOPE_FALLBACK:-unscoped}-s-ba5aecb3de71d779",
]

// A synthetic's segment is its project-qualified service name.
_ct_srcs_from: _ct_dc.compose.files."some-project-unit-test".services."ct-some-project-unit-test_srcs".build."x-bake"."cache-from"
_ct_srcs_from: [
	"type=registry,ref=reg.example/p:aaaaaaaaaa-bbbbbbbbbb-ccccc-50be3cfe432d9405-${CACHE_SCOPE:-unscoped}-c-a4296957ac258997",
	"type=registry,ref=reg.example/p:aaaaaaaaaa-bbbbbbbbbb-ccccc-50be3cfe432d9405-${CACHE_SCOPE_FALLBACK:-unscoped}-c-a4296957ac258997",
]

_ct_sibling_from: _ct_proj.targets[_ct_n2].bake.cache.from
_ct_sibling_from: [
	"type=registry,ref=reg.example/p:aaaaaaaaaa-bbbbbbbbbb-ccccc-50be3cfe432d9405-${CACHE_SCOPE:-unscoped}-s-0f1555fba7304db5",
	"type=registry,ref=reg.example/p:aaaaaaaaaa-bbbbbbbbbb-ccccc-50be3cfe432d9405-${CACHE_SCOPE_FALLBACK:-unscoped}-s-0f1555fba7304db5",
]

// cache-to carries the same bounded names, plus the export mode and the zstd
// settings that can only be stated at emission.
_ct_target_to: _ct_proj.targets[_ct_n1].bake.cache.to
_ct_target_to: [
	"type=registry,ref=reg.example/p:aaaaaaaaaa-bbbbbbbbbb-ccccc-50be3cfe432d9405-${CACHE_SCOPE:-unscoped}-s-ba5aecb3de71d779,mode=min,image-manifest=true,oci-mediatypes=true,compression=zstd,compression-level=3",
]

// --- gha sugar. The same two names are bounded on this path, where the tag is
// a cache key rather than an OCI ref: the 62-char budget is stricter than GHA
// needs, so bounding here is conservative, never wrong.
_ct_gha: #project & {
	name: "cg"
	dir:  "cg"
	bake: cache: {type: "gha", scope: _ct_long_in}
	targets: "some-project-unit-test": {
		srcs: globs: ["src/**"]
		cmd: "builtin": do: "cargo build"
		dockerfile: busybox
	}
}
_ct_gha_from: _ct_gha.targets[_ct_n1].bake.cache.from
_ct_gha_from: [
	"type=gha,scope=aaaaaaaaaa-bbbbbbbbbb-ccccc-50be3cfe432d9405-${CACHE_SCOPE:-unscoped}-s-ba5aecb3de71d779",
	"type=gha,scope=aaaaaaaaaa-bbbbbbbbbb-ccccc-50be3cfe432d9405-${CACHE_SCOPE_FALLBACK:-unscoped}-s-ba5aecb3de71d779",
]
_ct_gha_to: _ct_gha.targets[_ct_n1].bake.cache.to
_ct_gha_to: [
	"type=gha,mode=min,scope=aaaaaaaaaa-bbbbbbbbbb-ccccc-50be3cfe432d9405-${CACHE_SCOPE:-unscoped}-s-ba5aecb3de71d779",
]

// Every synthetic rides the same emitter; each is pinned so a change that stops
// keying them by service name has three places to fail, not one.
_ct_outs_from: _ct_dc.compose.files."some-project-unit-test".services."ct-some-project-unit-test_outs".build."x-bake"."cache-from"
_ct_outs_from: [
	"type=registry,ref=reg.example/p:aaaaaaaaaa-bbbbbbbbbb-ccccc-50be3cfe432d9405-${CACHE_SCOPE:-unscoped}-c-4d190ee7b998dce2",
	"type=registry,ref=reg.example/p:aaaaaaaaaa-bbbbbbbbbb-ccccc-50be3cfe432d9405-${CACHE_SCOPE_FALLBACK:-unscoped}-c-4d190ee7b998dce2",
]
_ct_bayt_from: _ct_dc.compose.files."some-project-unit-test".services."ct-some-project-unit-test_bayt".build."x-bake"."cache-from"
_ct_bayt_from: [
	"type=registry,ref=reg.example/p:aaaaaaaaaa-bbbbbbbbbb-ccccc-50be3cfe432d9405-${CACHE_SCOPE:-unscoped}-c-96b90bdc5d4ad0fa",
	"type=registry,ref=reg.example/p:aaaaaaaaaa-bbbbbbbbbb-ccccc-50be3cfe432d9405-${CACHE_SCOPE_FALLBACK:-unscoped}-c-96b90bdc5d4ad0fa",
]

// --- No sugar type. `from` / `to` are emitted as written and no name is
// bounded, because there is no scope to budget against. `_ct_bare` is the arm
// `_ct_pass` cannot reach: a non-empty `from` is taken before the type is ever
// consulted.
_ct_bare: #project & {
	name: "cb"
	dir:  "cb"
	bake: {}
	targets: "some-project-unit-test": {
		srcs: globs: ["src/**"]
		cmd: "builtin": do: "cargo build"
		dockerfile: busybox
	}
}
_ct_bare_from: _ct_bare.targets[_ct_n1].bake.cache.from
_ct_bare_from: []
_ct_bare_to: _ct_bare.targets[_ct_n1].bake.cache.to
_ct_bare_to: []
_ct_pass: #project & {
	name: "cp"
	dir:  "cp"
	bake: cache: {from: ["type=local,src=/tmp/c"], to: ["type=local,dest=/tmp/c"]}
	targets: "some-project-unit-test": {
		srcs: globs: ["src/**"]
		cmd: "builtin": do: "cargo build"
		dockerfile: busybox
	}
}
_ct_pass_from: _ct_pass.targets[_ct_n1].bake.cache.from
_ct_pass_from: ["type=local,src=/tmp/c"]
_ct_pass_to: _ct_pass.targets[_ct_n1].bake.cache.to
_ct_pass_to: ["type=local,dest=/tmp/c"]

// The key set, because a selector for a missing key is incomplete rather than
// wrong, and `cue eval` tolerates incomplete.
_ct_srcs_xbake: [for k, _ in _ct_dc.compose.files[_ct_n1].services."ct-some-project-unit-test_srcs".build."x-bake" {k}] & ["cache-from", "cache-to"]

// #bakeCacheRefs bound to a regular field. A hidden field is forced by how the
// caller binds the struct, so both emitters — which let-bind and select — leave
// an unconditionally bounded scope undetected, and passthrough breaks for the
// next caller who binds one to a field.
_ct_direct: (#bakeCacheRefs & {c: {from: ["type=local,src=/tmp/c"], to: []}, t: "some-project-unit-test"})
_ct_direct_from: _ct_direct.from & ["type=local,src=/tmp/c"]
_ct_direct_to:   _ct_direct.to & []
