package bayt

import "strings"

#passthroughFrom: {
	project: #project
	let _project = project
	files: [
		if _project.files != _|_ for filename, content in _project.files {name: filename, data: content},
		for targetName, target in _project.targets if target != null if target.files != _|_
		for file, content in target.files {
			let parts = strings.Split(file, ".")
			let ext = parts[len(parts)-1]
			{name: "\(strings.TrimSuffix(file, "."+ext)).\(targetName).\(ext)", data: content}
		},
	]
}
