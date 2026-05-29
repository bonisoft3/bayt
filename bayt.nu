#!/usr/bin/env nu

use runtime/generate.nu

# Walk bayt.cue and emit .bayt/* artifacts.
def "main generate" [--recursive (-r)] {
	if $recursive { generate --recursive } else { generate }
}

# Restore-or-run a target cmd under the content-addressable cache.
def --wrapped "main cache run" [...args] {
	use runtime/cache.nu
	cache main run ...$args
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

# Print install location: bayt's root (default) or its runtime/ dir.
def "main where" [target: string = "root"] {
	use runtime/where.nu
	where $target
}

# bayt — declarative build target generator.
def main [] {
	print (help main)
}
