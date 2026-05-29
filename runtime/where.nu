#!/usr/bin/env nu

const bayt_root = (path self | path dirname | path dirname)

# Print install location: bayt's root (default) or its runtime/ dir.
export def main [target: string = "root"] {
	match $target {
		"root"    => { print $bayt_root }
		"runtime" => { print ($bayt_root | path join "runtime") }
		_         => { error make { msg: $"bayt where: unknown target '($target)' (want root|runtime)" } }
	}
}
