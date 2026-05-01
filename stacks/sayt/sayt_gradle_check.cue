// sayt_gradle_check.cue — dogfood check for sayt.gradle consumers.
package sayt

// --- G1: Minimal consumer — name + dir + one k8s override.
_g1: gradle & {
	name: "g1-service"
	dir:  "services/g1"
	targets: {
		"release": skaffold: profiles: "bayt-build": build: artifact: image: "gcr.io/proj/g1"
	}
}

// Assertions on propagation through the stack defaults + overrides.
_g1: activate: "mise x --"
_g1: targets: build: cmd: "builtin": do:            "./gradlew assemble"
_g1: targets: build: cmd: "builtin": windows: do:   ".\\gradlew.bat assemble"
_g1: targets: build: cmd: "builtin": windows: shell: "pwsh"
_g1: targets: release: skaffold: profiles: "bayt-build": build: artifact: image: "gcr.io/proj/g1"

// --- G2: Consumer adds cross-project deps.
// Cross-project deps are string refs `project:target` (the producer's
// project + target is resolved via depManifests at pass-2 time).
_g2: gradle & {
	name: "g2"
	dir:  "services/g2"
	targets: {
		"build": deps: ["libbuild:build"]
	}
}

_g2: targets: build: deps: ["libbuild:build"]

// --- G3: Consumer overrides integrate cmd + secrets.
_g3: gradle & {
	name: "g3"
	dir:  "services/g3"
	targets: {
		"integrate": {
			cmd: "builtin": {
				dockerfile: mounts: [
					{type: "secret", id: "host.env", required: true},
					{type: "cache", target: "/root/.gradle", sharing: "locked"},
				]
			}
			dockerfile: secrets: ["host.env"]
		}
	}
}

// Assert secrets list + mount entry survive.
_g3: targets: integrate: dockerfile: secrets: ["host.env"]
