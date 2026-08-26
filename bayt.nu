#!/usr/bin/env nu

use core/generate.nu

# --runtime <path>: workspace-rooted path to bayt's source tree.
# Generated compose embeds a relative path to bayt-runtime instead of
# the default `${BAYT_RUNTIME:-docker-image://…}`.
# --depot: emit .bayt/{depot.yaml,depot.hcl} for every project, not just the
# `#project.depot` opt-ins.
def "main generate" [--recursive (-r), --all, --runtime: string = "", --depot] {
	generate --recursive=$recursive --all=$all --runtime $runtime --depot=$depot
}

# Signature mirrors runtime/cache.nu's `main run` because nu spread args
# are positional — `--manifest` etc. wouldn't survive forwarding through
# `...$args`.
def --wrapped "main cache run" [
	--manifest: string
	--cmd: string = ""
	--full
	--similar
	...cmd_args: string
] {
	use runtime/cache.nu
	# Strip the caller's `--` end-of-flags marker before re-emitting one
	# for the inner call; otherwise it lands as a positional and `--` runs
	# as the command instead of the user's cmd.
	let inner = if ($cmd_args | length) > 0 and ($cmd_args | first) == "--" { $cmd_args | skip 1 } else { $cmd_args }
	cache main run --manifest $manifest --cmd $cmd --full=$full --similar=$similar -- ...$inner
}

def "main cache gc" [--max-bytes: int = 10737418240] {
	use runtime/cache.nu
	cache main gc --max-bytes $max_bytes
}

def "main cache status" [] {
	use runtime/cache.nu
	cache main status
}

def "main cache clear" [] {
	use runtime/cache.nu
	cache main clear
}

# Stamp mode writes; check mode is silent (exit 0=match, 1=miss).
def "main fingerprint" [
	--manifest: string = ""
	--cmd: string = ""
	--stamp-file: string = ""
	--update-stamp
] {
	use runtime/fingerprint.nu
	fingerprint --manifest $manifest --cmd $cmd --stamp-file $stamp_file --update-stamp=$update_stamp
}

# The depot bake group as a leaf set for sayt/plan: one row per leaf carrying
# where the build phase pushes it and the fingerprint of its source closure.
#
# Fail open, per leaf: one that will not hash gets an empty fingerprint, which
# sayt/plan treats as a miss and builds. Erroring the whole plan instead would
# turn one unhashable leaf into a full rebuild of the closure.
def "main depot-plan" [
	--manifest: string = ""      # a project's .bayt/depot.json
	--out: string = ""           # write here instead of stdout
] {
	if ($manifest | is-empty) {
		error make { msg: "bayt depot-plan: --manifest is required" }
	}
	# Out of process, through this same interpreter: fingerprint --quiet prints
	# its hash rather than returning it, and a per-leaf failure has to stay a
	# per-leaf empty rather than aborting the walk.
	let fp_nu = ($env.FILE_PWD | path join "runtime" "fingerprint.nu")
	open $manifest | get targets | each { |t|
		let r = (do { ^$nu.current-exe $fp_nu --manifest $t.manifest --all-cmds --quiet } | complete)
		if $r.exit_code != 0 {
			print -e $"bayt depot-plan: ($t.target) will not fingerprint: ($r.stderr)"
		}
		{
			target: $t.target
			repo:   $t.repo
			fingerprint: (if $r.exit_code == 0 { $r.stdout | str trim } else { "" })
		}
	} | to json --raw | if ($out | is-empty) { print $in } else {
		# --out because stdout is shared: a launcher that prints its own line
		# before this one turns the result into something no caller can parse,
		# and the caller cannot tell that from a leaf set.
		$in | save -f $out
	}
}

# The key for "this exact input closure already passed": a target's source
# closure folded with the pipeline files that decide how it is exercised.
#
# The pipeline belongs in the key here and NOT in an image fingerprint: this
# gates a test RESULT, which a workflow edit can change, where an image
# fingerprint gates CONTENT, which the workflow never enters.
#
# Emits nothing when either half fails. A caller reads empty as "no stamp",
# so the work runs — only a positive hash can license a skip.
def "main run-stamp" [
	--manifest: string = ""      # the exercising target's .bayt/bayt.<n>.json
	--out: string = ""           # write here instead of stdout (see depot-plan)
	...pipeline: string          # workflow files, repo-root-relative
] {
	if ($manifest | is-empty) {
		error make { msg: "bayt run-stamp: --manifest is required" }
	}
	let fp_nu = ($env.FILE_PWD | path join "runtime" "fingerprint.nu")
	let closure = (do { ^$nu.current-exe $fp_nu --manifest $manifest --all-cmds --quiet } | complete)
	if $closure.exit_code != 0 {
		print -e $"bayt run-stamp: closure will not fingerprint: ($closure.stderr)"
		return
	}
	# Hashed from the cwd, where the pipeline paths are rooted; the manifest
	# half is rooted at its own project.
	let pipe = (do { ^$nu.current-exe $fp_nu --quiet ...$pipeline } | complete)
	if $pipe.exit_code != 0 {
		print -e $"bayt run-stamp: pipeline will not fingerprint: ($pipe.stderr)"
		return
	}
	let key = ($"($closure.stdout | str trim)\n($pipe.stdout | str trim)" | hash sha256)
	if ($out | is-empty) { print $key } else { $key | save -f $out }
}

def "main where" [target: string = "root"] {
	use runtime/where.nu
	where $target
}

def main [] {
	print (help main)
}
