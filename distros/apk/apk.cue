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

	// See distros/apt for `then` / `purge`. `apk del` drops the
	// dependencies that came in alongside the named packages.
	then: [...string & =~"[^[:space:]]" & !~"\n"]
	purge: [...string & !="" & !~"\n"]

	let _then = [if len(I.then) > 0 {"; (cd \"$p\" && \(strings.Join(I.then, " && "))) || exit"}, ""][0]
	let _purge = [if len(I.purge) > 0 {"; apk del \(strings.Join(I.purge, " ")) || exit"}, ""][0]

	let _pwd = [if len(I.then) > 0 {"p=\"$PWD\"; "}, ""][0]
	let _seed = "s=/apk-store; d=/var/cache/apk; mkdir -p \"$s\" \"$d\"; cp -r \"$s\"/. \"$d\"/ 2>/dev/null || true; "
	let _publish = "; cd \"$d\" && for f in *.apk; do [ -f \"$f\" ] || continue; o=\"$s/$f\"; [ -e \"$o\" ] && continue; t=\"$(mktemp \"$s/.pXXXXXX\")\" && cp \"$f\" \"$t\" && mv -f \"$t\" \"$o\"; done; :"

	out: {
		do:    "\(_pwd)\(_seed)apk add --cache-dir=/var/cache/apk \(strings.Join(I.pkgs, " ")) || exit\(_publish)\(_then)\(_purge)"
		shell: "sh"
		mounts: [_store, _cacheMount]
	}
}

// #users holds standard system user identities for Alpine Linux distributions.
// Note: on Alpine, nobody's default primary group is 'nobody' (GID 65534),
// while 'nogroup' is GID 65533.
#users: {
	root: {
		name:  "root"
		group: "root"
		uid:   0
		gid:   0
		chown: "0:0"
		user:  "0:0"
	}
	nobody: {
		name:  "nobody"
		group: "nobody"
		uid:   65534
		gid:   65534
		chown: "65534:65534"
		user:  "65534:65534"
	}
	nogroup: {
		name:  "nobody"
		group: "nogroup"
		uid:   65534
		gid:   65533
		chown: "65534:65533"
		user:  "65534:65533"
	}
	vscode: {
		name:  "vscode"
		group: "vscode"
		uid:   1000
		gid:   1000
		chown: "1000:1000"
		user:  "1000:1000"
	}
	// Alpine postgresql package
	postgres: {
		name:  "postgres"
		group: "postgres"
		uid:   70
		gid:   70
		chown: "70:70"
		user:  "70:70"
	}
}


