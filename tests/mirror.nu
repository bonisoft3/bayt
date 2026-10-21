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

export def load-image [ref: string]: nothing -> string {
  let parts = ($ref | split row "@sha256:")
  let tag = if ($parts | length) > 1 {
    let sep = if (($parts.0 | split row "/" | last) | str contains ":") { "-" } else { ":" }
    $"($parts.0)($sep)($parts.1 | str substring 0..<12)"
  } else { $ref }
  if ((do { ^docker image inspect $tag } | complete).exit_code != 0) {
    $"FROM ($ref)\n" | ^docker buildx build --quiet --load -t $tag - | ignore
  }
  $tag
}
