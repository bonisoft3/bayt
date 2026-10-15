// user_identity_check.cue — exercises #userIdentity, dockerfile.user,
// copy[].chown, and compose.user with both string and structured identities.
package bayt

import (
	"strings"
	"github.com/bonisoft3/bayt/distros/apt"
	"github.com/bonisoft3/bayt/distros/apk"
	"github.com/bonisoft3/bayt/distros/zypper"
)

// --- U1: target with structured user identity from apt (Debian/Ubuntu)
_u1: #project & {
	name: "u1"
	dir:  "u1"
	targets: {
		"release": {
			srcs: globs: []
			outs: globs: []
			dockerfile: {
				busybox
				user: apt.#users.nobody
				copy: [{
					from:  null
					srcs:  ["app.bin"]
					dst:   "/app/bin"
					chown: apt.#users.nobody
				}]
			}
		}
	}
}
_u1_dc: (#dockerComposeGen & {project: _u1, depManifests: {}})
_u1_df: _u1_dc.dockerfiles.release
// COPY must render with numeric UID:GID
_u1_copy_check: strings.Contains(_u1_df, "COPY --chown=65534:65534 app.bin /app/bin") & true
// USER must render with numeric UID:GID
_u1_user_check: strings.Contains(_u1_df, "USER 65534:65534") & true

// --- U2: target with raw strings for backwards compatibility
_u2: #project & {
	name: "u2"
	dir:  "u2"
	targets: {
		"legacy": {
			srcs: globs: []
			outs: globs: []
			dockerfile: {
				busybox
				user: "customuser"
				copy: [{
					from:  null
					srcs:  ["data/"]
					dst:   "/data"
					chown: "10001:10001"
				}]
			}
		}
	}
}
_u2_dc: (#dockerComposeGen & {project: _u2, depManifests: {}})
_u2_df: _u2_dc.dockerfiles.legacy
_u2_copy_check: strings.Contains(_u2_df, "COPY --chown=10001:10001 data/ /data") & true
_u2_user_check: strings.Contains(_u2_df, "USER customuser") & true

// --- U3: Alpine distro user verification (testing group discrepancy)
_u3: #project & {
	name: "u3"
	dir:  "u3"
	targets: {
		"alpine_app": {
			srcs: globs: []
			outs: globs: []
			dockerfile: {
				busybox
				user: apk.#users.nogroup
				copy: [{
					from:  null
					srcs:  ["pkg"]
					dst:   "/pkg"
					chown: apk.#users.nogroup
				}, {
					from:  null
					srcs:  ["db"]
					dst:   "/db"
					chown: apk.#users.postgres
				}]
			}
		}
	}
}
_u3_dc: (#dockerComposeGen & {project: _u3, depManifests: {}})
_u3_df: _u3_dc.dockerfiles.alpine_app
// Alpine nogroup is GID 65533
_u3_nogroup_check: strings.Contains(_u3_df, "COPY --chown=65534:65533 pkg /pkg") & true
// Alpine postgres is UID/GID 70:70
_u3_postgres_check: strings.Contains(_u3_df, "COPY --chown=70:70 db /db") & true
// Alpine user directive with nogroup
_u3_user_check: strings.Contains(_u3_df, "USER 65534:65533") & true

// --- U4: Compose service user mapping with #userIdentity
_u4: #project & {
	name: "u4"
	dir:  "u4"
	targets: {
		"srv": {
			srcs: globs: []
			outs: globs: []
			cmd: "builtin": do: "true"
			dockerfile: busybox
			compose: user: apt.#users.postgres
		}
	}
}
_u4_dc: (#dockerComposeGen & {project: _u4, depManifests: {}})
_u4_svc: _u4_dc.compose.files.srv.services."u4-srv"
_u4_svc_user: _u4_svc.user & "999:999"

// --- U5: Distroless nonroot preset verification
_u5: #project & {
	name: "u5"
	dir:  "u5"
	targets: {
		"distroless": {
			srcs: globs: []
			outs: globs: []
			dockerfile: {
				scratch
				user: #nonroot
				copy: [{
					from:  null
					srcs:  ["binary"]
					dst:   "/app/binary"
					chown: #nonroot
				}]
			}
		}
	}
}
_u5_dc: (#dockerComposeGen & {project: _u5, depManifests: {}})
_u5_df: _u5_dc.dockerfiles.distroless
_u5_copy_check: strings.Contains(_u5_df, "COPY --chown=65532:65532 binary /app/binary") & true
_u5_user_check: strings.Contains(_u5_df, "USER 65532:65532") & true

// --- U6: openSUSE / zypper distro user verification
_u6: #project & {
	name: "u6"
	dir:  "u6"
	targets: {
		"leap_app": {
			srcs: globs: []
			outs: globs: []
			dockerfile: {
				busybox
				user: zypper.#users.nobody
				copy: [{
					from:  null
					srcs:  ["leap.bin"]
					dst:   "/bin/leap.bin"
					chown: zypper.#users.nobody
				}]
			}
		}
	}
}
_u6_dc: (#dockerComposeGen & {project: _u6, depManifests: {}})
_u6_df: _u6_dc.dockerfiles.leap_app
_u6_copy_check: strings.Contains(_u6_df, "COPY --chown=65534:65534 leap.bin /bin/leap.bin") & true
_u6_user_check: strings.Contains(_u6_df, "USER 65534:65534") & true

// --- U7: Universal vscode user
_u7: #project & {
	name: "u7"
	dir:  "u7"
	targets: {
		"dev": {
			srcs: globs: []
			outs: globs: []
			dockerfile: {
				busybox
				user: #users.vscode
				copy: [{
					from:  null
					srcs:  ["workspace"]
					dst:   "/workspace"
					chown: #vscodeUser
				}]
			}
		}
	}
}
_u7_dc: (#dockerComposeGen & {project: _u7, depManifests: {}})
_u7_df: _u7_dc.dockerfiles.dev
_u7_copy_check: strings.Contains(_u7_df, "COPY --chown=1000:1000 workspace /workspace") & true
_u7_user_check: strings.Contains(_u7_df, "USER 1000:1000") & true

// --- U8: Direct usage of #users.nobody on a leaf image
_u8: #project & {
	name: "u8"
	dir:  "u8"
	targets: {
		"app": {
			srcs: globs: []
			outs: globs: []
			dockerfile: {
				from: name: "python:3.14-slim"
				user: #users.nobody
				copy: [{
					from:  null
					srcs:  ["venv"]
					dst:   "/venv"
					chown: #users.nobody
				}]
			}
		}
	}
}
_u8_dc: (#dockerComposeGen & {project: _u8, depManifests: {}})
_u8_df: _u8_dc.dockerfiles.app
_u8_copy_check: strings.Contains(_u8_df, "COPY --chown=65534:65534 venv /venv") & true
_u8_user_check: strings.Contains(_u8_df, "USER 65534:65534") & true
