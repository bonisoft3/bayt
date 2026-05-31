#!/usr/bin/env nu

use cache.nu
use fingerprint.nu
use where.nu

def --wrapped "main cache run" [
	--manifest: string
	--cmd: string = ""
	--full
	--similar
	...cmd_args: string
] {
	let inner = if ($cmd_args | length) > 0 and ($cmd_args | first) == "--" { $cmd_args | skip 1 } else { $cmd_args }
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

def main [] { print (help main) }
