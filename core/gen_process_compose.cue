// gen_process_compose.cue — every host process (an entrypoint not opted out
// with `host: false`) as one process in .bayt/process-compose.yaml, which
// process-compose runs from the project directory: `up <n>` keeps the stack
// running, `run <n>` exits with the process. Either starts what it waits on.
package bayt

import (
	"list"
	"regexp"
	"strings"
)

#processComposeGen: W={
	#processComposeFrom
	_m: (#manifestGen & {project: W.project, depManifests: W.depManifests})
}

#processComposeFrom: G={
	project: #project
	depManifests: {[string]: _}
	// As in #taskfileFrom: "" resolves `bayt` on PATH.
	runtime: *"" | string

	_m: _

	_procs: {for n, t in G._m.files if t.entrypoint != _|_ if t.entrypoint.host {(n): t}}

	let _rt = (_runtimeDir & {runtime: G.runtime, depth: G._m._depth}).out

	// bayt's own command, as argv, from a process's working_dir: a probe runs
	// there, below the project directory.
	_baytAt: B={
		working_dir: *"" | string
		let _up = strings.Repeat("../", len([for x in strings.Split(B.working_dir, "/") if x != "" {x}]))
		out: [if G.runtime != "" {["mise", "tool-stub", "\(_up)\(_rt)/nu.toml", "\(_up)\(_rt)/bayt.nu"]}, ["bayt"]][0]
	}

	// Every host port variable in the project, which a caller sets to move the
	// stack whichever process it starts. Each must be a distinct variable, and
	// every host process's port, movable or fixed, a distinct number when
	// launched, or two would share one; containers each have their own.
	let _all = [
		for n, t in G._procs if t.expose != _|_ for p, e in t.expose {
			who: "\(n).expose.\(p)"
			port: [if e.env != _|_ {(_hostDefault & {project: G.project.name, target: n, name: p, port: e}).out}, e.port][0]
			if e.env != _|_ {var: (_portVar & {target: n, name: p}).out}
		},
	]
	let _vars = [for x in _all if x.var != _|_ {x}]
	_clashes: {
		for i, x in _vars for j, y in _vars if i < j if x.var == y.var {(x.who): error("\(x.who) and \(y.who) both map to \(x.var)")}
		for i, x in _all for j, y in _all if i < j if x.port == y.port {(x.who): error("\(x.who) and \(y.who) both default to port \(x.port)")}
	}

	// A value names a peer as compose does, by its bare alias or its service
	// name. The service name contains the alias, one alias can end another and
	// a dotted hostname can end in one, so each match is anchored on both sides;
	// anchoring consumes a neighbour, so every rewrite runs twice to reach
	// adjacent names. Its output names no alias, so the second pass changes
	// nothing else.
	_rewrites: list.FlattenN([
		for n, t in G._procs if t.expose != _|_ for p, e in t.expose
		for alias in [(_serviceName & {project: G.project.name, target: n}).out, n] {
			let _rule = {
				peer:   n
				needle: "\(alias):\(e.port)"
				from:   "(^|[^A-Za-z0-9_.-])\((_reQuote & {in: alias}).out):\(e.port)\(_portEnd)"
				to:     "${1}127.0.0.1:\(strings.Replace((_hostPort & {project: G.project.name, target: n, name: p, port: e}).out, "$", "$$", -1))${2}"
			}
			[_rule, _rule]
		},
	], 1)

	// Whether a whole value names a target, by its alias or its service name.
	_names: N={
		value:  string
		target: string
		out: N.value == N.target || N.value == (_serviceName & {project: G.project.name, target: N.target}).out
	}

	// What a probe or a value needs to spell a target's own ports.
	_self: S={
		t: _
		out: {expose: [if S.t.expose != _|_ {S.t.expose}, {}][0], project: G.project.name, target: S.t.name}
	}

	// Only a rule whose alias and port appear can match.
	_rewrite: W={
		in: string
		let _live = [for r in G._rewrites if strings.Contains(W.in, r.needle) {r}]
		_steps: [W.in, for i, r in _live {regexp.ReplaceAll(r.from, W._steps[i], r.to)}]
		out: W._steps[len(_live)]
	}

	// The host environment: the entrypoint's, peers rewritten, plus each own
	// port's variable. A key set by both must agree, or generation fails.
	_hostEnv: H={
		t: _
		let _raw = {
			H.t.entrypoint.env
			if H.t.expose != _|_ for p, e in H.t.expose if e.env != _|_ {
				(e.env): (_hostPort & {project: G.project.name, target: H.t.name, name: p, port: e}).out
			}
		}
		let _own = (G._self & {t: H.t}).out

		// A host key and its port key naming one peer and a port it exposes,
		// as PGHOST and PGPORT: the port is that peer's on the host too, moved
		// or fixed.
		let _pairs = {
			for hk, hv in _raw if regexp.Match(_hostKeys, hk) if (_portKey & {in: hk}).out != hk
			for peer, pt in G._procs if (G._names & {value: hv, target: peer}).out
			let _pk = (_portKey & {in: hk}).out
			if _raw[_pk] != _|_ if pt.expose != _|_
			for p, e in pt.expose if _raw[_pk] == "\(e.port)" {
				(_pk): {host: hk, ref: (_hostPort & {project: G.project.name, target: peer, name: p, port: e}).out}
			}
		}
		out: {
			for k, v in _raw {
				// A process names its own ports on loopback, and they move too.
				let _rewritten = (G._rewrite & {in: (_ownPortsInURL & _own & {url: v}).out}).out

				// Under a key naming a host, as DB_HOST or PGHOST, and only there, a
				// whole value naming a target is that target's address: elsewhere
				// it may as well be a user or a driver called the same.
				let _hostKey = regexp.Match(_hostKeys, k)
				let _bare = [if _hostKey for peer, pt in G._procs if (G._names & {value: _rewritten, target: peer}).out {
					name: peer
					moves: len([if pt.expose != _|_ for _, e in pt.expose if e.env != _|_ {e}]) > 0
				}]

				// A port beside it, as a DB_PORT, holds a bare number no rewrite
				// can tell from any other, so a peer whose ports move on the host
				// is named with its port, as `<peer>:<port>`.
				if len(_bare) > 0 if _bare[0].moves if len([for _, x in _pairs if x.host == k {x}]) == 0 {
					(k): error("\(H.t.name): \(k) names \(_bare[0].name) alone, whose ports move on the host; name it as \(_bare[0].name):<port>\([if (_portKey & {in: k}).out != k {", or pair it with \((_portKey & {in: k}).out) holding a port \(_bare[0].name) exposes"}, ""][0])")
				}

				// A service the host does not run has no address there at all.
				for other, ot in G._m.files if _hostKey if G._procs[other] == _|_
				if ot.expose != _|_ || ot.compose != _|_
				if (G._names & {value: _rewritten, target: other}).out {
					(k): error("\(H.t.name): \(k) names \(other), which does not run on the host")
				}
				let _v = [if _pairs[k] != _|_ {_pairs[k].ref}, if len(_bare) > 0 {"127.0.0.1"}, _rewritten][0]
				for other, _ in G._m.files if strings.Contains(_v, other) {
					if regexp.Match((_peerName & {project: G.project.name, peer: other}).out, _v) {
						(k): error("\(H.t.name): \(k) names a port of \(other) that \(other) does not expose on the host")
					}
					if regexp.Match((_peerHost & {project: G.project.name, peer: other}).out, (_noUserinfo & {in: _v}).out) {
						(k): error("\(H.t.name): \(k) names \(other) as a host the rewrite cannot place; name it as \(other):<port> with a port it exposes on the host")
					}
				}
				(k): _v
			}
		}
	}

	// A healthcheck template's check on the host: the container's, on the
	// host's spelling of each own port.
	_templateProbe: P={
		t: _
		let _h = P.t.healthcheck
		let _me = (G._self & {t: P.t}).out
		let _own = {
			port: string
			out: (_ownPort & _me & {"port": port}).out
		}
		out: {
			exec: command: [
				if _h.template == "http" {"\(_microcheckHost) httpcheck \((_ownPortsInURL & _me & {url: _h.url}).out)"},
				if _h.template == "tcp" {"\(_microcheckHost) portcheck --port \((_own & {port: "\(_h.port)"}).out)"},
				if _h.template == "postgres" {"pg_isready -h \(_h.host) -p \((_own & {port: "\(_h.port)"}).out) -d \(_h.db) -U \(_h.user)"},
				if _h.template == "redis" {"redis-cli -p \((_own & {port: "6379"}).out) ping | grep PONG"},
				"env OLLAMA_HOST=127.0.0.1:\((_own & {port: "11434"}).out) ollama list | grep -q \(_h.model)",
			][0]
			(_probeTiming & {healthcheck: _h}).out
		}
	}

	// A host command runs under the target's toolchain, probes included, except
	// microcheck, which bayt runs from its own stubs.
	_activated: A={
		activate: string
		bayt: [...string]
		probe: _
		out: {
			for k, v in A.probe if k != "exec" {(k): v}
			if A.probe.exec != _|_ {
				let _cmd = A.probe.exec.command
				exec: {
					for k, v in A.probe.exec if k != "command" {(k): v}
					command: [
						if strings.HasPrefix(_cmd, _microcheckHost) {"\(strings.Join(A.bayt, " ")) microcheck\(strings.TrimPrefix(_cmd, _microcheckHost))"},
						if len(A.activate) > 0 {"\(A.activate) \(_cmd)"},
						_cmd,
					][0]
				}
			}
		}
	}

	// Each process's readiness probe before activation, or null. A template's
	// probe and the block's own must agree, as the rest of the sugar must with
	// its projection.
	_probes: {
		for n, t in G._procs {
			let _pc = [if t["process-compose"] != _|_ {t["process-compose"]}, {}][0]
			(n): [
				if t.healthcheck.template != _|_ if _pc.readiness_probe != _|_ {(G._templateProbe & {"t": t}).out & _pc.readiness_probe},
				if t.healthcheck.template != _|_ {(G._templateProbe & {"t": t}).out},
				if _pc.readiness_probe != _|_ {_pc.readiness_probe},
				null,
			][0]
		}
	}

	// The microcheck a process's probe runs, or "": installed by a one-shot the
	// process waits on, not by its first probe inside a one-second window.
	_checker: {
		for n, p in G._probes {
			(n): [
				if p != null if p.exec != _|_ if strings.HasPrefix(p.exec.command, "\(_microcheckHost) ") {
					strings.Split(strings.TrimPrefix(p.exec.command, "\(_microcheckHost) "), " ")[0]
				},
				"",
			][0]
		}
	}

	file: {
		version: "0.5"
		// Dependents stop before what they wait on, as they started after it.
		ordered_shutdown: true
		// Host processes resolve their `activate` pins, versions no lockfile
		// lists; probes inherit the environment too.
		environment: ["MISE_LOCKED=0"]
		processes: {
			G._clashes

			// A target's build is the task a dependent reaches, run once before
			// its process starts.
			for n, t in G._procs if t.taskfile != _|_ {
				"\(n):build": entrypoint: ["task", "-t", ".bayt/Taskfile.yml", "bayt:\(n)"]
			}
			for c in list.SortStrings([for n, c in G._checker if c != "" {c}]) {
				"bayt:\(c)": entrypoint: list.Concat([(G._baytAt & {}).out, ["microcheck", c, "--help"]])
			}

			for n, t in G._procs {
				let _e = t.entrypoint
				let _pc = [if t["process-compose"] != _|_ {t["process-compose"]}, {}][0]
				let _act = [if _pc.activate != _|_ {_pc.activate}, t.activate][0]
				let _bayt = (G._baytAt & {if _pc.working_dir != _|_ {working_dir: _pc.working_dir}}).out
				if _e.windows != _|_ || _e.linux != _|_ || _e.darwin != _|_ {
					(n): error("\(n): process-compose has no OS selection; the entrypoint cannot carry windows/linux/darwin variants")
				}

				// Only `env` is rewritten for the host; a command naming a peer
				// would reach for a compose hostname there.
				for other, _ in G._m.files if strings.Contains(_e.do, other)
				if regexp.Match((_peerHost & {project: G.project.name, peer: other}).out, (_noUserinfo & {in: _e.do}).out) {
					(n): error("\(n): its command names \(other); pass the address through env")
				}
				for r in G._rewrites if strings.Contains(_e.do, r.needle) if regexp.Match(r.from, _e.do) {
					(n): error("\(n): its command names \(r.peer) by a port it exposes; pass the address through env")
				}
				for k, _ in _e.after if G._procs[k] == _|_ {
					(n): error("\(n): waits on \(k), which does not run on the host")
				}

				// process-compose waits forever for health a process has no probe
				// to report.
				for k, c in _e.after if c == "healthy" if G._procs[k] != _|_ if G._probes[k] == null {
					(n): error("\(n): waits for \(k) to be healthy, but \(k) has no readiness probe")
				}
				(n): {
					// process-compose expands `${VAR}` at load, from the launcher's
					// environment, and reads `$$` as `$`. Every `$` doubled reaches the
					// process's own shell as written, as it does in a container.
					entrypoint: [for a in (_argv & {do: _e.do, shell: _e.shell, activate: _act}).out {strings.Replace(a, "$", "$$", -1)}]
					let _env = (G._hostEnv & {"t": t}).out
					if len(_env) > 0 {
						environment: [for k in list.SortStrings([for k, _ in _env {k}]) {"\(k)=\(_env[k])"}]
					}
					let _waits = {
						for k, c in _e.after {(k): condition: _processCondition[c]}
						if t.taskfile != _|_ {"\(n):build": condition: "process_completed_successfully"}
						if G._checker[n] != "" {"bayt:\(G._checker[n])": condition: "process_completed_successfully"}
					}
					if len(_waits) > 0 {depends_on: _waits}

					// A process skipped because what it waits on died otherwise
					// counts as success, and the stack's check would pass.
					availability: {
						exit_on_skipped: true
						if _pc.availability != _|_ {_pc.availability}
					}
					if G._probes[n] != null {
						readiness_probe: (G._activated & {activate: _act, bayt: _bayt, probe: G._probes[n]}).out
					}
					if _pc.liveness_probe != _|_ {
						liveness_probe: (G._activated & {activate: _act, bayt: _bayt, probe: _pc.liveness_probe}).out
					}
					if _pc.shutdown != _|_ {shutdown: _pc.shutdown}
					if _pc.working_dir != _|_ {working_dir: _pc.working_dir}
				}
			}
		}
	}
}
