use std/assert

const source = (path self | path dirname)
const repo = ($source | path join ".." ".." ".." | path expand)

def invoke [fixture: path, verb: string]: nothing -> record {
	do {
		cd $fixture
		with-env {MISE_TRUSTED_CONFIG_PATHS: $repo} {
			^nu ($repo | path join "plugins/sayt/sayt.nu") $verb
		}
	} | complete
}

def main [] {
	let fixture = mktemp -d -p ($repo | path join "apps") ".bayt-say-XXXXXXXX"
	let dir = $"apps/($fixture | path basename)"
	let graph = '
package fixture
import (
  bayt "bonisoft.org/plugins/bayt/core:bayt"
  sayt "bonisoft.org/plugins/bayt/stacks/sayt"
)
project: bayt.#project & sayt.gate & {
  name: "FIXTURE_NAME"
  dir: "DIR"
  activate: ""
  files: "settings.json": {enabled: true}
  targets: {
    lint: {
      taskfile: {}
      srcs: globs: ["lint-input.txt"]
      cmd: {
        first: {shell: "nu", do: "mkdir proof; print LINT_FIRST; if (open lint-input.txt --raw) == bad { error make {msg: rejected} }; \"first\" | save --force proof/lint.txt"}
        second: {shell: "nu", do: "print LINT_SECOND; \"second\" | save --append proof/lint.txt"}
      }
      files: "message.txt": "target payload"
    }
    test: {
      taskfile: {}
      srcs: globs: ["test-input.txt"]
      outs: globs: ["proof/test.txt"]
      cmd: builtin: {shell: "nu", do: "mkdir proof; print TEST_CUSTOM; \"tested\" | save --force proof/test.txt"}
    }
  }
}
depManifestsIn: {[string]: _}
_render: bayt.#render & {project: project, depManifests: depManifestsIn}
'
	$graph | str replace "DIR" $dir | str replace "FIXTURE_NAME" ($fixture | path basename | str replace --all "." "_") | save ($fixture | path join "bayt.cue")
	'package say
say: test: keep_going: false
' | save ($fixture | path join ".say.cue")
	"proof/\n.task/\n" | save ($fixture | path join ".gitignore")
	"initial" | save ($fixture | path join "lint-input.txt")
	"initial" | save ($fixture | path join "test-input.txt")
	let generated = (do {
		cd $fixture
		with-env {MISE_TRUSTED_CONFIG_PATHS: $repo} {
			^nu -c $"use ($source)/generate.nu; generate --runtime plugins/bayt"
		}
	} | complete)
	assert equal $generated.exit_code 0 $generated.stderr
	cp ($fixture | path join ".bayt/say.yaml") ($fixture | path join ".say.yaml")
	assert equal (open ($fixture | path join ".bayt/settings.json")) {enabled: true}
	assert equal (open --raw ($fixture | path join ".bayt/message.lint.txt")) "target payload"
	for verb in ["lint" "test"] {
		let first = invoke $fixture $verb
		assert equal $first.exit_code 0 $first.stderr
		if $verb == "lint" {
			assert (($first.stdout + $first.stderr) | str contains "LINT_FIRST") $first.stdout
			assert (($first.stdout + $first.stderr) | str contains "LINT_SECOND") $first.stdout
			assert equal (open --raw ($fixture | path join "proof/lint.txt")) "firstsecond"
		} else { assert (($first.stdout + $first.stderr) | str contains "TEST_CUSTOM") $first.stdout }
		let warm = invoke $fixture $verb
		assert equal $warm.exit_code 0 $warm.stderr
		assert ($warm.stderr | str contains "is up to date") $warm.stderr
		assert not ($warm.stdout | str contains "LINT_FIRST")
		assert not ($warm.stdout | str contains "TEST_CUSTOM")
	}
	"changed" | save --force ($fixture | path join "test-input.txt")
	let changed = invoke $fixture test
	assert equal $changed.exit_code 0 $changed.stderr
	assert (($changed.stdout + $changed.stderr) | str contains "TEST_CUSTOM") $changed.stdout
	rm ($fixture | path join "proof/test.txt")
	let repaired = invoke $fixture test
	assert equal $repaired.exit_code 0 $repaired.stderr
	assert (($repaired.stdout + $repaired.stderr) | str contains "TEST_CUSTOM") $repaired.stdout
	let stamp = $fixture | path join ".task/bayt/lint.hash"
	let previous = open --raw $stamp
	"bad" | save --force ($fixture | path join "lint-input.txt")
	let failed = invoke $fixture lint
	assert ($failed.exit_code != 0) $failed.stdout
	assert not ($failed.stdout | str contains "LINT_SECOND")
	assert equal (open --raw $stamp) $previous
	let before = open --raw ($fixture | path join ".bayt/say.yaml")
	$graph | str replace "DIR" $dir | str replace "FIXTURE_NAME" ($fixture | path basename | str replace --all "." "_") | str replace '"settings.json": {enabled: true}' '"compose.yaml": {}' | save --force ($fixture | path join "bayt.cue")
	let collision = (do {
		cd $fixture
		with-env {MISE_TRUSTED_CONFIG_PATHS: $repo} {
			^nu -c $"use ($source)/generate.nu; generate --runtime plugins/bayt"
		}
	} | complete)
	assert ($collision.exit_code != 0) $collision.stdout
	assert ($collision.stderr | str contains "generated file collision") $collision.stderr
	assert equal (open --raw ($fixture | path join ".bayt/say.yaml")) $before
	rm -rf $fixture
	print "passthrough_test: composed gates preserve checks, cache safely, repair outputs and reject collisions"
}
