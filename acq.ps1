# acq.ps1 - Windows launcher for acq through Git Bash.
#
# acq remains a Bash program in the Windows preview path. This launcher finds Git
# for Windows' bash.exe and delegates to the repository-local Bash entry point.

$ErrorActionPreference = "Stop"

# ACQ_IMPL runtime switch — the coexistence seam (ADR-0046m). On Windows the Bash
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
    $acqImplRepoRoot = Split-Path -Parent $PSCommandPath
    $runtimePy = Join-Path $acqImplRepoRoot "py-acq\runtime\python.exe"
    if ($env:ACQ_RUNTIME -and (Test-Path -LiteralPath $env:ACQ_RUNTIME -PathType Leaf)) {
        $acqPythonExe = $env:ACQ_RUNTIME
    }
    elseif (Test-Path -LiteralPath $runtimePy -PathType Leaf) {
        $acqPythonExe = $runtimePy
    }
    else {
        $pyCmd = Get-Command python -ErrorAction SilentlyContinue
        if ($null -eq $pyCmd) {
            [Console]::Error.WriteLine("acq: ACQ_IMPL=python but no Python interpreter was found")
            exit 1
        }
        $acqPythonExe = $pyCmd.Source
    }
    $srcDir = Join-Path $acqImplRepoRoot "py-acq\src"
    if (Test-Path -LiteralPath $srcDir -PathType Container) {
        $env:PYTHONPATH = $srcDir + $(if ($env:PYTHONPATH) { ";$env:PYTHONPATH" } else { "" })
    }
    & $acqPythonExe -m acq_py @args
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
$validatorData = Join-Path $env:LOCALAPPDATA "acq\provider-input-validator"
if (Test-Path -LiteralPath $validatorData -PathType Container) {
    $env:ACQ_PROVIDER_INPUT_DATA_DIR = (Convert-ToGitBashPath -Path $validatorData)
}
$convertedArgs = @($args | ForEach-Object { Convert-ArgumentForGitBash -Argument $_ })

& $bash --noprofile --norc $bashAcq @convertedArgs
exit $LASTEXITCODE
