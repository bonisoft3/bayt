package sayt

gate: G={
	targets: {[string]: _}
	files: "say.yaml": say: {
		for verb, target in G.targets if verb == "generate" || verb == "build" || verb == "lint" || verb == "test"
		if target != null if target.taskfile != _|_ {
			let refresh = [if verb != "generate" if G.targets.generate != _|_ if G.targets.generate != null if G.targets.generate.taskfile != _|_ {" --generate"}, ""][0]
			let command = "bayt-task \(verb)\(refresh)"
			(verb): rulemap: {
				if verb == "lint" || verb == "generate" {"auto-cue": null}
				if verb == "generate" {"auto-bayt": null, "auto-gomplate": null}
				builtin: {stop: true, cmds: [{use: "./bayt-task.nu", do: command}]}
			}
		}
	}
}
