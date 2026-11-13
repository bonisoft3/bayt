// npm_check.cue — dogfood check for the stacks/npm fragments.
package npm

// Pin the exported flag set — consumer overrides interpolate it.
_installFlagsPin: installFlags & "--prefer-offline --no-audit --no-fund"

// The install keys on the manifest, the optional .npmrc and the
// optional project-local lockfile, and nothing else.
_installPin: install & {
	cmd: "npm": {
		do: "mise x -- npm ci --prefer-offline --no-audit --no-fund"
		srcs: globs: ["package.json", "[.]npmrc", "[p]ackage-lock.json"]
	}
}

// dev's CMD is a default: a leaf passes flags through to the server.
_devFlags: dev & {dockerfile: cmd: ["npm", "run", "dev", "--", "--host", "0.0.0.0"]}
_devStock: dev & {dockerfile: cmd: ["npm", "run", "dev"]}
