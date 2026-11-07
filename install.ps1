# install.ps1 - user-scoped installer for the acq v1 Python replacement (ADR-0042m).
#
# Downloads the checksum-verified Windows release archive (acq-windows-x64.zip —
# the enumerated offline asset set: readable source + bundled Python.org embedded
# runtime + exact-hash wheelhouse + launcher scripts + SHA256SUMS + provenance),
# extracts it under LOCALAPPDATA, and offers to put it on the user PATH.
#
# Guarantees (ADR-0042m, ADR-0038m):
#   * dry-run       -DryRun            prints actions, makes no writes, no network
#   * consent       PATH edits are consent-gated (default NO; -Yes skips)
#   * checksum      the zip is verified against SHA256SUMS; mismatch fails closed
#   * user-scope    installs only under LOCALAPPDATA; never elevates
#   * update        re-running against a pinned, checksum-verified release is the
#                   only update path — there is no `acq update` command
#
# Windows x64 only (ADR-0042m platform matrix). Windows ARM64 is out of scope.

[CmdletBinding()]
param(
    [string]$Version = "0.1.0", # x-release-please-version
    [string]$InstallDir = "",
    [string]$Source = "",
    [string]$Channel = "python",
    [switch]$DryRun,
    [switch]$Yes,
    [switch]$Help
)

$ErrorActionPreference = "Stop"
$ReleaseBaseUrl = "https://github.com/GSA-TTS/agentic-coding-quickstart/releases/download/v$Version"
$PackageName = "acq-windows-x64.zip"
$SumsName = "SHA256SUMS"
$RuntimeRelative = "py-acq\runtime\python.exe"
$LauncherRelative = "acq.cmd"

function Show-Usage {
    @"
install.ps1 - install acq (agentic-coding-quickstart, Python v1)

Downloads and verifies the Windows release archive, installs it under
LOCALAPPDATA, and offers to add it to your user PATH. Update by re-running this
installer against a pinned release.

Usage:
  irm <release-url>/install.ps1 | iex
  .\install.ps1 [-InstallDir <path>] [-Source <url|dir>] [-Version <ver>]
                [-Channel <name>] [-DryRun] [-Yes] [-Help]

Options:
  -InstallDir <path>   User-writable install location. Default: %LOCALAPPDATA%\Programs\acq
  -Source <url|dir>    Release source. A URL fetches SHA256SUMS + the zip; a local
                       directory (the offline asset set) is read in place.
  -Version <ver>       Release version to install. Default: $Version
  -Channel <name>      Update channel to install (default: python; the only
                       channel supported on this fork).
  -DryRun              Print actions without making changes.
  -Yes                 Assume yes for the PATH prompt (non-interactive/CI).
  -Help                Show this help.

This installer never elevates, enables Windows features, or reboots.
"@
}

function Write-Step {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "==> $Message"
}

function Write-Warn {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Warning $Message
}

function Confirm-Action {
    param([Parameter(Mandatory = $true)][string]$Prompt)

    if ($Yes) { return $true }
    # A non-interactive run never infers consent (ADR-0038m section 50): fail closed.
    if ([Console]::IsInputRedirected) { return $false }
    $answer = Read-Host "$Prompt [y/N]"
    return $answer -match '^(y|yes)$'
}

function Invoke-InstallCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][scriptblock]$Command
    )

    if ($DryRun) {
        Write-Host "  [dry-run] $Description"
        return
    }
    & $Command
}

function Get-DefaultInstallDir {
    if ($env:LOCALAPPDATA) {
        return (Join-Path $env:LOCALAPPDATA "Programs\acq")
    }
    throw "LOCALAPPDATA is not set. install.ps1 requires a user profile to install under."
}

function Resolve-Source {
    # Empty -> default release URL. A local directory -> the offline asset set.
    if (-not $Source) {
        return @{ Url = "$ReleaseBaseUrl"; IsUrl = $true }
    }
    if ($Source -match '^https?://') {
        return @{ Url = $Source; IsUrl = $true }
    }
    return @{ Url = $Source; IsUrl = $false }
}

function Get-ExpectedHash {
    param(
        [Parameter(Mandatory = $true)][string]$SumsPath
    )

    foreach ($line in (Get-Content -LiteralPath $SumsPath)) {
        if ($line -match "^([0-9a-fA-F]{64})\s+\*?$([regex]::Escape($PackageName))\s*$") {
            return $Matches[1].ToLowerInvariant()
        }
    }
    throw "SHA256SUMS has no entry for $PackageName; refusing to install an unverified archive."
}

function Install-AcqZip {
    $resolved = Resolve-Source

    Write-Step "Installing acq $Version"
    Write-Host "  package:     $PackageName"
    Write-Host "  channel:     $Channel"
    Write-Host "  source:      $($resolved.Url)"
    Write-Host "  install dir: $InstallDir"

    if ($DryRun) {
        Write-Host "  [dry-run] download $($resolved.Url)/$SumsName and $($resolved.Url)/$PackageName"
        Write-Host "  [dry-run] verify $PackageName SHA-256 against $SumsName"
        Write-Host "  [dry-run] expand $PackageName into $InstallDir"
        Write-Host "  [dry-run] verify the bundled runtime and launcher are present"
        Write-Host "  [dry-run] offer to add $InstallDir to your user PATH"
        return
    }

    $tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("acq-install-" + [guid]::NewGuid().ToString("N"))
    try {
        New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null
        $zipPath = Join-Path $tmpRoot $PackageName
        $sumsPath = Join-Path $tmpRoot $SumsName

        if ($resolved.IsUrl) {
            Invoke-WebRequest -Uri "$($resolved.Url)/$SumsName" -OutFile $sumsPath
            Invoke-WebRequest -Uri "$($resolved.Url)/$PackageName" -OutFile $zipPath
        }
        else {
            if (-not (Test-Path -LiteralPath (Join-Path $resolved.Url $SumsName) -PathType Leaf)) {
                throw "offline asset set at $($resolved.Url) has no $SumsName."
            }
            if (-not (Test-Path -LiteralPath (Join-Path $resolved.Url $PackageName) -PathType Leaf)) {
                throw "offline asset set at $($resolved.Url) has no $PackageName."
            }
            Copy-Item -LiteralPath (Join-Path $resolved.Url $SumsName) -Destination $sumsPath
            Copy-Item -LiteralPath (Join-Path $resolved.Url $PackageName) -Destination $zipPath
        }

        $expected = Get-ExpectedHash -SumsPath $sumsPath
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath).Hash.ToLowerInvariant()
        if ($actual -ne $expected) {
            throw "SHA-256 verification failed for $PackageName. Expected $expected, got $actual."
        }
        Write-Host "  verified $PackageName SHA-256: $actual"

        $extractDir = Join-Path $tmpRoot "extract"
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force

        # The zip may wrap its contents in a single top-level directory.
        $sourceDir = $extractDir
        if (-not (Test-Path -LiteralPath (Join-Path $sourceDir $LauncherRelative))) {
            $children = @(Get-ChildItem -LiteralPath $extractDir -Directory)
            if ($children.Count -eq 1 -and (Test-Path -LiteralPath (Join-Path $children[0].FullName $LauncherRelative))) {
                $sourceDir = $children[0].FullName
            }
        }
        if (-not (Test-Path -LiteralPath (Join-Path $sourceDir $LauncherRelative) -PathType Leaf)) {
            throw "release archive is missing the '$LauncherRelative' launcher."
        }
        if (-not (Test-Path -LiteralPath (Join-Path $sourceDir $RuntimeRelative) -PathType Leaf)) {
            throw "release archive is missing the bundled runtime ($RuntimeRelative)."
        }

        # Publish: replace an existing install in place (the update path).
        $parent = Split-Path -Parent $InstallDir
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
        if (Test-Path -LiteralPath $InstallDir) {
            Remove-Item -LiteralPath $InstallDir -Recurse -Force
        }
        Move-Item -LiteralPath $sourceDir -Destination $InstallDir
    }
    finally {
        if (Test-Path -LiteralPath $tmpRoot) {
            Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Add-UserPath {
    param([Parameter(Mandatory = $true)][string]$Directory)

    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $parts = @()
    if ($userPath) {
        $parts = $userPath -split ';' | Where-Object { $_ }
    }

    if ($parts -contains $Directory) {
        Write-Host "  $Directory is already on your user PATH."
        return
    }

    if ($DryRun) {
        Write-Host "  [dry-run] add $Directory to your user PATH"
        return
    }

    if (-not (Confirm-Action "Add $Directory to your user PATH?")) {
        Write-Warn "Not changing PATH. Add this directory to your user PATH yourself: $Directory"
        return
    }

    $newPath = if ($userPath) { "$userPath;$Directory" } else { $Directory }
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    $env:Path = "$env:Path;$Directory"
    Write-Host "  Added $Directory to your user PATH."
}

if ($Help) {
    Show-Usage
    exit 0
}

# The -Channel flag is the update-channel seam (ADR-0046m). On this fork the only
# channel is `python` (the default); any other value fails closed.
if ($Channel -ne "python") {
    [Console]::Error.WriteLine("unknown channel '$Channel' (only 'python' is supported on this fork)")
    exit 2
}

# -Help and -DryRun are read-only/planning paths and must not require a user
# profile. Resolve the install dir lazily: -DryRun falls back to a placeholder
# when LOCALAPPDATA is absent, and only the real install path requires it.
if ($DryRun) {
    if (-not $InstallDir) {
        $InstallDir = if ($env:LOCALAPPDATA) { Get-DefaultInstallDir } else { "<LOCALAPPDATA>\Programs\acq" }
    }
    Write-Host "  [dry-run] check host is Windows"
}
else {
    if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
        throw "install.ps1 is only supported on Windows hosts."
    }
    if (-not $InstallDir) {
        $InstallDir = Get-DefaultInstallDir
    }
}

Write-Step "Installing acq"
Install-AcqZip
Add-UserPath -Directory $InstallDir

Write-Step "Done"
Write-Host "Try it now: acq version"
