const bayt_root = (path self | path dirname)

# Detect host libc — used by tool-stub selection (musl variant where a
# .musl.toml exists) and by runtime/fingerprint.nu's cache stamp.
# Single source of truth: divergence would silently corrupt cache
# keys when a glibc host's stamp is trusted by a musl container build.
export def libc-flavor []: nothing -> string {
	let host = sys host
	if $host.name != "Linux" { return "" }
	if (glob "/lib/ld-musl-*.so.1" | is-not-empty) { return "musl" }
	if ("/lib64/libc.so.6"        | path exists)  { return "glibc" }
	let target = (version | get build_target)
	if ($target | str ends-with "-musl") { return "musl" }
	if ($target | str ends-with "-gnu")  { return "glibc" }
	""
}

# Stubs live alongside tools.nu so the whole bayt-runtime context
# (what compose's additional_contexts: bayt-runtime copies into
# build stages) is self-contained. .musl.toml wins on musl Linux
# when present.
def stub-path [name: string]: nothing -> path {
	let base = ($bayt_root | path join $"($name).toml")
	let musl = ($bayt_root | path join $"($name).musl.toml")
	if ((libc-flavor) == "musl") and ($musl | path exists) { $musl } else { $base }
}

export def --wrapped run-cue [...args] {
	let input = $in
	with-env { MISE_LOCKED: "0" } { $input | ^mise tool-stub (stub-path "cue") ...$args }
}

export def --wrapped run-nu [...args] {
	let input = $in
	with-env { MISE_LOCKED: "0" } { $input | ^mise tool-stub (stub-path "nu") ...$args }
}

export def --wrapped run-oras [...args] {
	let input = $in
	with-env { MISE_LOCKED: "0" } { $input | ^mise tool-stub (stub-path "oras") ...$args }
}
