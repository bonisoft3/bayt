// deno_check.cue — dogfood check for stacks/deno fragments.
package deno

import "strings"

_storePin:  storeMount & {type: "cache", target: "/deno-store", scope: "target"}
_duckdbPin: duckdbMount & {type: "cache", target: "/duckdb-store", scope: "target"}

// The container script must wrap the whole two-phase body in `sh -c '...'` so
// a target's `activate` (`mise x --`) wraps the subshell rather than only the
// first variable assignment, and must escape embedded single quotes.
_quotedCmd: (#cmd & {
	do:    "deno eval 'console.log(1)'"
	shell: "sh"
}).out

_quotedPin: {
	hostDo:  _quotedCmd.do & "deno eval 'console.log(1)'"
	hasShC:  strings.HasPrefix(_quotedCmd.dockerfile.do, "sh -c '") & true
	hasSeed: strings.Contains(_quotedCmd.dockerfile.do, #"cp -a "$s/$k/$sub"/. "$d/$sub"/"#) & true
	hasPub:  strings.Contains(_quotedCmd.dockerfile.do, #"mv "$t" "$s/$k""#) & true
	mounts:  _quotedCmd.dockerfile.mounts & [storeMount]
}
