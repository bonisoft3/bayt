// stacks/mise — mise toolchain concept library.
//
// `mise` is the polyglot version manager (https://mise.jdx.dev/)
// that provisions per-project toolchain binaries from .mise.toml.
// This stack exports concepts a mise user would name, with no
// opinion about which target each lands on.
//
// Usage (unified into a project's targets alongside other stacks):
//
//   import mise "github.com/bonisoft3/bayt/stacks/mise"
//
//   targets: {
//       "setup":  mise.install
//       "doctor": mise.doctor
//       "build":  mise.exec & {cmd: do: "go build"}
//   }
package mise

// mise's download dir stays per-project: mise unpacks tarballs IN PLACE here
// (no temp+rename), so a shared dir collides on concurrent extraction ("File
// exists"). installs/ is layer content (never mounted), re-extracted and
// re-verified against mise.lock every RUN, so a poisoned mount can't fake
// "installed".
_downloadsMount: {type: "cache", target: "/root/.local/share/mise/downloads", scope: "project"}

// Global tarball store — checksummed tarballs only, shared across every project
// so a tool (java ~180MB) is fetched once, not per project. Safe on
// sharing=shared (scope: global) because WE write it with an atomic rename
// (temp + mv); mise's own in-place unpack is what keeps downloads per-project.
_tarballStore: {type: "cache", target: "/mise-tarball-store", scope: "global"}

// install — `mise install`. The host runs it plainly; the container RUN dedups
// tool downloads across projects via _installScript's two-phase.
// MISE_ALWAYS_KEEP_DOWNLOAD keeps the tarball for the publish step.
install: {
	activate: ""
	env: MISE_ALWAYS_KEEP_DOWNLOAD: "1"
	cmd: "builtin": {
		priority: -1
		// Host task: plain `mise install` (portable, no container store).
		do: *"mise install" | string
		// Container RUN: the seed/install/publish two-phase — only here do the
		// mounts and /root paths exist. `dockerfile.do` overrides the base `do`
		// in the Dockerfile, so the host never runs this shell/linux script.
		dockerfile: {
			do:     *_installScript | string
			shell:  "sh"
			mounts: [_downloadsMount, _tarballStore]
		}
		srcs: globs: installFiles.globs
	}
}

// Container two-phase: seed the per-project download dir from the global store
// (mise then skips the fetch); `mise install || exit` (unpack stays per-project
// — mise moves it to installs/, leaving only tarballs here — and a real install
// error fails the RUN); publish the new tarballs back, best-effort via atomic
// mktemp+mv (trailing `:`) so a torn dedup write can't fail a good install.
// cp -r (not the non-POSIX -n): overwrites are content-identical.
_installScript: #"d=/root/.local/share/mise/downloads; s=/mise-tarball-store; mkdir -p "$d" "$s"; cp -r "$s"/. "$d"/ 2>/dev/null || true; mise install || exit; cd "$d" && for f in */*/*; do [ -f "$f" ] || continue; o="$s/$f"; [ -e "$o" ] && continue; mkdir -p "$(dirname "$o")"; t="$(mktemp "$(dirname "$o")/.pXXXXXX")" && cp "$f" "$t" && mv -f "$t" "$o"; done; :"#

// installFiles — canonical list of mise's manifest files. Exposed
// as a constant so a workspace-root project that stages these
// files at target level (without composing mise.install itself,
// e.g. wsroot's `cmd: "builtin": do: "true"` placeholder) can
// reference the same list.
installFiles: globs: [
	"[m]ise.toml",
	"[.]mise.toml",
	"[m]ise.lock",
]

// exec — sets `activate: "mise x --"` so emitted command lines
// resolve binaries through mise's shim layer. Use on every target
// whose cmd needs a mise-installed tool (gradlew, pnpm, go, etc.).
exec: {
	activate: *"mise x --" | string
}

// doctor — `mise doctor` health check. Runs through mise's CLI
// directly (no `mise x --` wrap needed for `mise doctor` itself).
doctor: {
	activate: ""
	cmd: "builtin": do: *"mise doctor" | string
}
