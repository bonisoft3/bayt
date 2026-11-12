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
	udp?:  *false | bool
	env?:  string
	host?: int & >0 & <65536
	// A host process's fixed port reaches it through `env`; a published
	// container port listens on its own `port` whatever the host binds.
	if host != _|_ if publish == _|_ {env: string}

	// Published on the host by the container's compose service under a
	// variable sourced as a secret's is (#dockerfile.secrets): `true` takes
	// the derived `<TARGET>_<NAME>_PORT`, `{environment: V}` names one
	// (SPEC.md, Published ports).
	publish?: true | close({environment: =~"^[A-Za-z_][A-Za-z0-9_]*$"})
}

// The host variable a published port binds under.
_publishVar: {
	target: string
	name:   string
	port:   #port
	let _target = target
	let _name = name
	out: [
		if (port.publish & true) != _|_ {(_portVar & {target: _target, name: _name}).out},
		port.publish.environment,
	][0]
}

// A typed reference to a port in the project's `expose` maps (a peer's when
// `peer` is set, else the target's own). Lowered to the container's address in
// compose and to loopback with the port's host variable in process-compose.
#portRef: close({
	peer?:  string & !=""
	port:   string & !=""
	part:   *"addr" | "host" | "port"
	host?:  string & !=""
	prefix: *"" | string
	suffix: *"" | string
})

#envValue: string | #portRef | [...(string | #portRef)]

// The process the runtime starts, whether it serves until stopped or runs to
// completion: a #cmd, rendered as a cmd renders (dockerfile.do and shell in an
// image, activate on the host), plus what only a process has. A cmd's
// chain position, stop flag and per-cmd srcs mean nothing here and are closed.
#entrypoint: {
	_cmd
	name:     "entrypoint"
	do:       string
	priority: 0
	stop:     false
	srcs:     {globs: [], exclude: [], defaultGlobs: null, defaultExclude: null}

	// Base environment lowered into compose and process-compose; a projection's
	// own environment overrides per key.
	env: [string]: #envValue

	// The same-project targets this process waits on, and for what. A
	// one-shot that others need finished is waited on as "completed".
	after: [string]: "started" | "healthy" | "completed"

	// Whether the host runs it too, under process-compose. Off for a process
	// only its image can run: it then meets none of the host's checks.
	host: *true | bool
}

// Control and passthrough for the host projection. `activate` is the host
// process's toolchain, entrypoint and probes, where it differs from the
// target's own `activate`, which its build cmds run under. `env` overrides
// `entrypoint.env` per key on the host. The probe and lifecycle fields pass
// through verbatim.
#processCompose: {
	activate?: string
	env?: [string]: #envValue
	readiness_probe?: {...}
	liveness_probe?:  {...}
	availability?:    {...}
	shutdown?:        {...}
	// Below the project directory, where process-compose is started.
	working_dir?: string & !~"^/" & !~"(^|/)\\.\\.?(/|$)"
}

// The host variable carrying a target's port. Distinct names can collapse to
// one variable; gen_process_compose refuses a project where two do.
_portVar: {
	target: string
	name:   string
	out:    strings.ToUpper(regexp.ReplaceAll("[^A-Za-z0-9]+", "\(target)_\(name)_port", "_"))
}

// A port that differs between projects and repeats between checkouts of one:
// launch is for one person at one screen, so two checkouts of a project
// collide loudly on the bind rather than drifting apart. Below 32768, where
// neither Linux's nor macOS's ephemeral range hands out outbound ports.
_portDefault: {
	project: string
	target:  string
	name:    string
	let _h = strconv.ParseInt(strings.SliceRunes(hex.Encode(sha256.Sum256("\(project)/\(target)/\(name)")), 0, 8), 16, 64)
	out: 10000 + mod(_h, 22768)
}

// The port a launch binds: the one people type, else the per-project one.
_hostDefault: {
	project: string
	target:  string
	name:    string
	port:    #port
	let _project = project
	let _target = target
	let _name = name
	out: [if port.host != _|_ {port.host}, (_portDefault & {project: _project, target: _target, name: _name}).out][0]
}

// Every port a project's host processes bind when launched: its default and,
// when it moves, the variable that moves it. Read by process-compose's own
// clash check and by the published-port check, which must agree on both.
_hostProcPorts: {
	files:    _
	identity: string
	let _identity = identity
	out: [
		for n, t in files if t.entrypoint != _|_ if t.entrypoint.host if t.expose != _|_ for p, e in t.expose {
			target: n
			who:    "\(n).expose.\(p)"
			port:   [if e.env != _|_ {(_hostDefault & {project: _identity, target: n, name: p, port: e}).out}, e.port][0]
			if e.env != _|_ {var: (_portVar & {target: n, name: p}).out}
		},
	]
}

// The host spelling of a port: its variable, which the driver exports to move
// a whole stack at once, defaulting to `host` or else the per-project port. A
// port with no variable to carry it keeps its number.
_hostPort: {
	project: string
	target:  string
	name:    string
	port:    #port
	let _project = project
	let _target = target
	let _name = name
	let _port = port
	let _var = [
		if _port.env != _|_ {(_portVar & {target: _target, name: _name}).out},
		if _port.publish != _|_ {(_publishVar & {target: _target, name: _name, port: _port}).out},
		"",
	][0]
	out: [
		if _var != "" {
			"${\(_var):-\((_hostDefault & {project: _project, target: _target, name: _name, port: _port}).out)}"
		},
		"\(_port.port)",
	][0]
}

#_renderRef: {
	target:    _
	files:     _
	procs?:    _
	identity?: string
	key:       string
	ref:       #portRef
	let _target = target
	let _files = files
	let _hasProcs = procs != _|_
	let _procs = [if _hasProcs {procs}, null][0]
	let _key = key
	let _ref = ref
	let _concrete = len(_ref.port) > 0
	let _peer = [if _ref.peer != _|_ {_ref.peer}, _target.name][0]
	let _hasTarget = _files[_peer] != _|_
	let _onHost = [if _hasProcs && _ref.peer != _|_ {_procs[_peer] != _|_}, true][0]
	let _hasPort = [if _hasTarget if _files[_peer].expose != _|_ {_files[_peer].expose[_ref.port] != _|_}, false][0]
	out: [
		if _concrete if !_hasTarget {
			error("\(_target.name): \(_key) names \(_peer), which is no target of this project")
		},
		if _concrete if !_onHost {
			error("\(_target.name): \(_key) names \(_peer), which does not run on the host")
		},
		if _concrete if !_hasPort {
			error("\(_target.name): \(_key) names port \(_ref.port) of \(_peer), which \(_peer) does not expose")
		},
		if _concrete if _hasTarget && _onHost && _hasPort {
			let _e = _files[_peer].expose[_ref.port]
			let _h = [
				if _ref.host != _|_ {_ref.host},
				if !_hasProcs if _ref.peer != _|_ {_ref.peer},
				"127.0.0.1",
			][0]
			let _p = [
				if _hasProcs {
					(_hostPort & {project: identity, target: _peer, name: _ref.port, port: _e}).out
				},
				"\(_e.port)",
			][0]
			let _core = [
				if _ref.part == "host" {_h},
				if _ref.part == "port" {_p},
				"\(_h):\(_p)",
			][0]
			"\(_ref.prefix)\(_core)\(_ref.suffix)"
		},
	][0]
}

#_renderEnvValue: {
	target:    _
	files:     _
	procs?:    _
	identity?: string
	key:       string
	in:        #envValue
	let _target = target
	let _files = files
	let _procs = [if procs != _|_ {[procs]}, []][0]
	let _identity = [if identity != _|_ {[identity]}, []][0]
	let _key = key
	let _in = in
	let _ctx = {
		target: _target
		files:  _files
		for p in _procs {procs: p}
		for id in _identity {identity: id}
		key: _key
	}
	out: [
		if (_in & string) != _|_ {_in},
		if _in.port != _|_ {(#_renderRef & _ctx & {ref: _in}).out},
		if (_in & string) == _|_ && _in.port == _|_ {
			strings.Join([
				for x in _in {[
					if (x & string) != _|_ {x},
					if x.port != _|_ {(#_renderRef & _ctx & {ref: x}).out},
				][0]},
			], "")
		},
	][0]
}

// The way from a project at `depth` to the repository root.
_relPrefix: {
	depth: int
	out:   [if depth == 0 {"./"}, strings.Repeat("../", depth)][0]
}

// Where bayt's runtime sits relative to a project, for a generator emitting
// in-tree references; "" means bayt resolves from PATH.
_runtimeDir: {
	runtime: string
	depth:   int
	let _depth = depth
	out: "\((_relPrefix & {depth: _depth}).out)\(runtime)/runtime"
}

// An entrypoint as argv, never a shell string. The toolchain wraps the whole
// command, a shell included, so every command a shell `do` runs resolves under
// it: the exec shell splits on spaces as a Dockerfile RUN does; any other
// shell receives `do` as one -c argument.
_argv: {
	do:       string
	shell:    string
	activate: string
	let _act = [for tk in strings.Split(activate, " ") if tk != "" {tk}]
	out: list.Concat([_act, [
		if shell == "exec" {[for tk in strings.Split(do, " ") if tk != "" {tk}]},
		[shell, "-c", do],
	][0]])
}

// A compose duration as whole seconds, rounded up, at least `floor`:
// process-compose counts in seconds, so a sub-second interval still probes
// while a zero grace period adds none. Accepts Go's composite spelling
// (`1m30s`, `1.5s`); anything else fails generation.
_seconds: {
	in:    string
	floor: *1 | int
	let _re = "([0-9]+(?:\\.[0-9]+)?)(ns|us|µs|ms|s|m|h)"
	let _unit = {ns: 1e-9, us: 1e-6, "µs": 1e-6, ms: 1e-3, s: 1, m: 60, h: 3600}
	let _spelled = regexp.Match("^(?:\(_re))+$", in)
	let _parts = [if _spelled for m in regexp.FindAllSubmatch(_re, in, -1) {strconv.ParseFloat(m[1], 64) * _unit[m[2]]}]

	// A bare 0 is Go's one unitless duration.
	let _readable = in == "0" || _spelled
	let _total = math.Ceil(list.Sum(list.Concat([[0], _parts])))
	out: [
		if !_readable {error("\(in) is not a duration")},
		list.Max([floor, strconv.Atoi(strconv.FormatFloat(_total, 102, 0, 64))]),
	][0]
}

// A compose healthcheck's timing as a readiness probe's. Compose ignores
// failures during start_period; process-compose terminates a process after
// failure_threshold misses and skips what waits on it, so the threshold has
// to cover the start-up window as well as the retries.
_probeTiming: {
	healthcheck: _
	let _hc = healthcheck
	let _period = (_seconds & {in: _hc.interval}).out
	let _grace = (_seconds & {in: _hc.start_period, floor: 0}).out
	out: {
		period_seconds:    _period
		timeout_seconds:   (_seconds & {in: _hc.timeout}).out
		failure_threshold: _hc.retries + div(_grace + _period - 1, _period)
	}
}

// A port literal a probe names, as the host spelling when it is one of the
// target's own exposed ports.
_ownPort: {
	expose:  _
	project: string
	target:  string
	port:    string
	let _project = project
	let _target = target
	let _port = port
	let _own = [for n, e in expose if "\(e.port)" == _port {
		(_hostPort & {project: _project, target: _target, name: n, port: e}).out
	}]
	out: [if len(_own) > 0 {_own[0]}, _port][0]
}

// The host's microcheck: the checkers the http and tcp templates copy into
// images, run through bayt's checksum-pinned stubs (runtime/httpcheck.toml,
// portcheck.toml). gen_process_compose points it at the bayt it generates for.
_microcheckHost: "bayt microcheck"

_composeCondition: {started: "service_started", healthy: "service_healthy", completed: "service_completed_successfully"}
_processCondition: {started: "process_started", healthy: "process_healthy", completed: "process_completed_successfully"}

// A target's compose service, the name its peers wait on.
_serviceName: {
	project: string
	target:  string
	out:     "\(project)-\(target)"
}

// The entrypoint as a container runs it: dockerfile.do and its shell override
// the base, as they do for a cmd's RUN. No toolchain wraps it: a container's
// process starts from what its image baked in, and a runtime image carries no
// mise. An image whose process needs a wrapper says so in dockerfile.do.
_containerArgv: {
	t: _
	let _e = t.entrypoint
	out: (_argv & {
		do:       [if _e.dockerfile != _|_ if _e.dockerfile != null if _e.dockerfile.do != _|_ {_e.dockerfile.do}, _e.do][0]
		shell:    [if _e.dockerfile != _|_ if _e.dockerfile != null if _e.dockerfile.shell != _|_ {_e.dockerfile.shell}, _e.shell][0]
		activate: ""
	}).out
}

// A container keeps every canonical port, so a port's variable is its number.
_containerEnv: {
	t:     _
	files: _
	let _t = t
	let _files = files
	let _epEnv = {
		if _t.entrypoint != _|_ for k, v in _t.entrypoint.env {
			(k): (#_renderEnvValue & {target: _t, files: _files, key: k, in: v}).out
		}
	}
	out: {
		if _t.expose != _|_ for _, e in _t.expose if e.env != _|_ if _epEnv[e.env] == _|_ {
			(e.env): "\(e.port)"
		}
		_epEnv
	}
}

// A container waits only on a peer compose runs: one with a compose block.
_containerWaits: {
	t:     _
	files: _
	let _t = t
	let _files = files
	out: {
		if _t.entrypoint != _|_ for k, c in _t.entrypoint.after {
			// A compose file includes only what its target depends on.
			if !list.Contains(_t.sameProjectDeps, k) && !list.Contains(_t.sameProjectDeps, "\(k)_outs") {
				((_serviceName & {project: _t.project, target: k}).out): error("\(_t.name): waits on \(k) without depending on it; add \":\(k):outs\" to deps")
			}
			if _files[k].compose == _|_ {
				((_serviceName & {project: _t.project, target: k}).out): error("\(_t.name): waits on \(k), which has no container to wait on")
			}
			((_serviceName & {project: _t.project, target: k}).out): condition: _composeCondition[c]
		}
	}
}
