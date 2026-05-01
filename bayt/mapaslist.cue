// mapaslist.cue — the "map keyed by name, ordered by priority"
// pattern. CUE lists unify length-strict and positionally — `[a, b]
// & [c]` errors, `[a, b] & [c, d]` unifies pairwise — which makes
// them a poor representation for anything composable. Maps unify by
// key: `{a: 1, b: 2} & {c: 3}` → `{a: 1, b: 2, c: 3}`, and
// `{a: 1} & {a: 2}` errors with a precise "conflicting values"
// message. So everywhere a downstream tool wants an ordered list of
// named entries (taskfile cmds, dockerfile RUN rules, ...) we model
// the source-of-truth as a map and emit a list at the end.
//
// Three composition operations come for free:
//
//   - replace : same key, conflicting value → CUE error (loud).
//   - extend  : same key, compatible value  → field-by-field merge.
//   - delete  : assign `null` to the key (filtered at emit time).
//
// This is the same insight as docker-compose's `!override` / `!reset`
// YAML tag extensions: compose.yaml's authors hit the same length-
// strict-list problem and bolted on per-list-element override syntax.
// CUE doesn't need the bolt-on — the pattern falls out of unification
// once you stop trying to carry order in lists.
//
// `priority?: int` (defaulted to 0 at #MapToList time) controls the
// emit order. Ties break alphabetically by name for stability.
//
// Usage:
//
//   targets: "build": cmd: {
//       "lint":   {do: "ruff check", priority: -10}  // earlier
//       "build":  {do: "go build"}                   // priority 0
//       "stamp":  {do: "touch .stamp", priority: 10} // later
//       "legacy": null                               // dropped
//   }
//
//   cmds: (#MapToList & {in: cmd}).out
//   // → [{name:"lint", do:"ruff check"},
//   //    {name:"build", do:"go build"},
//   //    {name:"stamp", do:"touch .stamp"}]
//
// Lifted from sayt's config.cue so bayt doesn't depend on `say`.
package bayt

import "list"

#MapAsList: {
	#el: {name: string, priority?: int, ...}
	[Name=_]: #el & {name: Name} | null
}

#MapToList: {
	in: {[string]: #MapAsList.#el | null}
	_flat: [for v in in if v != null {v & {priority: *0 | int}}]
	out: [
		for i in list.Sort(_flat, {
			x: {}
			y: {}
			less: (x.priority < y.priority) ||
				(x.priority == y.priority && x.name < y.name)
		}) {
			{for k, v in i if k != "priority" {(k): v}}
		},
	]
}
