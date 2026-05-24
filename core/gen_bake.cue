// bake_gen.cue — per-target docker-bake HCL emission.
//
// Since bayt emits skaffold.yaml as well, we can fully control the custom
// build command skaffold uses and point it explicitly at the per-target
// .bayt/bake.<n>.hcl file via `-f`. That lets us split bake output the
// same way we split Taskfile / compose / skaffold — one file per target,
// independent cache invalidation.
//
//   docker buildx bake -f .bayt/bake.release.hcl release
//
// Each per-target file is self-contained: its own variable defaults and
// the single `target "<n>" { ... }` block. Users invoking bake locally
// pass -f explicitly; the hand-maintained docker-bake.override.hcl (if
// present) still auto-merges because bake discovers it by filename.
//
// Emits the skaffold custom-command contract:
//
//   variable "IMAGE"       { default = "<image>" }
//   variable "PUSH_IMAGE"  { default = "false" }
//   variable "CACHE_SCOPE" { default = "" }
//
//   target "<n>" {
//     tags     = [IMAGE]
//     output   = PUSH_IMAGE == "true" ? ["type=registry"] : ["type=docker"]
//     platforms = [...]
//     cache-from = CACHE_SCOPE != "" ? [...] : []
//     cache-to   = CACHE_SCOPE != "" ? [...] : []
//   }
package bayt

import (
	"list"
	"strings"
)

#bakeGen: G={
	project: #project
	depManifests:   {[string]: _}

	_m: (#manifestGen & {project: G.project, depManifests: G.depManifests})

	// Emit bake.<n>.hcl only for targets that declare a real release-
	// style bake (image set). Plain `bake: {}` on the release preset
	// still has `image: string` required by the consumer's override
	// (see iris release targets), so this naturally selects release
	// targets while skipping compose-x-bake-only configs where the
	// project fills `bake.cache.{from,to}` for layer-cache wiring but
	// no HCL artifact is wanted.
	_emit: {for n, t in G._m.files if t.bake != _|_ if t.bake.image != _|_ {(n): t}}

	// Helper: render one full HCL file body for a target (variables +
	// target block).
	_fileBody: {
		n: string
		t: _

		let _hasImage = t.bake.image != _|_

		// Variable blocks — IMAGE / PUSH_IMAGE.
		_varLines: [
			if _hasImage {"variable \"IMAGE\" {"},
			if _hasImage {"  default = \"\(t.bake.image)\""},
			if _hasImage {"}"},
			"variable \"PUSH_IMAGE\" {",
			"  default = \"\(t.bake.push)\"",
			"}",
		]

		let _tagList = [
			if _hasImage {"[IMAGE]"},
			if !_hasImage {"[" + strings.Join([for tag in t.bake.tags {"\"\(tag)\""}], ", ") + "]"},
		][0]

		let _platforms = [for p in t.bake.platforms {"\"\(p)\""}]
		let _argPairs =  [for k, v in t.bake.args {"    \"\(k)\" = \"\(v)\""}]

		let _cacheFrom = [for c in t.bake.cache.from {"\"\(c)\""}]
		let _cacheTo =   [for c in t.bake.cache.to {"\"\(c)\""}]

		// args = { ... } block. Hoisted because `for` inside a list-
		// literal `if` doesn't splat — multiple pairs would collide at
		// the same list position. list.Concat does the right thing.
		_argLines: [
			if len(_argPairs) > 0 {"  args = {"},
			for p in _argPairs {p},
			if len(_argPairs) > 0 {"  }"},
		]

		// Target block.
		_targetLines: list.Concat([[
			"target \"\(n)\" {",
			"  context    = \".\"",
			"  dockerfile = \".bayt/Dockerfile.\(n)\"",
			"  target     = \"\(n)\"",
			if len(_platforms) > 0 {"  platforms  = [\(strings.Join(_platforms, ", "))]"},
			"  tags       = \(_tagList)",
			"  output     = PUSH_IMAGE == \"true\" ? [\"type=registry\"] : [\"type=docker\"]",
			if len(_cacheFrom) > 0 {"  cache-from = [\(strings.Join(_cacheFrom, ", "))]"},
			if len(_cacheTo) > 0 {"  cache-to   = [\(strings.Join(_cacheTo, ", "))]"},
		], _argLines, [
			"}",
		]])

		_lines: [
			for l in _varLines {l},
			"",
			for l in _targetLines {l},
		]
		out: string
		out: strings.Join(_lines, "\n") + "\n"
	}

	// Per-target HCL bodies. Key is target name; written to
	// <project.dir>/.bayt/bake.<n>.hcl by generate-bayt.nu.
	files: {
		for n, t in _emit {
			(n): (_fileBody & {"n": n, "t": t}).out
		}
	}

	// Helper: the `docker buildx bake -f .bayt/bake.<n>.hcl <n>`
	// command skaffold should run as its build.custom.buildCommand for
	// a given target. Emitted into the manifest; projects point their
	// skaffold.build.custom at bake.commands.<n> for wiring.
	commands: {
		for n, _ in _emit {
			(n): "docker buildx bake -f .bayt/bake.\(n).hcl \(n)"
		}
	}
}
