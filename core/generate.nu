# generate.nu — walk the #render bundle and write every output file.
#
# Pure/impure split: CUE computes the full render (#manifestGen +
# #taskfileGen + #dockerComposeGen + #skaffoldGen + #vscodeGen + #bakeGen),
# this script reads the JSON output and writes files to disk.
#
# Usage (from a project directory containing bayt.cue):
#
#   bayt generate              # single project
#   bayt generate --recursive  # project + all cross-project deps
#   bayt generate --all        # every project in the workspace, topo order
#
# Or, referenced from sayt's auto-generation rulemap:
#
#   use ./generate.nu
#   generate [--recursive]
#
# bayt.cue MUST expose:
#   - project: <#project>         (first-pass dep extraction)
#   - depManifestsIn: {[string]: _} (second-pass injection point)
#   - _render: (bayt.#render & {project: ..., depManifests: depManifestsIn})
#
# Two-pass evaluation:
#   Pass 1: cue export ./bayt.cue -e project.targets --out json
#           Fast — no generators run. Extracts cross-project dep strings.
#   Pass 2: echo '{"depManifestsIn":{...}}' | cue export - ./bayt.cue -e _render --out json
#           Full render with resolved dep manifests injected via stdin.
#
# --recursive and --all walk up to the workspace root (cue.mod/ marker),
# topo-order the dep graph, and regenerate leaf-first — parallel within
# dependency levels (see run-schedule).
#
# Files emitted, relative to the project's dir. ALL bayt-generated
# files live under `.bayt/` with the `<tool>.<target>.<ext>` convention.
# Tool roots (Taskfile.yml, compose.yaml, skaffold.yaml) are
# user-authored composition points — bayt never writes them; each
# hand-written root includes the .bayt/ fragments it wants.
#
#   .bayt/bayt.<n>.json                 per-target canonical manifest
#   .bayt/Taskfile.yml                  launch root for bayt-initiated `task -t`
#   .bayt/Taskfile.bayt.yml             bayt namespace (target + dep includes)
#   .bayt/Taskfile.<n>.yaml             per-target go-task include
#   .bayt/Dockerfile.<n>                per-target Dockerfile
#   .bayt/compose.yaml                  compose aggregate include
#   .bayt/compose.<n>.yaml              per-target compose include
#   .bayt/skaffold.<n>.yaml             per-target skaffold include
#   .bayt/bake.<n>.hcl                  per-target bake HCL
#   .bayt/vscode.<n>.json               per-target vscode task entries
#                                       (user concatenates into
#                                       .vscode/tasks.json; sayt lint
#                                       warns on drift — vscode's
#                                       tasks.json has no native include
#                                       so we don't touch it directly)
#
# Existing files are overwritten atomically (tmp + rename). The entire
# .bayt/ directory is rebuilt on every run so removed targets don't
# leave stale per-target files behind.

use ../runtime/tools.nu [run-cue, run-nu]

# Data file holding the render.cue core-package import, so copybara can
# rewrite the mirror identity on the .nuon (not in this source). See it.
const render_import_file = (path self | path dirname | path join "render_import.nuon")

# BAYT_TIMING=1 prints generate phase timings to stderr.
def print-timing [label: string, start: datetime] {
	if ($env.BAYT_TIMING? | default "") != "" {
		print -e $"BAYT_TIMING generate ($label): ((date now) - $start)"
	}
}

# scan-projects runs ONE parallel `cue export` per bayt.cue and returns
# [{path, name, dir_rel, targets}] — the single CUE read behind the
# project index (name → dir), the topo schedule, and regen's pass 1.
# One read, not one per consumer: `cue export` costs ~40 ms here but the
# pass-2 render costs seconds, so keep work out of pass 2, not out of here.
def scan-projects [workspace_root: string] {
	# Enumerate bayt.cue files via `git ls-files`. Drop bayt's own
	# package + stacks files: they share the bayt.cue name but
	# define schemas, not projects. Anchor repo-relative paths to
	# workspace_root so the downstream `cue export` works from any cwd.
	let rel_paths = (do { cd $workspace_root; ^git ls-files --cached --others --exclude-standard }
		| lines
		| where ($it | str ends-with "/bayt.cue") or $it == "bayt.cue"
		| where not ($it | str starts-with "plugins/bayt/core/")
		| where not ($it | str starts-with "plugins/bayt/stacks/")
		| each { |p| $"($workspace_root)/($p)" }
	)
	$rel_paths | par-each { |path|
		# A sibling bayt.json is the project value itself (pronto's build
		# seat exports it; the bayt.cue stub only embeds it) — read it
		# directly. File-mode `cue export` has no module context, so the
		# stub's @embed cannot resolve there.
		let json_path = ($path | path dirname | path join "bayt.json")
		let p = if ($json_path | path exists) {
			open $json_path
		} else {
			let r = (do { run-cue export $path -e '{name: project.name, dir: project.dir, targets: project.targets}' --out json } | complete)
			if $r.exit_code != 0 {
				# A bayt.cue with no `project` defines schemas (a stack or a
				# consumer's roster), not a project — skip it.
				if ($r.stderr | str contains 'reference "project" not found') {
					null
				} else {
					error make {msg: $"bayt: project scan failed for ($path)\n($r.stderr)"}
				}
			} else {
				$r.stdout | from json
			}
		}
		if $p == null { null } else {
			let dir_rel = if ($p.dir | str trim) == "" { "." } else { $p.dir }
			{path: $path, name: $p.name, dir_rel: $dir_rel, targets: $p.targets}
		}
	} | compact
}

# dep-to-dir resolves a Bazel-style cross-project ref ("project:target")
# to a workspace-root-relative dir via the project index. Caller must
# have already filtered out same-project refs (leading `:`).
def dep-to-dir [dep: string, index: record] {
	let project = ($dep | split row ":" | first)
	let dir = ($index | get --optional $project)
	if $dir == null {
		error make {msg: $"bayt: cross-project ref ($dep) refers to unknown project '($project)' — known projects: (($index | columns | str join ', '))"}
	}
	$dir
}

# atomic-write writes `content` to `target` via a sibling tempfile then
# rename. mkdir-s the parent if needed. Accepts string content.
def atomic-write [target: string, content: string] {
	let parent = ($target | path dirname)
	mkdir $parent
	let tmp = $"($target).tmp"
	$content | save -f $tmp
	mv -f $tmp $target
}

# Rewrite the `bayt` build context from the published image to a
# compose-YAML-relative path when BAYT_RUNTIME_DIR is set (monorepo-dev
# mode).
#
# Operates on the record, not on the emitted text: the emitter folds a long
# scalar onto a `>-` continuation line, so a pattern expecting
# `bayt: docker-image://…` on one line matches nothing.
#
# Path points at `runtime/`, not the bayt project root — inner-bake
# FS only has /monorepo/plugins/bayt/runtime, so any broader context
# would hash differently outer-vs-inner and break the depot cache.
export def _inject-runtime [data: any, base: string]: nothing -> any {
	let runtime_dir = ($env.BAYT_RUNTIME_DIR? | default "")
	if ($runtime_dir | is-empty) { return $data }
	# base arrives with OS separators when generation runs on Windows —
	# normalize before splitting or the depth (and every ../ prefix)
	# comes out short.
	let depth = if ($base == "." or $base == "") { 0 } else { ($base | str replace --all '\' '/' | split row "/" | length) }
	let prefix = (0..$depth | each {|_| "../" } | str join "")
	let rel_path = $"($prefix)($runtime_dir)/runtime"
	if ($data | get -o services) == null { return $data }
	$data | update services {|d|
		$d.services | items {|name, svc|
			let ctx = ($svc | get -o build.additional_contexts.bayt)
			if $ctx != null and ($ctx | str starts-with "docker-image://") {
				{$name: ($svc | update build.additional_contexts.bayt $rel_path)}
			} else {
				{$name: $svc}
			}
		} | reduce --fold {} {|it, acc| $acc | merge $it}
	}
}

# Manifest twin of `_inject-runtime`: under --runtime the context a target
# COPYs --from is a directory in this tree, not the published image, so the
# manifest records the directory.
#
# Repo-root-relative, unlike the compose rewrite's `../`-prefixed form —
# fingerprint resolves manifest paths from the repo root.
def _inject-runtime-manifest [data: any]: nothing -> any {
	let runtime_dir = ($env.BAYT_RUNTIME_DIR? | default "")
	if ($runtime_dir | is-empty) { return $data }
	let ctxs = ($data | get -o dockerfile.preambleCopyContexts)
	if $ctxs == null { return $data }
	$data | update dockerfile.preambleCopyContexts { |it|
		$it.dockerfile.preambleCopyContexts | each { |c|
			if ($c | get -o image) != null and $c.name == "bayt" {
				$c | update image $"($runtime_dir)/runtime"
			} else { $c }
		}
	}
}


# Generated-from header, line 1 of every hash-comment file. JSON gets
# a field instead (no comment syntax).
def _hash-header       [c: string]: nothing -> string { "# generated from bayt.cue — do not edit\n"  + $c }
def _slash-header      [c: string]: nothing -> string { "// generated from bayt.cue — do not edit\n" + $c }
def _json-header  [d: any]: nothing -> any { {_generated_from: "bayt.cue (do not edit)"} | merge $d }

# write-bundle writes all output files for a pre-loaded render bundle.
# base — workspace-root-relative project dir (e.g. "path/to/project" or ".")
def write-bundle [bundle: record, base: string, --depot] {
	let ws = (pwd | str trim)
	let prefix = if $base == "." or $base == "" { "" } else { $"($base)/" }

	# Vendored-package handshake: consumers import the bayt CUE package
	# from their own repo (cue.mod), so a stale vendor evaluates old
	# templates under a new CLI and actively re-emits old shapes. The
	# launch-shim include is the marker; refuse to write stale output.
	let shim = ($bundle.taskfile | get -o root | get -o includes | get -o bayt | get -o taskfile | default "")
	if $shim != "./Taskfile.bayt.yml" {
		error make {msg: $"bayt: the imported bayt CUE package predates this CLI \(launch shim include resolves to '($shim)'\) — refresh the vendored plugins/bayt tree to match the installed bayt version"}
	}

	let bayt_dir = $"($prefix).bayt"
	if ($bayt_dir | path exists) {
		rm -rf $bayt_dir
	}
	mkdir $bayt_dir
	write-render-driver $"($prefix)bayt.cue"

	# --- canonical per-target manifests. Synthetics nest under
	# `.synthetics.{srcs,outs}`; uniq the nested srcs transitiveDeps (outs has none).
	for entry in ($bundle.manifest.files | transpose name data) {
		mut data = ($entry.data | update transitiveDeps {|it| $it.transitiveDeps | uniq})
		if (($data | get --optional synthetics | get --optional srcs) != null) {
			$data = ($data | update synthetics.srcs.transitiveDeps {|it| $it.synthetics.srcs.transitiveDeps | uniq})
		}
		atomic-write $"($prefix).bayt/bayt.($entry.name).json" (_json-header (_inject-runtime-manifest $data) | to json --indent 2)
	}

	# --- Taskfile (the project-root Taskfile.yml is user-authored)
	atomic-write $"($prefix).bayt/Taskfile.yml" (_hash-header ($bundle.taskfile.root | to yaml))
	atomic-write $"($prefix).bayt/Taskfile.bayt.yml" (_hash-header ($bundle.taskfile.bayt_root | to yaml))
	# Migration guard: a pre-0.28 generated project root includes the
	# aggregate at .bayt/Taskfile.yml — now the launch shim — silently
	# chaining host addresses to bayt:bayt:<n>. Warn loudly; the root is
	# user-authored, so bayt never rewrites it.
	let user_root = $"($prefix)Taskfile.yml"
	if ($user_root | path exists) and (open --raw $user_root | str contains "./.bayt/Taskfile.yml") {
		print -e $"bayt: ($user_root) includes ./.bayt/Taskfile.yml \(the launch shim, not the task aggregate) — point its bayt: include at ./.bayt/Taskfile.bayt.yml"
	}
	for entry in ($bundle.taskfile.files | transpose name data) {
		atomic-write $"($prefix).bayt/Taskfile.($entry.name).yaml" (_hash-header ($entry.data | to yaml))
	}

	# --- Dockerfile
	for entry in ($bundle.docker.dockerfiles | transpose name body) {
		atomic-write $"($prefix).bayt/Dockerfile.($entry.name)" (_hash-header $entry.body)
	}

	# --- compose
	atomic-write $"($prefix).bayt/compose.yaml" (_hash-header (_inject-runtime $bundle.docker.compose.root $base | to yaml))
	atomic-write $"($prefix).bayt/compose.bayt.yaml" (_hash-header (_inject-runtime $bundle.docker.compose.bayt_root $base | to yaml))
	for entry in ($bundle.docker.compose.files | transpose name data) {
		atomic-write $"($prefix).bayt/compose.($entry.name).yaml" (_hash-header (_inject-runtime $entry.data $base | to yaml))
	}

	# --- skaffold
	# No project-root .bayt/skaffold.yaml is emitted. Cross-project graph
	# composition is user-owned: hand-write <project>/skaffold.yaml and
	# `requires:` whichever .bayt/skaffold.<n>.yaml fragments matter.
	for entry in ($bundle.skaffold.files | transpose name data) {
		atomic-write $"($prefix).bayt/skaffold.($entry.name).yaml" (_hash-header ($entry.data | to yaml))
	}

	# --- vscode tasks (per-target, build/test only)
	# vscode's tasks.json has no native include mechanism; rather than
	# overwriting the user's hand-maintained .vscode/tasks.json, we
	# emit each task entry as its own .bayt/vscode.<target>.json. The
	# user merges them into .vscode/tasks.json (sayt lint warns on
	# drift). Only build and test are emitted — other targets (setup,
	# integrate, release, ...) don't fit vscode's build/test workflow.
	for entry in ($bundle.vscode.files | transpose name data) {
		atomic-write $"($prefix).bayt/vscode.($entry.name).json" (_json-header $entry.data | to json --indent 2)
	}

	# --- bake HCL
	# One bake HCL per project; its matrix names every federated target so
	# a bake positional selects which one builds. Emitted only when a
	# release target wants it.
	if ($bundle.bake.hcl? | is-not-empty) {
		atomic-write $"($prefix).bayt/bake.hcl" (_hash-header $bundle.bake.hcl)
	}

	# --- gradle init script (gradle-stack projects only)
	# Points gradle's local build cache at $BAYT_CACHE_DIR/gradle so
	# cache.nu's mount and gradle's cache share the same on-disk
	# store. Requires `org.gradle.caching=true` in the project's
	# gradle.properties for gradle to consult the cache.
	if ($bundle.manifest.projectManifest.gradleInit? | default false) {
	atomic-write $"($prefix).bayt/init.gradle.kts" (_slash-header 'settingsEvaluated {
    // Resolution mirrors cache.nu local-root:
    //   1. $BAYT_CACHE_DIR (explicit override)
    //   2. $XDG_CACHE_HOME/bayt (XDG Base Directory spec, *nix idiomatic)
    //   3. $LOCALAPPDATA/bayt (Windows-idiomatic, undefined on *nix)
    //   4. ~/.cache/bayt (XDG fallback — also lands at /root/.cache/bayt
    //      inside the BuildKit cache mount because user.home is /root)
    val cacheDir = System.getenv("BAYT_CACHE_DIR")
        ?: System.getenv("XDG_CACHE_HOME")?.let { "$it/bayt" }
        ?: System.getenv("LOCALAPPDATA")?.let { "$it/bayt" }
        ?: "${System.getProperty("user.home")}/.cache/bayt"
    buildCache {
        local {
            directory = file("$cacheDir/gradle")
        }
    }
}
')
	}

	# --- depot.{yaml,hcl,json}: after the compose files depot.yaml flattens.
	let depot_opted = ($bundle.manifest.projectManifest.depot? | default false)
	if $depot or $depot_opted {
		emit-depot-yaml $base $ws --required=$depot_opted --group=($bundle.bake.depotGroup? | default {})
		if ($bundle.bake.depotHcl? | is-not-empty) {
			atomic-write $"($prefix).bayt/depot.hcl" (_slash-header $bundle.bake.depotHcl)
		}
	}

	print $"bayt: wrote files for project ($bundle.manifest.projectManifest.name)"
}

# emit-depot-yaml writes <proj>/.bayt/depot.yaml: the integration graph
# flattened by `docker compose config --no-interpolate`, so ${VARS} stay literal
# for bake to resolve in CI (DESIGN.md on why compose, not bake). compose
# absolutizes contexts and emits `service:` refs, so rewrite to
# repo-root-relative and `service:X` -> `target:X` — depot bake stats a
# `service:` context as a path. Needs docker; hence the opt-in.
def emit-depot-yaml [proj_dir: string, ws: string, --required, --group: record = {}] {
	let dir = if $proj_dir == "." or $proj_dir == "" { $ws } else { $"($ws)/($proj_dir)" }
	# Explicit -f: default project-file resolution auto-loads
	# docker-compose.override.yml (and honors $COMPOSE_FILE) — local-only
	# dev config that must not flatten into a committed artifact. The
	# anchored regex admits exactly compose's base-name family and
	# nothing else; zero or several bases is a misconfigured project
	# (compose warns-and-picks on ambiguity — emission refuses).
	let bases = (ls $dir | get name | each { |p| $p | path basename } | where { |f| $f =~ '^(docker-)?compose\.ya?ml$' })
	let base = (match ($bases | length) {
		1 => ($bases | first)
		0 => { error make {msg: $"bayt: no compose base file in ($dir) — the depot flatten requires one"} }
		_ => { error make {msg: $"bayt: ambiguous compose base files in ($dir): ($bases | str join ', ')"} }
	})
	let r = (do { cd $dir; ^docker compose -f $base --profile '*' config --no-interpolate } | complete)
	if $r.exit_code != 0 {
		let detail = ($r.stderr | lines | last 3 | str join "\n")
		# A depot opt-in declares docker a generate dependency; skipping
		# would leave the committed depot.yaml silently stale.
		if $required {
			error make {msg: $"bayt: depot flatten failed for ($proj_dir) — `docker compose config` exited ($r.exit_code)\n($detail)"}
		}
		print -e $"bayt: depot.yaml skipped for ($proj_dir) — `docker compose config` exited ($r.exit_code) \(deps not generated? run with --recursive\)"
		print -e $detail
		return
	}
	let flat = ($r.stdout
		| str replace --all $"($ws)/" ""
		| str replace --all $ws "."
		| str replace --all "service:" "target:")
	atomic-write $"($dir)/.bayt/depot.yaml" (_hash-header (_dedup-x-bake $flat))
	if not ($group | is-empty) {
		atomic-write $"($dir)/.bayt/depot.json" (depot-plan $flat $group | to json --indent 2)
	}
}

# repo-of — a compose `image:` minus its tag. A tag cannot contain '/', so only
# a ':' after the last '/' separates one, and neither counts inside a `${...}`.
export def repo-of [ref: string]: nothing -> string {
	mut depth = 0
	mut cut = -1
	mut i = 0
	for c in ($ref | split chars) {
		if $c == "{" { $depth = $depth + 1 }
		if $c == "}" { $depth = $depth - 1 }
		if $depth == 0 and $c == "/" { $cut = -1 }
		if $depth == 0 and $c == ":" and $cut == -1 { $cut = $i }
		$i = $i + 1
	}
	if $cut < 0 { $ref } else { $ref | str substring ..<$cut }
}

# depot-plan — .bayt/depot.json: the bake group as data, one row per leaf
# carrying where the build phase pushes it and which manifest fingerprints
# it. Lets a caller decide per leaf instead of baking the group whole.
#
# Both facts are read off the flattened compose, never derived from a leaf's
# name: a group member may be an overlay service whose `extends` names a
# different target, and that indirection lives in hand-authored YAML the CUE
# model never sees — only the flatten resolves it. Paths are repo-root-
# relative and `${VAR:-default}` stays literal, as in depot.yaml.
def depot-plan [flat: string, group: record]: nothing -> record {
	let svcs = ($flat | from yaml | get services)
	_json-header {
		group: $group.name
		targets: ($group.targets | each { |t|
			let s = ($svcs | get -o $t)
			# A member the flatten cannot describe is an error, not an
			# omission: the caller bakes the misses it is handed, so a
			# dropped leaf is one that never builds and never publishes.
			if $s == null {
				error make {msg: $"bayt: depot group member ($t) is not a service in the flattened compose"}
			}
			if ($s | get -o build) == null or ($s | get -o image) == null {
				error make {msg: $"bayt: depot group member ($t) has no build or image block"}
			}
			{
				target:   $t
				repo:     (repo-of $s.image)
				manifest: $"($s.build.context)/.bayt/bayt.($s.build.target).json"
			}
		})
	}
}

# compose >= v5 re-concatenates x-* extension lists once per include
# path on diamond re-inclusion (compose-spec/compose-go#906; version
# pin: plugins/sayt/compose.toml) — and the flattening binary floats
# with the host, so emission dedups regardless. Line-wise surgery
# scoped to x-bake blocks, not a YAML round-trip: nu's emitter leaves
# 1.1-ambiguous scalars unquoted (`restart: "no"` re-parses as false).
# Only pure-scalar items dedup — dropping a duplicate mapping-item head
# would re-attach its continuation lines to the previous item — and
# only inside x-bake: elsewhere duplicate list items are meaningful
# (repeated command args).
export def _dedup-x-bake [flat: string]: nothing -> string {
	mut out = []
	mut xb_indent = -1        # indent of the open `x-bake:` line; -1 = outside
	mut seen: list<string> = []
	for line in ($flat | lines) {
		let stripped = ($line | str trim -l)
		let indent = (($line | str length) - ($stripped | str length))
		if $xb_indent >= 0 and ($stripped | is-not-empty) and $indent <= $xb_indent {
			$xb_indent = -1
		}
		if $xb_indent < 0 {
			if $stripped == "x-bake:" { $xb_indent = $indent; $seen = [] }
			$out = ($out ++ [$line])
			continue
		}
		if ($stripped | is-empty) {
			$out = ($out ++ [$line])
			continue
		}
		if ($stripped | str starts-with "- ") and not ($stripped | str contains ": ") {
			if $line in $seen { continue }
			$seen = ($seen ++ [$line])
		} else {
			# a new field key inside the block scopes its own list
			$seen = []
		}
		$out = ($out ++ [$line])
	}
	$out | str join "\n" | $in + "\n"
}

# pass1 extracts the project.targets map from a bayt.cue.
# bayt_cue — path to bayt.cue (relative or absolute).
def pass1 [bayt_cue: string] {
	let r = (do { run-cue export $bayt_cue -e project.targets --out json } | complete)
	if $r.exit_code != 0 {
		print -e $"bayt: pass-1 failed for ($bayt_cue)"
		print -e $r.stderr
		exit 1
	}
	$r.stdout | from json
}

# pass2 runs the full render with depManifests injected via stdin.
# bayt_cue      — path to bayt.cue.
# dep_manifests — record keyed by dep string, value = target manifest JSON.
#
# The render entry lives in a generated driver (.bayt/render.cue), not
# in the user's bayt.cue: `-e` expressions can't reach import aliases,
# cue tags don't propagate into imported packages (cue-lang/cue#1530),
# and injected params must be declared SOMEWHERE — the driver is that
# somewhere, keeping user files free of render plumbing.
def write-render-driver [bayt_cue: string] {
	let pkg = (open --raw $bayt_cue | lines | where ($it | str starts-with "package ") | first | str replace "package " "")
	let driver = ($bayt_cue | path dirname | path join ".bayt" "render.cue")
	let core_import = (open $render_import_file)
	atomic-write $driver $"// generated from bayt.cue — do not edit\npackage ($pkg)\n\nimport bayt_ \"($core_import)\"\n\n// Declared so a bayt.json project can inject the value via stdin —\n// file-mode identifier references only resolve against declarations.\nproject: _\ndepManifestsIn: {[string]: _}\nruntimeIn: *\"\" | string\n_render: \(bayt_.#render & {\"project\": project, depManifests: depManifestsIn, runtime: runtimeIn}\)\n"
}

def pass2 [bayt_cue: string, dep_manifests: record] {
	write-render-driver $bayt_cue
	let driver = ($bayt_cue | path dirname | path join ".bayt" "render.cue")
	# As in scan-projects: a sibling bayt.json is the project value, and
	# file-mode `cue export` cannot resolve the stub's @embed — inject the
	# value as `project` and render from the driver alone.
	let json_path = ($bayt_cue | path dirname | path join "bayt.json")
	let base = {depManifestsIn: $dep_manifests, runtimeIn: ($env.BAYT_RUNTIME_DIR? | default "")}
	let r = if ($json_path | path exists) {
		let inject = ($base | insert project (open $json_path) | to json --raw)
		(do { $inject | run-cue export - $driver -e _render --out json } | complete)
	} else {
		let inject = ($base | to json --raw)
		(do { $inject | run-cue export - $bayt_cue $driver -e _render --out json } | complete)
	}
	if $r.exit_code != 0 {
		print -e $"bayt: pass-2 failed for ($bayt_cue)"
		print -e $r.stderr
		exit 1
	}
	$r.stdout | from json
}

# cross-dep-strings — unique cross-project refs from a targets record: deps,
# dockerfile.from.ref, and dockerfile.copy[].from.ref (+ defaultCopy). Feeds
# manifest loading and cycle detection; same-project (":"-prefixed) refs drop.
def cross-dep-strings [targets: record] {
	$targets | values | each {|t|
		let copies = (($t.dockerfile?.copy? | default [])
			| append ($t.dockerfile?.defaultCopy? | default {} | values | where {|c| $c != null}))
		[
			...($t.deps? | default [])
			($t.dockerfile?.from?.ref? | default "")
			...($copies | each {|c| $c.from?.ref? | default "" })
		]
	} | flatten | where {|r| ($r | is-not-empty) and not ($r | str starts-with ":")} | uniq
}

# load-dep-manifests loads .bayt/bayt.<target>.json for each cross-project
# dep. deps  — list of refs like ["libraries_logs:build"]
#       index — project-name → workspace-root-relative-dir map
#       workspace_root — absolute workspace root path
#       optional — list of refs that silently skip when their manifest
#                  file is absent (used for auto-derived `:srcs` variants
#                  that may not exist if the upstream target has no srcs)
#
# Resolve a dep ref to its manifest. The file is the SECOND ref segment; a
# third segment (srcs/outs) indexes into `.synthetics.<view>`:
#   "proj:foo"        → bayt.foo.json                (whole entry)
#   "proj:foo:srcs"   → bayt.foo.json .synthetics.srcs
#   "proj:foo:outs"   → bayt.foo.json .synthetics.outs
#   "proj:bayt"       → bayt.bayt.json
#
# Result is keyed by the ref string. A missing synthetic view (target has no
# srcs) is treated like a missing file: skipped if `optional`, else a hard error.
def load-dep-manifests [deps: list<string>, index: record, workspace_root: string, optional: list<string> = []] {
	mut result = {}
	for dep in $deps {
		let parts = ($dep | split row ":")
		let file_target = ($parts | get 1)
		let view = if ($parts | length) >= 3 { ($parts | get 2) } else { null }
		let dep_dir_rel = (dep-to-dir $dep $index)
		let manifest_path = if $dep_dir_rel == "." {
			$"($workspace_root)/.bayt/bayt.($file_target).json"
		} else {
			$"($workspace_root)/($dep_dir_rel)/.bayt/bayt.($file_target).json"
		}
		if not ($manifest_path | path exists) {
			if ($dep in $optional) { continue }
			error make {msg: $"bayt: dep manifest not found: ($manifest_path)\n  run `bayt generate` for ($dep_dir_rel) first, or use --recursive"}
		}
		let full = (open $manifest_path)
		let value = if $view == null {
			$full
		} else {
			let synth = ($full | get --optional synthetics)
			if $synth == null { null } else { $synth | get --optional $view }
		}
		if $value == null {
			if ($dep in $optional) { continue }
			error make {msg: $"bayt: synthetic view '($view)' not found in ($manifest_path) for ref ($dep)\n  the upstream target may not emit a '($view)' synthetic"}
		}
		$result = ($result | insert $dep $value)
	}
	$result
}

# srcs-variants takes a list of two-segment cross-project refs
# ("proj:target") and returns their `:srcs` synthetic variants
# ("proj:target:srcs"). Used by regen-project to auto-load synthetic
# manifests for every cross-project dep, so consumers can transitively
# walk `:srcs` closures without enumerating each one explicitly.
def srcs-variants [deps: list<string>] {
	$deps | where {|r| ($r | split row ":" | length) == 2 } | each {|r| $"($r):srcs" }
}

# find-workspace-root walks up from cwd to find the directory containing cue.mod/.
def find-workspace-root [] {
	mut dir = (pwd)
	loop {
		if ($"($dir)/cue.mod" | path exists) {
			return $dir
		}
		let parent = ($dir | path dirname)
		if $parent == $dir {
			error make {msg: "bayt: could not find workspace root (no cue.mod/ found)"}
		}
		$dir = $parent
	}
}

# topo-schedule returns {order, edges}: workspace-root-relative project
# dirs in leaf-first (topological) order via post-order DFS, plus each
# dir's direct cross-project dep dirs (`edges: [{dir, deps}]` — a table,
# not a record, because dirs like "." are not safe record keys).
# Post-order puts every dep before its consumers in `order`;
# run-schedule derives its parallel levels from `edges`.
# roots — workspace-root-relative starting dirs ("." for root)
# scan  — scan-projects rows (targets feed the dep walk)
# index — project_name → dir map (resolves "project:target" refs)
def topo-schedule [roots: list<string>, scan: table, index: record] {
	mut visiting: list<string> = []  # nodes on current DFS stack (cycle detection)
	mut done: list<string> = []      # post-order output (leaf-first)
	mut edges: list = []             # [{dir, deps}] — one row per visited node

	# dfs-visit is implemented via explicit stack to avoid Nushell recursion limits.
	# Each entry on the stack is either {dir: string, phase: "enter"} or
	# {dir: string, phase: "exit"}. Multiple roots share one `done` list,
	# so a project reached from several roots is scheduled exactly once.
	mut stack = ($roots | reverse | each { |r| {dir: $r, phase: "enter"} })

	while ($stack | length) > 0 {
		let top = ($stack | last)
		$stack = ($stack | take (($stack | length) - 1))

		if $top.phase == "exit" {
			# Post-order: add to done list when leaving a node.
			if not ($top.dir in $done) {
				$done = ($done | append $top.dir)
			}
			# Pop from visiting on exit.
			$visiting = ($visiting | where $it != $top.dir)
			continue
		}

		# phase == "enter"
		let current = $top.dir
		if $current in $done {
			continue
		}
		# Cycle: this node is already on the DFS stack — depending on it
		# again would close a loop. Surface a clear error pointing at the
		# offending dep chain.
		if $current in $visiting {
			let chain = (($visiting | str join " → ") + $" → ($current)")
			error make {msg: $"bayt: cross-project cycle detected: ($chain)"}
		}

		$visiting = ($visiting | append $current)
		# Push exit marker so we add this node to done after all deps.
		$stack = ($stack | append {dir: $current, phase: "exit"})

		# `first` errors on a dir absent from the scan — impossible via
		# index/dep resolution (both scan-derived); fail loud, not late.
		let row = ($scan | where dir_rel == $current | first)
		# Cross-project deps and cross-project `from` refs share one
		# vocabulary ("<project>:<target>") and one resolution path
		# (project_index → dir), so the cycle detector covers both.
		let cdeps = (cross-dep-strings $row.targets)
		let dep_dirs = ($cdeps | each { |dep| dep-to-dir $dep $index } | uniq)
		$edges = ($edges | append {dir: $current, deps: $dep_dirs})
		# Push deps in reverse order so the first dep is processed first.
		for d in ($dep_dirs | reverse) {
			if not ($d in $done) {
				$stack = ($stack | append {dir: $d, phase: "enter"})
			}
		}
	}

	{order: $done, edges: $edges}
}

# regen-project renders one project (pass 2, plus pass 1 when no
# pre-parsed targets came from the scan) and writes the bundle.
#
# Auto-loads `<proj>:<target>:srcs` synthetic manifests for every
# two-segment cross-project dep so transitive `:srcs` walking lands the
# upstream source closures without consumers enumerating them. Missing
# `:srcs` manifests (upstream target had no srcs) silently skip.
def regen-project [bayt_cue: string, dir_rel: string, index: record, workspace_root: string, targets?: any, --depot] {
	let targets = if $targets == null { pass1 $bayt_cue } else { $targets }
	let cdeps = (cross-dep-strings $targets)
	let auto_srcs = (srcs-variants $cdeps)
	let all_deps = ($cdeps | append $auto_srcs | uniq)
	let dep_manifests = (load-dep-manifests $all_deps $index $workspace_root $auto_srcs)
	let bundle = (pass2 $bayt_cue $dep_manifests)
	write-bundle $bundle $dir_rel --depot=$depot
}

# run-schedule regenerates every project in a topo-schedule, parallel
# WITHIN dependency levels (level = longest dep chain to a leaf, barrier
# between levels). Writes are per-project-dir and disjoint, but a
# consumer reads its deps' .bayt manifests — which write-bundle rm -rfs
# transiently — so only projects with no dep path between them may run
# concurrently.
def run-schedule [schedule: record, scan: table, index: record, workspace_root: string, --depot] {
	# [{dir, lvl}] — a table, not a record ("." is not a safe record key).
	mut lvl_by_dir = []
	for d in $schedule.order {
		let deps = ($schedule.edges | where dir == $d | first | get deps)
		let seen = $lvl_by_dir # closures can't capture mut vars
		let lvl = ($deps | each { |x| ($seen | where dir == $x | first | get lvl) + 1 } | append 0 | math max)
		$lvl_by_dir = ($lvl_by_dir | append {dir: $d, lvl: $lvl})
	}
	for l in 0..($lvl_by_dir | get lvl | math max) {
		let batch = ($lvl_by_dir | where lvl == $l | get dir)
		let t = (date now)
		$batch | par-each { |dir_rel|
			let row = ($scan | where dir_rel == $dir_rel | first)
			regen-project $row.path $dir_rel $index $workspace_root $row.targets --depot=$depot
		} | ignore
		print-timing $"level ($l) [($batch | str join ' ')]" $t
	}
}

# Entry point.
const cache_nu = (path self | path dirname | path dirname | path join "runtime" "cache.nu")

export def main [--recursive (-r), --all, --runtime: string = "", --depot] {
	let effective = if ($runtime | is-empty) { ($env.BAYT_RUNTIME_DIR? | default "") } else { $runtime }
	with-env { BAYT_RUNTIME_DIR: $effective } { _main --recursive=$recursive --all=$all --depot=$depot }
}

# A workspace-relative dir spelled the way the scan spells it: `git ls-files`
# and a bayt.json's `dir` both answer in forward slashes, where the `path
# relative-to` this is given answers in the platform's own. Without it a
# project on Windows never matches its own scanned row, and the pass-1
# fallback below cannot read a bayt.json-backed stub.
export def scan-dir [rel: string]: nothing -> string {
	let slashed = ($rel | str replace --all '\' '/')
	if ($slashed | str trim) == "" { "." } else { $slashed }
}

def _main [--recursive (-r), --all, --depot] {
	if not $all and not ("bayt.cue" | path exists) {
		return
	}

	let workspace_root = (find-workspace-root)
	let t0 = (date now)
	let scan = (scan-projects $workspace_root)
	let index = ($scan | reduce -f {} { |row, acc| $acc | insert $row.name $row.dir_rel })
	print-timing scan $t0

	if $all {
		# Every project in the workspace; works from any cwd inside it.
		cd $workspace_root
		let schedule = (topo-schedule ($scan | get dir_rel | uniq) $scan $index)
		run-schedule $schedule $scan $index $workspace_root --depot=$depot
	} else if $recursive {
		let project_rel = (scan-dir ((pwd) | path relative-to $workspace_root))

		# Work from workspace root so write-bundle's relative paths are correct.
		cd $workspace_root

		let schedule = (topo-schedule [$project_rel] $scan $index)
		run-schedule $schedule $scan $index $workspace_root --depot=$depot
	} else {
		# Single-project mode: cd to workspace_root so write-bundle's
		# relative paths (used by --runtime injection) are computed
		# against the right depth — same convention --recursive uses.
		let project_rel = (scan-dir ((pwd) | path relative-to $workspace_root))
		let bayt_cue = if $project_rel == "." { $"($workspace_root)/bayt.cue" } else { $"($workspace_root)/($project_rel)/bayt.cue" }
		cd $workspace_root
		# The row can be missing here (e.g. a gitignored dir escapes the
		# scan's `git ls-files`); regen-project's pass 1 covers it.
		let row = ($scan | where dir_rel == $project_rel | get --optional 0)
		let tgts = if $row == null { null } else { $row.targets }
		regen-project $bayt_cue $project_rel $index $workspace_root $tgts --depot=$depot
	}

	# Run cache GC at end of generation: regen happens after bayt.cue
	# edits, exactly when projects most likely have accumulated cache
	# cruft from the prior shape. NOT cheap — it `du`s every cache entry
	# to decide, seconds on a full cache, even when under budget. Opt-out
	# via BAYT_CACHE_NO_GC=true for CI / disk-pressured envs. Errors
	# propagate — silently swallowed GC means the cache fills until it
	# eats the disk.
	run-nu $cache_nu gc
}
