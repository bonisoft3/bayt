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

// Cache mount over mise's download store only — the checksummed tarballs,
// NOT the extracted tools. `installs/` (a sibling, not mounted) is rebuilt
// in the layer on every RUN, so a stale/poisoned mount can't fake "already
// installed": `installs/` is empty at RUN start, mise re-extracts, and
// re-verifies each kept tarball against mise.lock (a corrupt one → refetch).
// This is what makes the store safe to share; the extracted tree stays
// deterministic and in-layer.
_downloadsMount: {type: "cache", target: "/root/.local/share/mise/downloads", scope: "project"}

// install — `mise install`. One cmd, identical on host and in-container:
// installs land in mise's default data dir either way; the container only
// adds the download mount (+ MISE_ALWAYS_KEEP_DOWNLOAD so the mount actually
// retains tarballs — mise deletes them post-extract by default). Empty
// `activate` so it runs without a `mise x --` wrap (mise's CLI is on PATH
// via lazybox/leap, not its shim).
install: {
	activate: ""
	env: MISE_ALWAYS_KEEP_DOWNLOAD: "1"
	cmd: "builtin": {
		priority: -1
		do:       *"mise install" | string
		dockerfile: mounts: [_downloadsMount]
		// Concrete (not disjunction-default) — list disjunctions inside
		// the cmd map break MapToList's `if v != null`. Override via cmd
		// nullification: `Mise.install & {cmd: "builtin": null} & {...}`.
		srcs: globs: installFiles.globs
	}
}

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
