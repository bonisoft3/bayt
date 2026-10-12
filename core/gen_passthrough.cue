package bayt

import "strings"

#passthroughFrom: G={
	project: #project
	files: [
		if G.project.files != _|_ for filename, content in G.project.files {name: filename, data: content},
		for targetName, target in G.project.targets if target != null if target.files != _|_
		for file, content in target.files {
			let parts = strings.Split(file, ".")
			let ext = parts[len(parts)-1]
			{name: "\(strings.TrimSuffix(file, "."+ext)).\(targetName).\(ext)", data: content}
		},
	]
}
