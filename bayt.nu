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
	...cmd_args                               # untyped: a typed `...string` rejects a bare keyword arg (`true`/`false`/`null`) at parse time
] {
	use runtime/cache.nu
	let raw = if ($cmd_args | length) > 0 and ($cmd_args | first) == "--" { $cmd_args | skip 1 } else { $cmd_args }
	let inner = ($raw | each {|a| $a | into string })
	cache main run --manifest $manifest --cmd $cmd --full=$full --similar=$similar -- ...$inner
}

def "main cache check" [--manifest: string, --stamp-file: string] {
	use runtime/cache.nu
	cache main check --manifest $manifest --stamp-file $stamp_file
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
	use runtime/fingerprint.nu [closure-hash, load-index]
	let targets = (open $manifest | get targets)
	# All targets in one depot manifest share the repo root; load the stat index once.
	let root = ("." | path expand)
	let index = (load-index $root)

	# Arguments for closure-hash:
	# cmd="", docker=false, view="", all_cmds=true (image scope), walk=false (trust stamps)
	mut memo = {}
	mut results = []
	for t in $targets {
		let cur_memo = $memo
		let res = (try {
			closure-hash $t.manifest "" false $cur_memo "" true false $index
		} catch { |err|
			# Fail open: a per-leaf failure must stay a per-leaf empty hash so sayt/plan
			# builds it, rather than aborting the walk for the whole group.
			let rendered = ($err.rendered? | default $err.msg)
			print -e $"bayt depot-plan: ($t.target) will not fingerprint: ($rendered)"
			{hash: "", memo: $cur_memo}
		})
		$memo = $res.memo
		$results ++= [{
			target: $t.target
			repo:   $t.repo
			fingerprint: $res.hash
		}]
	}
	let out_json = ($results | to json --raw)
	if ($out | is-empty) {
		print $out_json
	} else {
		# --out because stdout is shared: a launcher that prints its own line
		# before this one turns the result into something no caller can parse,
		# and the caller cannot tell that from a leaf set.
		$out_json | save -f $out
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
	use runtime/where.nu resolve
	resolve $target
}

def main [] {
	print (help main)
}
