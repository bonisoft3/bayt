// distros/apk — Alpine / Wolfi package installs. See distros/apt for the
// call shape and why `pkgs` is a regular field.
package apk

import "strings"

// apk keeps a lock in this dir, hence the non-concurrent scope (see #mount).
_cacheMount: {type: "cache", target: "/var/cache/apk", scope: "target"}

// The shared half — see distros/apt. .apk filenames carry name and
// version, and only the seed and publish steps touch this.
_store: {type: "cache", target: "/apk-store", scope: "global"}

// install — `apk add`.
//
// Bare names: `pkg=1.2.3-r0` parses, but Alpine prunes old versions and
// publishes no snapshot archive, so a pin that resolves today can 404
// later. Where byte-reproducibility matters a `COPY --from=<pinned digest>`
// beats installing at all — an image digest cannot be pruned.
#install: I={
	pkgs: [...string]

	let _seed = "s=/apk-store; d=/var/cache/apk; mkdir -p \"$s\" \"$d\"; cp -r \"$s\"/. \"$d\"/ 2>/dev/null || true; "
	let _publish = "; cd \"$d\" && for f in *.apk; do [ -f \"$f\" ] || continue; o=\"$s/$f\"; [ -e \"$o\" ] && continue; t=\"$(mktemp \"$s/.pXXXXXX\")\" && cp \"$f\" \"$t\" && mv -f \"$t\" \"$o\"; done; :"

	out: {
		do:    "\(_seed)apk add --cache-dir=/var/cache/apk \(strings.Join(I.pkgs, " ")) || exit\(_publish)"
		shell: "sh"
		mounts: [_store, _cacheMount]
	}
}
