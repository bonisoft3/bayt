// stacks/composer — PHP/Composer toolchain concept library.
//
// Pure composer concepts — no opinion about which target each lands
// on. A project unifies these fragments into its bayt targets. PHP
// and composer themselves are mise tools (a static PHP build and the
// composer phar over mise's `http:` backend work); this stack only
// runs them.
package composer

import "list"

// =============================================================================
// Toolchain concept library.
// =============================================================================

// Cache mounts for composer's download cache. `scope: "global"`:
// composer writes cache entries through a temp file and rename, so
// concurrent access is safe. Two targets because composer picks its
// cache dir from the image: wherever XDG is in use (an /etc/xdg dir,
// as on leap) it is ~/.cache/composer, even when ~/.composer exists;
// otherwise, as on debian slim and so nubox, ~/.composer/cache. A
// mount at only one of them leaves the other base installing uncached.
cacheMounts: [
	{type: "cache", target: "/root/.cache/composer", scope: "global"},
	{type: "cache", target: "/root/.composer/cache", scope: "global"},
]

// COMPOSER_ALLOW_SUPERUSER: container RUNs are root, and a
// non-interactive composer run as root disables plugins (pest's,
// php-http/discovery's) for safety. Harmless on the host. Exported
// because a target that composes no fragment from here can still run
// composer, and a COPY carries no ENV.
toolEnv: COMPOSER_ALLOW_SUPERUSER: "1"

// installFlags — interpolated into install's `do` default, which
// guards its load-bearing flag (see install):
// --no-scripts: script hooks (Laravel's post-autoload-dump runs
// package:discover) boot the app, which needs sources the install
// layer does not carry. dumpAutoload re-fires post-autoload-dump once
// they are present; post-install-cmd and post-update-cmd hooks never
// run, so a project that needs one adds its own cmd.
// --no-autoloader: the autoloader maps app classes (classmap entries
// scan app dirs), which the install layer does not carry either.
// --prefer-dist keeps installs on the cached dist archives, never git
// clones.
installFlags: "--no-interaction --no-progress --prefer-dist --no-scripts --no-autoloader"

// lockFiles — bracket-glob: a library project may not commit one.
lockFiles: globs: ["[c]omposer.lock"]

// composer.projectFiles — files a per-project composer setup target
// stages.
projectFiles: globs: [
	"composer.json",
]

// composer.install — the vendor/ closure as a real layer. composer's
// cache (on the cache mounts) is the opportunistic store and vendor/
// the exact materialization of composer.lock, so one RUN covers both.
// Cmd-level srcs key the layer on manifest + lockfile, independent of
// mise.install (priority -1, sorts first).
//
// Compose with mise.install — no manual srcs splice needed:
//
//   "setup": mise.install & composer.install
//
// The `do` is `*"…" | string`, so a consumer override selects the open
// arm; the `=~` guard is what keeps --no-scripts on a respelled
// command.
install: {
	env: toolEnv
	cmd: "composer": {
		do: (*"mise x -- composer install \(installFlags)" | string) & =~"--no-scripts"
		dockerfile: mounts: cacheMounts
		// Concrete (not disjunction-default) — list disjunctions
		// inside the cmd map break MapToList's `if v != null` check.
		srcs: globs: list.Concat([projectFiles.globs, lockFiles.globs])
	}
}

// composer.dumpAutoload — writes vendor/autoload.php against the app
// sources and runs the post-autoload-dump scripts (only those: see
// installFlags) that install skipped. It
// belongs on the first target that carries the sources (build). Its
// own cmd key at priority -1, so it composes with the target's builtin
// cmd (an asset build, an artisan call) and runs before anything that
// loads the autoloader.
dumpAutoload: {
	env: toolEnv
	cmd: "composer": {
		priority: -1
		do:       *"composer dump-autoload --optimize" | string
	}
}

// autoloadOuts — what dumpAutoload writes. Not set on the fragment: a
// concrete outs list would refuse the target's own entries, so the
// target splices it in (`list.Concat([composer.autoloadOuts.globs, …])`).
autoloadOuts: globs: [
	"vendor/autoload.php",
	"vendor/composer/**/*",
]
