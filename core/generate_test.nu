#!/usr/bin/env nu
# Tests for generate.nu's pure helpers.
#
# Run with: nu generate_test.nu (from this directory).

use std/assert
use ./generate.nu [repo-of, scan-dir]

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
