#!/usr/bin/env nu
# bazel_remote.nu — a disposable bazel-remote for the cache integration
# tests. Shared by every suite that needs one; not a test itself.
#
# Through docker rather than a mise-installed binary: upstream publishes no
# windows asset, so pinning the binary as a tool would make these suites —
# and so bayt's test story — linux/macos only. Docker itself is native on
# windows, which keeps the suites reachable everywhere.
#
# Storage is a named volume, never a bind: a host path would put the POSIX
# layout back into the one thing docker was chosen to keep portable. A
# runtime cache mount is not an alternative — `type=cache` exists only for
# BuildKit's `RUN --mount`, and `docker run` rejects it as an unknown type.
# The volume is named rather than anonymous so `in-storage` can attach to it.

# Multiplatform index (linux/amd64 + linux/arm64).
const BR = "buchgr/bazel-remote-cache:latest@sha256:730699ebe2a203dec68af34656f07e2fceedc3c6f8814642a73f231e0c8357be"
const BB = "busybox:musl@sha256:03db190ed4c1ceb1c55d179a0940e2d71d42130636a780272629735893292223"

# Retry on a fresh port: the port is picked at random, and a taken one fails
# the container start.
export def start-remote [] {
	for attempt in 1..3 {
		let rc = (try { start-remote-once } catch { null })
		if $rc != null { return $rc }
	}
	error make { msg: "bazel-remote did not come up after 3 port attempts" }
}

def start-remote-once []: nothing -> record {
	let port = (random int 20000..39000)
	let name = $"bayt-cas-test-($port)"
	let volume = $"bayt-cas-vol-($port)"
	^docker volume create $volume | ignore
	(^docker run -d --rm --name $name -p $"($port):8080" -v $"($volume):/data"
		$BR --dir /data --max_size 1 --disable_http_ac_validation --enable_endpoint_metrics) | ignore

	# Poll rather than sleep a fixed interval — image pull time varies.
	mut up = false
	for _ in 1..60 {
		let r = (do { ^curl -s -o /dev/null -w "%{http_code}" $"http://localhost:($port)/status" } | complete)
		if $r.stdout == "200" { $up = true; break }
		sleep 500ms
	}
	if not $up {
		^docker rm -f $name | ignore
		^docker volume rm -f $volume | ignore
		error make { msg: $"bazel-remote did not come up on port ($port)" }
	}
	{ port: $port, name: $name, volume: $volume, url: $"http://localhost:($port)" }
}

export def stop-remote [rc: record] {
	^docker rm -f $rc.name | ignore
	^docker volume rm -f $rc.volume | ignore
}

# Run a shell command against the server's storage. The bazel-remote image
# ships no shell, so `docker exec` cannot reach the volume — a busybox
# attached to the same volume is what makes it addressable.
export def in-storage [rc: record, script: string]: nothing -> string {
	(do { ^docker run --rm -v $"($rc.volume):/data" $BB sh -c $script } | complete).stdout
}

# Every blob currently in the server's CAS.
export def cas-blobs [rc: record]: nothing -> list<string> {
	in-storage $rc "find /data/cas.v2 -type f 2>/dev/null | while read f; do basename $f; done"
	| lines
	| where { |l| $l | is-not-empty }
}

# Truncate one CAS blob, leaving a valid address holding wrong bytes.
export def corrupt-blob [rc: record, digest: string] {
	in-storage $rc $"find /data/cas.v2 -name '($digest)*' -type f | while read f; do printf x > \"$f\"; done" | ignore
}

# One bazel-remote request counter, 0 when absent. `contains` counts the
# HEAD probes the store path makes; `get` counts blob downloads.
export def cas-count [rc: record, method: string, status: string]: nothing -> int {
	let want = $'bazel_remote_incoming_requests_total{kind="cas",method="($method)",status="($status)"}'
	let body = (do { ^curl -s $"($rc.url)/metrics" } | complete).stdout
	let line = ($body | lines | where { |l| $l | str starts-with $want } | get -o 0)
	if $line == null { 0 } else { $line | split row " " | last | into int }
}
