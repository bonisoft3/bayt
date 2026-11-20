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
def git-enumerate [root: string, subs: list<string>]: nothing -> any {
  if (which git | is-empty) { return null }
  let top = (do -i { ^git -C $root rev-parse --show-toplevel } | complete)
  if $top.exit_code != 0 { return null }
  # git applies ignore rules from every ancestor up to the real repo root; the
  # walk treats `root` as the top of the path space. Those agree only when
  # `root` IS the repo root, so anything below it stays on the walk.
  if ($top.stdout | str trim) != $root { return null }
  let scope = if ($subs | is-empty) { [] } else { ["--"] ++ $subs }
  # `-z`: NUL-separated and never quoted. Without it git renders a path holding
  # a byte outside ASCII as an escaped, double-quoted C string, which the walk
  # reports raw — so the two would name different files and key a target
  # differently depending on whether git answered.
  let all = (do -i { ^git --literal-pathspecs -C $root ls-files -z -co --exclude-per-directory=.gitignore ...$scope } | complete)
  if $all.exit_code != 0 { return null }
  let ign = (do -i { ^git --literal-pathspecs -C $root ls-files -z -ci --exclude-per-directory=.gitignore ...$scope } | complete)
  if $ign.exit_code != 0 { return null }
  let deleted = (do -i { ^git --literal-pathspecs -C $root ls-files -z --deleted ...$scope } | complete)
  if $deleted.exit_code != 0 { return null }
  # A record, not a list: `in` over a list is linear, and at repo scope that
  # turns the subtraction into |tracked| x |ignored| comparisons.
  let drop = (($ign.stdout + $deleted.stdout) | split row (char nul) | where { |p| not ($p | is-empty) }
    | each { |p| {$p: true} } | into record)
  # `.git` and `.task` are tool boundaries the walk never descends into. git
  # knows only ignore files, so in a repo whose .gitignore does not name
  # `.task/` the two paths would otherwise disagree — the fast path handing
  # back bayt's own stamps and index, which are rewritten on every run.
  $all.stdout | split row (char nul)
    | where { |p| not ($p | is-empty) and not ($p | str ends-with "/") }
    | where { |p| ($drop | get -o $p) == null }
    | where { |p| not (($p | str starts-with ".git/") or ($p | str starts-with ".task/")
                      or ($p | str contains "/.git/") or ($p | str contains "/.task/")) }
}

# Enumerate several scopes at once, returning `{scope: [paths]}` in the path
# space of `root`.
#
# The backends want opposite shapes. git's cost is per invocation, not per
# path, so one call covering every scope beats one call each. The walk's cost is
# what it descends, so it descends each scope and nothing else. Either way a
# scope is enumerated once per invocation, which is the point: a deep graph
# otherwise names the same directory once per dependent.
def norm-segs [s: string]: nothing -> list<string> {
  mut st = []
  for seg in ($s | split row "/" | where { |x| not ($x | is-empty) and $x != "." }) {
    if $seg == ".." and (not ($st | is-empty)) and (($st | last) != "..") {
      $st = ($st | drop 1)
    } else {
      $st ++= [$seg]
    }
  }
  $st
}

def norm-scope [s: string]: nothing -> string {
  norm-segs $s | str join "/"
}

def bucket-scopes [whole: list<string>, want: list<string>]: nothing -> record {
  # Group scopes by canonical segment count so each distinct depth runs one
  # builtin `group-by` pass and every scope resolves by direct key lookup
  # (including `./app` spellings) instead of scanning deeper sibling keys.
  $want
  | each { |s| {raw: $s, norm: (norm-scope $s)} }
  | group-by { |it| $it.norm | split row "/" | length }
  | transpose depth_str scopes_at_depth
  | each { |g|
    let d = ($g.depth_str | into int)
    let buckets = ($whole | group-by { |p|
      let segs = ($p | split row "/")
      if ($segs | length) > $d { $segs | first $d | str join "/" } else { "" }
    })
    $g.scopes_at_depth | each { |it|
      {$it.raw: ($buckets | get -o ([$it.norm] | into cell-path) | default [])}
    }
  }
  | flatten
  | into record
}

export def enumerate-scopes [
  root: string
  scopes: list<string>
  flavor: string = "git"
]: nothing -> record {
  # The repo root is not enumerated for either backend. git would walk the
  # whole tree for it and the walk would descend it; a target scoped there
  # names literal paths (go.mod and friends) that need no enumeration, and one
  # that does not still answers through the on-demand path below.
  let want = ($scopes | uniq | where { |s| not ((norm-scope $s) | is-empty) })
  if ($want | is-empty) { return {} }
  # Pathspecs: git lists the scopes asked for instead of the repo, so it reads
  # less of the index and the bucketing below has less to place.
  let whole = if $flavor == "git" { git-enumerate $root ($want | each { |s| norm-scope $s } | uniq) } else { null }
  if $whole != null {
    return (bucket-scopes $whole $want)
  }
  $want
  | par-each --keep-order { |s| {$s: (walk-scope $root $s $flavor)} }
  | into record
}

def has-nested-git [root_exp: string, segs: list<string>]: nothing -> bool {
  ($segs | enumerate | any { |it|
    let rel = ($segs | first ($it.index + 1) | str join "/")
    ($root_exp | path join $rel ".git" | path exists)
  })
}

def in-repo-scope [root_exp: string, s: string]: nothing -> bool {
  let segs = (norm-segs $s)
  if ($segs | is-empty) or ($segs | any { |seg| $seg == ".." }) { return false }
  let r_segs = ($root_exp | path split)
  let p_segs = ($root_exp | path join ($segs | str join "/") | path expand | path split)
  if not ((($p_segs | length) > ($r_segs | length)) and (($p_segs | first ($r_segs | length)) == $r_segs)) {
    return false
  }
  not (has-nested-git $root_exp $segs)
}

# Enumerate several scopes once while isolating per-scope walk errors so a
# batch caller (depot-plan) keeps healthy listings and records each failing
# scope's error without walking any scope twice.
export def enumerate-scopes-isolated [
  root: string
  scopes: list<string>
  flavor: string = "git"
]: nothing -> record {
  let want = ($scopes | uniq | where { |s| not ((norm-scope $s) | is-empty) })
  if ($want | is-empty) { return {trees: {}, errors: {}} }
  let root_exp = ($root | path expand)
  let in_repo = ($want | where { |s| in-repo-scope $root_exp $s })
  let out_repo = ($want | where { |s| not (in-repo-scope $root_exp $s) })
  let whole = if $flavor == "git" and not ($in_repo | is-empty) {
    try { git-enumerate $root ($in_repo | each { |s| norm-scope $s } | uniq) } catch { null }
  } else { null }
  let git_trees = if $whole != null { bucket-scopes $whole $in_repo } else { {} }
  let pending = if $whole != null { $out_repo } else { $want }
  if ($pending | is-empty) {
    return {trees: $git_trees, errors: {}}
  }
  let try_git = if ($flavor == "git") and (which git | is-not-empty) {
    let top = (do -i { ^git -C $root rev-parse --show-toplevel } | complete)
    ($top.exit_code == 0) and (($top.stdout | str trim) == $root)
  } else { false }
  let outcomes = ($pending | par-each --keep-order { |s|
    try {
      let paths = if $try_git and (in-repo-scope $root_exp $s) {
        walk-scope $root $s $flavor
      } else {
        walk-scope $root $s $flavor --no-git
      }
      {scope: $s, paths: $paths, err: null}
    } catch { |err|
      {scope: $s, paths: null, err: ($err.rendered? | default $err.msg)}
    }
  })
  {
    trees: ($git_trees | merge ($outcomes | where { |r| $r.err == null } | each { |r| {$r.scope: $r.paths} } | into record))
    errors: ($outcomes | where { |r| $r.err != null } | each { |r| {$r.scope: $r.err} } | into record)
  }
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
  let norm_segs = (norm-segs $sub)
  if ($norm_segs | any { |seg| $seg == ".git" or $seg == ".task" }) { return [] }
  if (not ($norm_segs | is-empty)) and (not ($norm_segs | any { |seg| $seg == ".." })) and (has-nested-git ($root | path expand) $norm_segs) { return [] }
  let norm_sub = ($norm_segs | str join "/")
  let fast = if $flavor == "git" and (not $no_git) {
    git-enumerate $root (if ($norm_sub | is-empty) { [] } else { [$norm_sub] })
  } else { null }
  if $fast != null { return $fast }

  let ignore_name = if $flavor == "docker" { ".dockerignore" } else { ".gitignore" }
  let segs = $norm_segs
  # Ancestors shallowest-first, so a deeper file overrides a shallower one.
  let bases = ([""] ++ ($segs | enumerate | each { |it| $segs | first ($it.index + 1) | str join "/" }))
  let seeded = ($bases | drop 1 | prepend "" | uniq | each { |b|
    let f = if ($b | is-empty) { $"($root)/($ignore_name)" } else { $"($root)/($b)/($ignore_name)" }
    if ($f | path exists) { parse-file (open --raw $f) $b $flavor } else { [] }
  } | flatten)
  let start = if ($norm_sub | is-empty) { $root } else { $"($root)/($norm_sub)" }
  # The scope's own ignore file is read by the walk itself, so drop it here.
  let seeded = ($seeded | where { |r| $r.base != $norm_sub })
  walk $start (compile-rules $seeded) $norm_sub $flavor
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

  # The same boundary the directory branch applies: in a git worktree `.git`
  # is a file holding `gitdir: ...`, not a directory, so a type-blind check is
  # what keeps one commit from fingerprinting differently in a worktree than
  # in a plain clone.
  let kept = ($entries | where type != dir | each { |f|
    if $f.name == ".git" or $f.name == ".task" { null } else {
      let p = if ($rel | is-empty) { $f.name } else { $"($rel)/($f.name)" }
      if (ignored? $p false $rules) { null } else { $p }
    }
  } | where { |x| $x != null })

  let descended = ($entries | where type == dir | each { |d|
    let p = if ($rel | is-empty) { $d.name } else { $"($rel)/($d.name)" }
    # `.git` and `.task` are tool boundaries, not project source content.
    if $d.name == ".git" or $d.name == ".task" { [] } else if (ignored? $p true $rules) { [] } else {
      walk $"($dir)/($d.name)" $rules $p $flavor
    }
  } | flatten)

  $kept ++ $descended
}
