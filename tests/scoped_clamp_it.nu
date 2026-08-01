# scoped_clamp_it.nu — guards the scoped mtime clamp in
# gen_compose.cue `_clampFlatten`: a nested-dir synthetic's flattened
# `FROM scratch` stage must have a REPRODUCIBLE digest (the identity that
# service-graph dedup and the registry cache key rely on).
#
# Only nested-dir projects exercise the scoping — the other integration tests
# build root projects (workdir == /monorepo), where `find /monorepo/<dir>`
# degenerates to the whole tree. Here a consumer at /monorepo/a/b pulls two deps
# under a shared parent /monorepo/x. Neither dep subtree nor /monorepo/x is in
# the consumer's clamp scope ({/monorepo, /monorepo/a} + the a/b walk); they must
# stay at EPOCH on their own via `COPY --from`, which preserves the dep stages'
# already-clamped mtimes even when the second copy merges into /monorepo/x.
# Asserts: (1) clamp on → digest identical across two builds with floated host
# mtimes; (2) clamp off (BAYT_CLAMP=0) → digests differ, proving the clamp (not
# SOURCE_DATE_EPOCH alone, set in both runs) is what makes it reproducible —
# i.e. the test isn't vacuous, and the toggle actually disables the clamp.
#
# Randomised names, so concurrent runs don't collide.

const FE = "docker/dockerfile:1.24@sha256:87999aa3d42bdc6bea60565083ee17e86d1f3339802f543c0d03998580f9cb89"
const BB = "busybox:musl@sha256:03db190ed4c1ceb1c55d179a0940e2d71d42130636a780272629735893292223"

# One clamp RUN, mirroring _clampFlatten's emission (kept in sync by hand — the
# shape is what's under test, so drift here is a real signal, not noise).
def clampline [wd: string, anc: string]: nothing -> string {
  $'RUN if [ "${BAYT_CLAMP:-1}" != 0 ]; then find ($wd) -exec touch -hd @${SOURCE_DATE_EPOCH:-0} {} + && touch -hd @${SOURCE_DATE_EPOCH:-0} ($anc); fi'
}
def dockerfile []: nothing -> string {
  let d1 = (clampline "/monorepo/x/dep1" "/monorepo /monorepo/x")
  let d2 = (clampline "/monorepo/x/dep2" "/monorepo /monorepo/x")
  let ab = (clampline "/monorepo/a/b"    "/monorepo /monorepo/a")
  $"# syntax=($FE)
FROM ($BB) AS dep1_ctxs
WORKDIR /monorepo/x/dep1
COPY --parents d1.txt ./
ARG SOURCE_DATE_EPOCH
ARG BAYT_CLAMP=1
($d1)
FROM scratch AS dep1_srcs
COPY --from=dep1_ctxs /monorepo /monorepo

FROM ($BB) AS dep2_ctxs
WORKDIR /monorepo/x/dep2
COPY --parents d2.txt ./
ARG SOURCE_DATE_EPOCH
ARG BAYT_CLAMP=1
($d2)
FROM scratch AS dep2_srcs
COPY --from=dep2_ctxs /monorepo /monorepo

FROM ($BB) AS ab_ctxs
WORKDIR /monorepo/a/b
COPY --parents f.txt ./
COPY --from=dep1_srcs /monorepo /monorepo
COPY --from=dep2_srcs /monorepo /monorepo
ARG SOURCE_DATE_EPOCH
ARG BAYT_CLAMP=1
($ab)
FROM scratch AS ab_srcs
COPY --from=ab_ctxs /monorepo /monorepo
"
}

def fresh-builder [bld: string]: nothing -> nothing {
  ^docker buildx create --name $bld --driver docker-container o> /dev/null e> /dev/null
  ^docker buildx inspect --bootstrap $bld o> /dev/null e> /dev/null
}
def cleanup [bld: string, work: string]: nothing -> nothing {
  ^docker buildx rm $bld o> /dev/null e> /dev/null
  rm -rf $work
}
def fail [bld: string, work: string, msg: string] {
  cleanup $bld $work
  print $msg
  exit 1
}

# Build ab_srcs to an OCI layout (no rewrite-timestamp — the export must NOT
# normalise, or it would mask whether the in-image clamp worked) and return the
# manifest digest, the reproducible identity of the flattened synthetic.
# --no-cache forces the COPY to re-read the (touched) context, so a floating
# mtime actually reaches the layer instead of being hidden by content-keyed cache.
def build-digest [work: string, bld: string, out: string, clamp: string]: nothing -> string {
  (with-env {SOURCE_DATE_EPOCH: "0"} {
    ^docker buildx build --builder $bld --no-cache -f $"($work)/Dockerfile" --target ab_srcs --build-arg $"BAYT_CLAMP=($clamp)" --output $"type=oci,dest=($out),tar=false" $work o> /dev/null e> /dev/null
  })
  (open --raw $"($out)/index.json" | from json | get manifests.0.digest)
}

# Build ab_srcs twice on `bld` with host mtimes bumped in between (simulating a
# fresh checkout whose mtimes float). Returns [d1, d2].
def two-builds [work: string, bld: string, clamp: string]: nothing -> list<string> {
  let d1 = (build-digest $work $bld $"($work)/oci-($clamp)-1" $clamp)
  ^touch $"($work)/f.txt" $"($work)/d1.txt" $"($work)/d2.txt"
  let d2 = (build-digest $work $bld $"($work)/oci-($clamp)-2" $clamp)
  [$d1, $d2]
}

def main [] {
  let id = (random chars --length 8 | str downcase)
  let work = (mktemp -d)
  "hello-a-b\n"    | save -f $"($work)/f.txt"
  "dep1-payload\n" | save -f $"($work)/d1.txt"
  "dep2-payload\n" | save -f $"($work)/d2.txt"
  (dockerfile) | save -f $"($work)/Dockerfile"
  let bld = $"scoped-clamp-($id)"
  fresh-builder $bld

  # (1) clamp on → reproducible despite floated host mtimes, two un-walked dep
  #     subtrees, and a shared non-ancestor intermediate (/monorepo/x)
  let on = (two-builds $work $bld "1")
  print $"clamp on : ($on.0) | ($on.1)"
  if $on.0 != $on.1 {
    fail $bld $work "FAIL scoped_clamp: clamp on but digests differ — a floating mtime survived the scoped walk (unclamped ancestor or dep-subtree drift)."
  }

  # (2) clamp off → digests must diverge, else the test is vacuous.
  let off = (two-builds $work $bld "0")
  print $"clamp off: ($off.0) | ($off.1)"
  if $off.0 == $off.1 {
    fail $bld $work "FAIL scoped_clamp: clamp off yet digests match — test is vacuous (host mtimes not floating, or export normalised them)."
  }

  cleanup $bld $work
  print "PASS scoped_clamp: nested-dir flatten digest reproducible under scoped clamp; floats without it"
  exit 0
}
