// go_check.cue — dogfood check for the stacks/go fragments.
package go

import "list"

// The file kinds go compiles beyond .go. A host that has the assembly or
// cgo sources on disk builds green while the key ignores them, so the
// gap only surfaces as a missing function body in a container.
// Fixtures live beside each package, so the testdata glob must be `**/`-rooted.
_testFileKinds: (test.srcs.defaultGlobs["go-testdata"] & {glob: _}).glob & "**/testdata/**"

_buildFileKinds: {
	let declared = [for k, _ in build.srcs.defaultGlobs {k}]
	for k, want in {"go-src": "**/*.go", "go-asm": "**/*.[sS]", "go-c": "**/*.c", "go-h": "**/*.h"} {
		(k): {
			// A missing default glob is incomplete, not a conflict, so the
			// name is asserted against the declared set, not by lookup.
			"declared": list.Contains(declared, k) & true
			"glob":     (build.srcs.defaultGlobs[k] & {glob: _}).glob & want
		}
	}
}
