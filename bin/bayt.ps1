$ErrorActionPreference = "Stop"
$Dir = Split-Path -Parent $MyInvocation.MyCommand.Path
# The runtime stubs' lock sits beside them; mise reads it only from a trusted
# config.
$Runtime = Join-Path (Split-Path -Parent $Dir) "runtime"
$env:MISE_TRUSTED_CONFIG_PATHS = if ($env:MISE_TRUSTED_CONFIG_PATHS) { "$Runtime;$env:MISE_TRUSTED_CONFIG_PATHS" } else { $Runtime }
# Windows reaches the stub through mise: a .toml runs by its shebang only
# where there is one to read.
& mise tool-stub (Join-Path $Dir ".." "runtime" "nu.toml") (Join-Path $Dir ".." "bayt.nu") @args
exit $LASTEXITCODE
