package bayt

_bkidMise: {
	settings: {
		locked:              true
		lockfile:            true
		experimental:        true
		github_attestations: false
		slsa:                false
		github: {github_attestations: false, slsa: false}
	}
	tools: {for name, tool in lock.tools {"github:\(name)": tool.version}}
}

lock: tools: {
	"go-task/task": {
		version:   "v3.54.0"
		backend:   "github:go-task/task"
		platforms: P={
			"linux-x64": {
				url:      "https://github.com/go-task/task/releases/download/v3.54.0/task_linux_amd64.tar.gz"
				url_api:  "https://api.github.com/repos/go-task/task/releases/assets/604090073"
				checksum: "sha256:680859dbb4d881a9c72d4d9a8f510825450849af8567deacd7302c01124416fb"
			}
			"linux-arm64": {
				url:      "https://github.com/go-task/task/releases/download/v3.54.0/task_linux_arm64.tar.gz"
				url_api:  "https://api.github.com/repos/go-task/task/releases/assets/604090041"
				checksum: "sha256:d7189d439d4a6058e39e1b2acd7c8b27acd4856691b408f23b242e4294e1df5b"
			}
			"linux-x64-musl":   P["linux-x64"]
			"linux-arm64-musl": P["linux-arm64"]
		}
	}
	"depot/cli": {
		version:   "2.102.25"
		backend:   "github:depot/cli"
		platforms: P={
			"linux-x64": {
				url:      "https://github.com/depot/cli/releases/download/v2.102.25/depot_2.102.25_linux_amd64.tar.gz"
				url_api:  "https://api.github.com/repos/depot/cli/releases/assets/660782770"
				checksum: "sha256:b62952f5951a0bcd4f48597b59fe29a4b7d84cac4e82710ee19d79262bf271af"
			}
			"linux-arm64": {
				url:      "https://github.com/depot/cli/releases/download/v2.102.25/depot_2.102.25_linux_arm64.tar.gz"
				url_api:  "https://api.github.com/repos/depot/cli/releases/assets/660782767"
				checksum: "sha256:52abe04ef24cd06f2ed37e15dbaa1d52d282db26ead04ff2493faf181347d6eb"
			}
			"linux-x64-musl":   P["linux-x64"]
			"linux-arm64-musl": P["linux-arm64"]
		}
	}
}
