// An unpinned `lock` entry must not evaluate. `lock` exists to hold the
// dependency closure still, so a bare name there is the exact silent no-op
// the constraint prevents — it reads as a pin and holds nothing.
//
// Its own case because the sibling negative only passes an unpinned `pkgs`,
// which leaves `lock`'s constraint free to be dropped unnoticed.
package negative_unpinned_lock

import zypper "github.com/bonisoft3/bayt/distros/zypper"

unpinned: (zypper.#install & {pkgs: ["which=2.23-160000.2.2"], lock: ["glibc"]}).out
