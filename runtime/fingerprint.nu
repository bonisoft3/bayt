# fingerprint.nu — content fingerprint of src patterns. One command,
# additive flags. Inputs come from --manifest and/or positional paths
# (both unioned).
#
# INPUT
#   --manifest <p> [--cmd <c>]   pull srcs/excludes/outs from a bayt
#                                .bayt/bayt.<n>.json. --cmd scopes to
#                                that cmd's effective srcs.
#   --exclude <list>             comma-separated glob excludes
#   --outs <list>                comma-separated existence-probe globs
#                                (checked in check mode only)
#   <paths>...                   positional path/glob args
#
# OUTPUT
#   (default)        per-file rows, TSV: `<sha256>\t<path>`. With
#                    --docker: `<sha256>\t<mode>\t<u>:<g>\t<mtime>\t
#                    <size>[\t<xattr>]\t<path>` (xattr column only
#                    when a reader is on PATH).
#   --docker         fold mode/uid/mtime/size/xattr into both the
#                    rolled-up hash and the per-file rows. Without
#                    --docker the hash is content-only — two stamps
#                    for two audiences (go-task vs docker layer cache).
#   --json           NDJSON per file; with -q, one-line `{"hash":...}`.
#   -q | --quiet     just the rolled-up hash.
#
# STAMP OPS (silent stdout; --docker selects the hash flavor stamped)
#   --stamp-file <p>     check: exit 0 on match + --outs present, else 1.
#   --update-stamp       requires --stamp-file. Writes atomically.

def git-available []: nothing -> bool {
  if (which git | is-empty) { return false }
  (do -i { ^git rev-parse --is-inside-work-tree } | complete | get exit_code) == 0
}

# Enumerate files matching the given patterns, pruning excluded dirs
# at walk time. nu's `glob` returns [] for no-match (deliberately
# silent); errors only on malformed patterns, which we let propagate.
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

# Translate nu-style `**/X` patterns to git pathspec. git's `*` is
# multi-segment, so `**/*.vue` MISSES root-level files; stripping the
# `**/` prefix matches recursively AND catches root-level files.
# Patterns without `**/` pass through unchanged.
def git-patterns [paths: list<string>]: nothing -> list<string> {
  $paths | each { |p|
    if ($p | str starts-with "**/") { $p | str substring 3.. } else { $p }
  }
}

use ./tools.nu [libc-flavor]

# Platform identity folded into every hash. Stops an arm64-mac stamp
# from being trusted on an amd64-linux host when a worktree is cross-
# mounted or shared. Matches Bazel's exec-platform action-key idea.
def platform-key []: nothing -> string {
  let host = sys host
  let arch = (uname | get machine)
  let flavor = (libc-flavor)
  let flavor_part = if ($flavor | is-empty) { "" } else { $"-($flavor)" }
  $"($host.name)-($host.os_version)-($arch)($flavor_part)"
}

# Returns the first available xattr-reading CLI (`getfattr` on Linux,
# `xattr` on macOS), or "" if neither is on PATH.
def xattr-tool []: nothing -> string {
  if (not (which getfattr | is-empty)) { return "getfattr" }
  if (not (which xattr | is-empty)) { return "xattr" }
  ""
}

# Returns the file's xattrs as record<name, value>, or {} when none.
# Precondition: tool != "". getfattr's `name="value"` form is unquoted;
# xattr's raw value passes through.
def read-xattrs [tool: string, path: string]: nothing -> record {
  if $tool == "getfattr" {
    let r = (do -i { ^getfattr -d --absolute-names $path } | complete)
    if $r.exit_code != 0 { return {} }
    $r.stdout
    | lines
    | where { |l| not ($l | str starts-with "#") and not ($l | is-empty) }
    | reduce --fold {} { |line, acc|
        let eq = ($line | str index-of "=")
        if $eq < 0 { return $acc }
        let n = ($line | str substring 0..($eq - 1))
        let v = ($line | str substring ($eq + 1)..)
        let unquoted = if ($v | str starts-with '"') and ($v | str ends-with '"') {
          $v | str substring 1..(($v | str length) - 2)
        } else { $v }
        $acc | insert $n $unquoted
      }
  } else {
    let r = (do -i { ^xattr $path } | complete)
    if $r.exit_code != 0 { return {} }
    $r.stdout
    | lines
    | where { |l| not ($l | is-empty) }
    | reduce --fold {} { |n, acc|
        let v = (do -i { ^xattr -p $n $path } | complete)
        $acc | insert $n ($v.stdout | str trim)
      }
  }
}

# Deterministic flat form of an xattr record: keys sorted, entries as
# `name="value"`, joined by `;`. Empty record → "". Same bytes feed
# both the rolled-up hash and the TSV column so they can't drift.
def format-xattrs [x: record]: nothing -> string {
  $x | transpose name value | sort-by name | each { |it| $"($it.name)=\"($it.value)\"" } | str join ";"
}

# compute-fingerprint — file enumeration + hashing in one pass.
# Returns {hash, inputs}; shapes depend on `docker`:
#
#   docker=false: hash = sha256 over `platform-key\n<sorted file
#                 hashes>`. inputs = record<path, sha256>.
#   docker=true:  hash = sha256 over `platform-key\n<sorted per-file
#                 rows>`, where each row carries sha256, mode,
#                 user:group, mtime (ns), size, xattr (flattened by
#                 format-xattrs; empty trailing field when a reader is
#                 on PATH but file has none — still hashed for
#                 stability). inputs = record<path, record{sha256,
#                 mode, user, group, mtime, size, [xattr: record]}>.
#                 The xattr sub-record is structured so JSON dumps
#                 emit nested objects rather than serialized strings.
#
# Path handling in git mode:
#   - Globs expand via `git ls-files -co --exclude-standard`
#     (respects .gitignore, fast on large trees).
#   - Literal paths bypass ls-files and hash via `git hash-object` —
#     matters for gitignored Merkle-chain dep stamps that ls-files
#     would silently drop. Missing literals print a warning, not
#     error: host invocations have no cross-project dep stamps until
#     docker COPY chains land them.
export def compute-fingerprint [
  paths: list<string>
  excludes: list<string>
  docker: bool = false
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
      print -e $"fingerprint: skipping ($n) missing literal paths: ($names)"
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
  # uniq-by path: distinct glob patterns can resolve to the same file.
  # Without uniq the reduce-insert below errors with "Column already
  # exists".
  let unique = ($pairs | uniq-by path | sort-by path)

  if not $docker {
    let inputs = ($unique | reduce --fold {} { |it, acc| $acc | insert $it.path $it.hash })
    let file_list = ($unique | get hash | str join "\n")
    let hash = ($"(platform-key)\n($file_list)" | hash sha256)
    return {hash: $hash, inputs: $inputs}
  }

  let xtool = (xattr-tool)
  # ls --long: portable mode/user/group/modified/size. mtime '%9f' is
  # nanosecond (BuildKit's snapshot diff hashes ns). user/group as
  # resolved names — two runs on the same image diff identically.
  let enriched = ($unique | each { |it|
    let info = (ls --long $it.path | first)
    let mtime = ($info.modified | format date '%Y-%m-%dT%H:%M:%S.%9f')
    let size = ($info.size | into int)
    let base = {
      path:   $it.path
      sha256: $it.hash
      mode:   $info.mode
      user:   $info.user
      group:  $info.group
      mtime:  $mtime
      size:   $size
    }
    if ($xtool | is-empty) { $base } else { $base | insert xattr (read-xattrs $xtool $it.path) }
  })
  let file_list = ($enriched | each { |r|
    let x = ($r | get -o xattr)
    let xs = if $x == null { "" } else { format-xattrs $x }
    $"($r.sha256)\t($r.mode)\t($r.user):($r.group)\t($r.mtime)\t($r.size)\t($xs)"
  } | str join "\n")
  let hash = ($"(platform-key)\n($file_list)" | hash sha256)
  let inputs = ($enriched | reduce --fold {} { |it, acc|
    $acc | insert $it.path ($it | reject path)
  })
  {hash: $hash, inputs: $inputs}
}

def parse-list [s: string]: nothing -> list<string> {
  if ($s | is-empty) { [] } else {
    $s | split row "," | each { |it| $it | str trim } | where { |it| not ($it | is-empty) }
  }
}

# True iff every glob in $pats resolves to ≥1 existing file. Cheap
# existence probe — the `generates:`-style check without content hashing.
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

# resolve-manifest — concrete inputs from a .bayt/bayt.<n>.json:
# srcs + Merkle-chain dep stamp paths + the manifest itself (always
# included, so any srcs/cmds/env/deps edit in bayt.cue flips the hash
# and every target — even srcs-less ones — gets a stable stamp).
# --cmd selects a per-cmd entry: its srcs feed in and the stamp name
# picks up `.<cmd>`. The `stamp` field is informational only; callers
# pick the stamp path via --stamp-file.
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
  {
    stamp:    $".task/bayt/($scope.stamp_name).hash"
    paths:    ([$manifest] ++ $scope.srcs ++ $dep_stamps)
    excludes: $scope.excludes
    outs:     ($m.outs.globs? | default [])
  }
}

# Union manifest (when present) and positional inputs into one record.
# Stamp path comes only from --stamp-file; manifest's `stamp` field is
# never auto-consumed, so bare --manifest just computes and prints.
def merge-inputs [
  manifest: string
  cmd: string
  paths: list<string>
  exclude: string
  outs: string
  stamp_file: string
]: nothing -> record {
  let m = if ($manifest | is-empty) {
    {paths: [], excludes: [], outs: []}
  } else {
    resolve-manifest $manifest $cmd
  }
  {
    stamp_file: $stamp_file
    paths:      (($m.paths ++ $paths) | uniq)
    excludes:   (($m.excludes ++ (parse-list $exclude)) | uniq)
    outs:       (($m.outs ++ (parse-list $outs)) | uniq)
  }
}

# Print per-file rows; format chosen once from (docker, json).
def emit-rows [inputs: any, docker: bool, json: bool]: nothing -> nothing {
  let rows = if $docker {
    $inputs | transpose path attrs | each { |it| $it.attrs | insert path $it.path }
  } else {
    $inputs | transpose path sha256
  }
  for row in $rows {
    if $json {
      let out = if $docker { $row } else { {sha256: $row.sha256, path: $row.path} }
      print ($out | to json --raw)
    } else if $docker {
      let x = ($row | get -o xattr)
      let xs = if $x == null { "" } else { $"\t(format-xattrs $x)" }
      print $"($row.sha256)\t($row.mode)\t($row.user):($row.group)\t($row.mtime)\t($row.size)($xs)\t($row.path)"
    } else {
      print $"($row.sha256)\t($row.path)"
    }
  }
}

export def main [
  --manifest: string = ""
  --cmd: string = ""
  --exclude (-e): string = ""
  --outs (-o): string = ""
  --docker                       # docker-style: include mode/uid/mtime/size/xattr in hash + rows
  --json                         # structured output (NDJSON or one-line JSON with -q)
  --quiet (-q)                   # emit only the rolled-up hash
  --stamp-file: string = ""      # check mode (silent, exit 0/1); + --update-stamp to write
  --update-stamp                 # write mode (atomic). Requires --stamp-file.
  ...paths: string
] {
  if $update_stamp and ($stamp_file | is-empty) {
    error make { msg: "fingerprint: --update-stamp requires --stamp-file" }
  }

  let merged = (merge-inputs $manifest $cmd $paths $exclude $outs $stamp_file)
  if ($merged.paths | is-empty) {
    error make { msg: "fingerprint: at least one path required (positional or --manifest)" }
  }

  let fp = (compute-fingerprint $merged.paths $merged.excludes $docker)

  if not ($merged.stamp_file | is-empty) {
    if $update_stamp {
      mkdir ($merged.stamp_file | path dirname)
      let tmp = $"($merged.stamp_file).tmp"
      $fp.hash | save -f $tmp
      mv -f $tmp $merged.stamp_file
    } else {
      if not ($merged.stamp_file | path exists) { exit 1 }
      if not (outs-present $merged.outs) { exit 1 }
      let stored = (open $merged.stamp_file | str trim)
      if $fp.hash != $stored { exit 1 }
    }
    return
  }

  if $quiet {
    if $json {
      print ({hash: $fp.hash} | to json --raw)
    } else {
      print $fp.hash
    }
  } else {
    emit-rows $fp.inputs $docker $json
  }
}
