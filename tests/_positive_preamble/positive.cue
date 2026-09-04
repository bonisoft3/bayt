// A distro fragment composes into both positions a package install can
// occupy. Consumer-side on purpose: this is what a project does, and it
// proves the fragment carries everything the two positions need without
// the consumer knowing the distro's internals.
//
// Rendering is covered by core/preamble_check.cue; what's pinned here is
// that the fragments satisfy the schema in both positions, which is the
// property that would break if the preamble arm or #cmd.dockerfile drifted.
package positive_preamble

import (
	bayt "github.com/bonisoft3/bayt/core:bayt"
	apt "github.com/bonisoft3/bayt/distros/apt"
	apk "github.com/bonisoft3/bayt/distros/apk"
	zypper "github.com/bonisoft3/bayt/distros/zypper"
)

_p: bayt.#project & {
	name: "pre"
	dir:  "pre"
	targets: {
		// Preamble position, alongside the other two arms, plus a
		// repo-derived `copy` that must stay expressible beside them.
		"build": {
			cmd: "builtin": do: "true"
			srcs: globs: ["src/**"]
			dockerfile: bayt.nubox & {
				defaultPreamble: {
					"env": {priority: -20, line: "ENV FOO=bar"}
					"pin": {priority: -19, copy: {
						from: {name: "busybox:musl@sha256:03db190ed4c1ceb1c55d179a0940e2d71d42130636a780272629735893292223"}
						srcs: ["/bin/busybox"]
						dst: "/busybox"
					}}
					"pkgs": {priority: -18} & (zypper.#install & {pkgs: ["which=2.23-160000.2.2"]}).out
					"apk": {priority: -17} & (apk.#install & {pkgs: ["curl", "jq"]}).out
				}
				copy: [{srcs: ["src/app.conf"], dst: "/etc/app.conf"}]
			}
		}
		// Cmd position. `dockerfile:` is required rather than decorative:
		// a package install has no host form, so it belongs on the
		// container axis only.
		"deps": {
			cmd: "builtin": dockerfile: (apt.#install & {pkgs: ["curl"]}).out
			dockerfile: from: name: "debian:bookworm-slim@sha256:0000000000000000000000000000000000000000000000000000000000000000"
		}
	}
}

project: _p

// --- assertions -----------------------------------------------------------

_aptCmd: _p.targets.deps.cmd.builtin.dockerfile

// Both apt mounts take the project arm: locked (apt is not
// concurrency-safe) and scoped so the lock stops at the project boundary
// rather than serializing every install in the monorepo.
_apt_mount_count: len(_aptCmd.mounts) & 3
// One shared store plus apt's two private working dirs. The store must be
// the shared one and the working dirs must not be: apt's lock lives in the
// archive dir, so sharing that is what makes concurrent installs fail.
_apt_scopes: [for m in _aptCmd.mounts {m.scope}] & ["global", "target", "target"]

// Each manager owns its own store rather than sharing one by convention:
// the subdir split that a single store needed was an unenforced naming
// agreement between three files, and a collision would seed one manager
// artifacts belonging to another.
_apt_store_target:    _aptCmd.mounts[0].target & "/apt-store"
_apk_store_target:    _apkEntry.mounts[0].target & "/apk-store"
_zypper_store_target: _zypperEntry.mounts[0].target & "/zypper-store"

// Seed before, publish after, and a hard exit between them so a failed
// install cannot reach the publish step.
_apt_seeds:            _aptCmd.do & =~"^s=/apt-store; d=/var/cache/apt/archives"
_apt_publishes:        _aptCmd.do & =~"mktemp .* && cp .* && mv -f"
_apt_exits_on_failure: _aptCmd.do & =~"\\|\\| exit"

// The docker-clean removal is load-bearing: Debian images erase the
// archive after every install, which would leave the mount empty.
_apt_unclean: _aptCmd.do & =~"rm -f /etc/apt/apt.conf.d/docker-clean"

// update and install stay in one RUN — split, the update layer caches
// indefinitely and the install resolves against a pruned index.
_apt_fused: _aptCmd.do & =~"apt-get update.*apt-get install"

// No `rm -rf /var/lib/apt/lists/*` tail: with the mount that deletes the
// shared index for the next build instead of shrinking the layer.
_apt_keeps_lists: _aptCmd.do & !~"rm -rf /var/lib/apt/lists"

// The package list must actually reach the command. Getting this wrong is
// silent — the install runs with no packages and no error (see distros/apt
// on why `pkgs` cannot be hidden). The bare name is deliberate: apt takes
// unpinned packages because its archive keeps one revision, so requiring a
// pin would encode a build failure with a date on it.
_apt_pkgs_present:    _aptCmd.do & =~"--no-install-recommends curl"
_zypper_pkgs_present: _zypperEntry.do & =~"which=2\\.23-160000\\.2\\.2"

_zypperEntry: _p.targets.build.dockerfile.defaultPreamble.pkgs
_zypper_scopes: [for m in _zypperEntry.mounts {m.scope}] & ["global", "target"]
_zypper_seeds: _zypperEntry.do & =~"^s=/zypper-store; d=/var/cache/zypp/packages"

// Walking only one depth drops the rest from the store with no error: the
// install still works, it just re-downloads forever.
_zypper_walks_both_depths: _zypperEntry.do & =~"for f in \\*/\\*\\.rpm \\*/\\*/\\*\\.rpm; do"

// A lock entry that never lands would pin nothing while looking like it did.
_zypperLocked: (zypper.#install & {
	pkgs: ["which=2.23-160000.2.2"]
	lock: ["glibc=2.40-160000.6.1"]
}).out
_zypper_lock_lands: _zypperLocked.do & =~"which=2.23-160000.2.2 glibc=2.40-160000.6.1"
// Pins the ENTIRE package list, not the absence of some unrelated name: a
// default silently appended to `lock` would land in every zypper install in
// the tree, and only an exact-list assertion sees it.
_zypper_lock_default_empty: _zypperEntry.do & =~"install which=2\\.23-160000\\.2\\.2 \\|\\| exit"

// The revert has to be last. `--no-keep-packages` empties the package
// cache, so running it before the publish leaves the store empty — and
// leaving it out entirely ships keeppackages=1 in the layer.
_zypper_reverts_last: _zypperEntry.do & =~"mv -f .*done; zypper -n modifyrepo --no-keep-packages --all \\|\\| true$"

_apkEntry: _p.targets.build.dockerfile.defaultPreamble.apk

// apk is the one arm that cannot enforce pins, so what it must get right
// is the mount: `--cache-dir` is what enables caching AND points it at the
// mount, and `--no-cache` would defeat it.
_apk_pkgs_present: _apkEntry.do & =~"curl jq"
_apk_cache_dir:    _apkEntry.do & =~"--cache-dir=/var/cache/apk"
_apk_no_nocache:   _apkEntry.do & !~"--no-cache"
_apk_scopes: [for m in _apkEntry.mounts {m.scope}] & ["global", "target"]
_apk_seeds:     _apkEntry.do & =~"^s=/apk-store; d=/var/cache/apk"
_apk_publishes: _apkEntry.do & =~"mktemp .* && cp .* && mv -f"

// The snapshot option is off unless asked for, and when asked for it emits
// exactly the rewrite verified against the noble base: only the distro's
// own sources file, leaving any third-party repo in the image alone.
_aptSnap: (apt.#install & {pkgs: ["curl"], snapshot: {at: "20250601T000000Z", distro: "ubuntu"}}).out

_apt_no_snapshot_by_default:        _aptCmd.do & !~"snapshot.ubuntu.com"
_apt_snapshot_rewrites_distro_only: _aptSnap.do & =~"snapshot.ubuntu.com/ubuntu/20250601T000000Z.*/etc/apt/sources.list.d/ubuntu.sources"
_apt_snapshot_precedes_update:      _aptSnap.do & =~"sed -i.*&& rm -f /etc/apt/apt.conf.d/docker-clean"

// --- build-only packages --------------------------------------------------

// Install, use and remove must share one RUN: Docker commits a layer per
// RUN, so a package removed in a later one has already shipped and the
// removal only adds a layer.
//
// Order is the assertion, and the publish sits in the middle of it. A purge
// before `then` takes away what the build needs; a publish after `then`
// throws away the packages just downloaded whenever the compile fails,
// which is the normal iteration state — BuildKit commits no layer for a
// failed RUN, so nothing is gained by withholding the store write.
_aptBuildOnly: (apt.#install & {
	pkgs: ["build-essential"]
	then: ["make", "make install"]
	purge: ["build-essential"]
}).out

_apt_publish_follows_install: _aptBuildOnly.do & =~"install -y -qq --no-install-recommends build-essential \\|\\| exit; cd "
_apt_then_follows_publish:    _aptBuildOnly.do & =~"done; :; \\(cd \"\\$p\" && make && make install\\) \\|\\| exit"
_apt_purge_follows_then:      _aptBuildOnly.do & =~"make install\\) \\|\\| exit; DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq --auto-remove build-essential \\|\\| exit$"

// Entries join with `&&`, not `; `. A subshell reports its LAST command's
// status, so `(make; make install)` lets a failed `make` through whenever
// `make install` happens to exit 0 — a broken build that ships.
_apt_then_joins: _aptBuildOnly.do & =~"make && make install\\)"

// `then` runs after the publish, which cds into the package-cache mount in
// this same shell. Without the capture the build would run in
// /var/cache/apt/archives and write into a mount that is discarded.
_apt_then_restores_workdir: _aptBuildOnly.do & =~"^p=\"\\$PWD\"; s=/apt-store"
// And the capture appears only when there is a `then` to need it, so the
// plain install stays byte-identical.
_apt_no_pwd_capture_by_default: _aptCmd.do & =~"^s=/apt-store"

// The purge runs maintainer scripts, which prompt for debconf-registered
// packages. The inline assignment on the install line does not carry.
_apt_purge_noninteractive: _aptBuildOnly.do & =~"noninteractive apt-get purge"

// Each half is independently optional, and each alone must still render a
// command that parses — the empty and multi-line arms are rejected by the
// schema, so what is left to pin is that neither omission strands a `;`.
_aptThenOnly: (apt.#install & {pkgs: ["gcc"], then: ["make"]}).out
_aptPurgeOnly: (apt.#install & {pkgs: ["gcc"], purge: ["gcc"]}).out
_apt_then_only:  _aptThenOnly.do & =~"done; :; \\(cd \"\\$p\" && make\\) \\|\\| exit$"
_apt_purge_only: _aptPurgeOnly.do & =~"done; :; DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq --auto-remove gcc \\|\\| exit$"

// Absent both, the command is exactly what it was: install, then publish.
// Asserting the adjacency rather than the absence of a substring — an empty
// `then` rendering as a stray `;` would pass a mere absence check.
_apt_unchanged_by_default: _aptCmd.do & =~"--no-install-recommends curl \\|\\| exit; cd "

_apkBuildOnly: (apk.#install & {
	pkgs: ["gcc", "musl-dev"]
	then: ["cc -o /out x.c"]
	purge: ["gcc", "musl-dev"]
}).out

_apk_sequence:             _apkBuildOnly.do & =~"gcc musl-dev \\|\\| exit; cd .*done; :; \\(cd \"\\$p\" && cc -o /out x.c\\) \\|\\| exit; apk del gcc musl-dev \\|\\| exit$"
_apk_unchanged_by_default: _apkEntry.do & =~"curl jq \\|\\| exit; cd "

_zypperBuildOnly: (zypper.#install & {
	pkgs: ["gcc=13-150000.1.1"]
	then: ["make"]
	purge: ["gcc"]
}).out

// Pinned on the way in, bare on the way out: a removal resolves against
// what is installed. zypper accepts a pin here too, so this is a
// convention the schema does not enforce.
_zypper_sequence: _zypperBuildOnly.do & =~"gcc=13-150000\\.1\\.1 \\|\\| exit; cd .*\\(cd \"\\$p\" && make\\) \\|\\| exit; zypper -n remove --clean-deps gcc \\|\\| exit$"

// The keep-packages revert must still follow the publish loop — before it
// the store ends up empty, omitted entirely it ships keeppackages=1 in the
// layer. It no longer ends the command, but nothing after it re-enables the
// setting.
_zypper_reverts_after_publish: _zypperBuildOnly.do & =~"mv -f .*done; zypper -n modifyrepo --no-keep-packages --all \\|\\| true; \\(cd "
