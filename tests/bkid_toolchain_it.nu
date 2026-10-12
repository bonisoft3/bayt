use std/assert

const repo = (path self | path dirname | path join ".." ".." ".." | path expand)

def main [--platform: string] {
	cd $repo
	let program = '
import bayt "bonisoft.org/plugins/bayt/core:bayt"
_project: bayt.#project & {
  name: "bkid-toolchain", dir: ".", activate: ""
  targets: check: {
    dockerfile: bayt.bkid
    cmd: builtin: {shell: "sh", do: "task --version && depot --version"}
  }
}
out: bayt.#render & {project: _project, depManifests: {}}
'
	let bundle = ($program | ^cue export - -e out | from json)
	let platform_args = if $platform == null { [] } else { ["--platform" $platform] }
	let fixture = mktemp -d
	try {
		mkdir ($fixture | path join ".bayt")
		$bundle.taskfile.root | to yaml | save ($fixture | path join ".bayt/Taskfile.yml")
		$bundle.taskfile.bayt_root | to yaml | save ($fixture | path join ".bayt/Taskfile.bayt.yml")
		$bundle.manifest.files.check | to json | save ($fixture | path join ".bayt/bayt.check.json")
		$bundle.docker.dockerfiles.check | save ($fixture | path join "Dockerfile")
		let result = (do { ^docker buildx build ...$platform_args --target check --no-cache --add-host api.github.com:127.0.0.1 --progress=plain --output type=cacheonly -f ($fixture | path join "Dockerfile") $fixture } | complete)
		assert equal $result.exit_code 0 $result.stderr
		assert ($result.stderr | str contains "3.49.1") $result.stderr
		assert ($result.stderr | str contains "2.101.78") $result.stderr
		assert (not ($result.stderr | str contains "ghcr.io")) $result.stderr
	} catch { |error|
		rm -rf $fixture
		error make $error
	}
	rm -rf $fixture
	print "bkid_toolchain_it: cold locked GitHub installs succeed with the API blocked and no credentials"
}
