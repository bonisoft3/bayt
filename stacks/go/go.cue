// stacks/go — Go toolchain concept library.
//
// Pure go concepts — no opinion about which target each lands on. A
// project unifies these fragments into its bayt targets.
//
// In-container, a `go env -w GOMODCACHE=$PWD/depsDir` stage preamble
// (persisted at /root/.config/go/env, inherited through FROM chains)
// points every go invocation at the project-local closure; commands
// stay plain exec-form. The host keeps go's default shared modcache.
package go

// Cache mounts at go's default root-user cache paths. Inside a stage
// the paths are cache mounts; on the host the same command hits the
// developer's regular caches — one command line serves both sides.
_modCacheMount:   {type: "cache", target: "/root/go/pkg/mod", scope: "project"}
_buildCacheMount: {type: "cache", target: "/root/.cache/go-build", scope: "project"}

// The materialized module closure's project-local home.
depsDir: ".gomodcache"

// _twoPhase — mount-as-proxy download. Phase 1 (`download`) fills the
// mount; phase 2 (`materialize`, `network:"none"`) re-resolves against it
// as a file:// GOPROXY (`,direct` for misses) into the active GOMODCACHE,
// materializing exactly the current closure — not the mount's accrued
// versions. Both phases are RUN-only (`dockerfile.do`, see #cmd): they
// write go's root-user cache path via the mount, which has no host
// analogue (a host go auto-downloads into its own modcache). `_dir`
// selects the module (`-C`); materialize runs at `_prio + 1`.
_twoPhase: T={
	_dir:  string // "" = module root; concrete (a disjunction default stays non-concrete under pass-2 interpolation)
	_prio: int
	let _c = [if T._dir != "" {"-C \(T._dir) "}, ""][0]
	cmd: "download": {
		priority: T._prio
		dockerfile: {
			do:     *"env GOMODCACHE=\(_modCacheMount.target) go \(_c)mod download" | string
			mounts: [_modCacheMount]
		}
	}
	cmd: "materialize": {
		priority: T._prio + 1
		dockerfile: {
			do:      *"env GOSUMDB=off GOPROXY=file://\(_modCacheMount.target)/cache/download,direct go \(_c)mod download" | string
			mounts:  [_modCacheMount]
			network: "none"
		}
	}
}

// Persists the project-local GOMODCACHE into the stage (go requires an
// absolute path; $PWD is the WORKDIR at preamble time).
_goEnvPreamble: "go-modcache": {
	line: "RUN mise x -- go env -w GOMODCACHE=$PWD/\(depsDir)"
}

// modDownload — the root module's closure as a real image layer (the
// `deps` target), reachable by runtime containers and cold builders.
// Rides the setup chain, so monorepo-wide setup churn re-keys it; the
// warm mount re-materializes without network. go.sum pins every artifact
// → digest-stable. Emits the closure at depsDir.
modDownload: _twoPhase & {
	_dir:  ""
	_prio: -1
	srcs: defaultGlobs: {
		"go-mod": {glob: "go.mod"}
		"go-sum": {glob: "go.sum"}
	}
	dockerfile: defaultPreamble: _goEnvPreamble
	outs: globs: ["\(depsDir)/**/*"]
}

// build — `go build`. Manifests are compile inputs, so they key this
// stage directly; the closure itself arrives from the `:deps:outs`
// view. Test files live beside sources in go packages, so **/*.go
// includes them — a test edit invalidates build; acceptable until
// srcs excludes earn their keep. Leaves outs to the leaf (the
// artifact name is the module's).
build: {
	srcs: defaultGlobs: {
		"go-src": {glob: "**/*.go"}
		"go-mod": {glob: "go.mod"}
		"go-sum": {glob: "go.sum"}
	}
	cmd: "builtin": {
		do: *"go build" | string
		dockerfile: mounts: [_buildCacheMount]
	}
	dockerfile: defaultPreamble: _goEnvPreamble
}

// test — `go test ./...`. it/ is its own module, so the walk never
// descends into it.
test: {
	srcs: defaultGlobs: {
		"go-test": {glob: "**/*_test.go"}
	}
	cmd: "builtin": {
		do: *"go test ./..." | string
		dockerfile: mounts: [_buildCacheMount]
	}
}

// integrationTest — `go -C it test ./...`. it/ is its own module (nested
// go.mod): units stay hermetic (no flags/tags) and the daemon-needing
// tree (testcontainers) lives in it/go.mod, off the service's graph. The
// stage inherits build's GOMODCACHE=.gomodcache (service closure only),
// so it two-phases the it/ closure before the tests run.
integrationTest: _twoPhase & {
	_dir:  "it"
	_prio: -2
	srcs: defaultGlobs: {
		"go-it": {glob: "it/**/*"}
	}
	cmd: "builtin": {
		do: *"go -C it test ./..." | string
		dockerfile: mounts: [_buildCacheMount]
	}
}

vet: cmd: "builtin": do: *"go vet ./..." | string

run: cmd: "builtin": do: *"go run ." | string
