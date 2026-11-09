# acq.ps1 - Windows launcher for acq through Git Bash.
#
# acq remains a Bash program in the Windows preview path. This launcher finds Git
# for Windows' bash.exe and delegates to the repository-local Bash entry point.

$ErrorActionPreference = "Stop"

# Programs started by acq never resolve from the current directory (normally the
# untrusted workspace): cmd.exe, CreateProcess and Python's shutil.which honour
# this for every child process.
$env:NoDefaultCurrentDirectoryInExePath = "1"

# ACQ_IMPL runtime switch — the coexistence seam (ADR-0047m). On Windows the Bash
# `acq` dispatches via Git Bash; here the Python implementation runs natively:
# the managed runtime `py-acq\runtime\python.exe -m acq_py`, else `python` on
# PATH. Unset / `bash` keeps the existing Git Bash path below; any other value
# fails closed (exit 2). argv and the exit status are forwarded verbatim.
$acqImpl = $env:ACQ_IMPL
if ($acqImpl -and $acqImpl -ne "bash") {
    if ($acqImpl -ne "python") {
        [Console]::Error.WriteLine("acq: unsupported ACQ_IMPL '$acqImpl' (expected 'bash' or 'python')")
        exit 2
    }
    # True when $Exe runs isolated and is Python 3.12+. Windows PowerShell 5.1
    # turns a native program's stderr into a terminating error under
    # $ErrorActionPreference = "Stop" (the Store alias stub writes to stderr),
    # so the probe runs with a local "Continue" preference.
    function Test-AcqPython {
        param([Parameter(Mandatory = $true)][string]$Exe)
        $ErrorActionPreference = "Continue"
        # Clear any exit code left by the caller's previous command (acq.ps1 may
        # run inside the user's own session), so a candidate that cannot start
        # is never accepted on a stale 0.
        $global:LASTEXITCODE = $null
        try {
            & $Exe -I -c "import sys; sys.exit(0 if sys.version_info >= (3, 12) else 1)" 2>$null | Out-Null
        }
        catch {
            return $false
        }
        return ($LASTEXITCODE -eq 0)
    }
    $acqImplRepoRoot = Split-Path -Parent $PSCommandPath
    $runtimePy = Join-Path $acqImplRepoRoot "py-acq\runtime\python.exe"
    # An ACQ_RUNTIME override must be a drive-rooted or UNC path: a relative
    # value would be resolved against the current directory (the workspace).
    if ($env:ACQ_RUNTIME -and -not ($env:ACQ_RUNTIME -match '^[A-Za-z]:[\\/]' -or $env:ACQ_RUNTIME.StartsWith('\\'))) {
        [Console]::Error.WriteLine("acq: ACQ_RUNTIME must be an absolute path to python.exe, got '$($env:ACQ_RUNTIME)'")
        exit 1
    }
    if ($env:ACQ_RUNTIME -and (Test-Path -LiteralPath $env:ACQ_RUNTIME -PathType Leaf)) {
        $acqPythonExe = $env:ACQ_RUNTIME
    }
    elseif (Test-Path -LiteralPath $runtimePy -PathType Leaf) {
        $acqPythonExe = $runtimePy
    }
    else {
        # Search PATH ourselves, like acq_py.hostexec: consider python.exe only in
        # drive-rooted or UNC entries, because a relative entry (even ".")
        # resolves against the current directory, which is normally the
        # workspace. Take the first candidate that passes the isolated 3.12+
        # probe: that skips the Microsoft Store App Execution Alias stub (it
        # exits 9009) and older interpreters, but keeps a real Store-installed
        # Python, which is reached through the same kind of alias. The path is
        # built as a string because Join-Path throws on a missing drive letter.
        $pyCmd = $null
        foreach ($entry in ($env:Path -split ';')) {
            $dir = $entry.Trim().Trim('"')
            if (-not ($dir -match '^[A-Za-z]:[\\/]' -or $dir.StartsWith('\\'))) { continue }
            $candidate = $dir.TrimEnd('\', '/') + '\python.exe'
            # Re-check after trimming: an entry of just "\\" would become the
            # drive-relative "\python.exe".
            if (-not ($candidate -match '^[A-Za-z]:[\\/]' -or $candidate.StartsWith('\\'))) { continue }
            if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
            if (Test-AcqPython -Exe $candidate) { $pyCmd = $candidate; break }
        }
        if ($null -eq $pyCmd) {
            [Console]::Error.WriteLine("acq: ACQ_IMPL=python but no Python 3.12+ was found on PATH. Install acq from a release (it bundles its own runtime), install Python 3.12+ from python.org with 'Add python.exe to PATH' checked, or set ACQ_RUNTIME to the full path of python.exe.")
            exit 1
        }
        $acqPythonExe = $pyCmd
    }
    $srcDir = Join-Path $acqImplRepoRoot "py-acq\src"
    # acq is stdlib-only, so the user's PYTHONPATH is never inherited: an empty
    # or relative entry would put the current directory back on sys.path.
    if (Test-Path -LiteralPath $srcDir -PathType Container) {
        $env:PYTHONPATH = $srcDir
    }
    else {
        Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue
    }
    # -P keeps `python -m` from putting the current directory first on sys.path
    # (a workspace json.py would otherwise run on the host); interpreters older
    # than the required 3.12 are refused because they may not honour -P. The
    # probe runs isolated and imports only the builtin sys module.
    if (-not (Test-AcqPython -Exe $acqPythonExe)) {
        [Console]::Error.WriteLine("acq: ACQ_IMPL=python needs Python 3.12 or newer; $acqPythonExe is not")
        exit 1
    }
    & $acqPythonExe -P -m acq_py @args
    exit $LASTEXITCODE
}

function Test-IsWslShim {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not $env:SystemRoot) {
        return $false
    }

    $full = [System.IO.Path]::GetFullPath($Path)
    foreach ($name in @("System32\bash.exe", "SysWOW64\bash.exe")) {
        if ($full -eq [System.IO.Path]::GetFullPath((Join-Path $env:SystemRoot $name))) {
            return $true
        }
    }

    return $false
}

function Find-GitBash {
    # Prefer Git for Windows' known install locations. A PATH lookup for bash.exe
    # often resolves to C:\Windows\System32\bash.exe - the WSL interop shim, not
    # Git Bash - so only fall back to PATH once those locations are exhausted, and
    # never accept the shim (it would run acq inside a WSL distro, where the
    # Windows msb.exe and this checkout's paths do not exist).
    $candidates = @(
        "$env:ProgramFiles\Git\bin\bash.exe",
        "$env:ProgramFiles\Git\usr\bin\bash.exe",
        "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
        "${env:ProgramFiles(x86)}\Git\usr\bin\bash.exe",
        "$env:LocalAppData\Programs\Git\bin\bash.exe",
        "$env:LocalAppData\Programs\Git\usr\bin\bash.exe"
    )

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return $candidate
        }
    }

    $fromPath = Get-Command bash.exe -ErrorAction SilentlyContinue
    if ($null -ne $fromPath -and -not (Test-IsWslShim -Path $fromPath.Source)) {
        return $fromPath.Source
    }

    throw "Git Bash was not found. Install Git for Windows, then re-run acq."
}

function Get-UncPrefix {
    $slash = [string][char]92
    return $slash + $slash
}

function Test-IsUncPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    return $Path.StartsWith((Get-UncPrefix))
}

function Convert-ToGitBashPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if ($fullPath -match '^([A-Za-z]):[\\/](.*)$') {
        $drive = $Matches[1].ToLowerInvariant()
        $rest = $Matches[2].Replace('\', '/')
        return "/$drive/$rest"
    }

    if (Test-IsUncPath -Path $fullPath) {
        return '//' + $fullPath.TrimStart([char]92).Replace('\', '/')
    }

    return $fullPath.Replace('\', '/')
}

function Convert-ArgumentForGitBash {
    param([Parameter(Mandatory = $true)][string]$Argument)

    if ($Argument -match '^[A-Za-z]:[\\/]' -or (Test-IsUncPath -Path $Argument)) {
        return Convert-ToGitBashPath -Path $Argument
    }

    if ($Argument -match '^([^:]+):([A-Za-z]:[\\/].*)$') {
        return $Matches[1] + ':' + (Convert-ToGitBashPath -Path $Matches[2])
    }

    if ($Argument -match '^([^:]+):(.*)$' -and (Test-IsUncPath -Path $Matches[2])) {
        return $Matches[1] + ':' + (Convert-ToGitBashPath -Path $Matches[2])
    }

    return $Argument
}

$repoRoot = Split-Path -Parent $PSCommandPath
$acqScript = Join-Path $repoRoot "acq"

if (-not (Test-Path -LiteralPath $acqScript -PathType Leaf)) {
    throw "Expected acq Bash entry point at '$acqScript'."
}

$bash = Find-GitBash
$bashAcq = Convert-ToGitBashPath -Path $acqScript
# LOCALAPPDATA counts only when fully qualified (drive-rooted or UNC): a relative
# value would point acq at a directory under the current one.
$validatorData = $null
if ($env:LOCALAPPDATA -match '^([A-Za-z]:[\\/]|[\\/]{2}[^\\/])') {
    $validatorData = Join-Path $env:LOCALAPPDATA "acq\provider-input-validator"
}
if ($validatorData -and (Test-Path -LiteralPath $validatorData -PathType Container)) {
    $env:ACQ_PROVIDER_INPUT_DATA_DIR = (Convert-ToGitBashPath -Path $validatorData)
}
$convertedArgs = @($args | ForEach-Object { Convert-ArgumentForGitBash -Argument $_ })

& $bash --noprofile --norc $bashAcq @convertedArgs
exit $LASTEXITCODE
