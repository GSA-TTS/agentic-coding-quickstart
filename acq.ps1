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
    if ($fullPath -match '^([A-Za-z]):[\\/](.*)$') {
        $drive = $Matches[1].ToLowerInvariant()
        $rest = $Matches[2].Replace('\', '/')
        return "/$drive/$rest"
    }

    if ($fullPath.StartsWith('\\')) {
        return '//' + $fullPath.TrimStart('\').Replace('\', '/')
    }

    return $fullPath.Replace('\', '/')
}

function Convert-ArgumentForGitBash {
    param([Parameter(Mandatory = $true)][string]$Argument)

    if ($Argument -match '^[A-Za-z]:[\\/]' -or $Argument -match '^\\\\[^\\]+\\[^\\]+') {
        return Convert-ToGitBashPath -Path $Argument
    }

    if ($Argument -match '^([^:]+):([A-Za-z]:[\\/].*)$') {
        return $Matches[1] + ':' + (Convert-ToGitBashPath -Path $Matches[2])
    }

    if ($Argument -match '^([^:]+):(\\\\[^\\]+\\[^\\]+.*)$') {
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
$convertedArgs = @($args | ForEach-Object { Convert-ArgumentForGitBash -Argument $_ })

& $bash --noprofile --norc $bashAcq @convertedArgs
exit $LASTEXITCODE
