# cache_hit_integration_test.nu — end-to-end registry-cache hit guard.
#
# Models the bayt synthetic-stage cache topology against a real local
# `registry:2` (the `type=registry` backend the generator targets; the GHA
# backend can't be simulated but shares the #bakeCacheRefs codepath) and asserts
# the consumer build caches 100% from the SECOND run on — using the exact
# RUN/ADD-vertex hit model sayt/summary computes.
#
# Two _srcs synthetics (proja, projb) are built on TWO SEPARATE buildkits (the
# cross-bake the generator's two-bake flow creates), each exporting its cache,
# then a consumer on a FRESH buildkit per run COPY --from's both and RUNs.
#
# This is a POSITIVE guard for the end-to-end registry-cache path: it proves a
# synthetic built on one buildkit, exported, and re-imported by a consumer on a
# fresh buildkit warms to 100%. It catches the cache chain going dark — caching
# disabled, an export that doesn't round-trip, tags a consumer can't import.
#
# It does NOT distinguish the project-qualified tag from the bare stage tag
# (`SCHEME=bare`): with sequential writers buildkit MERGES both into a shared tag
# (`mode=max` + `cache-from`), so both reach 100% here. The bare-tag failure is a
# *concurrent*-write race (registry `PUT` is last-write-wins, not atomic), which
# a single-runner test can't reproduce. The tag scheme and the per-stage cache
# mode are unit-guarded by D11 in docker_compose_check.cue. `SCHEME=bare` flips
# the tag scheme for manual concurrency experiments.
#
# Names and the registry port are randomized per invocation so concurrent runs
# don't collide. No docker guard: this is an integration test; it fails if
# docker is absent.

const FE = "docker/dockerfile:1.24@sha256:87999aa3d42bdc6bea60565083ee17e86d1f3339802f543c0d03998580f9cb89"
const BB = "busybox:musl@sha256:03db190ed4c1ceb1c55d179a0940e2d71d42130636a780272629735893292223"

# A project's _srcs synthetic: busybox _ctxs (COPY --parents + mtime clamp)
# flattened FROM scratch — the generator's shape. (r##'…'## so the leading
# `# syntax=` line survives nu's raw-string parser.)
def srcs-dockerfile [proj: string]: nothing -> string {
  (r##'# syntax=__FE__
FROM __BB__ AS ctxs
WORKDIR /monorepo
COPY --parents __PROJ__/app.txt ./
ARG SOURCE_DATE_EPOCH
RUN touch -hd @${SOURCE_DATE_EPOCH:-0} /tmp/ref && find /monorepo -newer /tmp/ref -exec touch -hd @${SOURCE_DATE_EPOCH:-0} {} + && rm /tmp/ref
FROM scratch AS __PROJ___srcs
COPY --from=ctxs /monorepo /monorepo
'##
  | str replace --all "__FE__" $FE | str replace --all "__BB__" $BB
  | str replace --all "__PROJ__" $proj)
}

# Consumer: COPY --from each synthetic with --parents, then a RUN (the step the
# cascade kills first).
def consumer-dockerfile []: nothing -> string {
  (r##'# syntax=__FE__
FROM __BB__ AS C
WORKDIR /monorepo
COPY --from=proja_srcs --parents /monorepo/proja/app.txt /
COPY --from=projb_srcs --parents /monorepo/projb/app.txt /
RUN echo CONSUMER_RUN && cat /monorepo/proja/app.txt /monorepo/projb/app.txt > /dev/null
'##
  | str replace --all "__FE__" $FE | str replace --all "__BB__" $BB)
}

# bake.hcl. SCHEME=qualified → per-project tags; SCHEME=bare → shared (clobber).
def bake-hcl [reg: string]: nothing -> string {
  (r#'variable "SCHEME" { default = "qualified" }
target "proja_srcs" {
  dockerfile = "Dockerfile.proja_srcs"
  target     = "proja_srcs"
  cache-from = ["type=registry,ref=__REG__:${SCHEME == "bare" ? "shared-srcs" : "shared-proja-srcs"}"]
  cache-to   = ["type=registry,ref=__REG__:${SCHEME == "bare" ? "shared-srcs" : "shared-proja-srcs"},mode=max,image-manifest=true,oci-mediatypes=true"]
}
target "projb_srcs" {
  dockerfile = "Dockerfile.projb_srcs"
  target     = "projb_srcs"
  cache-from = ["type=registry,ref=__REG__:${SCHEME == "bare" ? "shared-srcs" : "shared-projb-srcs"}"]
  cache-to   = ["type=registry,ref=__REG__:${SCHEME == "bare" ? "shared-srcs" : "shared-projb-srcs"},mode=max,image-manifest=true,oci-mediatypes=true"]
}
target "C" {
  dockerfile = "Dockerfile.C"
  target     = "C"
  contexts   = { proja_srcs = "target:proja_srcs", projb_srcs = "target:projb_srcs" }
  cache-from = ["type=registry,ref=__REG__:proj-C"]
  cache-to   = ["type=registry,ref=__REG__:proj-C,mode=max,image-manifest=true,oci-mediatypes=true"]
}
group "default" { targets = ["C"] }
'#
  | str replace --all "__REG__" $reg)
}

# Existence checks: a failing check surfaces a real docker problem loudly,
# rather than a blanket ignore-errors hiding it.
def bldr-exists [bld: string]: nothing -> bool {
  ((^docker buildx ls --format "{{.Name}}") | lines | any { ($in | str trim) == $bld })
}

def fresh-builder [bld: string]: nothing -> nothing {
  if (bldr-exists $bld) { ^docker buildx rm $bld o> /dev/null e> /dev/null }
  ^docker buildx create --name $bld --driver docker-container --driver-opt network=host o> /dev/null e> /dev/null
  ^docker buildx inspect --bootstrap $bld o> /dev/null e> /dev/null
}

# Build one bake target on a FRESH builder (no local cache, registry import
# only). Each synthetic is built in its own bake — like a separate CI job —
# so the cache-to is a separate registry export. That's what surfaces the
# bare-tag clobber: two projects writing one shared tag overwrite each other
# (a within-one-bake build merges them and hides it).
def bake-target [work: string, bld: string, target: string]: nothing -> record {
  fresh-builder $bld
  # The consumer bake rebuilds the synthetics (federated via target:); it must
  # READ their caches but not re-export them, or it re-clobbers the shared tag
  # and the registry state stops reflecting the two separate synthetic bakes.
  let extra = (if $target == "C" {
    ["--set" "proja_srcs.cache-to=" "--set" "projb_srcs.cache-to="]
  } else { [] })
  (with-env {SOURCE_DATE_EPOCH: "0"} {
    do { ^docker buildx bake --builder $bld -f $"($work)/bake.hcl" --set $"*.context=($work)" ...$extra --progress=rawjson $target } | complete
  })
}

# hit% over RUN/ADD vertices, exactly as sayt/summary: group_by(.name),
# hit = any event in the group cached.
def hit-stats [rawfile: string]: nothing -> record {
  let filter = '[.[].vertexes[]?]
    | map(select((.name // "") | test("^\\[[^\\]]+ [0-9]+/[0-9]+\\] (RUN|ADD) ")))
    | group_by(.name)
    | map({cached: (any(.[]; .cached == true))})
    | {total: length, hit: (map(select(.cached)) | length)}'
  (open --raw $rawfile | lines | where ($it | str starts-with "{") | str join "\n"
    | ^jq -s $filter | from json)
}

def cont-exists [name: string]: nothing -> bool {
  ((^docker ps -aq --filter $"name=^($name)$") | str trim | is-not-empty)
}
def teardown [reg_name: string, builders: list<string>, work: string]: nothing -> nothing {
  if (cont-exists $reg_name) { ^docker rm -f $reg_name o> /dev/null e> /dev/null }
  for b in $builders { if (bldr-exists $b) { ^docker buildx rm $b o> /dev/null e> /dev/null } }
  rm -rf $work
}
def fail [reg_name: string, builders: list<string>, work: string, msg: string, stderr: string] {
  teardown $reg_name $builders $work
  print $msg
  print ($stderr | lines | where ($it !~ '^\{') | str join "\n" | str substring 0..2000)
  exit 1
}

def main [] {
  let id = (random chars --length 10 | str downcase)
  let reg_name = $"bayt-cache-it-reg-($id)"
  let bk1 = $"bayt-cache-it-bk1-($id)"   # synthetic A's buildkit
  let bk2 = $"bayt-cache-it-bk2-($id)"   # synthetic B's buildkit (separate)
  let bkc = $"bayt-cache-it-bkc-($id)"   # consumer buildkit (fresh per run)
  let builders = [$bk1, $bk2, $bkc]

  let work = (mktemp -d)
  mkdir $"($work)/proja" $"($work)/projb"
  "alpha-content\n" | save -f $"($work)/proja/app.txt"
  "beta-content\n"  | save -f $"($work)/projb/app.txt"
  (srcs-dockerfile "proja") | save -f $"($work)/Dockerfile.proja_srcs"
  (srcs-dockerfile "projb") | save -f $"($work)/Dockerfile.projb_srcs"
  (consumer-dockerfile) | save -f $"($work)/Dockerfile.C"

  # registry on a random host port (discovered, so parallel runs don't collide)
  ^docker run -d --name $reg_name -p "127.0.0.1::5000" registry:2 o> /dev/null e> /dev/null
  let port = ((^docker port $reg_name "5000/tcp") | lines | first | parse "{ip}:{port}" | get port.0 | str trim)
  (bake-hcl $"localhost:($port)/cache") | save -f $"($work)/bake.hcl"
  sleep 1sec

  # Seed the two synthetics on TWO SEPARATE buildkits — the cross-bake the
  # clobber needs: one shared registry tag with two distinct writers (a single
  # bake building both would merge them and hide the clobber).
  let sa = (bake-target $work $bk1 "proja_srcs")
  if $sa.exit_code != 0 { fail $reg_name $builders $work "seed proja_srcs failed:" $sa.stderr }
  let sb = (bake-target $work $bk2 "projb_srcs")
  if $sb.exit_code != 0 { fail $reg_name $builders $work "seed projb_srcs failed:" $sb.stderr }

  # Three consumer runs on a FRESH buildkit each (no local cache → registry
  # import only). It reads the seeded synthetic caches; warm must be 100%.
  mut pcts = []
  for run in 1..3 {
    let r = (bake-target $work $bkc "C")
    if $r.exit_code != 0 { fail $reg_name $builders $work $"consumer run ($run) failed:" $r.stderr }
    let raw = $"($work)/run($run).json"
    $r.stderr | save -f $raw
    let s = (hit-stats $raw)
    let pct = (if $s.total > 0 { ($s.hit * 100 / $s.total) } else { 0 })
    $pcts = ($pcts | append $pct)
    print $"run ($run): consumer ($s.hit)/($s.total) RUN/ADD steps cached \(($pct)%\)"
  }
  teardown $reg_name $builders $work

  # Assert 100% from the second run on (the first is cold).
  let warm = ($pcts | skip 1)
  if ($warm | all { $in == 100 }) {
    print "PASS cache_hit: 100% from run 2 on"
    exit 0
  } else {
    print $"FAIL cache_hit: expected 100% from run 2 on, got ($pcts)"
    exit 1
  }
}
