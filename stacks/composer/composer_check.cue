// composer_check.cue — dogfood check for the stacks/composer fragments.
package composer

import (
	"strings"

	"github.com/bonisoft3/bayt/core:bayt"
	mise "github.com/bonisoft3/bayt/stacks/mise"
)

// Pin the exported flag set — a drift strips the install/autoload split
// from every consumer interpolating it.
_installFlagsPin: installFlags & "--no-interaction --no-progress --prefer-dist --no-scripts --no-autoloader"

// A respelled install keeps the guard satisfied while it keeps
// --no-scripts (tests/_negative_composer_scripts drops it).
_respelled: install & {cmd: "composer": do: "mise x -- composer install --no-dev \(installFlags)"}

// --- C1: a Laravel-shaped project. setup layers composer over mise;
// build dumps the autoloader ahead of its own asset build.
_c1: bayt.#project & {
	name:     "api"
	dir:      "services/api"
	activate: "mise x --"
	targets: {
		"setup": mise.install & install & {
			activate:   ""
			dockerfile: bayt.nubox
			state: globs: ["vendor"]
		}
		"build": mise.exec & dumpAutoload & {
			deps: [":setup"]
			srcs: globs: ["app/**/*", "composer.json", "composer.lock"]
			outs: globs: autoloadOuts.globs
			cmd: "builtin": do:    "php artisan route:list"
			dockerfile: from: ref: ":setup"
		}
	}
}

_c1_render: bayt.#render & {project: _c1, depManifests: {}}
_c1_setup:  _c1_render.docker.dockerfiles.setup
_c1_build:  _c1_render.docker.dockerfiles.build

// Both cache dirs composer may pick are mounted on the install RUN.
_c1_xdgMount:    true & strings.Contains(_c1_setup, "--mount=type=cache,target=/root/.cache/composer,")
_c1_legacyMount: true & strings.Contains(_c1_setup, "--mount=type=cache,target=/root/.composer/cache,")
_c1_install:     true & strings.Contains(_c1_setup, #"["mise", "x", "--", "composer", "install", "--no-interaction", "--no-progress", "--prefer-dist", "--no-scripts", "--no-autoloader"]"#)
_c1_superuser:   true & strings.Contains(_c1_setup, "ENV COMPOSER_ALLOW_SUPERUSER=1")

// The dump runs before the target's own cmd: anything PHP needs the
// autoloader it writes.
_c1_dumpAt:    strings.Index(_c1_build, #""composer", "dump-autoload", "--optimize"]"#)
_c1_builtinAt: strings.Index(_c1_build, #""php", "artisan", "route:list"]"#)
_c1_order:     true & (_c1_dumpAt >= 0) & (_c1_dumpAt < _c1_builtinAt)
