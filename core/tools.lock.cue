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
		version:   "v3.49.1"
		backend:   "github:go-task/task"
		platforms: P={
			"linux-x64": {
				url:      "https://github.com/go-task/task/releases/download/v3.49.1/task_linux_amd64.tar.gz"
				url_api:  "https://api.github.com/repos/go-task/task/releases/assets/369609772"
				checksum: "sha256:4e7d24f1bf38218aec8f244eb7ba671f898830f9f87b3c9b30ff1c09e3135576"
			}
			"linux-arm64": {
				url:      "https://github.com/go-task/task/releases/download/v3.49.1/task_linux_arm64.tar.gz"
				url_api:  "https://api.github.com/repos/go-task/task/releases/assets/369609773"
				checksum: "sha256:aa6732c9c66397c5380ec2b60c070fd599075b2a8538dba03f3a21edc99ab0cb"
			}
			"linux-x64-musl":   P["linux-x64"]
			"linux-arm64-musl": P["linux-arm64"]
		}
	}
	"depot/cli": {
		version:   "2.101.78"
		backend:   "github:depot/cli"
		platforms: P={
			"linux-x64": {
				url:      "https://github.com/depot/cli/releases/download/v2.101.78/depot_2.101.78_linux_amd64.tar.gz"
				url_api:  "https://api.github.com/repos/depot/cli/releases/assets/501083086"
				checksum: "sha256:15d066413b99c4fdd399d5fc79a64e50b2e266b509642995935bb96c01d28f1b"
			}
			"linux-arm64": {
				url:      "https://github.com/depot/cli/releases/download/v2.101.78/depot_2.101.78_linux_arm64.tar.gz"
				url_api:  "https://api.github.com/repos/depot/cli/releases/assets/501083092"
				checksum: "sha256:985308b4e9b124c9d8ca712b30b84ea613e7de2f9bb3bb193a710e45e254ea87"
			}
			"linux-x64-musl":   P["linux-x64"]
			"linux-arm64-musl": P["linux-arm64"]
		}
	}
}
