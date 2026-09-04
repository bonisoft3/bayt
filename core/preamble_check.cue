// preamble_check — the three #dockerfile._preambleEl arms render to their
// own instruction kinds, and a RUN arm's mounts get emitter-owned id +
// sharing.
//
// Guards a regression the other suites cannot see: a dropped arm renders
// as an absent line, and an absent line is not an error anywhere — the
// Dockerfile just silently loses a COPY or a package install.
//
// In package bayt because _expandPreamble is hidden (file-crossing but not
// package-crossing). The RUN arm is spelled inline so this pins the arm
// itself rather than whatever a distro fragment currently emits; the
// fragments are covered consumer-side in tests/_positive_preamble.
package bayt

import "strings"

_pc_preamble: {
	"env": {name: "env", priority: -20, line: "ENV FOO=bar"}
	// Spelled out field by field because `in` is typed `#MapAsList`, not
	// `_preambleEl` — the fixture gets none of the schema's defaults, so a
	// field added to _copyEntry and read by _copyLine has to be added here
	// too. `link` is one; a rename is not a `--link` shape anyway.
	"pin": {name: "pin", priority: -19, copy: {
		from: {name: "busybox:musl@sha256:03db"}
		srcs: ["/bin/busybox"]
		dst:     "/busybox"
		link:    true
		parents: false
		exclude: []
	}}
	"run": {name: "run", priority: -18, do: "install stuff", shell: "sh", mounts: [
		{type: "cache", target: "/var/cache/pkg", scope: "target", required: false},
	]}
}

_pc_lines: (_expandPreamble & {in: _pc_preamble, project: "proj", target: "tgt"}).out

// Indexed, so these pin priority order across arms as well as each arm's
// rendering — a COPY can be placed before a RUN that consumes it.
_pc_line_arm: _pc_lines[0] & "ENV FOO=bar"
_pc_copy_arm: _pc_lines[1] & "COPY --from=busybox:musl@sha256:03db /bin/busybox /busybox"

// Both halves of the `project` arm matter: sharing=locked, and an id
// qualified by project rather than the bare path.
_pc_run_arm: _pc_lines[2] & "RUN --mount=type=cache,target=/var/cache/pkg,id=proj-tgt:/var/cache/pkg,sharing=locked install stuff"

// Scope carries sharing; these pin the other two arms.
_pc_default_sharing: (_mount & {
	m: {type: "cache", target: "/t", scope: "target", required: false}
	project: "proj"
	name:    "tgt"
}).out & "--mount=type=cache,target=/t,id=proj-tgt:/t,sharing=locked"

_pc_default_shared: (_mount & {
	m: {type: "cache", target: "/t", scope: "global", required: false}
	project: "proj"
	name:    "tgt"
}).out & "--mount=type=cache,target=/t,id=/t,sharing=shared"

// End-to-end, through the compose generator: a preamble copy arm must
// reach additional_contexts, and the `image:` override must survive as the
// docker-image:// value. Asserting on the rendered COPY alone proves
// nothing — the line renders whether or not the context is wired, and a
// `--from=bayt` with no entry resolves as a registry image named "bayt"
// rather than the pinned digest.
//
// Ordering is pinned here too: the preamble sits above every repo-derived
// instruction (add, copy, dep COPYs, src COPYs), which is the property the
// region exists for. Nothing else in the suite observes where the preamble
// lands relative to them.
_pc_p: #project & {
	name: "pc"
	dir:  "pc"
	targets: "build": {
		srcs: globs: ["src/**"]
		cmd: "builtin": {do: "true", shell: "sh"}
		dockerfile: {
			from: name: "alpine"
			defaultPreamble: "runtime": copy: {
				from: {name: "bayt", image: "bonitao/bayt:0.0.0@sha256:deadbeef"}
				srcs: ["runtime"]
				dst:  "/opt/runtime"
			}
			add: [{url: "https://example.com/blob", sha256: "0000000000000000000000000000000000000000000000000000000000000000", dest: "/blob"}]
			copy: [{srcs: ["src/app.conf"], dst: "/etc/app.conf"}]
		}
	}
}

_pc_dc:   (#dockerComposeGen & {project: _pc_p, depManifests: {}})
_pc_dockerfile: _pc_dc.dockerfiles.build

_pc_ctx_wired: _pc_dc.compose.files.build.services."pc-build".build.additional_contexts.bayt &
	"docker-image://bonitao/bayt:0.0.0@sha256:deadbeef"

_pc_order_preamble_before_add:  (strings.Index(_pc_dockerfile, "/opt/runtime") < strings.Index(_pc_dockerfile, "/blob")) & true
_pc_order_preamble_before_copy: (strings.Index(_pc_dockerfile, "/opt/runtime") < strings.Index(_pc_dockerfile, "/etc/app.conf")) & true
_pc_order_copy_before_srcs:     (strings.Index(_pc_dockerfile, "/etc/app.conf") < strings.Index(_pc_dockerfile, "--parents")) & true

// A non-sh shell takes the exec form with the cmd JSON-escaped: backslash
// first, so the quote pass does not re-escape it. Nothing else in the suite
// puts a quote or a backslash in a `do`, so the escaping itself is
// otherwise unobserved.
_pc_escaped: (_runForm & {
	prefix: ""
	shell:  "nu"
	do:     "echo \"hi\" \\ there"
}).out & "RUN [\"nu\", \"-c\", \"echo \\\"hi\\\" \\\\ there\"]"
