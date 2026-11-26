@echo off
setlocal
set "ACQ_IMPL=python"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -File "%~dp0acq.ps1" %*
exit /b %errorlevel%
