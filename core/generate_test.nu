#!/usr/bin/env nu
# Tests for generate.nu's pure helpers.
#
# Run with: nu generate_test.nu (from this directory).

use std/assert
use ./generate.nu [repo-of]

def main [] {
	print "Running generate.nu tests...\n"

	test_repo_of_strips_a_plain_tag
	test_repo_of_keeps_a_ref_that_has_none
	test_repo_of_survives_a_templated_tag
	test_repo_of_keeps_a_registry_port
	test_repo_of_ignores_a_slash_inside_a_template

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
