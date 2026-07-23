#!/usr/bin/env nu

use cache.nu
use fingerprint.nu
use where.nu

const _fat_cli = (path self | path dirname | path join ".." "bayt.nu")

def --wrapped "main cache run" [
	--manifest: string
	--cmd: string = ""
	--full
	--similar
	...cmd_args                               # untyped: a typed `...string` rejects a bare keyword arg (`true`/`false`/`null`) at parse time
] {
	let raw = if ($cmd_args | length) > 0 and ($cmd_args | first) == "--" { $cmd_args | skip 1 } else { $cmd_args }
	# nu parsed a keyword arg as its bool/null value; stringify so it runs as a command
	let inner = ($raw | each {|a| $a | into string })
	cache main run --manifest $manifest --cmd $cmd --full=$full --similar=$similar -- ...$inner
}

def "main cache gc" [--max-bytes: int = 10737418240] {
	cache main gc --max-bytes $max_bytes
}

def "main cache status" [] { cache main status }
def "main cache clear" [] { cache main clear }

def "main fingerprint" [
	--manifest: string = ""
	--cmd: string = ""
	--stamp-file: string = ""
	--update-stamp
] {
	fingerprint --manifest $manifest --cmd $cmd --stamp-file $stamp_file --update-stamp=$update_stamp
}

def "main where" [target: string = "root"] {
	where $target
}

# generate — regenerate this project's .bayt from bayt.cue. No bayt.cue
# in cwd → nothing to generate (containers never stage config, so this
# is the in-container no-op). The fat CLI sibling only exists where
# bayt.cue does (checkout layouts), so the guard also gates the exec.
def "main generate" [] {
	if not ("bayt.cue" | path exists) { return }
	^$nu.current-exe $_fat_cli generate --runtime plugins/bayt
}

def main [] { print (help main) }
