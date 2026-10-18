$ErrorActionPreference = "Stop"
$Dir = Split-Path -Parent $MyInvocation.MyCommand.Path
# The nu stub is bayt's, not the project's: a consumer's locked mise has no
# lock entry for it.
$env:MISE_LOCKED = "0"
# Windows reaches the stub through mise: a .toml runs by its shebang only
# where there is one to read.
& mise tool-stub (Join-Path $Dir ".." "runtime" "nu.toml") (Join-Path $Dir ".." "bayt.nu") @args
exit $LASTEXITCODE
