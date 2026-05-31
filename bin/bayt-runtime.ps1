$ErrorActionPreference = "Stop"
$Dir = Split-Path -Parent $MyInvocation.MyCommand.Path
& (Join-Path $Dir ".." "runtime" "nu.toml") (Join-Path $Dir ".." "runtime" "bayt-runtime.nu") @args
exit $LASTEXITCODE
