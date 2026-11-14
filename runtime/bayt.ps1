$ErrorActionPreference = "Stop"
$Dir = Split-Path -Parent $MyInvocation.MyCommand.Path
# The stubs' lock sits beside mise.toml one level up in the source tree, and
# beside them where the runtime image's root is copied; the parent covers both.
$Parent = Split-Path -Parent $Dir
$env:MISE_TRUSTED_CONFIG_PATHS = if ($env:MISE_TRUSTED_CONFIG_PATHS) { "$Parent;$env:MISE_TRUSTED_CONFIG_PATHS" } else { $Parent }
& (Join-Path $Dir "nu.toml") (Join-Path $Dir "bayt.nu") @args
exit $LASTEXITCODE
