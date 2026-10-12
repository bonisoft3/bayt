// sayt_ci_check.cue — guards on the ci RUN body.
package sayt

import "strings"

// The fixtures below carry a `:srcs` dep because ci requires one; it is
// incidental to the RUN-body invariants each one checks.

// --- C3: ci loads its closure file, never the user root — the closure is
// the exact fragment set the ci layer carries; the hand-authored root (and the
// federation root it includes) need not exist in-layer. Its inner stack is
// `${BKID_PROJECT}_<check>`: apart from the caller's launch stack and from
// other checkouts', torn down before (a crashed run's leftovers) and after.
_c3_both_do: (ci & {name: "c3", project: "p", dir: "d", deps: [":integrate:srcs"]}).cmd.builtin.do
_c3_closure:  strings.Contains(_c3_both_do, "f=.bayt/compose.integrate.closure.yaml") & true
_c3_named:    strings.Contains(_c3_both_do, "p=\"${BKID_PROJECT}_integrate\"") & true
_c3_flatten:  strings.Contains(_c3_both_do, "docker compose -p \"$p\" --profile '*' -f \"$f\" config") & true
_c3_up:       strings.Contains(_c3_both_do, "docker compose -p \"$p\" --profile '*' -f \"$f\" up bayt") & true
_c3_down:     len(strings.Split(_c3_both_do, "-f \"$f\" down -v")) & 3
_c3_unnamed:  strings.Contains(_c3_both_do, "BKID_PROJECT is unset") & true
_c3_check_do: (ci & {name: "c3", project: "p", dir: "d", deps: [":check-window:srcs"], #closure: "check-window", #check: "window"}).cmd.builtin.do
_c3_check_closure: strings.Contains(_c3_check_do, "f=.bayt/compose.check-window.closure.yaml") & true
_c3_check_named:   strings.Contains(_c3_check_do, "p=\"${BKID_PROJECT}_window\"") & true

// --- C2: dev mode must NOT get --no-build — only `bayt` is a named bake
// target, so compose builds the deps at up time.
_c2_both_do: (ci & {name: "c2", project: "p", dir: "d", deps: [":integrate:srcs"]}).cmd.builtin.do
_c2_builds: strings.Contains(_c2_both_do, "--no-build") & false

// --- C4: the in-layer bake targets `bayt`, and `up --build` builds what it
// starts, so it never runs a stale image a dependency left as cache. A
// closure that unions every target holds services `up bayt` never starts (a
// RUN-only test), so baking the whole closure is wrong too. No bake HCL and
// no `[ -f … ]` fallback choosing between targets: depot-build names federated
// services, which exist only in a user-root flatten, and bake.hcl's
// `target "release"` binds `tags = [IMAGE]`, stripping every matrix member's
// compose-supplied tag.
_c4_both_do: (ci & {name: "c4", project: "p", dir: "d", deps: [":integrate:srcs"]}).cmd.builtin.do
_c4_alias:  strings.Contains(_c4_both_do, "--print bayt | $bake") & true
_c4_fresh:  strings.Contains(_c4_both_do, "up bayt --build ") & true
_c4_no_hcl: strings.Contains(_c4_both_do, ".hcl") & false
