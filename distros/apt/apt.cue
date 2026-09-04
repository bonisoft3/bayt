// distros/apt — Debian/Ubuntu package installs.
//
//   dockerfile: defaultPreamble: "pgclient": {priority: -8} &
//       (apt.#install & {pkgs: ["curl", "jq"]}).out
//
//   // on a shared target; `dockerfile:` because an install has no host form
//   cmd: "builtin": dockerfile: (apt.#install & {pkgs: [...]}).out
//
// `pkgs` is a regular field rather than hidden: a hidden field set by a
// consumer in another package is a different field, so the packages would
// vanish from the command with no error. `out` carries only the preamble
// arm's own fields, which is what lets it satisfy that arm's closedness.
package apt

import "strings"

// apt's own working dirs stay private to a target: its lock lives in the
// archive dir, and `apt-get update` prunes list files that don't match the
// current sources, so a project with two targets on two distros would have
// each run wiping the other's index.
_archiveMount: {type: "cache", target: "/var/cache/apt", scope: "target"}
_listsMount: {type: "cache", target: "/var/lib/apt/lists", scope: "target"}

// The store is the shared half: a .deb filename carries name, version and
// arch, so two distros cannot collide on one entry. Concurrency is safe
// because apt never touches the store — the seed and publish steps below
// are its only writers, and publish goes through mktemp+mv.
//
// Content is not: apt validates a cached archive by name and size, never by
// hash, so a same-size file under the right name reaches dpkg unchecked.
// Corruption fails loudly at unpack; a crafted same-size deb would not,
// leaving this store only as trustworthy as whatever can write to the
// builder. apk and zypper re-verify a cached file against repo metadata and
// do not carry this.
_store: {type: "cache", target: "/apt-store", scope: "global"}

// install — `apt-get install`.
//
// Debian images ship /etc/apt/apt.conf.d/docker-clean, which erases the
// archive after every install, so the RUN deletes it and sets
// Keep-Downloaded-Packages; without both the archive mount stays empty.
//
// update and install share one RUN: split across two, the update layer
// caches indefinitely and the install eventually resolves against a pruned
// index. No `rm -rf /var/lib/apt/lists/*` tail — the lists live on a mount,
// so that would only delete the next build's index.
#install: I={
	// Bare names. Debian and Ubuntu keep one revision per package in
	// -updates/-security — the noble archive offers curl 8.5.0-2ubuntu10.12
	// and 8.5.0-2ubuntu10 and nothing between — so an exact pin here is a
	// build failure with a date on it. For reproducibility, either
	// `snapshot` below or a leap base and distros/zypper, whose archive
	// retains versions.
	pkgs: [...string]

	// Build-only packages, all inside the install's own RUN: `then` runs
	// once they are in place, `purge` takes them out again, and
	// `--auto-remove` drops whatever apt then considers orphaned, which is
	// not only what `pkgs` pulled in — a base package already marked
	// auto-installed and orphaned for its own reasons goes too.
	// Order is install → publish → then → purge; tests/_positive_preamble
	// pins it and says why.
	//
	// `then` sees the repo only from the cmd position. In `defaultPreamble`
	// the RUN is emitted before `add`, the copy arms and the source COPYs,
	// so the workdir is still empty there and `then` can only work on what
	// the entry itself fetched. Put the fragment under
	// `cmd.<n>.dockerfile` when it has to compile checked-out sources.
	//
	// A list, like `pkgs`, so the element constraints are reached — see
	// tests/_negative_then_empty. Entries join with `&&`, so the first
	// failure stops the rest. Each must carry a non-space character: a
	// blank one renders `( )`, the same parse error an empty one does, and
	// both arrive from a mixin joining nothing rather than from anything an
	// author typed.
	then: [...string & =~"[^[:space:]]" & !~"\n"]
	purge: [...string & !="" & !~"\n"]

	// Fixes resolution at a point in time, which makes a version pin
	// redundant. Only the distro's own sources are rewritten, so any
	// third-party repo the base image ships (nodesource, pgdg, a vendor
	// mirror) keeps its live host and stays unreproducible.
	//
	// Costs ~40-70s on the first `apt-get update`, which the lists mount
	// amortizes across rebuilds of a target.
	//
	// Ubuntu only. Debian's sources carry a second `-security` stanza on a
	// separate snapshot path, so that arm needs its own rewrite.
	snapshot?: {
		at:     string & =~"^[0-9]{8}T[0-9]{6}Z$"
		distro: "ubuntu"
	}

	let _snap = [
		if I.snapshot != _|_ {
			"sed -i 's|^URIs: https\\?://[^ ]*ubuntu[^ ]*|URIs: https://snapshot.ubuntu.com/ubuntu/\(I.snapshot.at)|' /etc/apt/sources.list.d/ubuntu.sources && "
		},
		"",
	][0]

	// Seed from the store, install, publish anything new back. `|| exit`
	// keeps a real install failure fatal; the publish loop's trailing `:`
	// keeps a torn dedup write from failing a good install.
	let _pwd = [if len(I.then) > 0 {"p=\"$PWD\"; "}, ""][0]
	let _seed = "s=/apt-store; d=/var/cache/apt/archives; mkdir -p \"$s\" \"$d\"; cp -r \"$s\"/. \"$d\"/ 2>/dev/null || true; "

	// Fatal like the install.
	let _then = [if len(I.then) > 0 {"; (cd \"$p\" && \(strings.Join(I.then, " && "))) || exit"}, ""][0]
	let _purge = [if len(I.purge) > 0 {"; DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq --auto-remove \(strings.Join(I.purge, " ")) || exit"}, ""][0]

	let _publish = "; cd \"$d\" && for f in *.deb; do [ -f \"$f\" ] || continue; o=\"$s/$f\"; [ -e \"$o\" ] && continue; t=\"$(mktemp \"$s/.pXXXXXX\")\" && cp \"$f\" \"$t\" && mv -f \"$t\" \"$o\"; done; :"

	out: {
		do:    "\(_pwd)\(_seed)\(_snap)rm -f /etc/apt/apt.conf.d/docker-clean && echo 'Binary::apt::APT::Keep-Downloaded-Packages \"true\";' > /etc/apt/apt.conf.d/keep-cache && apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \(strings.Join(I.pkgs, " ")) || exit\(_publish)\(_then)\(_purge)"
		shell: "sh"
		mounts: [_store, _archiveMount, _listsMount]
	}
}
