# Docker Hub pulls through mirror.gcr.io. A CI runner shares its IP's
# anonymous Docker Hub quota with everyone else on it, and a 429 there fails a
# suite that has nothing wrong with it.

# A buildkitd config whose docker.io pulls go through the mirror, for
# `docker buildx create --buildkitd-config`.
export def buildkitd-config []: nothing -> string {
  let cfg = (mktemp --tmpdir --suffix .toml)
  "[registry.\"docker.io\"]\n  mirrors = [\"mirror.gcr.io\"]\n" | save -f $cfg
  $cfg
}
