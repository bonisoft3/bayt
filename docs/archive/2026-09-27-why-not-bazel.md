---
type: decision
title: Bazel comparison
description: Bayt subsumes the toolchain at package-sized targets instead of inverting it into sandboxed micro-actions, and keeps native host runs beside OCI isolation.
status: done
moved_to: ../../README.md#architectural-comparison-bazel-and-bayt
---

# Bazel comparison

Bayt's core model is Bazel's: content-addressed Merkle invalidation, declarative
`srcs`/`deps`/`outs`, a remote cache shared across machines. The decision is
where the boundaries sit.

## Subsume the toolchain, do not invert it

Bazel decomposes compilation into fine-grained actions and runs each in its own
sandbox. That bypasses the in-memory caches and persistent daemons modern
toolchains are built around — `GOCACHE`, pnpm's store, vitest's module graph,
gradle's daemon — and spends process startup and filesystem metadata on every
action.

Bayt draws its boundaries at package and target nodes. A clean target costs one
status check, a `cache.full` hit skips its whole dependency subgraph, and when
work is needed the native tool runs whole, with its own incremental engine and
worker pool intact; gradle's per-task cache and bayt's per-target cache share
one store. So bayt does not replace `./gradlew` or `pnpm install`; it decides
when they run, adoption is one target at a time, and the same declaration
drives a laptop, CI and a remote builder.

## Two isolation tiers, not one sandbox

Bazel sandboxes every action with Seatbelt or user/mount namespaces, still
sharing the host kernel and, unless toolchains are fully static, host-installed
dependencies. Bayt has two tiers. On the host, targets run natively: a
sub-second inner loop, no sandbox permissions, the IDE's own task runner. In CI
and integration a target runs inside an OCI build — kernel namespaces, cgroups,
`network: "none"` where a command asks for it, a rootfs — with BuildKit cache
mounts keeping warm builds fast.

## Where each fits

Bazel is unmatched in giant homogeneous monorepos and in organizations
staffing a build team for Starlark rules and remote execution. Bayt fits mixed
stacks that want an afternoon's onboarding and sub-second inner loops without
replacing their tools. The two are not exclusive: `.bayt/bayt.<target>.json`
describes every target's action, so a team that grows into Bazel can feed it to
a rule generator.

## What it costs

A missed target pays the whole native tool invocation, not one action's;
`cache.similar` and the tool's own cache warming from the same store narrow
that. A `cache.full` check hashes the closure from manifests, about 3.5s on a
deep one ([a hit skips its deps](2026-09-21-a-hit-skips-its-deps.md)).
