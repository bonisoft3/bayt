// stacks/mise — mise toolchain concept library.
//
// `mise` is the polyglot version manager (https://mise.jdx.dev/)
// that provisions per-project toolchain binaries from .mise.toml.
// This stack exports concepts a mise user would name, with no
// opinion about what sayt verbs they map to.
//
// Usage (composes with sayt verbs and other concept stacks):
//
//   import (
//       sayt "bonisoft.org/plugins/sayt/bayt"
//       mise "bonisoft.org/plugins/bayt/stacks/mise"
//   )
//
//   targets: {
//       "setup":  sayt.setup  & mise.install
//       "doctor": sayt.doctor & mise.doctor
//       "build":  sayt.build  & mise.exec & {cmd: do: "go build"}
//   }
package mise

// install — `mise install` runs the toolchain provisioning. Stages
// .mise.toml + mise.lock as the cmd's own srcs so its BuildKit COPY
// is independent of any other cmd in the same target. In a multi-cmd
// setup (mise.install & pnpm.install), editing package.json
// invalidates pnpm install's layer but leaves mise install's cached.
// Empty `activate` so the install runs without a preceding
// `mise x --` wrap (mise's own CLI is on PATH directly via
// lazybox/leap, not via mise's shim).
install: {
	activate: ""
	cmd: "builtin": {
		priority: -1
		do:       *"mise install" | string
		// Concrete (not disjunction-default) — list disjunctions
		// inside the cmd map break MapToList's `if v != null`
		// evaluation. To override, users compose via cmd nullification:
		//   "setup": Mise.install & {cmd: "builtin": null} & {cmd: ...}
		srcs: globs: installFiles.globs
	}
}

// installFiles — canonical list of mise's manifest files. Exposed
// as a constant so a workspace-root project that stages these
// files at target level (without composing mise.install itself,
// e.g. wsroot's `cmd: "builtin": do: "true"` placeholder) can
// reference the same list.
installFiles: globs: [
	".mise.toml",
	"mise.lock",
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
