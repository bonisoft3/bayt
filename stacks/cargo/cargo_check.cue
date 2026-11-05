// cargo_check.cue — dogfood check for stacks/cargo fragments.
package cargo

import "strings"

// Registry and git mounts must be project-scoped (`sharing=locked`): Cargo's
// `.package-cache` lockfile sits in `/root/.cargo/.package-cache`, outside
// both subdirectories, so global `sharing=shared` would let concurrent stages
// race on in-place unpacks into `registry/src`.
_registryScopePin: registryMount & {type: "cache", target: "/root/.cargo/registry", scope: "project"}
_gitScopePin:      gitMount & {type: "cache", target: "/root/.cargo/git", scope: "project"}
_crateStorePin:    crateStore & {type: "cache", target: "/cargo-crate-store", scope: "global"}

_lockFlagPin: lockFlag & "--locked"

// The two-phase fetch script must wrap in `sh -c '...'` (so `mise x --` covers
// the whole subshell) and publish `.crate` archives via atomic `mktemp` + `mv`.
_fetchScriptPin: {
	hasShC:    strings.HasPrefix(_fetchScript, "sh -c '") & true
	hasFetch:  strings.Contains(_fetchScript, "cargo fetch --locked; rc=$?") & true
	hasStub:   strings.Contains(_fetchScript, "if [ ! -e src ]; then stub=1") & true
	hasAtomic: strings.Contains(_fetchScript, #"mktemp "$(dirname "$o")/.pXXXXXX""#) & true
}
