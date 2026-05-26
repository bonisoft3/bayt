// bake_gen.cue — per-target docker-bake HCL emission. Minimal:
// only carries what compose's `x-bake` can't express — the IMAGE /
// PUSH_IMAGE bake variables (skaffold overrides via `--set` / env),
// the tag binding `tags = [IMAGE]`, and the output ternary
// `PUSH_IMAGE == "true" ? registry : docker`.
//
// Everything else (context, dockerfile, target, platforms, args,
// cache-from, cache-to) lives in compose's `x-bake` and reaches bake
// via the multi-file merge in the generated skaffold:
//
//   docker compose config | docker buildx bake -f- -f .bayt/bake.<n>.hcl <n>
//
// So the HCL alone won't build — `bake -f .bayt/bake.<n>.hcl` errors
// on missing context. Always invoke through the generated skaffold
// (which the project's hand-edited skaffold.yaml `requires:`), or
// pair the HCL with compose's flattened output as above.
package bayt

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

	// HCL body — only what bake's compose-input can't express: the
	// IMAGE / PUSH_IMAGE variables and the output ternary on
	// PUSH_IMAGE. The rest (context, dockerfile, target, platforms,
	// args, cache) lives in compose's x-bake and merges in via
	// gen_skaffold.cue's `docker compose config | bake -f- -f .bayt/…`.
	_fileBody: {
		n: string
		t: _

		out: string
		out: """
			variable "IMAGE" {
			  default = "\(t.bake.image)"
			}
			variable "PUSH_IMAGE" {
			  default = "\(t.bake.push)"
			}

			target "\(n)" {
			  tags   = [IMAGE]
			  output = PUSH_IMAGE == "true" ? ["type=registry"] : ["type=docker"]
			}

			"""
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
