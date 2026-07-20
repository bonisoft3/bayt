// stacks/gradle — Gradle/JVM toolchain concept library.
//
// Pure gradle concepts — no opinion about which target each lands on.
// A project unifies these fragments into its bayt targets.
package gradle

import (
	bayt "github.com/bonisoft3/bayt/core:bayt"
)

// =============================================================================
// Toolchain concept library.
// =============================================================================

// Cache mount for gradle's dependency + build cache.
_cacheMount: {type: "cache", target: "/root/.gradle", scope: "project"}

// The read-only dependency cache's in-image home. Gradle consults it
// natively (GRADLE_RO_DEP_CACHE) before the writable user home and never
// writes to it; misses fall through to repositories, so the mount is
// never load-bearing — and unlike a copied live `caches/`, the RO cache
// is designed to be relocated.
roDepCacheDir: "/opt/gradle-ro-cache"

// Per-project gradle configuration cache. Lives at <build-root>/.gradle/
// configuration-cache (project-local, NOT in $GRADLE_USER_HOME); the
// relative target resolves against the stage's WORKDIR so each stage
// gets its own slot under /monorepo/<dir>/.
_configCacheMount: {type: "cache", target: ".gradle/configuration-cache"}

// gradle's local build cache lives at $BAYT_CACHE_DIR/gradle (set by
// .bayt/init.gradle.kts that bayt emits per-project). Pass the init
// script via --init-script on every gradle invocation so the cache
// applies regardless of how gradle was launched. Per-task cache is
// ~15× finer than bayt's per-target cache — gradle skips the tasks
// whose inputs haven't changed even when the bayt-target as a whole
// has invalidated. Layered with bayt.cache.full (which short-circuits
// the daemon roundtrip on full-target hits), we get both grains.
_initFlag: "--init-script .bayt/init.gradle.kts"

// gradle.setupSrcs — files that change the gradle wrapper version.
// Stage them on a project's `setup` target alongside mise.install's
// .mise.toml/mise.lock so the setup stamp invalidates correctly.
setupSrcs: globs: [
	"gradle/wrapper/gradle-wrapper.properties",
]

// _manifestGlobs — the gradle-project manifest files, shared by the
// fragments whose stages must key on them (depsResolve, assemble).
// Each fragment adds its own extras (wrapper jar vs whole wrapper
// dir, language srcs, daemon-jvm criteria) on top.
_manifestGlobs: {
	"build-gradle":      {glob: "build.gradle.kts"}
	"settings-gradle":   {glob: "settings.gradle.kts"}
	"gradle-properties": {glob: "gradle.properties"}
	"gradlew":           {glob: "gradlew"}
	"libs-versions":     {glob: "gradle/lib[s].versions.toml"}
}

// gradle.depsResolve — the dependency closure as a real layer on a
// dedicated `deps` target (opt-in; the consuming project's build
// chains FROM it). The store is the project-shared
// /root/.gradle mount every gradle cmd already mounts: the resolve
// fills it (wrapper dist, jars, jdks), then copies caches/modules-2
// into the RO dep cache, read by every downstream stage via the
// inherited GRADLE_RO_DEP_CACHE env. Materializing the wrapper into
// the layer is deliberately NOT done: downstream cmds mount the whole
// user home, which would shadow it — the dist stays mount-side (one
// bounded refetch per cold builder, needed only at build time), while
// the many-artifact jar closure rides the layer.
// `--write-verification-metadata sha256 help` is gradle's
// resolve-everything invocation (all resolvable configurations in all
// projects, plugin classpaths included); the metadata file is a side
// effect the same RUN removes. No --init-script: the init script only
// wires the local build cache, and its .bayt/ COPY lands after the
// cmds in this stage. Composite-build consumers list their included
// builds on the target's `deps:` so the trees are present for
// configuration.
depsResolve: {
	srcs: defaultGlobs: _manifestGlobs & {
		"gradle-wrapper": {glob: "gradle/wrapper/**/*"}
		"daemon-jvm":     {glob: "gradle/gradle-daemon-jvm.propertie[s]"}
	}
	env: GRADLE_RO_DEP_CACHE: roDepCacheDir
	// Phase 1 — resolve (network on): fills the mount; a warm mount
	// re-resolves against it, misses fall through to repos (never
	// load-bearing).
	cmd: "resolve": {
		priority: -1
		shell:    "sh"
		do:       *#"./gradlew --write-verification-metadata sha256 help && rm -f gradle/verification-metadata.xml"# | string
		dockerfile: mounts: [_cacheMount]
	}
	// Phase 2 — copy the closure into the RO cache. RUN-only
	// (`dockerfile.do`, see #cmd): a build-time `cp` into /opt with no host
	// analogue (host gradle resolves into ~/.gradle natively).
	// `network: "none"` on its own RUN (pure-local cp).
	cmd: "materialize": {
		priority: 0
		dockerfile: {
			do:      *#"mkdir -p \#(roDepCacheDir) && cp -a \#(_cacheMount.target)/caches/modules-2 \#(roDepCacheDir)/"# | string
			shell:   "sh"
			mounts:  [_cacheMount]
			network: "none"
		}
	}
}

// gradle.assemble — `./gradlew assemble` with project-local sources.
// Whole-tree outs so gradle composite-build consumers (`includeBuild`
// in their settings.gradle.kts) get the producer's source +
// build.gradle.kts + build/libs/. Bayt internals + .git/ are excluded;
// .task/ rides along so cross-project consumers' `:depproject:bayt:build`
// task chain short-circuits on the producer's stamp.
assemble: bayt.cache.full & {
	// bayt.cache.full — gradle's daemon cold-start is ~5-10s even
	// when the entire project is UP-TO-DATE. cache.nu's default
	// "restore + run" mode pays the daemon roundtrip on every cached
	// invocation; full-on-hit trades that for trusting the restored
	// outs (build/libs/*.jar, build/classes/...). assemble is
	// deterministic in inputs (same srcs + toolchain → same bytes),
	// so the trust isn't speculative.
	//
	// Cross-build incrementality (warm-start when content hash
	// doesn't exact-match) is delegated to gradle's own per-task
	// build cache, configured via .bayt/init.gradle.kts to point at
	// $BAYT_CACHE_DIR/gradle. That's per-task granularity (~15× finer
	// than bayt's per-target cache) and uses gradle's hermetic-input
	// hashing — far better than what bayt could approximate.

	// Source globs scoped to src/main/ so changes under src/test/ or
	// src/it/ don't invalidate the build stage's COPY (and don't
	// trigger a wasted `./gradlew assemble` daemon cold-start). The
	// test and integrate targets bring in their own src/test/ and
	// src/it/ via their own defaultGlobs (Gradle.test and
	// Gradle.integrationTest).
	// Manifest set shared with depsResolve via _manifestGlobs.
	// gradle.properties is in it because gradle's own resolution rules
	// only consult `<project-root>/gradle.properties` (and
	// `$GRADLE_USER_HOME/gradle.properties`), never parent directories:
	// each gradle project keeps its own canonical copy so host and
	// container invocations see the same daemon JVM args / cache flags.
	srcs: defaultGlobs: _manifestGlobs & {
		"kotlin":          {glob: "src/main/**/*.kt"}
		"gradle-kts-srcs": {glob: "src/main/**/*.gradle.kts"}
		"java":            {glob: "src/main/**/*.java"}
		"sql":             {glob: "src/main/**/*.sql"}
		"sq":              {glob: "src/main/**/*.sq"}
		"sqm":             {glob: "src/main/**/*.sqm"}
		"gradle-wrapper":  {glob: "gradle/wrapper/gradle-wrapper.jar"}
	}
	// build/** + .gradle/** + project metadata. src/main/** is omitted
	// on purpose — composite-build consumers find existing build/classes
	// and hit gradle's NO-SOURCE skip rather than recompiling.
	outs: {
		globs: [
			"build/**/*",
			".gradle/**/*",
			"build.gradle.kts",
			"settings.gradle.kts",
			"gradle.properties",
			"gradlew",
			"gradle/wrapper/**/*",
			"gradle/lib[s].versions.toml",
		]
	}
	cmd: "builtin": {
		do: *"./gradlew \(_initFlag) assemble" | string
		windows: {
			do:    *".\\gradlew.bat \(_initFlag) assemble" | string
			shell: "pwsh"
		}
		dockerfile: mounts: [_cacheMount, _configCacheMount]
	}
}

// gradle.test — `./gradlew test`. Test-tree srcs only; main sources
// reach this target's fingerprint through the build dep's Merkle chain
// (listing them again would double-count and risk drift).
test: {
	srcs: defaultGlobs: {
		"test-kotlin":    {glob: "src/test/**/*.kt"}
		"test-java":      {glob: "src/test/**/*.java"}
		"test-sql":       {glob: "src/test/**/*.sql"}
		"test-resources": {glob: "src/test/resources/**/*"}
	}
	cmd: "builtin": {
		do: *"./gradlew \(_initFlag) test" | string
		windows: {
			do:    *".\\gradlew.bat \(_initFlag) test" | string
			shell: "pwsh"
		}
		dockerfile: mounts: [_cacheMount, _configCacheMount]
	}
	outs: globs: [
		"build/test-results/test/**/*.xml",
		"build/reports/tests/test/**/*",
	]
}

// gradle.integrationTest — `./gradlew integrationTest --rerun`.
// Integration test srcs (src/it/resources). Cache mount lives on the
// target's dockerfile (not the cmd's), so it doesn't collide with
// cmd-level mounts contributed by other fragments (e.g. a project-
// supplied secret mount). Without it, integrate stages re-download
// the gradle distribution + plugin jars into an empty /root/.gradle/
// every run — visible as "Downloading
// https://services.gradle.org/distributions/gradle-X.Y-bin.zip"
// at the top of the integrate RUN.
integrationTest: bayt.cache.full & {
	// bayt.cache.full — same gradle-daemon-cold-start argument as
	// assemble. integrationTest's outs are JUnit XMLs recording "it
	// passed once with these inputs"; skipping means we trust that
	// result. Acceptable because cache key includes srcs + dep stamps
	// + platform, so a hit means "this exact code was tested against
	// this exact dep state on this exact platform" — re-running would
	// only catch flakes in test infrastructure, not regressions.
	// Projects that don't tolerate this trade can override with
	// `cache: full: false`.

	// src/it/* source + resources. Listed here rather than relying on
	// FROM :build inheritance so an integration-test edit doesn't
	// invalidate the build stage's COPY. compileIntegrationTestKotlin
	// needs the .kt files; processIntegrationTestResources needs the
	// resources. Project-specific extensions (e.g. src/test/* shared
	// by integration tests) go on the project's `srcs.globs` user list.
	srcs: defaultGlobs: {
		"it-kotlin":    {glob: "src/it/**/*.kt"}
		"it-java":      {glob: "src/it/**/*.java"}
		"it-resources": {glob: "src/it/resources/**/*"}
	}
	cmd: "builtin": do: *"./gradlew \(_initFlag) integrationTest --rerun" | string
	dockerfile: mounts: [_cacheMount, _configCacheMount]
	outs: globs: [
		"build/test-results/integrationTest/**/*.xml",
		"build/reports/tests/integrationTest/**/*",
	]
}

// JibRelease — FROM-scratch deployable image, holding jib's pre-baked
// layers (which themselves include the JVM via jib.from.image). The
// final release output for jib-based services.
//
// This recipe defines only the image SHAPE — it doesn't run gradle.
// The leaf is responsible for the upstream artifact-production chain:
// typically a `release-artifact` target that runs `./gradlew jibBuildTar`
// (use `Gradle.GradleRelease & {target: "jibBuildTar", ...}` for that)
// and a `release-layers` target that extracts the tarball into a flat
// tree. JibRelease's `dockerfile.epilogue` then emits the cross-stage
// COPY landing those layers at `/`.
//
// `activate: ""` overrides any project-level `mise x --` prefix —
// FROM scratch has no mise binary. No `cmd` is declared either: FROM
// scratch has no /bin/sh, so any emitted RUN would fail (Docker
// defaults RUN to `/bin/sh -c <cmd>`). Image content comes entirely
// from the leaf-provided ENTRYPOINT + ENV + epilogue COPYs.
JibRelease: {
	activate: ""
	dockerfile: from: null
}

// GradleRelease — generic gradle artifact producer. Used either as
// the entire release (non-image releases: JAR published, distTar
// shipped) or as the upstream artifact-production stage feeding into
// a JibRelease-shaped image (tracker's `release-artifact`).
//
// `_target` picks the gradle task. Defaults to `distTar` (the
// application plugin's distribution tarball — neutral choice for
// non-image gradle services). Common alternatives: `bootJar` (Spring
// Boot fat JAR), `shadowJar` (with the shadow plugin), `jibBuildTar`
// (when this recipe drives the upstream of a JibRelease chain).
// Hidden (`_`-prefixed) so it doesn't trip #target's closedness check
// when this recipe unifies with a project's targets entry.
//
// `outs` are caller-supplied — they depend on which task is chosen
// (build/jib-image.tar for jibBuildTar, build/libs/*.jar for bootJar,
// build/distributions/*.tar for distTar, etc.).
GradleRelease: {
	_target: *"distTar" | string
	cmd: "builtin": {
		do: *"./gradlew \(_initFlag) \(_target)" | string
		dockerfile: mounts: [_cacheMount]
	}
}

check: {
	cmd: "builtin": do: *"./gradlew \(_initFlag) check" | string
}

run: {
	cmd: "builtin": do: *"./gradlew \(_initFlag) run" | string
}
