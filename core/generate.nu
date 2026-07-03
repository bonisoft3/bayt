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
# In --recursive mode the script walks up to find the workspace root
# (cue.mod/ marker), performs BFS over the dep graph leaf-first, then
# runs the target project last.
#
# Files emitted, relative to the project's dir. All bayt-generated
# files live under `.bayt/` with the `<tool>.<target>.<ext>` convention.
# Tool roots that the user authors (Taskfile.yml, compose.yaml,
# skaffold.yaml) get a single root file alongside.
#
#   .bayt/bayt.<n>.json                 per-target canonical manifest
#   Taskfile.yml                        root (version + includes)
#   .bayt/Taskfile.<n>.yaml             per-target go-task include
#   .bayt/Dockerfile.<n>                per-target Dockerfile
#   compose.yaml                        root (include: [...])
#   .bayt/compose.<n>.yaml              per-target compose include
#   skaffold.yaml                       root (requires: [...])
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

# build-project-index walks the workspace from workspace_root and returns a
# record mapping each project's name → its workspace-root-relative dir.
# Bazel-style cross-project refs ("<project>:<target>") resolve through
# this index. The scan only extracts project.name + project.dir.
def build-project-index [workspace_root: string] {
	mut idx = {}
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
	for path in $rel_paths {
		let r = (do { run-cue export $path -e '{name: project.name, dir: project.dir}' --out json } | complete)
		if $r.exit_code != 0 {
			print -e $"bayt: project-index scan failed for ($path)"
			print -e $r.stderr
			exit 1
		}
		let p = ($r.stdout | from json)
		let dir_rel = if ($p.dir | str trim) == "" { "." } else { $p.dir }
		$idx = ($idx | insert $p.name $dir_rel)
	}
	$idx
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

# write-bundle writes all output files for a pre-loaded render bundle.
# base — workspace-root-relative project dir (e.g. "services/tracker" or ".")
# Rewrite `bayt: docker-image://…` to a compose-YAML-relative path when
# BAYT_RUNTIME_DIR is set (monorepo-dev mode). Tag-based injection in
# gen_compose.cue would have been cleaner but cue tags don't propagate
# to imported packages (cue-lang/cue#1530), so the rewrite happens
# here at write time.
#
# Path points at `runtime/`, not the bayt project root — inner-bake
# FS only has /monorepo/plugins/bayt/runtime, so any broader context
# would hash differently outer-vs-inner and break the depot cache.
def _inject-runtime [content: string, base: string]: nothing -> string {
	let runtime_dir = ($env.BAYT_RUNTIME_DIR? | default "")
	if ($runtime_dir | is-empty) { return $content }
	let depth = if ($base == "." or $base == "") { 0 } else { ($base | split row "/" | length) }
	let prefix = (0..$depth | each {|_| "../" } | str join "")
	let rel_path = $"($prefix)($runtime_dir)/runtime"
	$content | str replace --regex --all 'bayt: docker-image://[^\n"]+' $"bayt: ($rel_path)"
}

# Pair with `_inject-runtime`: when the context is rewritten to point
# at `runtime/`, the COPY must take `.` (whole context) instead of the
# `runtime` subdir-selector. Non-monorepo (OCI image) consumers keep
# the selector — the published bayt image carries the full bayt tree.
def _inject-dockerfile-runtime [content: string]: nothing -> string {
	let runtime_dir = ($env.BAYT_RUNTIME_DIR? | default "")
	if ($runtime_dir | is-empty) { return $content }
	$content | str replace --regex --all '(COPY (?:--link )?--from=bayt) runtime ' '$1 . '
}

# Rewrite `bayt <subcommand>` invocations in Taskfile YAML to the
# depth-aware in-tree slim CLI when BAYT_RUNTIME_DIR is set (monorepo-
# dev mode). Default emission from gen_taskfile.cue is the bare `bayt`
# command, which non-monorepo consumers resolve via their host PATH
# (e.g. `mise install github:bonisoft3/bayt`). Monorepo developers
# pass `bayt generate --runtime plugins/bayt`, which flips this rewrite
# on so `task bayt:<n>` works from the monorepo without needing bayt
# installed globally.
#
# Paths are relative to PROJECT ROOT (the cwd inherited by every
# emitted task via `.bayt`'s `dir: ../` include): depth=0 prefixes `./`
# for argv unambiguity, depth>=1 emits `../` per level.
def _inject-taskfile-runtime [content: string, base: string]: nothing -> string {
	let runtime_dir = ($env.BAYT_RUNTIME_DIR? | default "")
	if ($runtime_dir | is-empty) { return $content }
	let depth = if ($base == "." or $base == "") { 0 } else { ($base | split row "/" | length) }
	let prefix = if $depth == 0 { "./" } else { (1..$depth | each {|_| "../" } | str join "") }
	let rel_path = $"($prefix)($runtime_dir)/runtime/bayt"
	$content | str replace --regex --all '\bbayt (cache|fingerprint|where)\b' $"($rel_path) $1"
}

# Generated-from header, line 1 of every hash-comment file. JSON gets
# a field instead (no comment syntax).
def _hash-header       [c: string]: nothing -> string { "# generated from bayt.cue — do not edit\n"  + $c }
def _slash-header      [c: string]: nothing -> string { "// generated from bayt.cue — do not edit\n" + $c }
def _json-header  [d: any]: nothing -> any { {_generated_from: "bayt.cue (do not edit)"} | merge $d }

def write-bundle [bundle: record, base: string, --depot] {
	let ws = (pwd | str trim)
	let prefix = if $base == "." or $base == "" { "" } else { $"($base)/" }

	let bayt_dir = $"($prefix).bayt"
	if ($bayt_dir | path exists) {
		rm -rf $bayt_dir
	}
	mkdir $bayt_dir

	# --- canonical per-target manifests. Synthetics nest under
	# `.synthetics.{srcs,outs}`; uniq the nested srcs transitiveDeps (outs has none).
	for entry in ($bundle.manifest.files | transpose name data) {
		mut data = ($entry.data | update transitiveDeps {|it| $it.transitiveDeps | uniq})
		if (($data | get --optional synthetics | get --optional srcs) != null) {
			$data = ($data | update synthetics.srcs.transitiveDeps {|it| $it.synthetics.srcs.transitiveDeps | uniq})
		}
		atomic-write $"($prefix).bayt/bayt.($entry.name).json" (_json-header $data | to json --indent 2)
	}

	# --- Taskfile
	atomic-write $"($prefix)Taskfile.yml" (_hash-header (_inject-taskfile-runtime ($bundle.taskfile.root | to yaml) $base))
	atomic-write $"($prefix).bayt/Taskfile.yml" (_hash-header (_inject-taskfile-runtime ($bundle.taskfile.bayt_root | to yaml) $base))
	for entry in ($bundle.taskfile.files | transpose name data) {
		atomic-write $"($prefix).bayt/Taskfile.($entry.name).yaml" (_hash-header (_inject-taskfile-runtime ($entry.data | to yaml) $base))
	}

	# --- Dockerfile
	for entry in ($bundle.docker.dockerfiles | transpose name body) {
		atomic-write $"($prefix).bayt/Dockerfile.($entry.name)" (_hash-header (_inject-dockerfile-runtime $entry.body))
	}

	# --- compose
	atomic-write $"($prefix).bayt/compose.yaml" (_hash-header (_inject-runtime ($bundle.docker.compose.root | to yaml) $base))
	atomic-write $"($prefix).bayt/compose.bayt.yaml" (_hash-header (_inject-runtime ($bundle.docker.compose.bayt_root | to yaml) $base))
	for entry in ($bundle.docker.compose.files | transpose name data) {
		atomic-write $"($prefix).bayt/compose.($entry.name).yaml" (_hash-header (_inject-runtime ($entry.data | to yaml) $base))
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
	for entry in ($bundle.bake.files | transpose name body) {
		atomic-write $"($prefix).bayt/bake.($entry.name).hcl" (_hash-header $entry.body)
	}

	# --- gradle init script
	# Points gradle's local build cache at $BAYT_CACHE_DIR/gradle so
	# cache.nu's mount and gradle's cache share the same on-disk
	# store. Emitted for every project — non-gradle projects' copy
	# never gets sourced. Requires `org.gradle.caching=true` in the
	# project's gradle.properties for gradle to consult the cache.
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

	# --- depot.{yaml,hcl}: emitted when the project opts in via
	# `#project.depot: true` (so its canonical regen keeps them fresh), or for
	# every project when the --depot flag forces it. Emitted after the compose
	# files they flatten.
	if $depot or ($bundle.manifest.projectManifest.depot? | default false) {
		emit-depot-yaml $base $ws
	}

	print $"bayt: wrote files for project ($bundle.manifest.projectManifest.name)"
}

# emit-depot-yaml writes two git-context-bakeable files for the depot build phase:
#   <proj>/.bayt/depot.yaml — the integration graph flattened by
#     `docker compose config --no-interpolate` (federation resolved, cross-project
#     services inlined) with late-bound ${VARS} (CACHE_SCOPE, BAYT_IMAGE_TAG,
#     BAYT_COMPOSE_OUTPUT) left literal for the bake caller to set. compose
#     absolutizes contexts and uses `service:` refs, so rewrite contexts to
#     repo-root-relative and `service:X` → `target:X` (depot bake stats a
#     `service:X` context as a path).
#   <proj>/.bayt/depot.hcl — the runtime closure (`integrate` + transitive
#     depends_on) as a bake `group`, so the build phase bakes it by name with no
#     local file read. bake builds `target:`-context deps implicitly but drops
#     their outputs, so every image the run phase pulls must be named in the
#     group; build-only intermediates stay implicit (built, cache-only). That's
#     what lets the build job go checkout-free:
#       depot bake <git-ref> -f <proj>/.bayt/depot.yaml -f <proj>/.bayt/depot.hcl \
#         --set "*.args.BUILDKIT_SYNTAX=…" depot-build
# `--no-interpolate` requires docker; the docker-CLI dep is why this is behind
# --depot.
def emit-depot-yaml [proj_dir: string, ws: string] {
	let dir = if $proj_dir == "." or $proj_dir == "" { $ws } else { $"($ws)/($proj_dir)" }
	let r = (do { cd $dir; ^docker compose config --no-interpolate } | complete)
	if $r.exit_code != 0 {
		print -e $"bayt: depot.yaml skipped for ($proj_dir) — `docker compose config` exited ($r.exit_code) \(deps not generated? run with --recursive\)"
		print -e ($r.stderr | lines | last 3 | str join "\n")
		return
	}
	let flat = ($r.stdout
		| str replace --all $"($ws)/" ""
		| str replace --all $ws "."
		| str replace --all "service:" "target:")
	atomic-write $"($dir)/.bayt/depot.yaml" (_hash-header $flat)

	# depot.hcl — the runtime-closure group (rationale in the header above).
	# Skipped for projects with no `integrate` service.
	let services = ($flat | from yaml | get --optional services | default {})
	if "integrate" in ($services | columns) {
		mut seen = ["integrate"]
		mut queue = ["integrate"]
		while ($queue | is-not-empty) {
			let deps = ($services | get --optional ($queue | first) | default {} | get --optional depends_on | default {} | columns)
			$queue = ($queue | skip 1)
			for d in $deps {
				if $d not-in $seen {
					$seen = ($seen | append $d)
					$queue = ($queue | append $d)
				}
			}
		}
		# A dep without a build section is pull-only — not a bake target, so
		# naming it in the group would fail resolution.
		let names = ($seen | where {|n| "build" in ($services | get $n | columns) } | sort)
		let group = ("group \"depot-build\" {\n  targets = [" + ($names | each {|n| $'"($n)"'} | str join ", ") + "]\n}\n")
		atomic-write $"($dir)/.bayt/depot.hcl" (_slash-header $group)
	}
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
def pass2 [bayt_cue: string, dep_manifests: record] {
	let inject = ({depManifestsIn: $dep_manifests} | to json --raw)
	let r = (do { $inject | run-cue export - $bayt_cue -e _render --out json } | complete)
	if $r.exit_code != 0 {
		print -e $"bayt: pass-2 failed for ($bayt_cue)"
		print -e $r.stderr
		exit 1
	}
	$r.stdout | from json
}

# cross-dep-strings returns the unique cross-project refs from a targets
# record — collected from both `t.deps` and `t.dockerfile.from.ref`.
# Bazel-style: same-project refs start with `:`, cross-project refs
# have a non-empty project prefix — we keep the latter. From-refs flow
# through the same federation pipeline as deps so a consumer chaining
# `dockerfile: from: ref: "X:Y"` doesn't also need to declare `deps: ["X:Y"]`.
def cross-dep-strings [targets: record] {
	let dep_refs = ($targets
		| values
		| each {|t| ($t.deps? | default []) | where {|d| not ($d | str starts-with ":")}}
		| flatten)
	let from_refs = ($targets
		| values
		| each {|t|
			let r = ($t.dockerfile?.from?.ref? | default "")
			if ($r | is-not-empty) and not ($r | str starts-with ":") { [$r] } else { [] }
		}
		| flatten)
	$dep_refs | append $from_refs | uniq
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

# topo-schedule returns a list of workspace-root-relative project dirs in
# leaf-first (topological) order via post-order DFS from root_rel.
# Post-order DFS guarantees that every dependency of a node appears
# before it in the output — correct order for leaf-first builds. Bazel-
# style refs ("project:target") resolve via project_index.
# workspace_root  — absolute workspace root path
# root_rel — workspace-root-relative dir of the starting project ("." for root)
# index    — project_name → workspace-root-relative-dir map
def topo-schedule [workspace_root: string, roots: list<string>, index: record] {
	mut visiting: list<string> = []  # nodes on current DFS stack (cycle detection)
	mut done: list<string> = []      # post-order output (leaf-first)

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

		let bayt_cue = if $current == "." {
			$"($workspace_root)/bayt.cue"
		} else {
			$"($workspace_root)/($current)/bayt.cue"
		}
		if not ($bayt_cue | path exists) {
			continue
		}
		let targets = (pass1 $bayt_cue)
		# Cross-project deps and cross-project `from` refs share one
		# vocabulary ("<project>:<target>") and one resolution path
		# (project_index → dir), so the cycle detector covers both.
		let cdeps = (cross-dep-strings $targets)
		# Push deps in reverse order so the first dep is processed first.
		for dep in ($cdeps | reverse) {
			let d = (dep-to-dir $dep $index)
			if not ($d in $done) {
				$stack = ($stack | append {dir: $d, phase: "enter"})
			}
		}
	}

	$done
}

# regen-project runs both CUE passes for one project's bayt.cue and
# writes the resulting bundle. Used by both single-project and recursive
# modes.
#
# Auto-loads `<proj>:<target>:srcs` synthetic manifests for every
# two-segment cross-project dep so transitive `:srcs` walking lands the
# upstream source closures without consumers enumerating them. Missing
# `:srcs` manifests (upstream target had no srcs) silently skip.
def regen-project [bayt_cue: string, dir_rel: string, index: record, workspace_root: string, --depot] {
	let targets = (pass1 $bayt_cue)
	let cdeps = (cross-dep-strings $targets)
	let auto_srcs = (srcs-variants $cdeps)
	let all_deps = ($cdeps | append $auto_srcs | uniq)
	let dep_manifests = (load-dep-manifests $all_deps $index $workspace_root $auto_srcs)
	let bundle = (pass2 $bayt_cue $dep_manifests)
	write-bundle $bundle $dir_rel --depot=$depot
}

# Entry point.
const cache_nu = (path self | path dirname | path dirname | path join "runtime" "cache.nu")

export def main [--recursive (-r), --all, --runtime: string = "", --depot] {
	let effective = if ($runtime | is-empty) { ($env.BAYT_RUNTIME_DIR? | default "") } else { $runtime }
	with-env { BAYT_RUNTIME_DIR: $effective } { _main --recursive=$recursive --all=$all --depot=$depot }
}

def _main [--recursive (-r), --all, --depot] {
	if not $all and not ("bayt.cue" | path exists) {
		return
	}

	let workspace_root = (find-workspace-root)
	# One-shot scan of every bayt.cue to map project_name → dir.
	# Cross-project refs ("<project>:<target>") resolve through this.
	let index = (build-project-index $workspace_root)

	if $all {
		# Every project in the workspace, deps before consumers — one
		# process, one index, one topo pass. Works from any cwd inside
		# the workspace; the multi-root DFS dedupes shared closures.
		cd $workspace_root
		let schedule = (topo-schedule $workspace_root ($index | values | uniq) $index)
		for dir_rel in $schedule {
			let bayt_cue = if $dir_rel == "." {
				$"($workspace_root)/bayt.cue"
			} else {
				$"($workspace_root)/($dir_rel)/bayt.cue"
			}
			regen-project $bayt_cue $dir_rel $index $workspace_root --depot=$depot
		}
	} else if $recursive {
		let project_abs = (pwd)
		let project_rel = ($project_abs | path relative-to $workspace_root)
		let project_rel = if ($project_rel | str trim) == "" { "." } else { $project_rel }

		# Work from workspace root so write-bundle's relative paths are correct.
		cd $workspace_root

		let schedule = (topo-schedule $workspace_root [$project_rel] $index)
		for dir_rel in $schedule {
			let bayt_cue = if $dir_rel == "." {
				$"($workspace_root)/bayt.cue"
			} else {
				$"($workspace_root)/($dir_rel)/bayt.cue"
			}
			regen-project $bayt_cue $dir_rel $index $workspace_root --depot=$depot
		}
	} else {
		# Single-project mode: cd to workspace_root so write-bundle's
		# relative paths (used by --runtime injection) are computed
		# against the right depth — same convention --recursive uses.
		let project_abs = (pwd)
		let project_rel = ($project_abs | path relative-to $workspace_root)
		let project_rel = if ($project_rel | str trim) == "" { "." } else { $project_rel }
		let bayt_cue = if $project_rel == "." { $"($workspace_root)/bayt.cue" } else { $"($workspace_root)/($project_rel)/bayt.cue" }
		cd $workspace_root
		regen-project $bayt_cue $project_rel $index $workspace_root --depot=$depot
	}

	# Run cache GC at end of generation. Cheap (no-op when under
	# budget), folds eviction into a natural rate-limit: regen
	# happens after bayt.cue edits, exactly when projects most likely
	# have accumulated cache cruft from the prior shape. Opt-out via
	# BAYT_CACHE_NO_GC=true for CI / disk-pressured envs. Errors
	# propagate — silently swallowed GC means the cache fills until
	# it eats the disk.
	run-nu $cache_nu gc
}
