use std/assert

const repo = (path self | path dirname | path join ".." ".." ".." | path expand)
const frontend = "docker/dockerfile:1.26@sha256:ecfaec9ed6d810b56388c508f4121597bfbba70d41a6dfeee4d8cad5f295fc32"

def build [fixture: path]: nothing -> record {
	with-env {TOKEN: "synthetic-test-token"} {
		do { ^docker buildx build --progress=plain --secret id=token,env=TOKEN --target check --output type=cacheonly -f ($fixture | path join "Dockerfile") $fixture } | complete
	}
}

def main [] {
	cd $repo
	let fixture = mktemp -d
	# The assertions read what the RUN printed, which a builder that already ran
	# this command answers CACHED, printing nothing: the ARC fleet's shared
	# BuildKit outlives every job. A run of its own makes the command its own.
	let run = (random uuid)
	let program = ('
import bayt "bonisoft.org/plugins/bayt/core:bayt"
_project: bayt.#project & {
  name: "inject-check", dir: ".", activate: ""
  targets: check: {
    taskfile: {incremental: false}
    dockerfile: {from: name: bayt.lock.images.lazybox, incremental: true, secrets: token: environment: "TOKEN"}
    cmd: builtin: {
      shell: "sh"
      do: #"value=TASK_LEAF; tick=`printf TASK_BACKTICK`; test -n "$TOKEN" && echo "$value" && echo "$tick"; : RUN_ID"#
      dockerfile: inject: {
        secrets: [{id: "token", var: contents: "TOKEN"}]
        steps: [{pre: "echo SETUP_MARKER", post: "echo CLEANUP_MARKER"}]
      }
    }
  }
}
out: bayt.#render & {project: _project, depManifests: {}}
' | str replace "RUN_ID" $run)
	try {
		let bundle = ($program | ^cue export - -e out | from json)
		mkdir ($fixture | path join ".bayt")
		$bundle.taskfile.root | to yaml | save ($fixture | path join ".bayt/Taskfile.yml")
		$bundle.taskfile.bayt_root | to yaml | save ($fixture | path join ".bayt/Taskfile.bayt.yml")
		$bundle.taskfile.files.check | to yaml | save ($fixture | path join ".bayt/Taskfile.check.yaml")
		$bundle.manifest.files.check | to json | save ($fixture | path join ".bayt/bayt.check.json")
		$"# syntax=($frontend)\n($bundle.docker.dockerfiles.check)" | save ($fixture | path join "Dockerfile")
		let success = build $fixture
		assert equal $success.exit_code 0 $success.stderr
		assert ($success.stderr | str contains "TASK_LEAF") $success.stderr
		assert ($success.stderr | str contains "TASK_BACKTICK") $success.stderr
		assert ($success.stderr | str contains "CLEANUP_MARKER") $success.stderr
		assert (not ($success.stderr | str contains "synthetic-test-token")) "secret content reached the build log"
		let failed_bundle = ($program | str replace "value=TASK_LEAF" "value=FAILED_LEAF" | str replace 'echo "$value"' 'echo "$value"; exit 23' | ^cue export - -e out | from json)
		$failed_bundle.taskfile.files.check | to yaml | save -f ($fixture | path join ".bayt/Taskfile.check.yaml")
		let failure = build $fixture
		assert ($failure.exit_code != 0) "a failed Task leaf must fail the build"
		assert ($failure.stderr | str contains "FAILED_LEAF") $failure.stderr
		assert ($failure.stderr | str contains "CLEANUP_MARKER") $failure.stderr
		print "incremental_inject_it: actual Docker Task runs preserve secrets, cleanup, and failure verdicts"
	} catch { |error|
		rm -rf $fixture
		error make $error
	}
	rm -rf $fixture
}
