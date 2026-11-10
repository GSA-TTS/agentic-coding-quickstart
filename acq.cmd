@echo off
setlocal

rem acq.cmd is a thin delegate to acq.ps1, which resolves the ACQ_IMPL runtime
rem switch (coexistence seam, ADR-0047m; Windows default, ADR-0048m): unset or
rem `python` runs the Python implementation natively, `bash` runs the Bash `acq`
rem via Git Bash, and any other value fails closed (exit 2). ACQ_IMPL is
rem inherited through the environment.

set "ACQ_PS1=%~dp0acq.ps1"
if not exist "%ACQ_PS1%" (
  echo acq: expected PowerShell launcher at "%ACQ_PS1%" 1>&2
  exit /b 1
)

rem Launch Windows PowerShell by its full path. cmd.exe looks for a bare command
rem in the current directory before PATH, and acq usually runs from inside the
rem workspace it sandboxes, so a bare `powershell.exe` would run a copy planted
rem there on the host. An undefined SystemRoot would leave a drive-rooted path,
rem so it is required. NoDefaultCurrentDirectoryInExePath makes cmd.exe,
rem CreateProcess and Python's shutil.which skip the current directory for every
rem process acq starts, as defence in depth.
if not defined SystemRoot (
  echo acq: SystemRoot is not set; cannot locate Windows PowerShell 1>&2
  exit /b 1
)
set "NoDefaultCurrentDirectoryInExePath=1"
set "ACQ_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%ACQ_POWERSHELL%" (
  echo acq: Windows PowerShell not found at "%ACQ_POWERSHELL%" 1>&2
  exit /b 1
)

rem acq.ps1 recognises exactly this argument shape (-NoLogo -NoProfile -File
rem then its own path) and then starts Python with an exact command line built
rem from its own argv, because Windows PowerShell's call operator would drop
rem empty arguments and mangle embedded quotes. Keep the two in step.
"%ACQ_POWERSHELL%" -NoLogo -NoProfile -File "%ACQ_PS1%" %*
exit /b %ERRORLEVEL%
