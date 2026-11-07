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

# The static musl curl binary carries no compiled-in host CA path and fails if
# /etc/ssl/openssl.cnf loads dynamic glibc engines (e.g. openSUSE).
export def --wrapped run-curl [...args] {
	let input = $in
	let ca = (["/etc/ssl/certs/ca-certificates.crt" "/var/lib/ca-certificates/ca-bundle.pem" "/etc/ssl/ca-bundle.pem" "/etc/ssl/cert.pem"] | where {|p| $p | path exists } | get -o 0 | default "")
	mut env_map = { MISE_LOCKED: "0", OPENSSL_CONF: ($env.OPENSSL_CONF? | default "/dev/null") }
	if ($ca | is-not-empty) {
		if (($env.CURL_CA_BUNDLE? | default "") == "") { $env_map = ($env_map | insert CURL_CA_BUNDLE $ca) }
		if (($env.SSL_CERT_FILE? | default "") == "") { $env_map = ($env_map | insert SSL_CERT_FILE $ca) }
	}
	with-env $env_map { $input | ^mise tool-stub (stub-path "curl") ...$args }
}

export def --wrapped run-oras [...args] {
	let input = $in
	with-env { MISE_LOCKED: "0" } { $input | ^mise tool-stub (stub-path "oras") ...$args }
}

# The checkers the healthcheck templates copy into images, for host probes.
# Short micro-retries absorb process-compose firing the first probe while a
# service is binding its listen socket.
export def --wrapped run-microcheck [checker: string, ...args] {
	if $checker not-in [httpcheck portcheck] { error make {msg: $"microcheck: no stub for ($checker)"} }
	if $nu.os-info.name == "windows" {
		if ("--help" in $args) or ("-h" in $args) { return }
		if $checker == "httpcheck" {
			mut hdrs = []
			mut i = 0
			while $i < ($args | length) {
				let a = ($args | get $i)
				if $a == "-H" and ($i + 1) < ($args | length) {
					let kv = ($args | get ($i + 1) | split row -n 2 ": ")
					if ($kv | length) == 2 { $hdrs = ($hdrs | append [$kv.0 $kv.1]) }
					$i += 2
				} else {
					$i += 1
				}
			}
			let url = ($args | last)
			mut last_err = ""
			for _ in 1..10 {
				let err = (try { http get --max-time 2sec --headers $hdrs $url | ignore; null } catch {|e| $e.msg? | default ($e | to text) })
				if $err == null { return }
				$last_err = $err
				sleep 50ms
			}
			print -e $"httpcheck ($url) failed: ($last_err)"
			exit 1
		}
		let port = ($args | last | into string)
		let ps = (if (which pwsh | is-not-empty) { "pwsh" } else { "powershell" })
		let res = (do { ^$ps -NoLogo -NoProfile -NonInteractive -Command $"for \($i = 0; $i -lt 10; $i++\) { $c = [System.Net.Sockets.TcpClient]::new\(\); try { $t = $c.ConnectAsync\('127.0.0.1', ($port)\); if \($t.Wait\(1000\) -and $c.Connected\) { $c.Close\(\); exit 0 } } catch {} finally { $c.Dispose\(\) }; Start-Sleep -Milliseconds 50 }; exit 1" } | complete)
		if $res.exit_code == 0 { return }
		print -e $"portcheck ($port) failed: ($res.stderr | str trim)"
		exit 1
	}
	let input = $in
	if ("--help" in $args) or ("-h" in $args) {
		with-env { MISE_LOCKED: "0" } { $input | ^mise tool-stub (stub-path $checker) ...$args }
		return
	}
	mut last_err = ""
	for _ in 1..10 {
		let res = (with-env { MISE_LOCKED: "0" } { do { $input | ^mise tool-stub (stub-path $checker) ...$args } | complete })
		if $res.exit_code == 0 { return }
		$last_err = ($res.stderr | str trim)
		sleep 50ms
	}
	if ($last_err | is-not-empty) { print -e $last_err }
	exit 1
}
