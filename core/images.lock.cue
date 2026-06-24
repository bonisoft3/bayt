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
	bayt:         "bonitao/bayt:0.19.2@sha256:8c1d142badce44c181219759701895502ae84760e0578f2a08116a4dd979346b"
	lazybox:      "bonitao/lazybox:0.8.3@sha256:c896a6836673d8fd217f6021a2522351fd82d580ed985159feb2f10373018e73"
	busybox:      "busybox:musl@sha256:03db190ed4c1ceb1c55d179a0940e2d71d42130636a780272629735893292223"
	docker:       "docker:29.2.0-cli@sha256:ae2609c051339b48c157d97edc4f1171026251607b29a2b0f25f990898586334"
	alpine_socat: "alpine/socat:latest@sha256:bfd2550379212e087dc18db2f4611f43477be4b575d660c8f18c5b9a1b2e2757"
	leap: "opensuse/leap:16.0@sha256:859560554b625c225fa767b76d61253d529b95d082c2d68579ad69168d5e3da7"
	// envoyproxy/envoy ships /usr/local/bin/envoy and /usr/bin/envsubst.
	// Both are glibc-linked, so they COPY into any glibc-based stage
	// when the matching /usr/lib shared libs are COPY'd alongside.
	envoy: "envoyproxy/envoy:v1.35.3@sha256:4d496918618a7ebd6c71ae8285e31ebff092f3a0a5ad642d50decf4a54eb2456"
	// tarampampam/microcheck — tiny static healthcheck binaries
	// (httpcheck, portcheck) for COPY-from in dockerfile preambles.
	microcheck: "tarampampam/microcheck:1@sha256:79c187c05bfa67518078bf4db117771942fa8fe107dc79a905861c75ddf28dfa"
	// mockserver/mockserver — HTTP mock with declarative expectations
	// loaded from MOCKSERVER_INITIALIZATION_JSON_PATH.
	mockserver: "mockserver/mockserver:mockserver-5.15.0@sha256:0f9ef78c94894ac3e70135d156193b25e23872575d58e2228344964273b4af6b"
}
