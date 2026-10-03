---
type: decision
title: Host isolation without a daemon
description: A frozen, sandboxed copy of the host task graph, built and measured on a pronto app, and not pursued — isolation tracks the environment, not the speed.
status: rejected
---

# Host isolation without a daemon

The host tier reads the working tree, so an edit landing mid-run is read by the
command while its cache key already describes the bytes from before. Docker
isolates by copying the closure into an image. The question was whether bayt
could give the host tier the same guarantee without a daemon, so the two
environments that lack one choice or the other — native Windows has no
sandbox, a Claude cloud session has no Docker daemon — still get an isolated
run.

**Decision: not pursued.** Pronto apps run `launch` and `integrate` on the host
with no isolation; a caller that needs a frozen tree uses a git worktree. Only
the process-compose stack driver survived.

## What was built

`task bayt:<target> ISOLATION=snapshot` copied the declared closure of the whole
go-task graph into a stage outside the checkout, verified the copy against the
input hashes, ran the graph inside it under Landlock (landrun) on Linux or
Seatbelt on macOS, and exported only declared outs and state, refusing on a
competing local edit. Rclone did the copying. Services ran under process-compose
from a hand-written `process-compose.yaml`, one host process per compose
service.

## What was measured

Truco's integrate — Postgres, PostgREST, Electric, auth, Caddy, then the
omnishell visual check in Chromium — on an Apple Silicon Mac, warm caches, every
run passing:

| | stack up | check | teardown | total |
|---|---|---|---|---|
| Docker compose | 16.5 s | 89.3 s, with integrate's own up | 7.8 s | 113.6 s |
| host, no isolation | 4.0 s | 58.9 s | 17.8 s | 80.7 s |
| host, snapshot | 1.6 s stage + 4.1 s | 56.8 s | 5–19 s | 67.6–84.6 s |

- The check dominates every column, and most of Docker's gap is Chromium running
  in Docker Desktop's VM rather than natively — not the isolation. Linux, where
  Docker has no VM, was not measured.
- Teardown is Electric's graceful shutdown and varies 5–19 s. An integrate run
  persists nothing, so its services can simply be killed.
- One-time host cost: Electric built from source in 94 s, and Playwright's
  browsers, which the integrate image ships, installed in 32 s; the other
  services are mise-installed binaries.
- Snapshot staging first cost 26.3 s, 25.3 s of it pruning the previous run's
  undeclared `node_modules` path by path against the keep list; a top-down walk
  made it 0.76 s.

A Claude cloud session is a Firecracker VM on Linux 6.18, glibc, root, Landlock
ABI 7, landrun's deny test passing, user namespaces available, no Docker
daemon. GitHub release pages answered 403 through its proxy, so tool pins that
download release assets may not install there; landrun came from `go install`.

## Why not

- **No speed winner.** Snapshot and plain host runs differ by noise; both beat
  Docker on a Mac for a reason that is not isolation.
- **Environment decides, not taste.** Which backend runs is forced by what the
  machine has, so the choice belongs to auto-selection — and auto-selection is
  only safe if both backends see the same closure, which they did not: Docker
  inherits everything a `FROM` producer left behind, snapshot reconstructs only
  what is declared, and snapshot shares the host's toolchains where Docker
  brings its own.
- **The middle ground had no far-reaching implementation.** Each step exposed a
  semantic the copy did not carry:
  - declared state lost its empty directories in both directions, so a staged
    Postgres refused to start (`could not open directory "pg_notify"`) and the
    export left a broken data directory in the checkout;
  - srcs are matched only under the project's own directory, so a `../../` glob
    silently selected nothing and the stage lacked the services' sources;
  - a sources-only target added to carry them broke the Docker tier, which
    expected an image for every dependency;
  - the snapshot was tied to the `taskfile {}` block, a file emitter, rather than
    to how a target runs.
- **integrate and launch declare no outs.** Isolation's original purpose was to
  stop a mid-run edit from poisoning a cache key; targets with no outputs have
  no key to poison, and a worktree gives a frozen tree with no machinery.

## What replaces it

Pronto apps are to emit `integrate@local` and `launch@local`, meaning the host
with no isolation, beside the Docker defaults; bayt provides the host side as
each target's `stack` task (SPEC, *The runtime process*). Where Docker is absent, the caller
isolates with a worktree: `git worktree add --detach <dir> $(git stash create)`
captures the dirty tree without touching the stash stack; untracked files need
`git add` first.

Concurrent stacks must not collide where it matters. Launch keeps ports stable
per project, computed at generation time: it is for one person at one screen,
so two checkouts of a project collide loudly instead of drifting apart.
Integrate takes ephemeral ports and a throwaway data directory, the native
counterpart of publishing the door on port 0.

## process-compose, as learned

What survived is the host projection of a target's entrypoint, specified in
[The runtime process](../../SPEC.md#the-runtime-process). What the spike taught
that the specification does not argue:

- A process skipped because a dependency died counts as success, so a stack that
  cannot start reports a green test — the reason every generated process sets
  `exit_on_skipped`.
- `restart: exit_on_failure` treats the supervisor's own shutdown SIGTERM as a
  failure. Electric, Caddy and Postgres exit 0 on it; PostgREST and Deno die by
  it.
- PostgREST's macOS release links Homebrew's libpq by absolute path.
- On macOS every service shares 127.0.0.1, so each takes its own port. Linux
  could give each service its own loopback address on its canonical port —
  measured with three services on `:3000` at 127.0.0.4, .5 and .9 — which would
  leave values naming peers unrewritten.

## Also rejected

**Per-service chroot jails from extracted image rootfs**, with process-compose
outside every jail and a generated `/etc/hosts` standing in for compose DNS.
Postgres with extensions and Electric both ran chrooted over loopback, but the
jails kill unix sockets between services and need `/proc` for Nushell, and
host-installed services made them unnecessary.

**Buck2 as the engine.** No local sandboxing, so none of this goes away, and in
local mode it forgets built targets when its daemon restarts.

**overlayfs in a user namespace.** A snapshot with no copying, but both the
namespace and the mount are refused in a default container.

**proot / fakechroot.** Chroot semantics by trapping every path-bearing syscall;
filesystem-heavy work is their worst case.

**mDNS for the external name.** Gives name→address, not name→port, and browsers
do not query SRV, so the port stays in the URL.

**A shared front-door Caddy** routing every stack by `Host`. Works, h2 intact,
but a permanent per-machine daemon to work around a macOS-only limit.

**A redirect chain between stacks' Caddies.** TLS picks the certificate from SNI
before any `Host` header exists: `SNI truco-2.local -> tlsv1 alert internal
error`.
