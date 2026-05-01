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
	lazybox: "bonitao/lazybox:0.8.0@sha256:98414753b9ae2e90b096a1e3a9f7598ac2477e10fa3e5384083d9e29dde3c499"
	busybox: "busybox:musl@sha256:03db190ed4c1ceb1c55d179a0940e2d71d42130636a780272629735893292223"
	docker:  "docker:29.2.0-cli@sha256:ae2609c051339b48c157d97edc4f1171026251607b29a2b0f25f990898586334"
	leap:    "opensuse/leap:15.6@sha256:99c3ce36da52de669d5fd6663528438b0579cafa7efeab2e9e6d610a3c4b6c9e"
	// envoyproxy/envoy ships its binary at /usr/local/bin/envoy and
	// envsubst at /usr/bin/envsubst. tracker-tx's launch COPYs both
	// into a leap-based stage. Ubuntu (envoy) and leap are both glibc,
	// so the binaries run cross-distro after a small set of /usr/lib
	// shared libs are also COPY'd.
	envoy: "envoyproxy/envoy:v1.35.3@sha256:4d496918618a7ebd6c71ae8285e31ebff092f3a0a5ad642d50decf4a54eb2456"
}
