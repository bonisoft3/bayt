# diamond_dedup_integration_test.nu — end-to-end "expensive bottom runs once" guard.
#
# Models a true DIAMOND against a real buildkit:
#
#         top              consumes both arms, compares the two markers
#        /    \
#       A      B           each COPY --from the shared bottom
#        \    /
#        bottom            the "expensive" node — emits a NON-deterministic marker
#
# Each node is a SEPARATE per-target Dockerfile federated via `contexts =
# {bottom = "target:bottom"}` — the exact cross-target shape bayt's generator
# emits (and the same federation the cache-hit test models for the fan-in case).
# A single multi-stage Dockerfile would dedup trivially; the interesting bayt
# regression hides in the per-target federation.
#
# HOW "RUNS ONCE" IS PROVEN (soundly):
#   bottom's RUN writes a RANDOM marker (/dev/urandom). Both arms COPY it; `top`
#   diffs the two copies.
#     - bottom executed ONCE  → both arms see the same random marker → diff passes
#                               → bake exits 0.
#     - bottom executed TWICE → two different random markers → diff fails
#                               → bake exits non-zero.
#   So `bake exit 0` <=> the expensive bottom ran exactly once. The marker being
#   non-deterministic is what makes this airtight: two separate executions cannot
#   coincidentally agree.
#
# WHAT IT GUARDS (the bayt-relevant part):
#   buildkit dedups a shared `target:` subgraph by CACHE KEY. The realistic way
#   bayt could break "runs once" is injecting an arm-specific input (a
#   per-consumer build-arg, label, or context) into the otherwise-shared bottom
#   stage — that splits the cache key and forces a second execution of the
#   expensive node. This test fails loudly if that regresses.
#
# SECONDARY STRUCTURAL ASSERTION:
#   parses --progress=rawjson and asserts the bottom RUN resolves to exactly ONE
#   distinct vertex digest — a direct dedup count with a clearer diagnostic than
#   a bare build failure.
#
# LIMITATION: like the cache-hit test, this hand-writes the bake.hcl modeling the
# shape bayt emits, not bayt's generator output. It guards "the federated-target:
# diamond dedups", not "bayt's generated diamond project dedups". Driving the
# generator is a larger follow-up.
#
# Names are randomized per invocation so concurrent runs don't collide. No docker
# guard: this is an integration test; it fails if docker is absent.

const FE = "docker/dockerfile:1.24@sha256:87999aa3d42bdc6bea60565083ee17e86d1f3339802f543c0d03998580f9cb89"
const BB = "busybox:musl@sha256:03db190ed4c1ceb1c55d179a0940e2d71d42130636a780272629735893292223"

# The expensive shared bottom. Both arms reference this single target, so its
# cache key is identical down both — buildkit runs it once. The RUN is
# non-deterministic (/dev/urandom) so a hypothetical second execution would
# diverge, which is what makes the marker comparison a sound single-run proof.
def bottom-dockerfile []: nothing -> string {
  (r##'# syntax=__FE__
FROM __BB__ AS bottom
RUN echo BOTTOM_EXPENSIVE && head -c 16 /dev/urandom | sha256sum | cut -c1-16 > /marker
'##
  | str replace --all "__FE__" $FE | str replace --all "__BB__" $BB)
}

# An arm: COPY the marker out of the federated `bottom` context. `slot` names the
# output file so `top` can tell the two arms apart.
def arm-dockerfile [stage: string, slot: string]: nothing -> string {
  (r##'# syntax=__FE__
FROM __BB__ AS __STAGE__
COPY --from=bottom /marker /__SLOT__.marker
'##
  | str replace --all "__FE__" $FE | str replace --all "__BB__" $BB
  | str replace --all "__STAGE__" $stage | str replace --all "__SLOT__" $slot)
}

# top: pull both arms' markers and diff them. diff exits non-zero (build fails)
# iff the two markers differ — i.e. iff bottom ran more than once.
def top-dockerfile []: nothing -> string {
  (r##'# syntax=__FE__
FROM __BB__ AS top
COPY --from=arma /a.marker /a.marker
COPY --from=armb /b.marker /b.marker
RUN echo TOP_COMPARE && diff /a.marker /b.marker
'##
  | str replace --all "__FE__" $FE | str replace --all "__BB__" $BB)
}

# bake.hcl. Both arms reference one `target:bottom`, so buildkit dedups it to a
# single vertex — the diamond's whole point.
def bake-hcl []: nothing -> string {
  r#'target "bottom" {
  dockerfile = "Dockerfile.bottom"
  target     = "bottom"
}
target "arma" {
  dockerfile = "Dockerfile.arma"
  target     = "arma"
  contexts   = { bottom = "target:bottom" }
}
target "armb" {
  dockerfile = "Dockerfile.armb"
  target     = "armb"
  contexts   = { bottom = "target:bottom" }
}
target "top" {
  dockerfile = "Dockerfile.top"
  target     = "top"
  contexts   = { arma = "target:arma", armb = "target:armb" }
}
group "default" { targets = ["top"] }
'#
}

# Existence checks: a failing check surfaces a real docker problem loudly.
def bldr-exists [bld: string]: nothing -> bool {
  ((^docker buildx ls --format "{{.Name}}") | lines | any { ($in | str trim) == $bld })
}

def fresh-builder [bld: string]: nothing -> nothing {
  if (bldr-exists $bld) { ^docker buildx rm $bld o> /dev/null e> /dev/null }
  ^docker buildx create --name $bld --driver docker-container --driver-opt network=host o> /dev/null e> /dev/null
  ^docker buildx inspect --bootstrap $bld o> /dev/null e> /dev/null
}

# Build the diamond's `top` target on a FRESH builder (no local cache → bottom
# actually executes cold, so a duplicate would genuinely re-run, not warm-hit).
def bake-top [work: string, bld: string]: nothing -> record {
  fresh-builder $bld
  (do {
    ^docker buildx bake --builder $bld -f $"($work)/bake.hcl" --set $"*.context=($work)" --progress=rawjson top
  } | complete)
}

# Count DISTINCT bottom-RUN vertex digests from rawjson. One digest == ran once;
# two == the cache key split and the expensive node ran twice. Digest (not name)
# because two divergent executions can share a name prefix but never a digest.
def bottom-run-digests [rawfile: string]: nothing -> int {
  let filter = '[.[].vertexes[]?]
    | map(select((.name // "") | test("RUN .*BOTTOM_EXPENSIVE")))
    | [.[].digest] | unique | length'
  (open --raw $rawfile | lines | where ($it | str starts-with "{") | str join "\n"
    | ^jq -s $filter | into int)
}

def teardown [builders: list<string>, work: string]: nothing -> nothing {
  for b in $builders { if (bldr-exists $b) { ^docker buildx rm $b o> /dev/null e> /dev/null } }
  rm -rf $work
}
def fail [builders: list<string>, work: string, msg: string, stderr: string] {
  teardown $builders $work
  print $msg
  print ($stderr | lines | where ($it !~ '^\{') | str join "\n" | str substring 0..2000)
  exit 1
}

def main [] {
  let id  = (random chars --length 10 | str downcase)
  let bld = $"bayt-diamond-it-bk-($id)"
  let builders = [$bld]

  let work = (mktemp -d)
  (bottom-dockerfile)        | save -f $"($work)/Dockerfile.bottom"
  (arm-dockerfile "arma" "a") | save -f $"($work)/Dockerfile.arma"
  (arm-dockerfile "armb" "b") | save -f $"($work)/Dockerfile.armb"
  (top-dockerfile)           | save -f $"($work)/Dockerfile.top"
  (bake-hcl)                 | save -f $"($work)/bake.hcl"

  let r = (bake-top $work $bld)
  let raw = $"($work)/top.json"
  $r.stderr | save -f $raw

  # Behavioral proof: the in-build diff fails (non-zero exit) iff the two arms saw
  # different random markers, i.e. iff the expensive bottom ran more than once.
  if $r.exit_code != 0 {
    fail $builders $work "FAIL diamond_dedup: top diff failed — the two arms saw DIFFERENT markers, so the expensive bottom ran more than once." $r.stderr
  }

  # Structural proof: the bottom RUN must be exactly one distinct vertex.
  let digests = (bottom-run-digests $raw)
  teardown $builders $work

  if $digests == 1 {
    print "PASS diamond_dedup: expensive bottom ran exactly once (1 RUN vertex, markers identical down both arms)"
    exit 0
  } else {
    print $"FAIL diamond_dedup: expected 1 bottom RUN vertex, found ($digests) — the shared bottom was duplicated."
    exit 1
  }
}
