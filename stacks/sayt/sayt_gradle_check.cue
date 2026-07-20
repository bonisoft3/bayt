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

// --- G3: Consumer overrides integrate cmd + secrets.
_g3: gradle & {
	name: "g3"
	dir:  "services/g3"
	targets: {
		"integrate": {
			cmd: "builtin": {
				dockerfile: mounts: [
					{type: "secret", id: "creds", required: true},
					{type: "cache", target: "/root/.gradle"},
				]
			}
			dockerfile: secrets: "creds": null
		}
	}
}

// Assert secrets entry + cmd-level mount survive after override.
_g3: targets: integrate: dockerfile: secrets: "creds": null

// --- G4: deps opt-in — RO dep cache shape survives the mapping.
_g4: gradle & {
	name: "g4"
	dir:  "services/g4"
	targets: {
		"deps": {deps: ["lib:build"]}
		"build": dockerfile: from: ref: ":deps"
	}
}

_g4: targets: deps: {
	env: GRADLE_RO_DEP_CACHE: "/opt/gradle-ro-cache"
	cmd: "resolve": dockerfile: mounts: [{type: "cache", target: "/root/.gradle", scope: "project"}]
	dockerfile: from: ref: ":setup"
}
