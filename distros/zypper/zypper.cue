// distros/zypper — openSUSE / SLES package installs. See distros/apt for
// the call shape and why `pkgs` is a regular field.
package zypper

import (
	"list"
	"strings"
)

// The whole cache, not just packages/: zypper's metadata (raw/, solv/) is
// ~69MB of build-time scratch that would otherwise ride the layer.
//
// zypper takes its own lock, hence the non-concurrent scope (see #mount).
_cacheMount: {type: "cache", target: "/var/cache/zypp", scope: "target"}

// The shared half — see distros/apt. The store mirrors the cache's own
// directory layout rather than flattening: zypper only looks for an rpm
// under the path it belongs to, so a flat store could not be seeded back.
_store: {type: "cache", target: "/zypper-store", scope: "global"}

// install — `zypper install`.
//
// The `modifyrepo --keep-packages` prefix is load-bearing: zypper deletes
// each .rpm after installing it, so without the flip the mount stays empty.
// The setting is volatile on service-managed repos (zypper warns it "is
// reset by the next service refresh"), so it is re-applied inside every
// install RUN rather than set once in a base stage.
//
// It is also reverted before the RUN ends. `modifyrepo` rewrites
// /etc/zypp/repos.d/*.repo, which unlike the cache lands in the layer and
// is inherited by every descendant and shipped image, so leaving it set
// would make a later install with no mount silently retain its rpms in the
// image.
//
// No clean tail: every `zypper clean` empties the mount, `--metadata`
// included despite the name, and with the cache mounted there is nothing
// left in the layer to reclaim.
#install: I={
	// What this stage needs. Pinned, unlike apt and apk: leap retains
	// versions for the life of a release, so a pin resolves for as long as
	// the base image does.
	pkgs: [...string & =~"^[^=]+=[^=]+$"]

	// Transitive packages, pinned to hold the closure still. A pin covers
	// what it names and nothing else — the solver takes current versions
	// for the rest, from a repo that moves independently of the base image
	// digest. There is no snapshot to fix the whole resolution at, so the
	// closure is pinned by naming it; `zypper --xmlout install --dry-run`
	// produces the list.
	//
	// Identical to `pkgs` in effect, both landing in the same install. The
	// split records which entries were chosen and which are here to stop
	// the ground moving, so regenerating one leaves the other alone.
	lock: [...string & =~"^[^=]+=[^=]+$"]

	// Seed, install, publish, then revert. An rpm lands at
	// `packages/<arch>/` or at `packages/<repo>/<arch>/` depending on which
	// repo served it, and the leap base ships no `find`, so each depth gets
	// its own fixed glob.
	let _seed = "s=/zypper-store; d=/var/cache/zypp/packages; mkdir -p \"$s\" \"$d\"; cp -r \"$s\"/. \"$d\"/ 2>/dev/null || true; "
	// The leap base serves its repos over plaintext http; where those
	// connections come back empty, zypper skips the repo and every pinned
	// package resolves to "no provider". The service pin precedes the rewrite
	// because a RIS service regenerates these .repo files at their http
	// baseurls during an install. Not --disable: that drops the repos with it.
	let _https = "zypper -n modifyservice --no-refresh --all; sed -i 's|http://|https://|g' /etc/zypp/repos.d/*.repo; "
	let _publish = "; cd \"$d\" && for f in */*.rpm */*/*.rpm; do [ -f \"$f\" ] || continue; o=\"$s/$f\"; [ -e \"$o\" ] && continue; mkdir -p \"$(dirname \"$o\")\"; t=\"$(mktemp \"$(dirname \"$o\")/.pXXXXXX\")\" && cp \"$f\" \"$t\" && mv -f \"$t\" \"$o\"; done; zypper -n modifyrepo --no-keep-packages --all || true"

	out: {
		do:    "\(_seed)\(_https)zypper -n modifyrepo --keep-packages --all && zypper -n install \(strings.Join(list.Concat([I.pkgs, I.lock]), " ")) || exit\(_publish)"
		shell: "sh"
		mounts: [_store, _cacheMount]
	}
}
