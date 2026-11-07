// gen_process_compose.cue — every host process (an entrypoint not opted out
// with `host: false`) as one process in .bayt/process-compose.yaml, which
// process-compose runs from the project directory: `up <n>` keeps the stack
// running, `run <n>` exits with the process. Either starts what it waits on.
package bayt

import (
	"list"
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
	let _all = (_hostProcPorts & {files: G._m.files, identity: G.project._portIdentity}).out
	let _vars = [for x in _all if x.var != _|_ {x}]
	_clashes: {
		for i, x in _vars for j, y in _vars if i < j if x.var == y.var {(x.who): error("\(x.who) and \(y.who) both map to \(x.var)")}
		for i, x in _all for j, y in _all if i < j if x.port == y.port {(x.who): error("\(x.who) and \(y.who) both default to port \(x.port)")}
	}

	let _pubs = [
		for n, t in G._m.files if t.expose != _|_ for p, e in t.expose if e.publish != _|_ {
			let _var = (_publishVar & {target: n, name: p, port: e}).out
			let _port = (_hostDefault & {project: G.project._portIdentity, target: n, name: p, port: e}).out
			var:      _var
			spelling: "${\(_var):-\(_port)}"
		},
	]
	_published: {for i, x in _pubs if len([for j, y in _pubs if j < i if y.var == x.var {y}]) == 0 {(x.var): x.spelling}}
	let _pubVars = [for v, _ in _published {v}]
	_withPublished: F={
		in: string
		_steps: [F.in, for i, v in _pubVars {strings.Replace(F._steps[i], "${\(v)}", _published[v], -1)}]
		out: F._steps[len(_pubVars)]
	}

	// What a probe needs to spell a target's own ports.
	_self: S={
		t: _
		out: {expose: [if S.t.expose != _|_ {S.t.expose}, {}][0], project: G.project._portIdentity, target: S.t.name}
	}

	// The host environment: the entrypoint's, overridden per key by
	// process-compose.env, plus each own port's variable.
	_hostEnv: H={
		t: _
		let _pcEnv = [if H.t["process-compose"] != _|_ if H.t["process-compose"].env != _|_ {H.t["process-compose"].env}, {}][0]
		let _merged = {
			for k, v in H.t.entrypoint.env if _pcEnv[k] == _|_ {(k): v}
			for k, v in _pcEnv {(k): v}
		}
		let _epEnv = {
			for k, v in _merged {
				(k): (G._withPublished & {
					in: (#_renderEnvValue & {
						target:   H.t
						files:    G._m.files
						procs:    G._procs
						identity: G.project._portIdentity
						key:      k
						in:       v
					}).out
				}).out
			}
		}
		out: {
			if H.t.expose != _|_ for p, e in H.t.expose if e.env != _|_ if _epEnv[e.env] == _|_ {
				(e.env): (_hostPort & {project: G.project._portIdentity, target: H.t.name, name: p, port: e}).out
			}
			_epEnv
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
		// Read through its template, so a check embedded from a bayt.json
		// written before a field was declared takes that field's default.
		let _http = healthcheck.#http & _h
		let _authHeader = [if _h.template == "http" if _http.authorization != null {
			let val = _http.authorization
			let auth = [if strings.Contains(val, " ") {val}, "Bearer \(val)"][0]
			"Authorization: \(auth)"
		}]
		let _allHeaders = list.Concat([_authHeader, [if _h.template == "http" for h in _http.headers {h}]])
		let _headerFlags = strings.Join([for h in _allHeaders {"-H \"\(h)\""}], " ")
		let _httpArgs = [if len(_headerFlags) > 0 {"\(_headerFlags) "}, ""][0]
		let _httpURL = [
			if _h.template == "http" if _http.port != _|_ {
				"\(_http.scheme)://\(_http.host):\((_own & {port: "\(_http.port)"}).out)\(_http.path)"
			},
			if _h.template == "http" {_http.url},
			"",
		][0]
		out: {
			exec: command: [
				if _h.template == "http" {"\(_microcheckHost) httpcheck \(_httpArgs)\(_httpURL)"},
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

	// Each process's readiness probe before activation, or null. The
	// process-compose block's own readiness_probe overrides the template's
	// per field.
	_probes: {
		for n, t in G._procs {
			let _pc = [if t["process-compose"] != _|_ {t["process-compose"]}, {}][0]
			let _base = [
				if t.healthcheck.template != _|_ {(G._templateProbe & {"t": t}).out},
				null,
			][0]
			(n): [
				if _base != null && _pc.readiness_probe != _|_ {
					for k, v in _base if _pc.readiness_probe[k] == _|_ {(k): v}
					for k, v in _pc.readiness_probe if k != "exec" {(k): v}
					if _pc.readiness_probe.exec != _|_ {
						exec: {
							if _base.exec != _|_ {
								for k, v in _base.exec if _pc.readiness_probe.exec[k] == _|_ {(k): v}
							}
							for k, v in _pc.readiness_probe.exec {(k): v}
						}
					}
				},
				if _base != null {_base},
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
					// environment, and reads `$$` as `$` and `\\` as `\`. Every `$`
					// doubled reaches the process's own shell as written, and every `\`
					// doubled reaches its argv and environment intact.
					entrypoint: [for a in (_argv & {do: _e.do, shell: _e.shell, activate: _act}).out {strings.Replace(strings.Replace(a, "\\", "\\\\", -1), "$", "$$", -1)}]
					let _env = (G._hostEnv & {"t": t}).out
					if len(_env) > 0 {
						environment: [for k in list.SortStrings([for k, _ in _env {k}]) {"\(k)=\(strings.Replace(_env[k], "\\", "\\\\", -1))"}]
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
