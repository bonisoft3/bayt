$ErrorActionPreference = "Stop"
$Dir = Split-Path -Parent $MyInvocation.MyCommand.Path
& (Join-Path $Dir "nu.toml") (Join-Path $Dir "bayt.nu") @args
exit $LASTEXITCODE
