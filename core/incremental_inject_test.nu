use std/assert

const source = (path self | path dirname)
const repo = ($source | path join ".." ".." ".." | path expand)

def render [extra: string]: nothing -> record {
	let program = '
import bayt "bonisoft.org/plugins/bayt/core:bayt"
_project: bayt.#project & {
  name: "inject-check", dir: ".", activate: ""
  targets: check: {
    taskfile: {incremental: false}
    dockerfile: {from: name: "alpine", incremental: true, secrets: token: environment: "TOKEN"}
    cmd: builtin: {
      do: *"echo original" | string, shell: "sh"
      dockerfile: inject: {secrets: [{id: "token", var: contents: "TOKEN"}], steps: []}
    }
    EXTRA
  }
}
out: (bayt.#render & {project: _project, depManifests: {}}).docker.dockerfiles.check
'
	($program | str replace "EXTRA" $extra) | do { ^cue export - -e out --out text } | complete
}

def main [] {
	cd $repo
	let injected = render ""
	assert equal $injected.exit_code 0 $injected.stderr
	assert ($injected.stdout | str contains "task -t .bayt/Taskfile.yml bayt:check") $injected.stdout
	let multiple = render 'cmd: another: {do: "echo next", shell: "sh"}'
	assert ($multiple.exit_code != 0) "multiple command injections must not leak secrets across task scopes"
	assert ($multiple.stderr | str contains "injection requires a single task command") $multiple.stderr
	let overridden = render 'cmd: builtin: dockerfile: do: "echo different"'
	assert ($overridden.exit_code != 0) "a container-only override must not silently execute the host command"
	assert ($overridden.stderr | str contains "cannot replace a task with dockerfile.do") $overridden.stderr
	print "incremental_inject_test: singleton injection is preserved and incompatible task scopes fail"
}
