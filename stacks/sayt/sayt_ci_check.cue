// sayt_ci_check.cue — guards on the ci / ciRun RUN bodies.
package sayt

import "strings"

// --- C1: the run phase's `up` is pull-only. --no-build is load-bearing:
// docker compose force-builds `service:` additional_contexts refs (the
// _srcs/_outs synthetics) even under pull_policy=missing and with the
// image pullable, so dropping the flag rebuilds the federated closure
// inside the run phase's dindbox.
_c1_run_do: (ciRun & {name: "c1", project: "p", dir: "d"}).cmd.builtin.do
_c1_no_build: strings.Contains(_c1_run_do, "docker compose -f .bayt/compose.integrate.closure.yaml up bayt --no-build") & true
_c1_pull: strings.Contains(_c1_run_do, "BAYT_PULL_POLICY=missing") & true

// --- C3: both phases load the integrate closure file, never the user
// root — the closure is the exact fragment set the ci layer carries;
// the hand-authored root (and the federation root it includes) need
// not exist in-layer.
_c3_both_do: (ci & {name: "c3", project: "p", dir: "d"}).cmd.builtin.do
_c3_closure_flatten: strings.Contains(_c3_both_do, "docker compose -f .bayt/compose.integrate.closure.yaml config") & true
_c3_closure_up: strings.Contains(_c3_both_do, "docker compose -f .bayt/compose.integrate.closure.yaml up bayt") & true

// --- C2: dev mode must NOT get --no-build — without .bayt/depot.hcl
// only `integrate` is a named bake target and compose builds the deps
// at up time.
_c2_both_do: (ci & {name: "c2", project: "p", dir: "d"}).cmd.builtin.do
_c2_builds: strings.Contains(_c2_both_do, "--no-build") & false
