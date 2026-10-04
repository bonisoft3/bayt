#!/usr/bin/env nu
# Tests for generate.nu's pure helpers.
#
# Run with: nu generate_test.nu (from this directory).

use std/assert
use ./generate.nu [repo-of, scan-dir, _inject-runtime, relative-flat, scan-projects, clear-bayt-dir, find-workspace-root, root-for, partition-scan, topo-schedule, check-dirs]

def main [] {
	print "Running generate.nu tests...\n"

	test_repo_of_strips_a_plain_tag
	test_repo_of_keeps_a_ref_that_has_none
	test_repo_of_survives_a_templated_tag
	test_repo_of_keeps_a_registry_port
	test_repo_of_ignores_a_slash_inside_a_template
	test_scan_dir_answers_the_scan_s_spelling
	test_scan_dir_answers_dot_at_the_root
	test_scan_dir_leaves_a_posix_dir_alone
	test_relative_flat_on_windows
	test_relative_flat_leaves_other_backslashes
	test_relative_flat_on_posix
	test_scan_finds_projects_outside_a_repository
	test_scan_honours_git_excludes_in_a_work_tree
	test_inject_runtime_rewrites_the_published_image
	test_inject_runtime_climbs_out_of_a_nested_project
	test_inject_runtime_is_a_noop_without_the_env
	test_inject_runtime_keeps_service_order
	test_clear_keeps_the_env_file
	test_scan_places_a_nested_rooted_project_where_it_sits
	test_scan_reads_a_rooted_project_from_its_bayt_cue
	test_root_walk_stops_at_cue_mod
	test_a_rooted_project_containing_here_is_the_root
	test_a_plain_project_runs_from_the_cue_mod_root
	test_a_rooted_cue_mod_root_is_rooted
	test_a_dir_where_the_project_sits_passes
	test_a_dir_elsewhere_fails_naming_both
	test_partition_keeps_a_nested_root_s_subtree_to_it
	test_partition_marks_a_nested_root_in_the_index
	test_a_ref_to_a_nested_root_is_refused
	test_partition_passes_only_outermost_roots

	print "\nAll generate.nu tests passed!"
}

def check [label: string, ref: string, want: string] {
	assert equal (repo-of $ref) $want
	print $"  PASS  ($label)"
}

def test_repo_of_strips_a_plain_tag [] {
	check "plain tag" "bayt-guis_iris-build_bayt:latest" "bayt-guis_iris-build_bayt"
}

def test_repo_of_keeps_a_ref_that_has_none [] {
	check "untagged ref" "gcr.io/trash-362115/iris-database" "gcr.io/trash-362115/iris-database"
}

# The generated `image:` carries an uninterpolated `${BAYT_IMAGE_TAG:-latest}`.
# Cutting at the LAST colon lands inside that default and yields a repo ending
# in `:${BAYT_IMAGE_TAG`.
def test_repo_of_survives_a_templated_tag [] {
	check "templated tag" "${ORG:-o}.registry.example/${PROJ:-p}/bayt-x:${BAYT_IMAGE_TAG:-latest}" "${ORG:-o}.registry.example/${PROJ:-p}/bayt-x"
}

# Cutting at the FIRST colon instead takes the registry's port for a tag.
def test_repo_of_keeps_a_registry_port [] {
	check "registry port" "registry:5000/foo/bar:1.2.3" "registry:5000/foo/bar"
}

# A '/' inside a template is not a path separator, so it must not reset the
# search for the tag colon.
def test_repo_of_ignores_a_slash_inside_a_template [] {
	check "slash in template" "${R:-a/b}/img:${T:-latest}" "${R:-a/b}/img"
}

# The scan keys its rows by a forward-slash dir and a project is looked up by
# this, so a platform spelling its own paths differently misses every row —
# and the fallback that covers a miss cannot read a bayt.json-backed stub.
# Windows is that platform, and nothing else in this suite runs there.
def test_scan_dir_answers_the_scan_s_spelling [] {
	assert equal (scan-dir "apps\\shadcnui") "apps/shadcnui"
	print "  PASS  a windows dir answers in the scan's slashes"
}

def test_scan_dir_answers_dot_at_the_root [] {
	assert equal (scan-dir "") "."
	print "  PASS  the workspace root answers ."
}

def test_scan_dir_leaves_a_posix_dir_alone [] {
	assert equal (scan-dir "apps/truco") "apps/truco"
	print "  PASS  a posix dir is unchanged"
}

# _inject-runtime's failure mode is silent: a rewrite that does not happen
# leaves the published image as the build context, which builds fine and
# looks intentional. Nothing downstream notices, so the behaviour is pinned
# here rather than trusted.
def _svc [ctx: string]: nothing -> record {
	{services: {a: {build: {additional_contexts: {bayt: $ctx, other: "service:x"}}}}}
}
const IMG = "docker-image://bonitao/bayt-runtime:1.0.1@sha256:e0f4"

def test_inject_runtime_rewrites_the_published_image [] {
	print "test the published image becomes a relative runtime path..."
	# `../` even at the root: the compose file sits in `.bayt/`, so every
	# path climbs out of that before the repo-relative part.
	let got = (with-env {BAYT_RUNTIME_DIR: "plugins/bayt"} { _inject-runtime (_svc $IMG) "." })
	assert equal $got.services.a.build.additional_contexts.bayt "../plugins/bayt/runtime"
	# Siblings are left alone: the rewrite is keyed on the context name.
	assert equal $got.services.a.build.additional_contexts.other "service:x"
}

# One `../` per path segment plus one for the project's own .bayt dir; the
# compose file resolves its contexts relative to itself, not the repo root.
def test_inject_runtime_climbs_out_of_a_nested_project [] {
	print "test the relative path climbs out of a nested project..."
	let got = (with-env {BAYT_RUNTIME_DIR: "plugins/bayt"} { _inject-runtime (_svc $IMG) "libraries/logs" })
	assert equal $got.services.a.build.additional_contexts.bayt "../../../plugins/bayt/runtime"
}

# Unset is the published path: a consumer outside this repo has no local
# runtime tree to point at.
def test_inject_runtime_is_a_noop_without_the_env [] {
	print "test an unset BAYT_RUNTIME_DIR leaves the image ref alone..."
	let got = (with-env {BAYT_RUNTIME_DIR: ""} { _inject-runtime (_svc $IMG) "." })
	assert equal $got.services.a.build.additional_contexts.bayt $IMG
}

# On Windows compose spells the flattened contexts with backslashes, and the
# prefix strip missed them: depot.json named `.\apps\primer/.bayt/...` and
# depot.yaml `.\apps\primer`, so the cross job's stale-tree check failed.
def test_relative_flat_on_windows [] {
	print "test a Windows context comes out repo-relative with forward slashes..."
	let flat = "services:\n  a:\n    build:\n      context: D:\\a\\trash\\trash\\apps\\primer\n"
	assert equal (relative-flat $flat 'D:\a\trash\trash') "services:\n  a:\n    build:\n      context: apps/primer\n"
}

def test_relative_flat_leaves_other_backslashes [] {
	print "test a backslash outside a workspace path is content..."
	let flat = "      command: echo a\\nb\n"
	assert equal (relative-flat $flat 'D:\a\trash\trash') $flat
}

def test_relative_flat_on_posix [] {
	print "test a POSIX context loses the workspace prefix..."
	let flat = "      context: /home/r/trash/apps/primer\n      root: /home/r/trash\n"
	assert equal (relative-flat $flat '/home/r/trash') "      context: apps/primer\n      root: .\n"
}

# A scan that asked git alone came back empty outside a work tree, and every
# cross-project ref then failed as an unknown project naming no cause; the act
# replay's build context, which leaves .git out, was such a place.
def test_scan_finds_projects_outside_a_repository [] {
	print "test the scan walks a workspace that is no work tree..."
	let dir = (mktemp -d)
	mkdir ($dir | path join app) ($dir | path join dist/app)
	"dist/\n" | save ($dir | path join .gitignore)
	for d in [app, dist/app] { _project $dir $d }
	let got = (_scanned $dir)
	assert equal $got ["app"]
}

# In a work tree the scan is git's own listing, so every exclude git honours
# still holds: a scratch copy of a project under .git/info/exclude would
# otherwise join the index under a name another project already has.
def test_scan_honours_git_excludes_in_a_work_tree [] {
	print "test the scan keeps git's excludes in a work tree..."
	let dir = (mktemp -d)
	^git -C $dir init -q
	mkdir ($dir | path join app) ($dir | path join scratch/app)
	"scratch/\n" | save --append ($dir | path join .git/info/exclude)
	for d in [app, scratch/app] { _project $dir $d }
	let got = (_scanned $dir)
	assert equal $got ["app"]
}

def _project [root: string, d: string] {
	"" | save ($root | path join $d bayt.cue)
	{name: ($d | str replace "/" "_"), dir: $d, targets: {}} | to json | save ($root | path join $d bayt.json)
}

# The scan's project names, with the workspace removed whether it answers or throws.
def _scanned [dir: string]: nothing -> list<string> {
	let got = (try { scan-projects $dir | get name } catch {|e| rm -rf $dir; error make {msg: $e.msg} })
	rm -rf $dir
	$got
}

# The record is rebuilt service by service, so order is not free. Emitted
# order is the diff a reviewer reads.
def test_inject_runtime_keeps_service_order [] {
	print "test rebuilding the record preserves service order..."
	let d = {services: {zeta: {build: {additional_contexts: {bayt: $IMG}}}, alpha: {image: "x"}, mid: {build: {additional_contexts: {bayt: $IMG}}}}}
	let got = (with-env {BAYT_RUNTIME_DIR: "plugins/bayt"} { _inject-runtime $d "." })
	assert equal ($got.services | columns) ["zeta", "alpha", "mid"]
}

# .bayt/.env is the monorepo's own file (MONOREPO=service): regeneration
# rebuilds everything around it and never touches it.
def test_clear_keeps_the_env_file [] {
	print "test clearing .bayt keeps .env and drops the rest..."
	let dir = (mktemp -d | path join .bayt)
	mkdir ($dir | path join sub)
	"MONOREPO=service\n" | save ($dir | path join .env)
	"x" | save ($dir | path join compose.yaml)
	"x" | save ($dir | path join sub/stale.json)
	clear-bayt-dir $dir
	let left = (ls -a $dir | get name | path basename | sort)
	rm -rf ($dir | path dirname)
	assert equal $left [".env"]
}

def _rooted [root: string, d: string] {
	mkdir ($root | path join $d)
	"" | save ($root | path join $d bayt.cue)
	{name: ($d | str replace -a "/" "_"), dir: ".", targets: {}} | to json | save ($root | path join $d bayt.json)
}

# Nested in the monorepo, a project rooted at itself declares dir "."; the
# outer scan places it where it sits, so nothing of it is written at the
# root's .bayt/.
def test_scan_places_a_nested_rooted_project_where_it_sits [] {
	print "test the outer scan places a nested rooted project by location..."
	let dir = (mktemp -d)
	mkdir ($dir | path join app)
	_project $dir app
	_rooted $dir apps/ws
	let rows = (try { scan-projects $dir } catch {|e| rm -rf $dir; error make {msg: $e.msg} })
	rm -rf $dir
	assert equal ($rows | sort-by name | select name dir_rel rooted) [
		{name: app, dir_rel: app, rooted: false}
		{name: apps_ws, dir_rel: apps/ws, rooted: true}
	]
}

# A project with no bayt.json is read by file-mode export; its dir roots it.
def test_scan_reads_a_rooted_project_from_its_bayt_cue [] {
	print "test the scan reads a rooted project from its bayt.cue..."
	let dir = (mktemp -d)
	mkdir ($dir | path join apps/ws)
	'project: {name: "apps_ws", dir: ".", targets: {}}' | save ($dir | path join apps/ws bayt.cue)
	let rows = (try { scan-projects $dir } catch {|e| rm -rf $dir; error make {msg: $e.msg} })
	rm -rf $dir
	assert equal ($rows | select name dir_rel rooted) [{name: apps_ws, dir_rel: apps/ws, rooted: true}]
}






# A scan row; `at` is where its bayt.cue sits, which a project below a nested
# root does not declare (its dir is relative to that root).
def _row [name: string, dir_rel: string, rooted: bool, at?: string] {
	{path: $"/w/($at | default $dir_rel)/bayt.cue", name: $name, dir_rel: $dir_rel, targets: {}, rooted: $rooted}
}

# A project below a nested root belongs to that root: generated against this
# one, its paths would be the monorepo's, not its own checkout's.
def test_partition_keeps_a_nested_root_s_subtree_to_it [] {
	print "test a nested root's subtree stays out of this root's schedule..."
	let got = (partition-scan [(_row root "." false) (_row ws apps/ws true) (_row svc svc false apps/ws/svc) (_row lib libs/x false)])
	assert equal ($got.local | get name) [root lib]
	assert equal ($got.nested | get dir_rel) [apps/ws]
}

# The index marks a nested root, so a ref to it is refused by name rather
# than reported as unknown.
def test_partition_marks_a_nested_root_in_the_index [] {
	print "test the index marks a nested root..."
	let got = (partition-scan [(_row root "." false) (_row ws apps/ws true) (_row svc svc false apps/ws/svc)])
	assert equal $got.index {root: ".", ws: {rooted: apps/ws}}
}

# A project rooted at itself has no siblings: its manifests state dir ".",
# its own root, which a dependent here would read as this root.
def test_a_ref_to_a_nested_root_is_refused [] {
	print "test a ref to a nested root is refused..."
	let app = {path: "/w/app/bayt.cue", name: app, dir_rel: app, targets: {build: {deps: ["ws:build"]}}, rooted: false}
	let parts = (partition-scan [$app (_row ws apps/ws true)])
	let got = (try { topo-schedule [app] $parts.local $parts.index; "scheduled" } catch {|e| $e.rendered | ansi strip })
	assert str contains $got "ws:build names ws, rooted at itself in apps/ws"
}

# A root nested in a nested root is generated by the outer one's pass; this
# root starts only the outermost, or the inner would be generated twice.
def test_partition_passes_only_outermost_roots [] {
	print "test only the outermost nested roots get a pass..."
	let got = (partition-scan [(_row root "." false) (_row ws apps/ws true) (_row inner apps/ws/inner true)])
	assert equal ($got.nested | get name) [ws]
	assert equal ($got.local | get name) [root]
}

# The walk reads no bayt.cue: it stops at the nearest cue.mod, and the scan
# from there says which root a run belongs to.
def test_root_walk_stops_at_cue_mod [] {
	print "test the root walk stops at the nearest cue.mod..."
	let dir = (mktemp -d)
	mkdir ($dir | path join cue.mod) ($dir | path join plugins/bayt/core)
	"package bayt\n#x: #MapAsList\n" | save ($dir | path join plugins/bayt/core bayt.cue)
	let got = (find-workspace-root ($dir | path join plugins/bayt/core))
	rm -rf $dir
	assert equal $got $dir
}

# Run from inside a project rooted at itself, under an outer cue.mod, the run
# is that project's own root.
def test_a_rooted_project_containing_here_is_the_root [] {
	print "test a rooted project containing here is the root..."
	let scanned = [(_row root "." false) (_row ws apps/ws true) (_row inner apps/ws/inner true)]
	assert equal (root-for $scanned /w /w/apps/ws/src) {root: /w/apps/ws, rooted: true}
	assert equal (root-for $scanned /w /w/apps/ws/inner) {root: /w/apps/ws/inner, rooted: true}
}

def test_a_plain_project_runs_from_the_cue_mod_root [] {
	print "test a plain project runs from the cue.mod root..."
	let scanned = [(_row root "." false) (_row ws apps/ws true) (_row lib libs/x false)]
	assert equal (root-for $scanned /w /w/libs/x) {root: /w, rooted: false}
}

# A mirror's root: the cue.mod and the rooted project in one directory.
def test_a_rooted_cue_mod_root_is_rooted [] {
	print "test a cue.mod root holding a rooted project is rooted..."
	let scanned = [{path: "/w/bayt.cue", name: app, dir_rel: ".", targets: {}, rooted: true}]
	assert equal (root-for $scanned /w /w) {root: /w, rooted: true}
}

# A dir is authored, never inferred; checked against where its bayt.cue sits,
# so a stale one fails here instead of writing a .bayt/ somewhere else.
def test_a_dir_where_the_project_sits_passes [] {
	print "test declared dirs matching their places pass..."
	check-dirs [(_row root "." false) (_row lib libs/x false) (_row ws apps/ws true)] /w
}

def test_a_dir_elsewhere_fails_naming_both [] {
	print "test a declared dir elsewhere fails, naming both..."
	let got = (try { check-dirs [(_row sub apps/ws/sub false sub)] /w; "passed" } catch {|e| $e.rendered | ansi strip })
	assert str contains $got "sub declares dir apps/ws/sub but its bayt.cue sits at sub"
}
