// process_compose.cue — the runtime process a target starts, and what every
// projection needs to start it: the entrypoint (a #cmd a supervisor runs as a
// process, beside the target's tasks), the ports it listens on, and the helpers
// that render both for the host. gen_compose lowers the same declarations into the
// Dockerfile and the compose service; gen_process_compose into
// .bayt/process-compose.yaml.
package bayt

import (
	"crypto/sha256"
	"encoding/hex"
	"list"
	"math"
	"regexp"
	"strconv"
	"strings"
)

// One listening port. `env` names the variable the process reads it from —
// directly, or through its entrypoint's shell (`-p "$PORT"`), which expands at
// run time in a container and on the host alike. On the host that variable
// carries a per-project port, or `host` where people type it; without `env`
// nothing can carry another number, so the port keeps its own.
#port: {
	port:  int & >0 & <65536
	env?:  string
	host?: int & >0 & <65536
	if host != _|_ {env: string}
}

// The process the runtime starts, whether it serves until stopped or runs to
// completion: a #cmd, rendered as a cmd renders (dockerfile.do and shell in an
// image, activate on the host), plus what only a process has. A cmd's
// chain position, stop flag and per-cmd srcs mean nothing here and are closed.
#entrypoint: {
	#cmd
	name:     "entrypoint"
	do:       string
	priority: 0
	stop:     false
	srcs: {globs: [], exclude: [], defaultGlobs: null, defaultExclude: null}

	// The process's environment in compose and on the host. A value names a
	// peer the way compose does; the host projection rewrites it to loopback
	// (gen_process_compose).
	env: [string]: string

	// The same-project targets this process waits on, and for what. A
	// one-shot that others need finished is waited on as "completed".
	after: [string]: "started" | "healthy" | "completed"

	// Whether the host runs it too, under process-compose. Off for a process
	// only its image can run: it then meets none of the host's checks.
	host: *true | bool
}

// Control and passthrough for the host projection. `activate` is the host
// process's toolchain, entrypoint and probes, where it differs from the
// target's own `activate`, which its build cmds run under. The probe and
// lifecycle fields pass through verbatim.
#processCompose: {
	activate?: string
	readiness_probe?: {...}
	liveness_probe?: {...}
	availability?: {...}
	shutdown?: {...}
	// Below the project directory, where process-compose is started.
	working_dir?: string & !~"^/" & !~"(^|/)\\.\\.?(/|$)"
}

// The host variable carrying a target's port. Distinct names can collapse to
// one variable; gen_process_compose refuses a project where two do.
_portVar: V={
	target: string
	name:   string
	out:    strings.ToUpper(regexp.ReplaceAll("[^A-Za-z0-9]+", "\(V.target)_\(V.name)_port", "_"))
}

// A port that differs between projects and repeats between checkouts of one:
// launch is for one person at one screen, so two checkouts of a project
// collide loudly on the bind rather than drifting apart. Below 32768, where
// neither Linux's nor macOS's ephemeral range hands out outbound ports.
_portDefault: D={
	project: string
	target:  string
	name:    string
	let _h = strconv.ParseInt(strings.SliceRunes(hex.Encode(sha256.Sum256("\(D.project)/\(D.target)/\(D.name)")), 0, 8), 16, 64)
	out: 10000 + mod(_h, 22768)
}

// The port a launch binds: the one people type, else the per-project one.
_hostDefault: H={
	project: string
	target:  string
	name:    string
	port:    #port
	out: [if H.port.host != _|_ {H.port.host}, (_portDefault & {project: H.project, target: H.target, name: H.name}).out][0]
}

// The host spelling of a port: its variable, which the driver exports to move
// a whole stack at once, defaulting to `host` or else the per-project port. A
// port with no variable to carry it keeps its number.
_hostPort: R={
	project: string
	target:  string
	name:    string
	port:    #port
	out: [
		if R.port.env != _|_ {
			"${\((_portVar & {target: R.target, name: R.name}).out):-\((_hostDefault & {project: R.project, target: R.target, name: R.name, port: R.port}).out)}"
		},
		"\(R.port.port)",
	][0]
}

// Keys whose whole value is an address when it names a peer: a separated
// suffix, so GHOST and OBSERVER are not, and libpq's PGHOST by name.
_hostKeys: "(?i)((^|_)(host|hostname|addr|address|server)|^pghost)$"

// The port key beside a host key: PGHOST's PGPORT, DB_host's DB_port.
_portKey: K={
	in:  string
	out: regexp.ReplaceAll("host$", regexp.ReplaceAll("Host$", regexp.ReplaceAll("HOST$", K.in, "PORT"), "Port"), "port")
}

// Where a port ends: `redis:7-alpine` is an image, `user:1234@` a password,
// `tcp(db:3306)` and `[db:3306]` an address.
_portEnd: "([/?#,;\\s\"')\\]|&>]|$)"

// A name as a regex literal: target and project names may carry a `.`.
_reQuote: Q={
	in:  string
	out: strings.Replace(Q.in, ".", "\\.", -1)
}

// A peer named as compose names it — `<target>:<port>` or
// `<project>-<target>:<port>` — as a pattern for what the host rewrite left.
_peerName: P={
	project: string
	peer:    string
	out:     "(^|[^A-Za-z0-9_.-])(\((_reQuote & {in: P.project}).out)-)?\((_reQuote & {in: P.peer}).out):[0-9]+\(_portEnd)"
}

// A peer as a URL's host, with or without a port, read after the userinfo is
// gone (`_noUserinfo`): `://postgres:1234@` names a user, not a host.
_peerHost: P={
	project: string
	peer:    string
	out:     "(://|@)(\((_reQuote & {in: P.project}).out)-)?\((_reQuote & {in: P.peer}).out)([:/?#]|$)"
}

// A URL with its userinfo removed, so only its host is left to read.
_noUserinfo: U={
	in:  string
	out: regexp.ReplaceAll("://[^/@\\s]*@", U.in, "://")
}

// The way from a project at `depth` to the repository root.
_relPrefix: R={
	depth: int
	out: [if R.depth == 0 {"./"}, strings.Repeat("../", R.depth)][0]
}

// Where bayt's runtime sits relative to a project, for a generator emitting
// in-tree references; "" means bayt resolves from PATH.
_runtimeDir: R={
	runtime: string
	depth:   int
	out:     "\((_relPrefix & {depth: R.depth}).out)\(R.runtime)/runtime"
}

// An entrypoint as argv, never a shell string. The toolchain wraps the whole
// command, a shell included, so every command a shell `do` runs resolves under
// it: the exec shell splits on spaces as a Dockerfile RUN does; any other
// shell receives `do` as one -c argument.
_argv: A={
	do:       string
	shell:    string
	activate: string
	let _act = [for tk in strings.Split(A.activate, " ") if tk != "" {tk}]
	out: list.Concat([_act, [
		if A.shell == "exec" {[for tk in strings.Split(A.do, " ") if tk != "" {tk}]},
		[A.shell, "-c", A.do],
	][0]])
}

// A compose duration as whole seconds, rounded up, at least `floor`:
// process-compose counts in seconds, so a sub-second interval still probes
// while a zero grace period adds none. Accepts Go's composite spelling
// (`1m30s`, `1.5s`); anything else fails generation.
_seconds: S={
	in:    string
	floor: *1 | int
	let _re = "([0-9]+(?:\\.[0-9]+)?)(ns|us|µs|ms|s|m|h)"
	let _unit = {ns: 1e-9, us: 1e-6, "µs": 1e-6, ms: 1e-3, s: 1, m: 60, h: 3600}
	let _spelled = regexp.Match("^(?:\(_re))+$", S.in)
	let _parts = [if _spelled for m in regexp.FindAllSubmatch(_re, S.in, -1) {strconv.ParseFloat(m[1], 64) * _unit[m[2]]}]

	// A bare 0 is Go's one unitless duration.
	let _readable = S.in == "0" || _spelled
	let _total = math.Ceil(list.Sum(list.Concat([[0], _parts])))
	out: [
		if !_readable {error("\(S.in) is not a duration")},
		list.Max([S.floor, strconv.Atoi(strconv.FormatFloat(_total, 102, 0, 64))]),
	][0]
}

// A compose healthcheck's timing as a readiness probe's. Compose ignores
// failures during start_period; process-compose terminates a process after
// failure_threshold misses and skips what waits on it, so the threshold has
// to cover the start-up window as well as the retries.
_probeTiming: P={
	healthcheck: _
	let _period = (_seconds & {in: P.healthcheck.interval}).out
	let _grace = (_seconds & {in: P.healthcheck.start_period, floor: 0}).out
	out: {
		period_seconds: _period
		timeout_seconds: (_seconds & {in: P.healthcheck.timeout}).out
		failure_threshold: P.healthcheck.retries + div(_grace+_period-1, _period)
	}
}

// A port literal a probe names, as the host spelling when it is one of the
// target's own exposed ports.
_ownPort: O={
	expose:  _
	project: string
	target:  string
	port:    string
	let _own = [for n, e in O.expose if "\(e.port)" == O.port {
		(_hostPort & {project: O.project, target: O.target, name: n, port: e}).out
	}]
	out: [if len(_own) > 0 {_own[0]}, O.port][0]
}

// A loopback URL with each own exposed port in its host spelling. Rewritten
// rather than parsed, so any URL compose takes is one the host probe takes.
_ownPortsInURL: U={
	expose:  _
	project: string
	target:  string
	url:     string
	let _rules = [for n, e in U.expose if e.env != _|_ {
		// A loopback host carries no image tag or password, so any non-digit
		// ends its port.
		needle: ":\(e.port)"
		from:   "(127\\.0\\.0\\.1|localhost|\\[::1\\]):\(e.port)([^0-9]|$)"
		to:     "${1}:\(strings.Replace((_hostPort & {project: U.project, target: U.target, name: n, port: e}).out, "$", "$$", -1))${2}"
	}]

	// Only a rule whose port appears can match; a regex per value and rule
	// otherwise dominates generation.
	let _live = [for r in _rules if strings.Contains(U.url, r.needle) {r}]
	_steps: [U.url, for i, r in _live {regexp.ReplaceAll(r.from, U._steps[i], r.to)}]
	out: U._steps[len(_live)]
}

// The host's microcheck: the checkers the http and tcp templates copy into
// images, run through bayt's checksum-pinned stubs (runtime/httpcheck.toml,
// portcheck.toml). gen_process_compose points it at the bayt it generates for.
_microcheckHost: "bayt microcheck"

_composeCondition: {started: "service_started", healthy: "service_healthy", completed: "service_completed_successfully"}
_processCondition: {started: "process_started", healthy: "process_healthy", completed: "process_completed_successfully"}

// A target's compose service, the name its peers wait on.
_serviceName: N={
	project: string
	target:  string
	out:     "\(N.project)-\(N.target)"
}

// The entrypoint as a container runs it: dockerfile.do and its shell override
// the base, as they do for a cmd's RUN. No toolchain wraps it: a container's
// process starts from what its image baked in, and a runtime image carries no
// mise. An image whose process needs a wrapper says so in dockerfile.do.
_containerArgv: C={
	t: _
	let _e = C.t.entrypoint
	out: (_argv & {
		do: [if _e.dockerfile != _|_ if _e.dockerfile.do != _|_ {_e.dockerfile.do}, _e.do][0]
		shell: [if _e.dockerfile != _|_ if _e.dockerfile.shell != _|_ {_e.dockerfile.shell}, _e.shell][0]
		activate: ""
	}).out
}

// A container keeps every canonical port, so a port's variable is its number.
_containerEnv: C={
	t: _
	out: {
		if C.t.entrypoint != _|_ {C.t.entrypoint.env}
		if C.t.expose != _|_ for _, e in C.t.expose if e.env != _|_ {(e.env): "\(e.port)"}
	}
}

// A container waits only on a peer compose runs: one with a compose block.
_containerWaits: C={
	t:     _
	files: _
	out: {
		if C.t.entrypoint != _|_ for k, c in C.t.entrypoint.after {
			// A compose file includes only what its target depends on.
			if !list.Contains(C.t.sameProjectDeps, k) && !list.Contains(C.t.sameProjectDeps, "\(k)_outs") {
				((_serviceName & {project: C.t.project, target: k}).out): error("\(C.t.name): waits on \(k) without depending on it; add \":\(k):outs\" to deps")
			}
			if C.files[k].compose == _|_ {
				((_serviceName & {project: C.t.project, target: k}).out): error("\(C.t.name): waits on \(k), which has no container to wait on")
			}
			((_serviceName & {project: C.t.project, target: k}).out): condition: _composeCondition[c]
		}
	}
}
