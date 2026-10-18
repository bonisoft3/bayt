@echo off
REM The PATH entry of bayt on Windows, which resolves a bare `bayt` only
REM through a PATHEXT extension: what a checkout's mise.local.toml and
REM `mise install github:bonisoft3/bayt` put in front of `bayt cache run`.
pwsh -NoProfile -File "%~dp0bayt.ps1" %*
exit /b %ERRORLEVEL%
