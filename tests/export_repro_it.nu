#!/usr/bin/env nu
# export_repro_it.nu — what actually makes a pushed leaf's digest reproducible.
#
# A leaf is exported once per commit and its manifest is the identity consumers
# and any content-addressed skip both key on. Two exporter settings claim to
# protect that identity, and they are not equals:
#
#   rewrite-timestamp  normalises layer mtimes at export
#   attestations       add provenance/SBOM manifests to the index
#
# The bayt pipeline already clamps mtimes INSIDE the build (`_ctxs` stage),
# and `COPY --from` carries the clamped mtimes through the `_srcs` flatten into
# the leaf — so the export has nothing left to normalise. This asserts that
# directly, over the 2x2 of both settings, with host mtimes floated between the
# two builds of each cell the way a fresh checkout floats them.
#
# Asserts, per cell: digest stable iff attestations are off — rewrite-timestamp
# does not appear in the condition. Attestations carry a build timestamp, so
# they drift the index on their own and no exporter attr can hold it still.
#
# Randomised names, so concurrent runs don't collide.

const FE = "docker/dockerfile:1.26@sha256:ecfaec9ed6d810b56388c508f4121597bfbba70d41a6dfeee4d8cad5f295fc32"
const BB = "busybox:musl@sha256:03db190ed4c1ceb1c55d179a0940e2d71d42130636a780272629735893292223"

# One clamp RUN, mirroring _clampFlatten's emission (kept in sync by hand — the
# shape is what's under test, so drift here is a real signal, not noise).
def clampline [wd: string, anc: string]: nothing -> string {
  $'RUN if [ "${BAYT_CLAMP:-1}" != 0 ]; then find ($wd) -exec touch -hd @${SOURCE_DATE_EPOCH:-0} {} + && touch -hd @${SOURCE_DATE_EPOCH:-0} ($anc); fi'
}

# The leaf deliberately does NOT clamp: it inherits already-clamped mtimes
# through `COPY --from`, which is the property the export is being asked to
# make redundant.
def dockerfile []: nothing -> string {
  let c = (clampline "/monorepo/app" "/monorepo")
  $"# syntax=($FE)
FROM ($BB) AS app_ctxs
WORKDIR /monorepo/app
COPY --parents src.txt ./
ARG SOURCE_DATE_EPOCH
ARG BAYT_CLAMP=1
($c)
FROM scratch AS app_srcs
COPY --from=app_ctxs /monorepo /monorepo

FROM ($BB) AS app_launch
COPY --from=app_srcs /monorepo /monorepo
CMD [\"/bin/sh\"]
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

# Export app_launch to an OCI layout and return the index digest — the identity
# a registry would serve. --no-cache forces the COPY to re-read the (touched)
# context, so a floating mtime actually reaches the layer instead of being
# hidden by content-keyed cache.
def build-digest [
  work: string, bld: string, out: string, prov: string, rwts: string
]: nothing -> string {
  let attrs = if $rwts == "1" { ",rewrite-timestamp=true" } else { "" }
  (with-env {SOURCE_DATE_EPOCH: "0"} {
    (^docker buildx build --builder $bld --no-cache
      -f $"($work)/Dockerfile" --target app_launch
      --provenance $"($prov == '1' | into string | str downcase)"
      --sbom=false
      --output $"type=oci,dest=($out),tar=false($attrs)" $work) o> /dev/null e> /dev/null
  })
  (open --raw $"($out)/index.json" | from json | get manifests.0.digest)
}

# Build twice with host mtimes bumped in between, the way a fresh checkout
# floats them. Returns [d1, d2].
def two-builds [work: string, bld: string, cell: string, prov: string, rwts: string]: nothing -> list<string> {
  let d1 = (build-digest $work $bld $"($work)/oci-($cell)-1" $prov $rwts)
  ^touch $"($work)/src.txt"
  let d2 = (build-digest $work $bld $"($work)/oci-($cell)-2" $prov $rwts)
  [$d1, $d2]
}

def main [] {
  let id = (random chars --length 8 | str downcase)
  let work = (mktemp -d)
  "app-payload\n" | save -f $"($work)/src.txt"
  (dockerfile) | save -f $"($work)/Dockerfile"
  let bld = $"export-repro-($id)"
  fresh-builder $bld

  print "Running bayt export-reproducibility matrix...\n"
  print "  attest  rwts  stable  digests"

  # stable iff attestations are off — rewrite-timestamp is absent from the
  # condition, which is the whole claim.
  let cells = [
    {name: "A", prov: "1", rwts: "1", want: false}
    {name: "B", prov: "0", rwts: "1", want: true}
    {name: "C", prov: "1", rwts: "0", want: false}
    {name: "D", prov: "0", rwts: "0", want: true}
  ]

  for c in $cells {
    let d = (two-builds $work $bld $c.name $c.prov $c.rwts)
    let stable = ($d.0 == $d.1)
    let mark = if $stable { "yes" } else { "NO " }
    print $"  ($c.prov)       ($c.rwts)     ($mark)     ($d.0 | str substring 0..18) | ($d.1 | str substring 0..18)"
    if $stable != $c.want {
      let expected = if $c.want { "stable" } else { "drifting" }
      fail $bld $work $"\nFAIL export_repro cell ($c.name) \(provenance=($c.prov) rewrite-timestamp=($c.rwts)): expected ($expected), got the opposite.\n  ($d.0)\n  ($d.1)"
    }
  }

  cleanup $bld $work
  print "\nAll bayt export-reproducibility cells behaved as asserted!"
}
