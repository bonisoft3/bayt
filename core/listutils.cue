// listutils.cue — small, named comprehension helpers that show up
// repeatedly across gen_*.cue. Each is one line of inlineable CUE;
// the value of pulling them out is naming the intent and giving a
// single grep target when the implementation needs to change.
//
// Hidden (`_`-prefixed) so they don't surface in `cue export`.
// Package-scoped, like every other helper here.
package bayt

// _uniqStrings — order-preserving uniq over a list of strings; keeps
// each value at its first occurrence. Linear: a struct keyed by value keeps
// fields in first-insertion order; a prefix scan copies a slice per element.
_uniqStrings: {
	in:  [...string]
	out: [for k, _ in {for v in in {(v): _}} {k}]
}
