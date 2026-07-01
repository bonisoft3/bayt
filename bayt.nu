#!/usr/bin/env nu

use core/generate.nu

# --runtime <path>: workspace-rooted path to bayt's source tree.
# Generated compose embeds a relative path to bayt-runtime instead of
# the default `${BAYT_RUNTIME:-docker-image://…}`.
# Projects opt into .bayt/{depot.yaml,depot.hcl} emission via `#project.depot:
# true` in bayt.cue — a normal `generate` keeps them fresh (docker required only
# for those projects). --depot forces emission for EVERY generated project,
# regardless of opt-in (mostly for one-off inspection).
def "main generate" [--recursive (-r), --runtime: string = "", --depot] {
	if $recursive { generate --recursive --runtime $runtime --depot=$depot } else { generate --runtime $runtime --depot=$depot }
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

def "main where" [target: string = "root"] {
	use runtime/where.nu
	where $target
}

def main [] {
	print (help main)
}
