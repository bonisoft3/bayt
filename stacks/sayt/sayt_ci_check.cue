// sayt_ci_check.cue — guards on the ci / ciRun RUN bodies.
package sayt

import "strings"

// --- C1: the run phase's `up` is pull-only. --no-build is load-bearing:
// docker compose force-builds `service:` additional_contexts refs (the
// _srcs/_outs synthetics) even under pull_policy=missing and with the
// image pullable, so dropping the flag rebuilds the federated closure
// inside the run phase's dindbox.
_c1_run_do: (ciRun & {name: "c1", project: "p", dir: "d"}).cmd.builtin.do
_c1_no_build: strings.Contains(_c1_run_do, "docker compose --profile '*' -f .bayt/compose.integrate.closure.yaml up bayt --no-build") & true
_c1_pull: strings.Contains(_c1_run_do, "BAYT_PULL_POLICY=missing") & true

// --- C3: both phases load the integrate closure file, never the user
// root — the closure is the exact fragment set the ci layer carries;
// the hand-authored root (and the federation root it includes) need
// not exist in-layer.
_c3_both_do: (ci & {name: "c3", project: "p", dir: "d"}).cmd.builtin.do
_c3_closure_flatten: strings.Contains(_c3_both_do, "docker compose --profile '*' -f .bayt/compose.integrate.closure.yaml config") & true
_c3_closure_up: strings.Contains(_c3_both_do, "docker compose --profile '*' -f .bayt/compose.integrate.closure.yaml up bayt") & true

// --- C2: dev mode must NOT get --no-build — only `bayt` is a named bake
// target, so compose builds the deps at up time.
_c2_both_do: (ci & {name: "c2", project: "p", dir: "d"}).cmd.builtin.do
_c2_builds: strings.Contains(_c2_both_do, "--no-build") & false

// --- C4: the in-layer bake targets `bayt` unconditionally — no bake HCL,
// and no `[ -f … ]` fallback choosing between two targets. depot-build names
// federated services, which exist only in a user-root flatten; this pipeline
// flattens the closure file, whose print is the single `bayt` alias, so
// naming the group here fails to resolve. bake.hcl is doubly wrong: its
// `target "release"` binds `tags = [IMAGE]`, stripping every matrix member's
// compose-supplied tag.
_c4_both_do: (ci & {name: "c4", project: "p", dir: "d"}).cmd.builtin.do
_c4_alias:  strings.Contains(_c4_both_do, "--print bayt | $bake") & true
_c4_no_hcl: strings.Contains(_c4_both_do, ".hcl") & false
