// A project rooted at itself (dir ".") has no dir to name it after: its
// name is its identity in every dependent's Taskfile keys and image names,
// so it states one.
package negative_rooted_unnamed

import bayt "github.com/bonisoft3/bayt/core:bayt"

out: bayt.#project & {dir: "."}
