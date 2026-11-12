package sayt

gate: {
	targets: {[string]: _}
	let _targets = targets
	files: "say.yaml": say: {
		for verb, target in _targets if verb == "generate" || verb == "build" || verb == "lint" || verb == "test"
		if target != null if target.taskfile != _|_ {
			let refresh = [if verb != "generate" if _targets.generate != _|_ if _targets.generate != null if _targets.generate.taskfile != _|_ {" --generate"}, ""][0]
			let command = "bayt-task \(verb)\(refresh)"
			(verb): rulemap: {
				if verb == "lint" || verb == "generate" {"auto-cue": null}
				if verb == "generate" {"auto-bayt": null, "auto-gomplate": null}
				builtin: {stop: true, cmds: [{use: "./bayt-task.nu", do: command}]}
			}
		}
	}
}
