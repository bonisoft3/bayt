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
	lazybox: "bonitao/lazybox:0.8.3@sha256:c896a6836673d8fd217f6021a2522351fd82d580ed985159feb2f10373018e73"
	busybox: "busybox:musl@sha256:03db190ed4c1ceb1c55d179a0940e2d71d42130636a780272629735893292223"
	docker:  "docker:29.2.0-cli@sha256:ae2609c051339b48c157d97edc4f1171026251607b29a2b0f25f990898586334"
	leap:    "opensuse/leap:16.0@sha256:859560554b625c225fa767b76d61253d529b95d082c2d68579ad69168d5e3da7"
	// envoyproxy/envoy ships its binary at /usr/local/bin/envoy and
	// envsubst at /usr/bin/envsubst. tracker-tx's launch COPYs both
	// into a leap-based stage. Ubuntu (envoy) and leap are both glibc,
	// so the binaries run cross-distro after a small set of /usr/lib
	// shared libs are also COPY'd.
	envoy: "envoyproxy/envoy:v1.35.3@sha256:4d496918618a7ebd6c71ae8285e31ebff092f3a0a5ad642d50decf4a54eb2456"
	// tarampampam/microcheck — tiny static healthcheck binaries
	// (httpcheck, portcheck) for COPY-from in dockerfile preambles.
	// Used by bayt's healthcheck.http / .tcp templates.
	microcheck: "tarampampam/microcheck:1@sha256:79c187c05bfa67518078bf4db117771942fa8fe107dc79a905861c75ddf28dfa"
	// mockserver/mockserver — HTTP mock with declarative expectations
	// loaded from MOCKSERVER_INITIALIZATION_JSON_PATH. Used by iris's
	// integrate stage to stub the OpenAI/Ollama chat-completions
	// endpoint without pulling a real AI runtime + model. Same image
	// products/iris/images/mockserver/Dockerfile uses.
	mockserver: "mockserver/mockserver:mockserver-5.15.0@sha256:0f9ef78c94894ac3e70135d156193b25e23872575d58e2228344964273b4af6b"
}
