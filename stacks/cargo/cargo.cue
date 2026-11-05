// stacks/cargo — Rust/Cargo toolchain concept library.
//
// Pure cargo concepts — no opinion about which target each lands on. A
// project unifies these fragments into its bayt targets.
//
// Cache-mount architecture:
//   * Cargo's own advisory lock (`.package-cache`) sits at
//     `/root/.cargo/.package-cache`, OUTSIDE `/root/.cargo/registry` and
//     `/root/.cargo/git`. Mounting those subdirectories with `scope: "global"`
//     (`sharing=shared`) would give each container its own rootfs lockfile
//     while sharing `registry/src` where Cargo unpacks `.crate` archives in
//     place. Both mounts therefore use `scope: "project"` (`sharing=locked`),
//     serializing concurrent stages of the same project while letting `build`,
//     `test`, and `integrate` share one unpacked `registry/src` + sparse index.
//   * Checksum-verified `.crate` tarballs under `registry/cache/*/*.crate` are
//     content-addressed and immutable. `fetch` seeds `registry/cache` from the
//     builder-wide `crateStore` (`/cargo-crate-store`, `scope: "global"`) and
//     publishes new `.crate` files back via atomic `mktemp` + `mv` (the same
//     two-phase pattern `stacks/mise` uses for `/mise-tarball-store`).
package cargo

// Per-project locked mounts: shared across a project's `deps`/`build`/`test`/
// `integrate` stages without concurrent in-place unpack races.
registryMount: {type: "cache", target: "/root/.cargo/registry", scope: "project"}
gitMount:      {type: "cache", target: "/root/.cargo/git", scope: "project"}

// Builder-wide store of immutable `<index>/<crate>-<version>.crate` archives.
crateStore: {type: "cache", target: "/cargo-crate-store", scope: "global"}

projectFile: "Cargo.toml"
lockFile:    "Cargo.lock"

// Every in-stage cargo invocation carries `--locked` so a Cargo.lock that has
// fallen behind Cargo.toml fails immediately instead of silently re-resolving
// against the network. Guarded via `=~"--locked"` on each command's `do`.
lockFlag: "--locked"

_targetExclude: {
	"cargo-target-dir": {glob: "target"}
	"cargo-target-tree": {glob: "target/**"}
}

// Container two-phase for `cargo fetch --locked`: seed the project's
// `registry/cache` from the global crate store, run `cargo fetch --locked`
// (creating and cleaning up a transient `src/{main,lib}.rs` stub when `src/`
// is omitted from the `deps` stage's srcs so Cargo's target-discovery check
// passes without keying `deps` on `src/**`), and atomically publish any newly
// fetched `.crate` files back to `/cargo-crate-store`.
_fetchScript: #"sh -c 'd=/root/.cargo/registry/cache; s=/cargo-crate-store; mkdir -p "$d" "$s"; cp -r "$s"/. "$d"/ 2>/dev/null || true; stub=0; if [ ! -e src ]; then stub=1; mkdir -p src && : > src/main.rs && : > src/lib.rs; fi; cargo fetch --locked; rc=$?; if [ "$stub" = 1 ]; then rm -rf src; fi; [ "$rc" = 0 ] || exit "$rc"; cd "$d" && for f in */*.crate; do [ -f "$f" ] || continue; o="$s/$f"; [ -e "$o" ] && continue; mkdir -p "$(dirname "$o")"; t="$(mktemp "$(dirname "$o")/.pXXXXXX")" && cp "$f" "$t" && mv -f "$t" "$o"; done; :'"#

// fetch — pre-resolve and download the locked crate closure (`deps` target)
// keyed on Cargo.toml + Cargo.lock alone, so source edits in `src/` or `tests/`
// never re-trigger crate downloads.
fetch: {
	srcs: defaultGlobs: {
		"cargo-project": {glob: projectFile}
		"cargo-lock": {glob: lockFile}
	}
	cmd: "cargo": {
		do: (*"cargo fetch \(lockFlag)" | string) & =~"--locked"
		dockerfile: {
			do:     *_fetchScript | string
			shell:  "sh"
			mounts: [registryMount, gitMount, crateStore]
		}
	}
}

// #build — `cargo build --locked`. Keyed on `src/` + Cargo manifests (`tests/`
// stays out so editing unit/integration tests under `tests/` never invalidates
// the build stage).
#build: {
	srcDir: *"src" | string
	out: {
		srcs: {
			defaultGlobs: {
				"cargo-project": {glob: projectFile}
				"cargo-lock": {glob: lockFile}
				"cargo-src": *{glob: "\(srcDir)/**/*"} | null
			}
			defaultExclude: _targetExclude
		}
		cmd: "builtin": {
			do: (*"cargo build \(lockFlag)" | string) & =~"--locked"
			dockerfile: mounts: [registryMount, gitMount]
		}
	}
}

build: (#build).out

// #test — unit tests (`cargo test --locked --lib --bins`). Skips `tests/`
// integration crates so integration-test edits do not re-key unit tests.
#test: {
	srcDir: *"src" | string
	out: {
		srcs: {
			defaultGlobs: {
				"cargo-project": {glob: projectFile}
				"cargo-lock": {glob: lockFile}
				"cargo-src": *{glob: "\(srcDir)/**/*"} | null
			}
			defaultExclude: _targetExclude
		}
		cmd: "builtin": {
			do: (*"cargo test \(lockFlag) --lib --bins" | string) & =~"--locked"
			dockerfile: mounts: [registryMount, gitMount]
		}
	}
}

test: (#test).out

// #integrationTest — integration test crates in `tests/` (`cargo test --locked --tests`).
#integrationTest: {
	integrationDir: *"tests" | string
	out: {
		srcs: {
			defaultGlobs: {
				"cargo-project": {glob: projectFile}
				"cargo-lock": {glob: lockFile}
				"cargo-integration": *{glob: "\(integrationDir)/**/*"} | null
			}
			defaultExclude: _targetExclude
		}
		cmd: "builtin": {
			do: (*"cargo test \(lockFlag) --tests" | string) & =~"--locked"
			dockerfile: mounts: [registryMount, gitMount]
		}
	}
}

integrationTest: (#integrationTest).out

clippy: {
	cmd: "builtin": {
		do: (*"cargo clippy \(lockFlag) --all-targets -- -D warnings" | string) & =~"--locked"
		dockerfile: mounts: [registryMount, gitMount]
	}
}
