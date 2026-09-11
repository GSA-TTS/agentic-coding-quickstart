# acq.ps1 - Windows launcher for acq through Git Bash.
#
# acq remains a Bash program in the Windows preview path. This launcher finds Git
# for Windows' bash.exe and delegates to the repository-local Bash entry point.

$ErrorActionPreference = "Stop"

function Find-GitBash {
    $fromPath = Get-Command bash.exe -ErrorAction SilentlyContinue
    if ($null -ne $fromPath) {
        return $fromPath.Source
    }

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

    throw "Git Bash was not found. Install Git for Windows, then re-run acq."
}

function Convert-ToGitBashPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $drive = [System.IO.Path]::GetPathRoot($fullPath).TrimEnd('\', ':').ToLowerInvariant()
    $rest = $fullPath.Substring(3).Replace('\', '/')
    return "/$drive/$rest"
}

$repoRoot = Split-Path -Parent $PSCommandPath
$acqScript = Join-Path $repoRoot "acq"

if (-not (Test-Path -LiteralPath $acqScript -PathType Leaf)) {
    throw "Expected acq Bash entry point at '$acqScript'."
}

$bash = Find-GitBash
$bashAcq = Convert-ToGitBashPath -Path $acqScript

$env:MSYS2_ARG_CONV_EXCL = "*"
& $bash --noprofile --norc $bashAcq @args
exit $LASTEXITCODE
