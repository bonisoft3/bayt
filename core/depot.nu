# repo-of — a compose `image:` minus its tag. A tag cannot contain '/', so only
# a ':' after the last '/' separates one, and neither counts inside a `${...}`.
export def repo-of [ref: string]: nothing -> string {
	mut depth = 0
	mut cut = -1
	mut i = 0
	for c in ($ref | split chars) {
		if $c == "{" { $depth = $depth + 1 }
		if $c == "}" { $depth = $depth - 1 }
		if $depth == 0 and $c == "/" { $cut = -1 }
		if $depth == 0 and $c == ":" and $cut == -1 { $cut = $i }
		$i = $i + 1
	}
	if $cut < 0 { $ref } else { $ref | str substring ..<$cut }
}

# Resolve aliases from Bake's evaluated targets, including user-authored overlays.
export def depot-targets [plan: record, group: string = "depot-build"]: nothing -> list<record> {
	let names = ($plan.group | get $group | get targets)
	$names | each { |name|
		let target = ($plan.target | get $name)
		let repo = (repo-of ($target.tags | first))
		if ($repo | is-empty) { error make {msg: $"bayt: ($name) has no image repository"} }
		{
			target: $name
			repo: $repo
			manifest: ($target.context | path join ".bayt" $"bayt.($target.target).json" | path expand)
		}
	}
}
