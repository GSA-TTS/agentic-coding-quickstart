@echo off
setlocal

set "ACQ_PS1=%~dp0acq.ps1"
if not exist "%ACQ_PS1%" (
  echo acq: expected PowerShell launcher at "%ACQ_PS1%" 1>&2
  exit /b 1
)

powershell.exe -NoLogo -NoProfile -File "%ACQ_PS1%" %*
exit /b %ERRORLEVEL%
