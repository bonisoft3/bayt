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

# A pattern is a glob when it carries any wildcard metachar. `[` covers the
# bracket-class idiom bayt emits for optional single files (`[m]ise.toml`,
# `gradle/lib[s].versions.toml`); classing those as literals drops them from
# every fingerprint, since a literal must exist on disk to count.
def is-glob [p: string]: nothing -> bool {
  ($p | str contains "*") or ($p | str contains "?") or ($p | str contains "[")
}

use ./tools.nu [libc-flavor]
use ./ignore.nu [to-regex, walk-scope]

# Platform identity folded into every hash. Stops an arm64-mac stamp
# from being trusted on an amd64-linux host when a worktree is cross-
# mounted or shared. Matches Bazel's exec-platform action-key idea.
def platform-key []: nothing -> string {
  let host = sys host
  let arch = (uname | get machine)
  let flavor = (libc-flavor)
  let flavor_part = if ($flavor | is-empty) { "" } else { $"-($flavor)" }
  let major = ($host.os_version | split row "." | first)
  $"($host.name)-($major)-($arch)($flavor_part)"
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
#   docker=false: hash = sha256 over `platform-key\n<dep hashes>\n<sorted file
#                 hashes>`. inputs = record<path, sha256>.
#   docker=true:  hash = sha256 over `platform-key\n<dep hashes>\n<sorted per-file
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
  root: string = "."
  project: string = "."
  dep_hashes: list<string> = []
]: nothing -> record {
  let gpaths = $paths
  let globs = ($gpaths | where { |p| is-glob $p })
  let plain = ($gpaths | where { |p| not (is-glob $p) })
  # A directory names its whole subtree, so it joins the glob side and the
  # ignore rules and excludes apply to what is under it. Only file literals
  # bypass them.
  let abs = { |p| $project | path join $p }
  let dirs = ($plain | where { |p| (do $abs $p | path type) == "dir" } | each { |p| $"($p)/**/*" })
  let literals = ($plain | where { |p| (do $abs $p | path type) != "dir" })
  let present_literals = ($literals | where { |p| (do $abs $p | path type) == "file" })
  let missing = ($literals | where { |p| (do $abs $p | path type) != "file" })
  if not ($missing | is-empty) {
    let n = ($missing | length)
    let names = ($missing | str join ', ')
    print -e $"fingerprint: skipping ($n) missing literal paths: ($names)"
  }

  # One enumeration whether or not git is installed, so the input set is a
  # function of the tree alone — see ignore.nu for why it reads only the tracked
  # ignore files.
  #
  # Literals bypass it: the Merkle-chain dep stamps live under the gitignored
  # `.task/`, and filtering them would break the chain.
  let globs = ($globs ++ $dirs)
  let matched = if ($globs | is-empty) { [] } else {
    let here = ($project | path expand)
    let scope = if $here == $root { "" } else { $here | str substring (($root | str length) + 1).. }
    let res = ($globs | each { |g| to-regex $g })
    let exres = ($excludes | each { |g| to-regex ($g | str trim --left --char '/') })
    walk-scope $root $scope
    | each { |p| if ($scope | is-empty) { $p } else { $p | str substring (($scope | str length) + 1).. } }
    | where { |p| $res | any { |re| $p =~ $re } }
    | where { |p| not ($exres | any { |re| $p =~ $re }) }
  }

  let files = (($matched ++ $present_literals) | sort | uniq)
  if ($files | is-empty) {
    error make { msg: $"fingerprint: no files found for: ($paths | str join ' ')" }
  }

  # Hashed in-process rather than by `git hash-object` or `sha256sum`: both are
  # faster but exist only where installed, and git's is a SHA-1 blob id, so an
  # identical tree would fingerprint differently on either side of the build
  # container boundary — and neither ships on Windows.
  #
  # Hashing the column in one native pass beats a closure per file by ~4x. The
  # cost is peak memory: `hash` consumes a byte stream incrementally, but
  # `insert` collects one into a Value first, so the peak is the largest single
  # file in scope rather than flat. Chunking cannot lower that floor — one row
  # holds one whole file — so the alternative is a per-file `par-each`, which
  # streams but gives back the speed.
  let pairs = ($files | wrap path | insert hash { |r| open --raw ($project | path join $r.path) } | hash sha256 hash)
  # uniq-by path: distinct glob patterns can resolve to the same file.
  # Without uniq the reduce-insert below errors with "Column already
  # exists".
  let unique = ($pairs | uniq-by path | sort-by path)

  if not $docker {
    let inputs = ($unique | reduce --fold {} { |it, acc| $acc | insert $it.path $it.hash })
    let file_list = ($unique | get hash | str join "\n")
    let dep_list = ($dep_hashes | sort | str join "\n")
  let hash = ($"(platform-key)\n($dep_list)\n($file_list)" | hash sha256)
    return {hash: $hash, inputs: $inputs}
  }

  let xtool = (xattr-tool)
  # ls --long: mode/user/group/modified/size. mtime '%9f' is nanosecond
  # (BuildKit's snapshot diff hashes ns). user/group as resolved names — two
  # runs on the same image diff identically. Windows carries none of the
  # ownership trio, only a readonly bit; the substitutes keep the row shape
  # uniform and need not match another platform's, since platform-key already
  # scopes the hash.
  let windows = ($nu.os-info.name == "windows")
  let enriched = ($unique | each { |it|
    let info = (ls --long ($project | path join $it.path) | first)
    let mtime = ($info.modified | format date '%Y-%m-%dT%H:%M:%S.%9f')
    let size = ($info.size | into int)
    let base = {
      path:   $it.path
      sha256: $it.hash
      mode:   (if $windows { if $info.readonly { "ro" } else { "rw" } } else { $info.mode })
      user:   (if $windows { "-" } else { $info.user })
      group:  (if $windows { "-" } else { $info.group })
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
  let dep_list = ($dep_hashes | sort | str join "\n")
  let hash = ($"(platform-key)\n($dep_list)\n($file_list)" | hash sha256)
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
    # Keep `path type` off globs.
    let found = if ($p | str contains "*") or ($p | str contains "?") {
      not ((glob $p --no-dir) | is-empty)
    } else if (is-glob $p) {
      # Bracket-only pattern: the optional-file idiom. Zero matches is a
      # legitimate state (the file simply isn't part of this project), not
      # a missing output — probing it strictly would permanently fail the
      # status short-circuit of any target declaring an optional out.
      true
    } else {
      let t = ($p | path type)
      $t == "file" or $t == "dir"
    }
    if not $found { return false }
  }
  true
}

# The synthetic views gen_bayt emits into a manifest's `synthetics` map. A
# `:X:<view>` dep is one of these, and never a file on disk.
const synthetic_views = ["srcs" "outs" "bayt"]

# A target's fingerprint folds its deps' — see dep-hashes for where those come
# from.
#
# `memo` is threaded rather than closed over because nushell closures cannot
# mutate an outer binding. Keyed by manifest plus view, cmd and scope flavor —
# each selects a different file set from the same file, so a shared key would
# hand one scope another's hash. A diamond within one key is walked once.
def closure-hash [
  manifest: string
  cmd: string
  docker: bool
  memo: record
  view: string = ""
  all_cmds: bool = false
]: nothing -> record {
  let base = if ($view | is-empty) { $manifest } else { $"($manifest)!($view)" }
  let base = if $all_cmds { $"($base)+cmds" } else { $base }
  let key = if ($cmd | is-empty) { $base } else { $"($base)#($cmd)" }
  if $key in $memo { return {hash: ($memo | get $key), memo: $memo} }

  let r = (resolve-manifest $manifest $cmd $view $all_cmds)
  let dr = (dep-hashes $r.deps $docker $memo $all_cmds)
  let deps = $dr.hashes
  let ctx = (context-hashes $r.contexts $docker $r.root)
  let own = (compute-fingerprint $r.paths $r.excludes $docker $r.root $r.project ($deps ++ $ctx))
  {hash: $own.hash, memo: ($dr.memo | upsert $key $own.hash)}
}

# Hash each context directory over its own contents. Rooted AT the directory so
# the walk covers it and nothing else, while ignore rules still compose from the
# repo root.
def context-hashes [dirs: list<string>, docker: bool, root: string]: nothing -> list<string> {
  $dirs | each { |d|
    (compute-fingerprint ["**/*"] [] $docker $root ($root | path join $d) []).hash
  }
}

# Resolve each dep to its fingerprint. The stamp is a memo of that value, left
# by a `task` run go-task ordered ahead of this one; reading it keeps each
# target's sources walked once per invocation rather than once per dependent,
# which is what makes a per-target invocation model affordable on deep graphs.
#
# Only the narrow content flavor is memoized: a stamp records whichever scope
# wrote it, and every stamped call the generated Taskfiles emit is content-only
# and cmd-scoped.
def dep-hashes [nodes: list<record>, docker: bool, memo: record, all_cmds: bool = false]: nothing -> record {
  mut acc = $memo
  mut out = []
  for d in $nodes {
    # The stamp is only ever written at the narrow scope (the generated
    # Taskfiles never pass --all-cmds), so reading one here would swap this
    # walk's wider hash for a narrower one and reinstate the blind spot
    # --all-cmds exists to close.
    let cached = (if (not $docker) and (not $all_cmds) and ($d.stamp | path exists) {
      open $d.stamp | str trim
    } else { "" })
    if not ($cached | is-empty) {
      $out = ($out ++ [$cached])
      continue
    }
    if not ($d.manifest | path exists) {
      error make { msg: $"fingerprint: dep manifest not found: ($d.manifest)" }
    }

    let sub = (closure-hash $d.manifest "" $docker $acc $d.view $all_cmds)
    $acc = $sub.memo
    $out = ($out ++ [$sub.hash])
  }
  {hashes: $out, memo: $acc}
}

# resolve-manifest — concrete inputs from a .bayt/bayt.<n>.json: srcs, the
# manifest itself (always included, so any srcs/cmds/env/deps edit in bayt.cue
# flips the hash and every target — even srcs-less ones — gets a stable stamp),
# and the deps whose own fingerprints fold into this one.
#
# `chainedDeps` is one link of the Merkle chain, not a transitive closure — a
# dep two hops out appears only in the intermediate's own list. Folding each
# dep's fingerprint reaches the rest by recursion.
# --cmd selects a per-cmd entry: its srcs feed in and the stamp name
# picks up `.<cmd>`. The `stamp` field is informational only; callers
# pick the stamp path via --stamp-file.
export def resolve-manifest [manifest: string, cmd: string = "", view: string = "", all_cmds: bool = false]: nothing -> record {
  let file = (open $manifest)
  # A synthetic view is a manifest-shaped record inside its parent's
  # `synthetics` map, not a file of its own.
  let m = if ($view | is-empty) { $file } else {
    let syn = ($file.synthetics? | default {} | get -o $view)
    # `emitsSrcs: false` is the one reason a view is legitimately absent: the
    # target exports no sources, so a consumer's `:X:srcs` edge carries no
    # files. Any other absence is a generator bug.
    let syn = if $syn != null { $syn } else if $view == "srcs" and (($file.emitsSrcs? | default true) == false) {
      {name: $"($file.name)_($view)", dir: $file.dir, srcs: {globs: [], exclude: []}, outs: {globs: [], exclude: []}, chainedDeps: [], cmds: []}
    } else {
      error make { msg: $"fingerprint: ($manifest) has no synthetic view '($view)'" }
    }
    # A view's file set is its declared INTERFACE, which the generator emits as
    # `outs`; its `srcs` is always empty. Its `chainedDeps` is empty too — the
    # chain it actually carries is the transitive one. Reading the real
    # manifest's fields here would fold in nothing and hash a constant.
    # transitiveDeps names same-project targets; transitiveCrossDeps carries
    # whole records, each with its own dir.
    let same = (($syn.transitiveDeps? | default []) | each { |d| {name: $d, dir: $syn.dir} })
    let cross = (($syn.transitiveCrossDeps? | default []) | each { |d| {name: $d.name, dir: $d.dir} })
    {
      name:        $syn.name
      dir:         $syn.dir
      srcs:        $syn.outs
      outs:        {globs: [], exclude: []}
      state:       {globs: [], exclude: []}
      cmds:        []
      chainedDeps: ($same ++ $cross)
    }
  }
  let consumer_dir = $m.dir
  # `../` hops from consumer's dir to repo root: one per path segment.
  let hops = ($consumer_dir | path split | where { |s| not ($s | is-empty) } | length)
  let up = (0..<$hops | each { "../" } | str join)
  # Anchored on the manifest, not the cwd: a dep manifest is opened from
  # wherever the consumer happens to be, and a cwd-derived root would resolve
  # that dep's own deps against the consumer's project.
  let mdir = ($manifest | path dirname | path expand)
  let project = (if ($mdir | path basename) == ".bayt" { $mdir | path dirname } else { $mdir })
  let root = (0..<$hops | reduce --fold $project { |_, acc| $acc | path dirname })
  # A `:X:srcs` dep names a synthetic view, which gen_bayt emits inside its
  # parent's manifest rather than as `bayt.X_srcs.json` — that file does not
  # exist. The views are a closed set and no target may take one of their
  # names, so the suffix decides, and the dep resolves to the parent file plus
  # the view to select from it.
  # The image scope walks the whole serialized graph, not just the next hop:
  # cross-project edges the Dockerfile COPYs from live in transitiveCrossDeps,
  # and the target's own bayt view enumerates the rendered files it COPYs in
  # (Dockerfile, compose fragment, Taskfiles).
  let _cross = (if $all_cmds and ($view | is-empty) {
    ($m.transitiveCrossDeps? | default [] | each { |d| {name: $d.name, dir: $d.dir} })
  } else { [] })
  let _own_bayt = (if $all_cmds and ($view | is-empty) and (($file.synthetics? | default {} | get -o "bayt") != null) {
    [{name: $"($m.name)_bayt", dir: $m.dir}]
  } else { [] })
  let dep_nodes = (($m.chainedDeps ++ $_cross ++ $_own_bayt) | each { |d|
    let base = (if ($d.dir | is-empty) { $root } else { $"($root)/($d.dir)" })
    let view = ($synthetic_views | where { |v| $d.name | str ends-with $"_($v)" } | get -o 0 | default "")
    let owner = (if ($view | is-empty) { $d.name } else {
      $d.name | str substring ..<(($d.name | str length) - ($view | str length) - 1)
    })
    {
      manifest: $"($base)/.bayt/bayt.($owner).json"
      view:     $view
      # The stamp keeps the dep's own name: it is a memo of this node, and the
      # parent's stamp is a different value.
      stamp:    $"($base)/.task/bayt/($d.name).hash"
    }
  })
  # A context the target COPYs --from is a build input. An image ref needs no
  # walk — it rides the manifest bytes, which are already hashed — but a
  # directory does: the path is fixed while its contents are not. It folds in
  # as its own hash rather than as a glob, because the srcs walk is rooted at
  # the project and a context lives outside it.
  let contexts = (if $all_cmds and ($view | is-empty) {
    ($file | get -o dockerfile.preambleCopyContexts | default [])
      | each { |c| $c | get -o image }
      | where { |i| $i != null and (($root | path join $i) | path type) == "dir" }
  } else { [] })

  let scope = if ($cmd | is-empty) and $all_cmds {
    # The image's source set. A Dockerfile COPYs the target's own srcs AND
    # every cmd's, so a per-cmd scope answers a narrower question than "what
    # goes into this image" — a target whose srcs live only under cmds would
    # otherwise hash over nothing.
    {
      stamp_name: $m.name
      srcs:       ($m.srcs.globs   ++ ($m.cmds | each { |c| $c.srcs.globs }   | flatten) | uniq)
      excludes:   ($m.srcs.exclude ++ ($m.cmds | each { |c| $c.srcs.exclude } | flatten) | uniq)
    }
  } else if ($cmd | is-empty) {
    {
      stamp_name: $m.name
      srcs:       $m.srcs.globs
      excludes:   $m.srcs.exclude
    }
  } else {
    let entry = ($m.cmds | where name == $cmd | first)
    if $entry == null {
      error make { msg: $"fingerprint: cmd ($cmd) not found in manifest ($manifest)" }
    }
    {
      stamp_name: $"($m.name).($cmd)"
      srcs:       $entry.srcs.globs
      excludes:   $entry.srcs.exclude
    }
  }
  {
    stamp:    $".task/bayt/($scope.stamp_name).hash"
    # Ignore rules compose from the repo root down, and `up` is already the hop
    # count to it. Without this the project's own .gitignore would be the only
    # one applied, and the root's `**/.task/`, `dist` and friends would be missed.
    root:     $root
    project:  $project
    # Project-relative, so the spelling a caller used cannot change the hash:
    # the srcs walk finds this same file, and two spellings of it would survive
    # dedup and get hashed twice.
    paths:    ([($manifest | path expand | str replace $"($project)/" "")] ++ $scope.srcs)
    deps:     $dep_nodes
    contexts: $contexts
    excludes: $scope.excludes
    # state entries gate presence like outs but are never CAS payload —
    # cache.nu reads m.outs.globs directly and never sees them.
    outs:     ($m.outs.globs ++ $m.state.globs)
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
  all_cmds: bool = false
]: nothing -> record {
  let m = if ($manifest | is-empty) {
    # No manifest: positional paths are relative to the cwd and nothing above it
    # is in scope, so the cwd is the root.
    {paths: [], excludes: [], outs: [], deps: [], contexts: [], root: ("." | path expand), project: ("." | path expand)}
  } else {
    resolve-manifest $manifest $cmd "" $all_cmds
  }
  {
    stamp_file: $stamp_file
    root:       $m.root
    project:    $m.project
    deps:       $m.deps
    contexts:   $m.contexts
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
  --all-cmds                     # image scope: every cmd's srcs fold in too
  --stamp-file: string = ""      # check mode (silent, exit 0/1); + --update-stamp to write
  --update-stamp                 # write mode (atomic). Requires --stamp-file.
  ...paths: string
] {
  if $update_stamp and ($stamp_file | is-empty) {
    error make { msg: "fingerprint: --update-stamp requires --stamp-file" }
  }

  let merged = (merge-inputs $manifest $cmd $paths $exclude $outs $stamp_file $all_cmds)
  if ($merged.paths | is-empty) {
    error make { msg: "fingerprint: at least one path required (positional or --manifest)" }
  }

  let deps = (dep-hashes $merged.deps $docker {} $all_cmds).hashes
  let ctx = (context-hashes ($merged.contexts? | default []) $docker $merged.root)
  let fp = (compute-fingerprint $merged.paths $merged.excludes $docker $merged.root $merged.project ($deps ++ $ctx))

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
