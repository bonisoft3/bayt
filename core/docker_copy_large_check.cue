package bayt

import (
	"list"
	"strings"
)

// Docker's scanner rejects a physical line over 65535 bytes, even when a COPY is valid.
_largeSources: list.Repeat(["shell/assets/things/abcdefghijklmnopqrstuvwxyz0123456789.png"], 1500)
_largeCopy: (_copyParents & {srcs: _largeSources, excludes: ["*.tmp"]}).out
_largeCopyLength: len(strings.Join(_largeSources, " ")) > 65535 & true
_largeCopyCount:  len(strings.Split(_largeCopy, " \\\n  ")) & 1503
_largeCopyLimit: {for i, line in strings.Split(_largeCopy, "\n") {"\(i)": (len(line) < 65535) & true}}
_largeCopyExcludes: strings.Contains(_largeCopy, "--exclude=*.tmp") & true

_compactProject: _d1 & {targets: build: dockerfile: finalCopy: ["/served", "/served.scripts"]}
_compactDockerfile: (#dockerComposeGen & {project: _compactProject, depManifests: {}}).dockerfiles.build
_compactStage: strings.Contains(_compactDockerfile, "FROM scratch AS build\nCOPY --from=build_build /served /served\nCOPY --from=build_build /served.scripts /served.scripts") & true
