// stacks/gradle — Gradle/JVM toolchain concept library.
//
// Pure gradle concepts — no opinion about which sayt verb each maps
// to. Projects compose these with sayt verb fragments (or use the
// `sayt.gradle` standard mapping in plugins/bayt/stacks/sayt) to
// land them on canonical bayt targets.
package gradle

import (
	bayt "bonisoft.org/plugins/bayt/bayt"
)

// =============================================================================
// Toolchain concept library.
// =============================================================================

// Shared cache mount for the gradle dependency + build cache.
// `sharing=shared` lets parallel sibling stages (libs_logs:build,
// libs_xproto:build, ...) under COMPOSE_BAKE actually run concurrently
// instead of serializing on the lock — the realized parallelism win is
// substantial. gradle's own cache directories
// (~/.gradle/caches/modules-2/, ~/.gradle/caches/build-cache-1/) are
// concurrent-safe per gradle docs (per-key file locks + atomic writes).
//
// Caveat: if you ever observe mysterious gradle cache corruption,
// classpath-snapshot inconsistencies, or "lock acquisition failed"
// errors that BuildKit's lock would have prevented, switch back to
// `sharing=locked` and file an issue against the offending plugin.
_cacheMount: {type: "cache", target: "/root/.gradle", sharing: "shared"}

// Per-project configuration cache. Lives at <build-root>/.gradle/
// configuration-cache (project-local, NOT in $GRADLE_USER_HOME). The
// relative target resolves against the stage's WORKDIR — every stage
// gets `.gradle/configuration-cache` under its own /monorepo/<dir>/
// without us threading `dir` into the gradle package. Cache id
// defaults to the target string, so all stages share storage; this
// is safe because gradle keys entries by build-root path, so each
// project's entries occupy disjoint slots in the shared dir.
// `sharing=locked` — gradle's configuration-cache locking is less
// battle-tested than the build-cache's, prefer correctness over the
// marginal parallelism win.
_configCacheMount: {type: "cache", target: ".gradle/configuration-cache", sharing: "locked"}

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
	//
	// Defaults registered as a MapAsList so other stacks / project-
	// level conventions can compose, override, or null-delete by key.
	// Project leaves that just want to add a glob write
	// `srcs: globs: [...]` (the user-side plain list); the manifest
	// concatenates defaults + user list at emit time.
	srcs: defaultGlobs: {
		"kotlin":           {glob: "src/main/**/*.kt"}
		"gradle-kts-srcs":  {glob: "src/main/**/*.gradle.kts"}
		"java":             {glob: "src/main/**/*.java"}
		"sql":              {glob: "src/main/**/*.sql"}
		"sq":               {glob: "src/main/**/*.sq"}
		"sqm":              {glob: "src/main/**/*.sqm"}
		"build-gradle":     {glob: "build.gradle.kts"}
		"settings-gradle":  {glob: "settings.gradle.kts"}
		// gradle.properties is per-project because gradle's own
		// resolution rules only consult `<project-root>/gradle.properties`
		// (and `$GRADLE_USER_HOME/gradle.properties`), never parent
		// directories. Each gradle project keeps its own canonical copy
		// so both host invocations (`cd <proj> && ./gradlew build`) and
		// container builds see the same daemon JVM args / cache flags.
		// `sayt lint` (planned) keeps these in sync against the
		// workspace template.
		"gradle-properties": {glob: "gradle.properties"}
		"gradlew":          {glob: "gradlew"}
		"gradle-wrapper":   {glob: "gradle/wrapper/gradle-wrapper.jar"}
		// Project-local version catalog. No-op if absent.
		"libs-versions":    {glob: "gradle/libs.versions.toml"}
	}
	outs: {
		globs: ["**/*"]
		exclude: [
			".bayt/**",
			".git/**",
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
// cmd-level mounts contributed by orthogonal fragments like
// `bayt.hostenv` (which sets cmd.builtin.dockerfile.mounts for the
// host.env secret). Without it, integrate stages re-download the
// gradle distribution + plugin jars into an empty /root/.gradle/
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
// final release verb output for jib-based services.
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
// the entire release verb (non-image releases: JAR published, distTar
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
	_target: *"distTar" | "bootJar" | "shadowJar" | "jibBuildTar" | string
	cmd: "builtin": {
		do: *"./gradlew \(_initFlag) \(_target)" | string
		dockerfile: mounts: [_cacheMount]
	}
}

// gradle.check — `./gradlew check`. Conventional verify-verb cmd.
check: {
	cmd: "builtin": do: *"./gradlew \(_initFlag) check" | string
}

// gradle.run — `./gradlew run`. Conventional launch-verb cmd.
run: {
	cmd: "builtin": do: *"./gradlew \(_initFlag) run" | string
}

// The standard sayt-verb mapping for pure-gradle projects lives at
// `sayt.gradle` (plugins/bayt/stacks/sayt). It composes these
// concepts with sayt + mise to produce the canonical 10-target
// shape.
