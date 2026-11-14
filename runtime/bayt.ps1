$ErrorActionPreference = "Stop"
$Dir = Split-Path -Parent $MyInvocation.MyCommand.Path
# The stubs' lock sits beside them; mise reads it only from a trusted config.
$env:MISE_TRUSTED_CONFIG_PATHS = if ($env:MISE_TRUSTED_CONFIG_PATHS) { "$Dir;$env:MISE_TRUSTED_CONFIG_PATHS" } else { $Dir }
& (Join-Path $Dir "nu.toml") (Join-Path $Dir "bayt.nu") @args
exit $LASTEXITCODE
