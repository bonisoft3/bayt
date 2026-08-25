# ignore.nu — the input set, as a function of repo filesystem state alone.
#
# Parses the TRACKED ignore files and nothing else. `git ls-files
# --exclude-standard` also consults `.git/info/exclude` and `core.excludesFile`,
# neither of which is in the tree, so the same commit can enumerate differently
# on two machines. Reading only tracked files is what makes a fingerprint a
# function of the commit — the omission is the point, not an oversight.
#
# Consequence to expect: this set can differ from what `git status` hides.
#
# Two paths compute the set — see `git-enumerate` — and an integration test
# holds them to the same answer.
#
# gitignore semantics implemented, per gitignore(5):
#   - blank lines and `#` comments skipped; `\#` is a literal `#`
#   - `!` negates; the LAST matching rule wins
#   - a trailing `/` matches directories only
#   - a `/` anywhere but the end anchors the pattern to its own file's directory;
#     otherwise the pattern matches at any depth
#   - `*` and `?` do not cross `/`; `**` does
#   - a file cannot be re-included when a parent directory is excluded
#
# That last rule is what makes pruning sound: a directory that matches an
# exclude can never need re-entering, so the walk never descends it. Without it
# every negation would force a full descent.
#
# dockerignore is the same matcher minus nesting: one file at the context root,
# and no directory-only `/` suffix. Passed as `--flavor docker`.

# A parsed rule. `base` is the dir the ignore file lived in, repo-relative
# ("" at the root); `re` matches a path already made relative to `base`.
export def parse-file [text: string, base: string, flavor: string = "git"]: nothing -> list<record> {
  $text
  | lines
  | each { |raw| $raw | str trim --right }
  | where { |l| ($l | str length) > 0 and not ($l | str starts-with "#") }
  | each { |l|
    let neg = ($l | str starts-with "!")
    let body = if $neg { $l | str substring 1.. } else { $l }
    let body = if ($body | str starts-with '\#') { $body | str substring 1.. } else { $body }
    let dir_only = ($flavor == "git" and ($body | str ends-with "/"))
    let trimmed = ($body | str trim --right --char '/')
    if ($trimmed | is-empty) { null } else {
      # The last segment, when it globs nothing, is a basename every matching
      # path must have — the index key. `**` and friends leave it null.
      let last = ($trimmed | split row "/" | last)
      let name = if ($last =~ '[*?\[]') { null } else { $last }
      # `*.ext` is the other shape that pins something a path must end with.
      # Indexing it the same way keeps the always-test list to real globs.
      # The extension must hold no dot of its own: the lookup keys on the text
      # after the LAST dot, so `*.tar.gz` would index under `tar.gz` and never be
      # found under `gz`. Those fall through to `always` and match by regex.
      let ext = if $name == null and ($last =~ '^\*\.[^*?\[/.]+$') {
        $last | str substring 2..
      } else { null }
      {base: $base, negate: $neg, dir_only: $dir_only, name: $name, ext: $ext, re: (to-regex $trimmed $flavor)}
    }
  }
  | where { |r| $r != null }
}

# Glob to anchored regex. Segment-aware: `*`/`?` stop at `/`, `**` does not.
export def to-regex [pat: string, flavor: string = "git"]: nothing -> string {
  # dockerignore patterns are always context-root relative, so they anchor
  # unconditionally; git's anchoring rule is in the header contract.
  let inner = ($pat | str trim --left --char '/')
  let anchored = ($flavor == "docker") or ($pat | str starts-with "/") or ($inner | str contains "/")

  let chars = ($inner | split chars)
  mut out = ""
  mut i = 0
  let n = ($chars | length)
  while $i < $n {
    let c = ($chars | get $i)
    if $c == "*" {
      let star2 = ($i + 1 < $n) and (($chars | get ($i + 1)) == "*")
      if $star2 {
        # `**/` consumes any number of leading segments (including none);
        # a trailing `**` swallows the rest of the path.
        let slash3 = ($i + 2 < $n) and (($chars | get ($i + 2)) == "/")
        if $slash3 {
          $out = $out + "(?:.*/)?"
          $i = $i + 3
        } else {
          $out = $out + ".*"
          $i = $i + 2
        }
      } else {
        $out = $out + "[^/]*"
        $i = $i + 1
      }
    } else if $c == "?" {
      $out = $out + "[^/]"
      $i = $i + 1
    } else if $c == "[" {
      # Character class passes through; `!` negation becomes regex `^`.
      mut j = ($i + 1)
      mut cls = "["
      if $j < $n and (($chars | get $j) == "!") { $cls = $cls + "^"; $j = $j + 1 }
      mut closed = false
      while $j < $n and not $closed {
        let cc = ($chars | get $j)
        if $cc == "]" { $closed = true } else { $cls = $cls + $cc }
        $j = $j + 1
      }
      $out = $out + (if $closed { $cls + "]" } else { '\[' })
      $i = if $closed { $j } else { $i + 1 }
    } else if ($c =~ '[a-zA-Z0-9_/-]') {
      $out = $out + $c
      $i = $i + 1
    } else {
      $out = $out + '\' + $c
      $i = $i + 1
    }
  }

  # A floating pattern may start at any segment boundary. Both flavors match a
  # directory by prefix, so anything under a match is covered by the caller
  # testing each ancestor, not by a trailing wildcard here.
  let head = if $anchored { "^" } else { "^(?:.*/)?" }
  $head + $out + "$"
}

# Is `rel` (a path relative to the rule's base) matched by this rule?
def rule-hits [rule: record, rel: string, is_dir: bool]: nothing -> bool {
  if $rule.dir_only and not $is_dir { return false }
  $rel =~ $rule.re
}

# Index rules by the basename they require. Testing every rule against every
# path costs a regex per rule per path; indexing is worth ~60x on a real tree,
# so it is load-bearing rather than a refinement. Almost every pattern pins its
# last segment to a literal — `node_modules`, `**/.omc/`, `docs/build` all do —
# leaving only the few with a globby last segment to test unconditionally.
export def compile-rules [rules: list<record>]: nothing -> list<record> {
  $rules
  | enumerate
  # upsert, not insert: the walk recompiles an already-ordered set each time a
  # nested ignore file joins it.
  | each { |it| $it.item | upsert ord $it.index }
  | group-by base
  | transpose base rs
  | each { |g| {
      base: $g.base
      # `null` name = the last segment globs, so no basename can rule it out.
      by_name: ($g.rs | where { |r| $r.name != null } | group-by name)
      by_ext: ($g.rs | where { |r| $r.ext != null } | group-by ext)
      always: ($g.rs | where { |r| $r.name == null and $r.ext == null })
      # Flat and ordered, so a nested ignore file can be folded in and the
      # whole set recompiled as the walk descends.
      rules: $g.rs
    } }
  # Shallowest base first: a deeper ignore file overrides a shallower one.
  | sort-by { |g| $g.base | split row "/" | length }
}

# Last match wins, across bases shallowest-first and within a base in file
# order. `ord` carries that order through the index, so candidates need no
# re-sorting — the highest matching ord is the deciding rule.
export def ignored? [path: string, is_dir: bool, compiled: list<record>]: nothing -> bool {
  mut verdict = false
  for g in $compiled {
    let base = $g.base
    if ($base | is-empty) or ($path | str starts-with $"($base)/") {
      let rel = if ($base | is-empty) { $path } else { $path | str substring (($base | str length) + 1).. }
      let bn = ($rel | path basename)
      let named = ($g.by_name | get -o $bn | default [])
      # `*` matches empty, so `*.log` matches a bare `.log` — the suffix is
      # everything after the LAST dot even when that dot leads the name, which
      # is not what `path parse` calls an extension.
      let dot = ($bn | str index-of "." --end)
      let exted = if $dot < 0 { [] } else {
        $g.by_ext | get -o ($bn | str substring ($dot + 1)..) | default []
      }
      let cands = ($named ++ $exted ++ $g.always)
      mut best = -1
      mut neg = false
      for rule in $cands {
        if $rule.ord > $best and (rule-hits $rule $rel $is_dir) {
          $best = $rule.ord
          $neg = $rule.negate
        }
      }
      if $best >= 0 { $verdict = not $neg }
    }
  }
  $verdict
}

# git enumerating the same set, an order of magnitude faster.
# `--exclude-per-directory` reads
# ONLY the per-directory ignore files, so unlike `--exclude-standard` it never
# consults `.git/info/exclude` or `core.excludesFile` — the machine state that
# would otherwise make one commit enumerate differently on two hosts. That is
# what makes this an exact substitute rather than an approximation.
#
# `-c` lists tracked files regardless of ignore rules, so the tracked-and-
# ignored set is subtracted: here ignore rules apply to everything, tracked or
# not. ignore_agrees_it in tests/ pins the two paths to the same answer.
#
# Returns null when git cannot answer — no binary, or not a work tree — and the
# walk takes over. The build container has no `.git` (it is dockerignored), so
# that path is the one CI actually runs.
def git-enumerate [root: string, sub: string]: nothing -> any {
  if (which git | is-empty) { return null }
  let top = (do -i { ^git -C $root rev-parse --show-toplevel } | complete)
  if $top.exit_code != 0 { return null }
  # git applies ignore rules from every ancestor up to the real repo root; the
  # walk treats `root` as the top of the path space. Those agree only when
  # `root` IS the repo root, so anything below it stays on the walk.
  if ($top.stdout | str trim) != $root { return null }
  let scope = if ($sub | is-empty) { [] } else { ["--" $sub] }
  let all = (do -i { ^git -C $root ls-files -co --exclude-per-directory=.gitignore ...$scope } | complete)
  if $all.exit_code != 0 { return null }
  let ign = (do -i { ^git -C $root ls-files -ci --exclude-per-directory=.gitignore ...$scope } | complete)
  if $ign.exit_code != 0 { return null }
  let drop = ($ign.stdout | lines)
  $all.stdout | lines | where { |p| not ($p in $drop) }
}

# Enumerate a scope, in the path space of `root`. Rules are seeded from every
# ancestor ignore file between `root` and `sub` before descending: a scope
# nested under the repo root is still governed by the root's file, which is
# where `**/.task/`, `dist` and friends are declared.
export def walk-scope [
  root: string                      # absolute repo root — the path space
  sub: string = ""                  # scope to enumerate, relative to root
  flavor: string = "git"
  --no-git                          # skip the fast path; the walk is the oracle
]: nothing -> list<string> {
  let fast = if $flavor == "git" and (not $no_git) { git-enumerate $root $sub } else { null }
  if $fast != null { return $fast }

  let ignore_name = if $flavor == "docker" { ".dockerignore" } else { ".gitignore" }
  let segs = if ($sub | is-empty) { [] } else { $sub | split row "/" | where { |s| not ($s | is-empty) } }
  # Ancestors shallowest-first, so a deeper file overrides a shallower one.
  let bases = ([""] ++ ($segs | enumerate | each { |it| $segs | first ($it.index + 1) | str join "/" }))
  let seeded = ($bases | drop 1 | prepend "" | uniq | each { |b|
    let f = if ($b | is-empty) { $"($root)/($ignore_name)" } else { $"($root)/($b)/($ignore_name)" }
    if ($f | path exists) { parse-file (open --raw $f) $b $flavor } else { [] }
  } | flatten)
  let start = if ($sub | is-empty) { $root } else { $"($root)/($sub)" }
  # The scope's own ignore file is read by the walk itself, so drop it here.
  let seeded = ($seeded | where { |r| $r.base != $sub })
  walk $start (compile-rules $seeded) $sub $flavor
}

# Descend `dir`, collecting files that survive the rules. A nested ignore file
# inside a pruned directory is never read, for the same reason git never applies
# one: the walk does not go there.
def walk [
  dir: string                       # absolute directory to descend
  rules: list<record> = []          # inherited, shallowest first
  rel: string = ""                  # `dir` relative to the walk root
  flavor: string = "git"
]: nothing -> list<string> {
  # `cd` first so names come back bare; `ls -a` already omits `.` and `..`.
  let entries = (do { cd $dir; ls -a })
  let names = ($entries | get name)

  # A `.git` entry marks a separate repository — submodule or linked worktree —
  # whose contents are not this repo's source and which no ignore rule covers.
  # Taking it from the listing avoids a probe per subdirectory.
  if (not ($rel | is-empty)) and (".git" in $names) { return [] }

  let ignore_name = if $flavor == "docker" { ".dockerignore" } else { ".gitignore" }
  # dockerignore does not nest: only the context root's file is honoured.
  let here = if ($ignore_name in $names) and ($flavor == "git" or ($rel | is-empty)) {
    parse-file (open --raw $"($dir)/($ignore_name)") $rel $flavor
  } else { [] }
  # Recompiled per directory, not per file: a nested ignore file joins the set
  # here and the index has to take it in.
  let rules = if ($here | is-empty) { $rules } else {
    compile-rules (($rules | each { |g| $g.rules } | flatten) ++ $here)
  }

  let kept = ($entries | where type != dir | each { |f|
    let p = if ($rel | is-empty) { $f.name } else { $"($rel)/($f.name)" }
    if (ignored? $p false $rules) { null } else { $p }
  } | where { |x| $x != null })

  let descended = ($entries | where type == dir | each { |d|
    let p = if ($rel | is-empty) { $d.name } else { $"($rel)/($d.name)" }
    # `.git` itself is the boundary, not content.
    if $d.name == ".git" { [] } else if (ignored? $p true $rules) { [] } else {
      walk $"($dir)/($d.name)" $rules $p $flavor
    }
  } | flatten)

  $kept ++ $descended
}
