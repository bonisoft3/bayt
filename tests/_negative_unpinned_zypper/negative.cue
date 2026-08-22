// An unpinned zypper package must not evaluate. Leap retains versions in
// its update repo, so a pin there resolves for the life of the release and
// the constraint costs the author nothing beyond a `zypper info` lookup.
//
// apt deliberately has no such constraint: Debian and Ubuntu keep one
// revision per package, so the same rule would be a dated build failure
// (see distros/apt). Paired with tests/_positive_preamble, which passes an
// unpinned apt package to prove the two libraries differ on purpose.
package negative_unpinned_zypper

import zypper "github.com/bonisoft3/bayt/distros/zypper"

unpinned: (zypper.#install & {pkgs: ["which"]}).out
