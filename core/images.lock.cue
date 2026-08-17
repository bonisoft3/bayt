// images.lock.cue — pinned digests for the container images bayt
// references. Each value is `<image-name>:<tag>@sha256:<digest>` —
// Docker's native ref grammar, copy-pasteable into a Dockerfile FROM.
//
// Pin policy: prefer manifest-list (multiplatform) digests so the
// same pin works on linux/amd64 + linux/arm64. Manifest-list and
// single-arch digests are indistinguishable in this grammar — verify
// by reading the `Manifests:` block in the inspect output.
//
// Updating:
//   • Latest tags:  `crane ls <image>`  (or `skopeo list-tags docker://<image>`)
//   • Pin a tag:    `docker buildx imagetools inspect <image>:<tag>`
//                    — copy the top-level `Digest:` field; verify
//                    multiple `Platform:` entries appear.
//   • Bulk refresh: a Renovate custom manager (regex on this file)
//                    or any LLM with a shell tool can iterate.
//
// We'd prefer YAML (idiomatic for lockfiles) but CUE's `@embed` for
// runtime file reads needs module-config setup we haven't done. When
// that lands, this becomes images.lock.yaml + a one-liner shim.
package bayt

lock: images: {
	// bayt itself — `FROM scratch + COPY .` of the bayt source tree.
	// Consumers' generated compose wires this as an additional_context
	// so `COPY --from=bayt-runtime` lands the runtime in build stages.
	//
	// Self-reference necessarily lags one release: writing the digest
	// into this file changes the file, which changes the COPY content,
	// which changes the digest. There's no fixed point. The two-step
	// release ritual:
	//   1. Code-change PR merges; tag `plugins/bayt/vX.Y.Z`; image
	//      publishes. The tagged tree still pins v(X.Y.Z-1).
	//   2. Lock-bump PR merges; lock now pins vX.Y.Z. main HEAD is
	//      current, the vX.Y.Z tag's file is stale-by-one.
	// Regen against main picks up the latest; regen against a tagged
	// tarball lags by one. In practice, consumers regenerate after
	// bumping bayt anyway, so the lag closes naturally.
	bayt:         "bonitao/bayt:0.42.3@sha256:c483fbdaddd732f8f94dc04b8ae493ca9ed76f4fdc8d3026df746954cb6a78db"
	lazybox:      "bonitao/lazybox:0.8.3@sha256:c896a6836673d8fd217f6021a2522351fd82d580ed985159feb2f10373018e73"
	busybox:      "busybox:musl@sha256:03db190ed4c1ceb1c55d179a0940e2d71d42130636a780272629735893292223"
	docker:       "docker:29.7.1-cli@sha256:27a51d5ab1cd38d9eeaba7b415b8c07bc10c31e1cf1ec8d78f6413fcfab3f44f"
	alpine_socat: "mirror.gcr.io/alpine/socat:1.8.0.0@sha256:a6be4c0262b339c53ddad723cdd178a1a13271e1137c65e27f90a08c16de02b8"
	// depot CLI — static binary for the dindbox's inner depot bake. Multiplatform digest.
	depot_cli:    "ghcr.io/depot/cli:2.101.78@sha256:71fc7e6cf9f10ee1699bdba40e9461387f3a8406bc7bb9a9b1857c38587a7254"
	leap: "opensuse/leap:16.0@sha256:859560554b625c225fa767b76d61253d529b95d082c2d68579ad69168d5e3da7"
	// envoyproxy/envoy ships /usr/local/bin/envoy and /usr/bin/envsubst.
	// Both are glibc-linked, so they COPY into any glibc-based stage
	// when the matching /usr/lib shared libs are COPY'd alongside.
	envoy: "envoyproxy/envoy:v1.35.3@sha256:4d496918618a7ebd6c71ae8285e31ebff092f3a0a5ad642d50decf4a54eb2456"
	// tarampampam/microcheck — tiny static healthcheck binaries
	// (httpcheck, portcheck) for COPY-from in dockerfile preambles.
	microcheck: "tarampampam/microcheck:1@sha256:79c187c05bfa67518078bf4db117771942fa8fe107dc79a905861c75ddf28dfa"
	// mockoon/cli — multi-arch (arm64+amd64) Node HTTP mock driven by a
	// declarative environment file. Replaces mockserver, whose x86-only
	// JVM image ran under qemu on Apple Silicon and never bound its port.
	mockoon: "mockoon/cli:9.3.0@sha256:71b47e0ff0c4db496e63fc36a710ce971084e2e31f7504deb5cdf15555af598f"
	// node:22-slim — glibc runtime base for Next.js standalone servers
	// (`node server.js`). Multiplatform digest (linux/amd64 + arm64).
	node: "node:22-slim@sha256:6c74791e557ce11fc957704f6d4fe134a7bc8d6f5ca4403205b2966bd488f6b3"
}
