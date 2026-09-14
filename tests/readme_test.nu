use std/assert

const root = (path self | path dirname | path dirname)

def main [] {
  let example = open --raw ($root | path join README.md)
    | parse -r '(?s)```cue\r?\n(?<source>.*?)```'
    | first | get source
  let result = do { cd $root; $example | ^cue export - -e project --out json } | complete
  assert equal $result.exit_code 0 $result.stderr
  let project = $result.stdout | from json
  assert equal $project.dir "services/my-service"
  assert ("build" in ($project.targets | columns))
  assert equal $project.targets.release.bake.image "gcr.io/proj/my-service"
}
