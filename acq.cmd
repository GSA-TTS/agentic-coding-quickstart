@echo off
setlocal

rem acq.cmd is a thin delegate to acq.ps1, which resolves the ACQ_IMPL runtime
rem switch (coexistence seam, ADR-0046m): unset/`bash` runs the Bash `acq` via
rem Git Bash, `python` runs the Python implementation natively, and any other
rem value fails closed (exit 2). ACQ_IMPL is inherited through the environment.

set "ACQ_PS1=%~dp0acq.ps1"
if not exist "%ACQ_PS1%" (
  echo acq: expected PowerShell launcher at "%ACQ_PS1%" 1>&2
  exit /b 1
)

powershell.exe -NoLogo -NoProfile -File "%ACQ_PS1%" %*
exit /b %ERRORLEVEL%
