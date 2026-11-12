// sayt_go_check.cue — dogfood check for sayt.go consumers.
package sayt

import (
	"strings"

	"github.com/bonisoft3/bayt/core:bayt"
)

// Guard pass-2 export of Go._twoPhase's defaulted `dockerfile.do` arms inside
// `*(...) | null` targets (`deps`, `integrate` + `sayt.inject`): an incomplete
// helper comprehension leaves the default non-concrete under `shell: "exec"`
// only when exported through `#render`.
_go1: go & {
	name: "shelfie"
	dir:  "services/shelfie"
	targets: {
		"build": outs: globs: ["shelfie"]
		"integrate": inject
		"launch":    null
		"release":   null
		"verify":    null
	}
}

_go1_render:        bayt.#render & {project: _go1, depManifests: {}}
_go1_deps_arm:      true & strings.Contains(_go1_render.docker.dockerfiles.deps, #"["mise", "x", "--", "env", "GOMODCACHE=/root/go/pkg/mod", "go", "mod", "download"]"#)
_go1_integrate_arm: true & strings.Contains(_go1_render.docker.dockerfiles.integrate, #"["mise", "x", "--", "env", "GOMODCACHE=/root/go/pkg/mod", "go", "-C", "it", "mod", "download"]"#)
