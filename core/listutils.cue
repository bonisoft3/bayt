// listutils.cue — small, named comprehension helpers that show up
// repeatedly across gen_*.cue. Each is one line of inlineable CUE;
// the value of pulling them out is naming the intent and giving a
// single grep target when the implementation needs to change.
//
// Hidden (`_`-prefixed) so they don't surface in `cue export`.
// Package-scoped, like every other helper here.
package bayt

import "list"

// _uniqStrings — order-preserving uniq over a list of strings; keeps
// each value at its first occurrence. O(n²) — target graphs are small,
// not worth a hash-table workaround.
_uniqStrings: {
	in:  [...string]
	out: [for i, v in in if !list.Contains(list.Slice(in, 0, i), v) {v}]
}
