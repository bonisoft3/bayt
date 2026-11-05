// stacks/deno — Deno toolchain concept library.
//
// DENO_DIR must stay a real image path so runtime containers and downstream
// FROM stages (which run with `--cached-only` or without network) find the
// module, npm, and V8 compile caches in the image layer. A bare BuildKit cache
// mount on DENO_DIR would unmount at the end of RUN and leave the layer empty.
//
// Every container RUN therefore uses a two-phase seed/publish script against
// `storeMount` (/deno-store, scope: target), keyed by lockfile digest:
//   1. Seed ${DENO_DIR:-/root/.cache/deno} from /deno-store/$k.
//   2. Run the deno command (`|| exit` so any failure fails the RUN).
//   3. Publish newly fetched entries atomically back to /deno-store/$k and prune
//      superseded keys.
//
// Wrapped in `sh -c '...'` as a single command so a target's `activate` prefix
// (`mise x --`) wraps the entire subshell, not only the first `;`-separated
// assignment.
package deno

import "strings"

storeMount:  {type: "cache", target: "/deno-store", scope: "target"}
duckdbMount: {type: "cache", target: "/duckdb-store", scope: "target"}

lockFiles: globs: [
	"[d]eno.json",
	"[d]eno.jsonc",
	"[d]eno.lock",
]

#twoPhase: T={
	do:  string
	dir: *"${DENO_DIR:-/root/.cache/deno}" | string
	let _body = #"d="\#(T.dir)"; s=\#(storeMount.target); k="$(sha256sum deno.lock */deno.lock */*/deno.lock deno.json */deno.json */*/deno.json package.json */package.json 2>/dev/null | sha256sum | cut -d' ' -f1)"; mkdir -p "$d" "$s"; for sub in remote npm jsr; do if [ -d "$s/$k/$sub" ]; then mkdir -p "$d/$sub" && cp -a "$s/$k/$sub"/. "$d/$sub"/ 2>/dev/null || true; fi; done; (\#(T.do)) || exit; t="$s/.tmp.$$"; rm -rf "$t"; mkdir -p "$t"; for sub in remote npm jsr; do if [ -d "$d/$sub" ]; then mkdir -p "$t/$sub" && cp -a "$d/$sub"/. "$t/$sub"/ 2>/dev/null || true; fi; done; rm -rf "$s/$k" && mv "$t" "$s/$k" 2>/dev/null || rm -rf "$t"; find "$s" -mindepth 1 -maxdepth 1 ! -name "$k" -exec rm -rf {} + 2>/dev/null || true"#
	out: "sh -c '\(strings.Replace(_body, "'", "'\\''", -1))'"
}

#duckdbTwoPhase: T={
	do:  string
	dir: *"${DUCKDB_EXTENSIONS_DIR:-/app/extensions}" | string
	let _body = #"d="\#(T.dir)"; s=\#(duckdbMount.target); mkdir -p "$d" "$s"; cp -a "$s"/. "$d"/ 2>/dev/null || true; (\#(T.do)) || exit; cd "$d" && find . -type f | while IFS= read -r f; do rel="${f#./}"; dst="$s/$rel"; [ -e "$dst" ] && continue; mkdir -p "$(dirname "$dst")"; tmp="$dst.tmp.$$"; cp -p "$rel" "$tmp" 2>/dev/null && mv -f "$tmp" "$dst" 2>/dev/null || rm -f "$tmp"; done"#
	out: "sh -c '\(strings.Replace(_body, "'", "'\\''", -1))'"
}

// #cmd — host + container command. Host runs `do` directly against the user's
// native DENO_DIR; container runs the two-phase against storeMount.
#cmd: C={
	priority?: int
	do:        string
	shell:     *"exec" | string
	srcs?:     _
	out: {
		if C.priority != _|_ {"priority": C.priority}
		if C.srcs != _|_ {"srcs": C.srcs}
		"do":    C.do
		"shell": C.shell
		dockerfile: {
			do:     (#twoPhase & {do: C.do}).out
			shell:  "sh"
			mounts: [storeMount]
		}
	}
}

// #containerCmd — container-only RUN step (no host `do`, like stacks/go's
// _twoPhase). Used on image-only targets (`cmd: builtin: null`) to populate
// the image layer's DENO_DIR from storeMount after sources are copied.
#containerCmd: C={
	priority?: int
	do:        string
	srcs?:     _
	out: {
		if C.priority != _|_ {"priority": C.priority}
		if C.srcs != _|_ {"srcs": C.srcs}
		dockerfile: {
			do:     (#twoPhase & {do: C.do}).out
			shell:  "sh"
			mounts: [storeMount]
		}
	}
}

// #duckdbContainerCmd — container-only RUN step that populates DuckDB's
// extension directory from duckdbMount.
#duckdbContainerCmd: C={
	priority?: int
	do:        string
	out: {
		if C.priority != _|_ {"priority": C.priority}
		dockerfile: {
			do:     (#duckdbTwoPhase & {do: C.do}).out
			shell:  "sh"
			mounts: [duckdbMount]
		}
	}
}

// #preamble — defaultPreamble entry that runs a two-phase deno command before
// target.srcs COPYs so source edits do not invalidate the install layer.
#preamble: P={
	priority?: int
	do:        string
	out: {
		if P.priority != _|_ {"priority": P.priority}
		do:     (#twoPhase & {do: P.do}).out
		shell:  "sh"
		mounts: [storeMount]
	}
}

// install — `deno install --frozen` as a composable cmd fragment.
install: {
	cmd: "deno-install": (#cmd & {
		priority: -1
		do:       "deno install --frozen"
		srcs:     lockFiles
	}).out
}

// #cache — `deno cache --frozen <entrypoints>` as a composable cmd fragment.
#cache: C={
	entrypoints: string
	frozen:      *true | bool
	let _flag = [if C.frozen {"--frozen "}, ""][0]
	out: cmd: "deno-cache": (#containerCmd & {
		priority: -1
		do:       "deno cache \(_flag)\(C.entrypoints)"
	}).out
}
