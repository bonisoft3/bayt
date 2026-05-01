# fingerprint.nu — content fingerprint of src patterns. nu's `glob -e`
# prunes excluded directories at walk time (crucial for node_modules-
# heavy monorepos — go-task's default globber walks everything then
# filters, taking tens of seconds on real projects).
#
# Three subcommands:
#
#   hash-check  — compute fingerprint, read stored stamp, exit 0 on
#                 match (task skipped) or non-zero on miss (task runs).
#                 Never writes. Used in go-task `status:`.
#
#   hash-stamp  — compute fingerprint, write stamp atomically (tmp +
#                 rename). Called as the last cmd in a task so later
#                 runs short-circuit via hash-check.
#
#   hash        — print the hash. No stamp I/O. For ad-hoc use.
#
# Two execution modes (auto-detected):
#
#   1. Git context: `git ls-files -co --exclude-standard` enumerates
#      tracked + untracked files (respects .gitignore). `git hash-object`
#      produces the blob hashes we combine.
#
#   2. No-git context (Dockerfile RUN layer, copied tarball, CI without
#      .git): native `glob -e` + per-file `hash sha256`. Output differs
#      from git mode but is stable within that environment — each stamp
#      is local to its environment, so that's fine for cache keys.
#
# Usage (manifest mode — what bayt's emitter generates):
#
#   nu fingerprint.nu hash-check --manifest .bayt/bayt.<verb>.json
#   nu fingerprint.nu hash-stamp --manifest .bayt/bayt.<verb>.json
#
# In manifest mode, srcs / outs / dep-stamp paths and the stamp
# location are all derived from the manifest. Used by every generated
# Taskfile and by cache.nu (via the exported resolve-manifest +
# compute-fingerprint helpers). The merkle-chain (cross-project dep
# stamps) only resolves correctly inside containers — on host
# invocations missing dep stamps are warned + skipped, weaker but
# non-blocking.
#
# Usage (positional / ad-hoc mode — direct CLI use without a manifest):
#
#   nu fingerprint.nu hash-check \
#       --stamp .task/bayt/build.hash \
#       --exclude node_modules/** --exclude .nuxt/** \
#       components pages '**/*.vue' package.json
#
#   nu fingerprint.nu hash-stamp \
#       --stamp .task/bayt/build.hash \
#       --exclude node_modules/** --exclude .nuxt/** \
#       components pages '**/*.vue' package.json
#
#   nu fingerprint.nu hash components pages '**/*.vue'

def git-available []: nothing -> bool {
  if (which git | is-empty) { return false }
  (do -i { ^git rev-parse --is-inside-work-tree } | complete | get exit_code) == 0
}

# Enumerate files matching the given patterns, pruning excluded dirs.
# nu's `glob` returns [] for no-match (including a nonexistent parent);
# it errors only on malformed patterns, which we deliberately let
# propagate — a bad pattern is a caller bug, not an empty input set.
def expand-paths [paths: list<string>, excludes: list<string>]: nothing -> list<string> {
  $paths
  | each { |p|
    let t = ($p | path type)
    if $t == "file" {
      [$p]
    } else if $t == "dir" {
      glob $"($p)/**/*" --exclude $excludes
      | where ($it | path type) == "file"
    } else if ($p | str contains "*") or ($p | str contains "?") {
      glob $p --exclude $excludes
      | where ($it | path type) == "file"
    } else {
      []
    }
  }
  | flatten
  | sort -n
}

# Git pathspec and nushell's glob disagree on `**`:
#   git:  `*` matches any chars including `/` → `*.vue` matches at every
#         depth. `**/*.vue` MISSES root-level files (needs dir above).
#   nu:   `*` is single-segment → `**/*.vue` matches every depth, `*.vue`
#         only matches current dir.
# Emitters use the nu convention (`**/*.X` for recursive). In git mode,
# we strip the `**/` prefix so the pattern becomes `*.X` — matches
# recursively AND catches root-level files. Patterns without `**/` pass
# through unchanged (specific files / dirs).
def git-patterns [paths: list<string>]: nothing -> list<string> {
  $paths | each { |p|
    if ($p | str starts-with "**/") { $p | str substring 3.. } else { $p }
  }
}

# libc flavor — distinguishes glibc and musl Linux at the binary-ABI
# level. `cargo build` against a musl rust toolchain in lazybox produces
# binaries that won't run against a glibc /lib64/ld-linux-*.so.2; the
# inverse breaks too. Without this in the platform key, a cache stamp
# from a host glibc build would be reused for a container musl build
# (or vice versa) and the restored target/debug/ artifacts would be
# subtly wrong.
#
# Detection priority:
#   1. Filesystem (dynamic linker presence): reflects what the build
#      tools running on this system will actually link against — the
#      authoritative signal for cache compatibility. Catches the case
#      of a glibc-built nu running inside a musl container, where
#      check (2) would mis-report glibc but the build outputs are musl.
#   2. nu's rust target triple: fallback for nonstandard filesystem
#      layouts where neither expected linker path is present.
#
# Empty for non-Linux (Darwin/Windows have one ABI per host).
def libc-flavor []: nothing -> string {
  let host = sys host
  if $host.name != "Linux" { return "" }

  # (1) filesystem
  if (glob "/lib/ld-musl-*.so.1" | is-not-empty) { return "musl" }
  if ("/lib64/libc.so.6" | path exists) { return "glibc" }

  # (2) interpreter target triple fallback
  let target = (version | get build_target)
  if ($target | str ends-with "-musl") { return "musl" }
  if ($target | str ends-with "-gnu")  { return "glibc" }
  ""
}

# Platform identity folded into every hash. Prevents a stamp or cache
# entry written on one host (arm64 mac) from being trusted on another
# (amd64 linux) when a worktree is cross-mounted (host ↔ container) or
# shared across machines. Matches Bazel's exec-platform action-key
# convention.
#
# Components: kernel name + kernel version + arch + libc flavor (Linux
# only).
def platform-key []: nothing -> string {
  let host = sys host
  let arch = (uname | get machine)
  let flavor = (libc-flavor)
  let flavor_part = if ($flavor | is-empty) { "" } else { $"-($flavor)" }
  $"($host.name)-($host.os_version)-($arch)($flavor_part)"
}

# compute-fingerprint — single source of truth for the input fingerprint.
# Returns both the structured per-file map AND the rolled-up hash key
# in one pass over the file system (one git ls-files + one git
# hash-object, vs two of each if hash and map were derived separately).
# cache.nu consumes both fields — hash for the cache key, inputs for
# similarity-based lookup.
#
# Every hash is platform-scoped (see platform-key above); callers that
# want a cross-platform-shared hash don't exist today.
#
# Git-mode path handling:
#   - Glob patterns expand via `git ls-files -co --exclude-standard`
#     (respects .gitignore, fast on large trees).
#   - Literal file paths bypass ls-files and hash directly via
#     `git hash-object`. This matters for Merkle-chain dep stamps at
#     `.task/bayt/<n>.hash` — those paths are gitignored, so
#     ls-files would silently drop them and the chain would break.
#   - Missing literals are skipped with a warning, not errored. Host
#     `just sayt build` invocations have no cross-project dep stamps
#     (those only land via the docker COPY chain); warning weakens the
#     merkle chain in that mode but keeps the workflow alive.
export def compute-fingerprint [
  paths: list<string>
  excludes: list<string>
]: nothing -> record {
  let pairs = if (git-available) {
    let gpaths = (git-patterns $paths)
    let globs = ($gpaths | where { |p| ($p | str contains "*") or ($p | str contains "?") })
    let literals = ($gpaths | where { |p| not (($p | str contains "*") or ($p | str contains "?")) })
    let present_literals = ($literals | where { |p| ($p | path type) == "file" })
    let missing = ($literals | where { |p| ($p | path type) != "file" })
    if not ($missing | is-empty) {
      let n = ($missing | length)
      let names = ($missing | str join ', ')
      print -e $"fingerprint: skipping ($n) missing literal paths -- merkle chain incomplete, likely host invocation: ($names)"
    }
    let tracked = if ($globs | is-empty) { [] } else { ^git ls-files -co --exclude-standard -- ...$globs | lines }
    let files = (($tracked ++ $present_literals) | sort | uniq)
    if ($files | is-empty) {
      error make { msg: $"fingerprint: no files found for: ($paths | str join ' ')" }
    }
    let hashes = (^git hash-object ...$files | lines)
    $files | zip $hashes | each { |p| {path: ($p | get 0), hash: ($p | get 1)} }
  } else {
    let files = (expand-paths $paths $excludes)
    if ($files | is-empty) {
      error make { msg: $"fingerprint: no files found for: ($paths | str join ' ')" }
    }
    $files | each { |f| {path: $f, hash: ((open --raw $f) | hash sha256)} }
  }
  # uniq-by path: globs can overlap (tracker's srcs lists
  # `src/it/resources/**/*` twice via different default globs that
  # collapse to the same pattern). Without uniq, the reduce-insert
  # below errors with "Column already exists" — and the rolled-up
  # hash would double-count those files.
  let unique = ($pairs | uniq-by path)
  let inputs = ($unique | reduce --fold {} { |it, acc| $acc | insert $it.path $it.hash })
  # Rolled-up hash: platform-key + per-file hashes joined by newline,
  # sorted by path so input ordering doesn't perturb the digest. Paths
  # aren't included in the rolled-up bytes — only the content hashes.
  # If a file moves to a different path with identical content the
  # rolled-up hash is unchanged, which is the desired property
  # (content-addressed, not path-addressed).
  let file_list = ($unique | sort-by path | get hash | str join "\n")
  let hash = ($"(platform-key)\n($file_list)" | hash sha256)
  {hash: $hash, inputs: $inputs}
}

# compute-hash — thin wrapper for callers that only need the rolled-up
# hash key (hash-check, hash-stamp, ad-hoc `hash` subcommand). cache.nu
# wants both hash and per-file map and calls compute-fingerprint directly.
export def compute-hash [paths: list<string>, excludes: list<string>]: nothing -> string {
  (compute-fingerprint $paths $excludes).hash
}

def parse-excludes [s: string]: nothing -> list<string> {
  if ($s | is-empty) { [] } else {
    $s | split row "," | each { |it| $it | str trim } | where { |it| not ($it | is-empty) }
  }
}

# Both hash-check and hash-stamp accept either --manifest (read
# everything from the .bayt/bayt.<n>.json) or positional --stamp +
# paths + flags (ad-hoc mode). Same dispatch on both — extracted to one
# place. `who` is the subcommand name for error messages. `outs` is only
# meaningful for hash-check (hash-stamp ignores the field), but carrying
# it in both shapes lets the resolved record stay uniform.
def resolve-args [
  who: string
  manifest: string
  cmd: string
  stamp: string
  paths: list<string>
  exclude: string
  outs: string
]: nothing -> record {
  if ($manifest | is-not-empty) { return (resolve-manifest $manifest $cmd) }
  if ($stamp | is-empty) {
    error make { msg: $"fingerprint ($who): --manifest or --stamp required" }
  }
  if ($paths | is-empty) {
    error make { msg: $"fingerprint ($who): at least one path required (or --manifest)" }
  }
  {
    stamp: $stamp
    paths: $paths
    excludes: (parse-excludes $exclude)
    outs: (parse-excludes $outs)
  }
}

# outs-present? — return true iff every glob pattern in $pats
# resolves to at least one existing file. Cheap existence probe; no
# content hashing. Matches go-task's native `generates:` semantics
# without paying its glob-walk tax.
def outs-present [pats: list<string>]: nothing -> bool {
  for p in $pats {
    let t = ($p | path type)
    let found = if $t == "file" or $t == "dir" {
      true
    } else if ($p | str contains "*") or ($p | str contains "?") {
      not ((glob $p --no-dir) | is-empty)
    } else {
      false
    }
    if not $found { return false }
  }
  true
}

# Resolve a manifest (.bayt/bayt.<n>.json) into the concrete args
# the hash pipeline needs: stamp file path, input path list (manifest
# + srcs + direct-dep stamp paths, Merkle-chained), exclude list,
# outs glob list.
#
# The manifest file itself is always an input — any change to srcs,
# cmds, excludes, outs, deps, or env in bayt.cue flips the manifest's
# bytes, which flips this hash, which invalidates the task. That also
# gives every target a stable stamp even when srcs is empty (verify,
# doctor, launch, generate, lint), so they can participate in the
# Merkle chain as either upstream or downstream.
#
# Path math for cross-project chainedDeps lives here — nushell's
# `path split` handles separators cleanly, unlike CUE string concat.
export def resolve-manifest [manifest: string, cmd: string = ""]: nothing -> record {
  let m = (open $manifest)
  let consumer_dir = $m.dir
  # `../` hops from consumer's dir to repo root: one per path segment.
  let hops = ($consumer_dir | path split | where { |s| not ($s | is-empty) } | length)
  let up = (0..<$hops | each { "../" } | str join)
  let dep_stamps = ($m.chainedDeps | default [] | each { |d|
    if $d.dir == $consumer_dir {
      $".task/bayt/($d.name).hash"
    } else {
      $"($up)($d.dir)/.task/bayt/($d.name).hash"
    }
  })
  # When --cmd is set, the per-cmd manifest entry's `srcs` carries the
  # effective srcs (target.srcs ∪ cmd.srcs, with defaultGlobs expanded)
  # — what fingerprint.nu hashes for that cmd-task's stamp. The stamp
  # path becomes .task/bayt/<target>.<cmd>.hash. When --cmd is empty,
  # behavior is unchanged: hash the target's top-level srcs into
  # .task/bayt/<target>.hash.
  let scope = if ($cmd | is-empty) {
    {
      stamp_name: $m.name
      srcs:       ($m.srcs.globs? | default [])
      excludes:   ($m.srcs.exclude? | default [])
    }
  } else {
    let entry = ($m.cmds | where name == $cmd | first)
    if $entry == null {
      error make { msg: $"fingerprint: cmd ($cmd) not found in manifest ($manifest)" }
    }
    {
      stamp_name: $"($m.name).($cmd)"
      srcs:       ($entry.srcs.globs? | default [])
      excludes:   ($entry.srcs.exclude? | default [])
    }
  }
  let paths = (
    [$manifest] ++
    $scope.srcs ++
    $dep_stamps
  )
  {
    stamp: $".task/bayt/($scope.stamp_name).hash"
    paths: $paths
    excludes: $scope.excludes
    outs: ($m.outs.globs? | default [])
  }
}

# hash — print the hash of the src set.
def "main hash" [
  --exclude (-e): string = ""   # comma-separated glob patterns
  ...paths: string
] {
  if ($paths | is-empty) {
    error make { msg: "fingerprint hash: at least one path required" }
  }
  print (compute-hash $paths (parse-excludes $exclude))
}

# hash-check — exit 0 on match, 1 on miss. Meant for go-task `status:`.
#
# Two input modes:
#   --manifest <path>  → read everything from a .bayt/bayt.<n>.json
#                        (what the bayt emitter generates). All path
#                        math and Merkle-chain dep stamp resolution
#                        happens here; the caller gives one flag.
#   positional args    → ad-hoc use. --stamp / --exclude / --outs /
#                        <paths>... directly.
#
# --outs presence check: if any glob resolves to zero files, exit 1
# (treated as a cache miss) so cmds run and can refetch/rebuild. This
# is the cheap form of go-task's `generates:` — existence only, no
# content hashing.
def "main hash-check" [
  --manifest: string = ""       # .bayt/bayt.<n>.json
  --cmd: string = ""            # cmd name within the manifest's cmds list
  --stamp (-s): string = ""
  --exclude (-e): string = ""   # comma-separated glob patterns
  --outs (-o): string = ""      # comma-separated output globs
  ...paths: string
] {
  let resolved = (resolve-args "hash-check" $manifest $cmd $stamp $paths $exclude $outs)
  if not ($resolved.stamp | path exists) {
    exit 1
  }
  if not (outs-present $resolved.outs) {
    exit 1
  }
  let stored = (open $resolved.stamp | str trim)
  let current = (compute-hash $resolved.paths $resolved.excludes)
  if $current == $stored { exit 0 } else { exit 1 }
}

# hash-stamp — atomically write the current fingerprint to the stamp.
# Same two input modes as hash-check. Outs-presence isn't checked
# here (cmds just produced them).
def "main hash-stamp" [
  --manifest: string = ""
  --cmd: string = ""            # cmd name within the manifest's cmds list
  --stamp (-s): string = ""
  --exclude (-e): string = ""
  ...paths: string
] {
  let resolved = (resolve-args "hash-stamp" $manifest $cmd $stamp $paths $exclude "")
  let current = (compute-hash $resolved.paths $resolved.excludes)
  mkdir ($resolved.stamp | path dirname)
  let tmp = $"($resolved.stamp).tmp"
  $current | save -f $tmp
  mv -f $tmp $resolved.stamp
}

# Default invocation — `nu fingerprint.nu [--stamp <path>] <paths>...`.
# Prints the hash; with --stamp, atomically writes it to the file when
# the hash changed and prints the new value (silent on no change).
# Kept for ad-hoc CLI use; bayt's emit always goes through the
# hash-check / hash-stamp subcommands with --manifest.
def main [
  --stamp: string
  ...paths: string
] {
  if ($paths | is-empty) {
    error make { msg: "fingerprint: at least one path required (or a subcommand)" }
  }
  let current = (compute-hash $paths [])
  if ($stamp | is-empty) {
    print $current
  } else {
    let stored = if ($stamp | path exists) { open $stamp | str trim } else { "" }
    if $current != $stored {
      mkdir ($stamp | path dirname)
      $current | save -f $stamp
      print $current
    }
  }
}
