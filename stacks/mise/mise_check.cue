// mise_check.cue — dogfood check for the stacks/mise fragments.
package mise

import "list"

// .tool-versions is a manifest mise reads: a project that pins its
// toolchains there gets a stage with mise and nothing installed if the
// install target does not stage it.
_manifests: list.Contains(installFiles.globs, "[.]tool-versions") & true
