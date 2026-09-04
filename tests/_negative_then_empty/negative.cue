// An empty `then` entry renders `()`, which is a shell *parse* error: the
// RUN never executes at all, so the install goes down with it and the
// build fails naming a bare `()` with nothing pointing back at the field.
//
// Projected inline, the way a consumer writes it. That is the point of the
// list shape — the same value behind an optional scalar `then?` renders
// clean here, because the constraint is never reached.
//
// Paired with tests/_positive_preamble, which must stay green: eval-fail
// accepts any non-zero exit, so unrelated breakage would keep this
// vacuously passing.
package negative_then_empty

import apt "github.com/bonisoft3/bayt/distros/apt"

out: (apt.#install & {pkgs: ["curl"], then: [""]}).out

// A blank entry is the same parse error by a different route, and the one a
// generator actually produces — `strings.Join` over a list whose entries are
// themselves empty. Guarded here rather than left to the `!=""` half, which
// it walks straight past.
blank: (apt.#install & {pkgs: ["curl"], then: [" "]}).out
