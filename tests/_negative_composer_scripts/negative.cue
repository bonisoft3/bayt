// A composer install respelled without --no-scripts must not evaluate:
// the post-install hooks boot the app, which the install layer carries
// none of, so the build fails far from the edit that dropped the flag.
// The `do` is `*"…" | string`, so only stacks/composer's `=~` guard
// catches it.
package negative_composer_scripts

import composer "github.com/bonisoft3/bayt/stacks/composer"

unscripted: composer.install & {cmd: "composer": do: "mise x -- composer install --no-interaction"}
