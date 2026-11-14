$ErrorActionPreference = "Stop"
$Dir = Split-Path -Parent $MyInvocation.MyCommand.Path
# The runtime stubs' lock sits beside mise.toml one level up; mise reads it
# only from a trusted config.
$Root = Split-Path -Parent $Dir
$env:MISE_TRUSTED_CONFIG_PATHS = if ($env:MISE_TRUSTED_CONFIG_PATHS) { "$Root;$env:MISE_TRUSTED_CONFIG_PATHS" } else { $Root }
# Windows reaches the stub through mise: a .toml runs by its shebang only
# where there is one to read.
& mise tool-stub (Join-Path $Dir ".." "runtime" "nu.toml") (Join-Path $Dir ".." "bayt.nu") @args
exit $LASTEXITCODE
