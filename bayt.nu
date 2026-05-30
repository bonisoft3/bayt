#!/usr/bin/env nu

use runtime/generate.nu

# Walk bayt.cue and emit .bayt/* artifacts.
# --runtime <path>: workspace-rooted path to bayt's source tree. When
# set, generated compose embeds a relative path to bayt-runtime
# instead of the default `${BAYT_RUNTIME:-docker-image://…}`. Use
# this in monorepo-dev configs (sayt's auto-bayt rule) so committed
# YAML points at the local checkout.
def "main generate" [--recursive (-r), --runtime: string = ""] {
	if $recursive { generate --recursive --runtime $runtime } else { generate --runtime $runtime }
}

# Restore-or-run a target cmd under the content-addressable cache.
# Signature mirrors runtime/cache.nu's `main run` because nu spread
# args are positional — `--manifest` etc. wouldn't survive forwarding
# through `...$args`.
def --wrapped "main cache run" [
	--manifest: string
	--cmd: string = ""
	--full
	--similar
	...cmd_args: string
] {
	use runtime/cache.nu
	# Strip the caller's `--` end-of-flags marker before re-emitting
	# one for the inner call; otherwise it lands as a positional and
	# `--` runs as the command instead of the user's cmd.
	let inner = if ($cmd_args | length) > 0 and ($cmd_args | first) == "--" { $cmd_args | skip 1 } else { $cmd_args }
	cache main run --manifest $manifest --cmd $cmd --full=$full --similar=$similar -- ...$inner
}

# Evict local-FS cache entries to fit byte budget.
def "main cache gc" [--max-bytes: int = 10737418240] {
	use runtime/cache.nu
	cache main gc --max-bytes $max_bytes
}

# Print local-FS cache size and entry count.
def "main cache status" [] {
	use runtime/cache.nu
	cache main status
}

# Wipe local-FS cache.
def "main cache clear" [] {
	use runtime/cache.nu
	cache main clear
}

# Compute or check the cache fingerprint of a target's srcs.
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

# Print install location: bayt's root (default) or its runtime/ dir.
def "main where" [target: string = "root"] {
	use runtime/where.nu
	where $target
}

# bayt — declarative build target generator.
def main [] {
	print (help main)
}
