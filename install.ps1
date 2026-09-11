# install.ps1 - Windows preview installer for acq.
#
# This installer keeps Windows support deliberately scoped: it installs the acq
# release zip and uses Git Bash to run the existing Bash implementation. It does
# not elevate PowerShell, enable Windows features, or reboot the machine.

[CmdletBinding()]
param(
    [string]$Version = "3.1.0", # x-release-please-version
    [string]$InstallDir = "",
    [string]$PackageUrl = "",
    [string]$Sha256 = "",
    [string]$MsbPackageId = $env:ACQ_MSB_WINGET_ID,
    [switch]$NoMsb,
    [switch]$NoPath,
    [switch]$DryRun,
    [switch]$Yes,
    [switch]$Help
)

$ErrorActionPreference = "Stop"
$ReleaseBaseUrl = "https://github.com/GSA-TTS/agentic-coding-quickstart/releases/download/v$Version"
$PackageName = "acq-windows-x64.zip"

function Get-DefaultInstallDir {
    if ($env:LOCALAPPDATA) {
        return (Join-Path $env:LOCALAPPDATA "Programs\acq")
    }

    if ($Help -or $DryRun) {
        return (Join-Path ([System.IO.Path]::GetTempPath()) "acq-preview-install")
    }

    throw "LOCALAPPDATA is not set. install.ps1 must run on Windows unless -DryRun is used."
}

function Show-Usage {
    @"
install.ps1 - install acq for Windows preview hosts

Usage:
  irm https://github.com/GSA-TTS/agentic-coding-quickstart/releases/download/v$Version/install.ps1 | iex
  .\install.ps1 [-Version <version>] [-InstallDir <path>] [-NoMsb] [-DryRun] [-Yes]

Options:
  -Version <version>      Release version to install. Default: $Version
  -InstallDir <path>      User-writable install location. Default: $InstallDir
  -PackageUrl <url>       Override the acq zip URL. Requires -Sha256 for verification.
  -Sha256 <hash>          Expected SHA-256 for -PackageUrl.
  -MsbPackageId <id>      Optional WinGet package ID for msb when available.
  -NoMsb                 Do not install the msb runtime.
  -NoPath                Do not offer to add acq to the user PATH.
  -DryRun                Print actions without making changes.
  -Yes                   Assume yes for consent prompts.
  -Help                  Show this help.

The installer does not elevate, enable Windows features, or reboot. Windows
Hypervisor Platform must already be enabled.
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

    if ($Yes) {
        return $true
    }

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

function Assert-WindowsHost {
    if ($DryRun) {
        Write-Host "  [dry-run] check host is Windows"
        return
    }

    if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
        throw "install.ps1 is only supported on Windows preview hosts."
    }
}

function Test-WhpEnabled {
    $dism = Get-Command dism.exe -ErrorAction SilentlyContinue
    if ($null -ne $dism) {
        $output = & $dism.Source /online /Get-FeatureInfo /FeatureName:HypervisorPlatform 2>&1
        if ($LASTEXITCODE -eq 0) {
            $text = $output -join "`n"
            if ($text -match 'State\s*:\s*Enabled') { return $true }
            if ($text -match 'State\s*:\s*Disabled') { return $false }
        }
    }

    $featureCmd = Get-Command Get-WindowsOptionalFeature -ErrorAction SilentlyContinue
    if ($null -ne $featureCmd) {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -ErrorAction Stop
        return $feature.State -eq "Enabled"
    }

    throw "Could not determine whether Windows Hypervisor Platform is enabled."
}

function Assert-WhpEnabled {
    if ($DryRun) {
        Write-Host "  [dry-run] check Windows Hypervisor Platform is enabled"
        return
    }

    if (-not (Test-WhpEnabled)) {
        throw "Windows Hypervisor Platform is not enabled. Enable it through your device or enterprise administrator, reboot if required, then re-run this installer."
    }
}

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

    return $null
}

function Install-WinGetPackage {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($null -eq $winget) {
        throw "WinGet is required to install $Name automatically, but winget.exe was not found."
    }

    Invoke-InstallCommand "winget install --id $Id --exact" {
        & $winget.Source install --id $Id --exact --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -ne 0) {
            throw "WinGet failed to install $Name ($Id)."
        }
    }
}

function Ensure-GitBash {
    $bash = Find-GitBash
    if ($null -ne $bash) {
        Write-Host "  Git Bash: $bash"
        return
    }

    Write-Step "Git Bash is not installed"
    if ($DryRun) {
        Write-Host "  [dry-run] would prompt to install Git for Windows with WinGet"
        return
    }

    if (-not (Confirm-Action "Install Git for Windows with WinGet now?")) {
        throw "Git Bash is required. Install Git for Windows, then re-run this installer."
    }

    Install-WinGetPackage -Id "Git.Git" -Name "Git for Windows"
    if (-not $DryRun -and $null -eq (Find-GitBash)) {
        throw "Git for Windows installed, but Git Bash was not found on PATH or in standard install locations. Open a new PowerShell window and re-run this installer."
    }
}

function Ensure-Msb {
    if ($NoMsb) {
        Write-Warn "Skipping msb install because -NoMsb was set."
        return
    }

    $msb = Get-Command msb.exe -ErrorAction SilentlyContinue
    if ($null -ne $msb) {
        Write-Host "  msb: $($msb.Source)"
        return
    }

    Write-Step "msb is not installed"
    if ($DryRun) {
        if ($MsbPackageId) {
            Write-Host "  [dry-run] would prompt to install msb with WinGet package '$MsbPackageId'"
        }
        else {
            Write-Host "  [dry-run] would prompt to install msb with the upstream Windows installer"
        }
        return
    }

    if ($MsbPackageId) {
        if (-not (Confirm-Action "Install msb with WinGet package '$MsbPackageId' now?")) {
            throw "msb is required. Install msb, then re-run this installer."
        }
        Install-WinGetPackage -Id $MsbPackageId -Name "msb"
        if (-not $DryRun -and $null -eq (Get-Command msb.exe -ErrorAction SilentlyContinue)) {
            throw "msb installed, but msb.exe was not found on PATH. Open a new PowerShell window and re-run this installer."
        }
        return
    }

    if (-not (Confirm-Action "Install msb with the upstream Windows installer now?")) {
        throw "msb is required. Install it with 'irm https://install.microsandbox.dev/windows | iex', then re-run this installer."
    }

    Invoke-InstallCommand "irm https://install.microsandbox.dev/windows | iex" {
        Invoke-Expression (Invoke-RestMethod "https://install.microsandbox.dev/windows")
        if ($null -eq (Get-Command msb.exe -ErrorAction SilentlyContinue)) {
            throw "msb installer completed, but msb.exe was not found on PATH. Open a new PowerShell window and re-run this installer."
        }
    }
}

function Get-ExpectedPackageHash {
    if ($Sha256) {
        return $Sha256.ToLowerInvariant()
    }

    if ($PackageUrl) {
        throw "-PackageUrl requires -Sha256 so the downloaded zip can be verified."
    }

    $sumsUrl = "$ReleaseBaseUrl/SHA256SUMS"
    $sums = Invoke-RestMethod $sumsUrl
    foreach ($line in ($sums -split "`n")) {
        if ($line -match "^([0-9a-fA-F]{64})\s+\*?$([regex]::Escape($PackageName))$") {
            return $Matches[1].ToLowerInvariant()
        }
    }

    throw "SHA256SUMS did not contain an entry for $PackageName."
}

function Install-AcqZip {
    $url = if ($PackageUrl) { $PackageUrl } else { "$ReleaseBaseUrl/$PackageName" }
    $tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("acq-install-" + [guid]::NewGuid().ToString("N"))
    $zipPath = Join-Path $tmpRoot $PackageName
    $extractDir = Join-Path $tmpRoot "extract"

    try {
        Invoke-InstallCommand "download $url" {
            New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null
            Invoke-WebRequest -Uri $url -OutFile $zipPath
        }

        if (-not $DryRun) {
            $expected = Get-ExpectedPackageHash
            $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath).Hash.ToLowerInvariant()
            if ($actual -ne $expected) {
                throw "SHA-256 verification failed for $PackageName. Expected $expected, got $actual."
            }
            Write-Host "  verified $PackageName SHA-256: $actual"
        }

        Invoke-InstallCommand "expand $zipPath to $InstallDir" {
            Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force
            $sourceDir = $extractDir
            if (-not (Test-Path -LiteralPath (Join-Path $sourceDir "acq") -PathType Leaf)) {
                $children = Get-ChildItem -LiteralPath $extractDir -Directory
                if ($children.Count -eq 1 -and (Test-Path -LiteralPath (Join-Path $children[0].FullName "acq") -PathType Leaf)) {
                    $sourceDir = $children[0].FullName
                }
            }
            if (-not (Test-Path -LiteralPath (Join-Path $sourceDir "acq") -PathType Leaf)) {
                throw "Downloaded package does not contain the acq entry point."
            }

            New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
            foreach ($item in @("acq", "acq.backends", "acq.cmd", "acq.ps1", "install.ps1", "README.md", "LICENSE", "package.json")) {
                $src = Join-Path $sourceDir $item
                if (Test-Path -LiteralPath $src) {
                    $dst = Join-Path $InstallDir $item
                    if (Test-Path -LiteralPath $dst) {
                        Remove-Item -LiteralPath $dst -Recurse -Force
                    }
                    Copy-Item -LiteralPath $src -Destination $dst -Recurse
                }
            }
        }
    }
    finally {
        if (-not $DryRun -and (Test-Path -LiteralPath $tmpRoot)) {
            Remove-Item -LiteralPath $tmpRoot -Recurse -Force
        }
    }
}

function Ensure-Path {
    if ($NoPath) {
        Write-Warn "Not changing PATH because -NoPath was set."
        Write-Host "Add this directory to your user PATH to run acq from anywhere: $InstallDir"
        return
    }

    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $parts = @()
    if ($userPath) {
        $parts = $userPath -split ';' | Where-Object { $_ }
    }

    if ($parts -contains $InstallDir) {
        Write-Host "  $InstallDir is already on your user PATH."
        return
    }

    if (-not (Confirm-Action "Add $InstallDir to your user PATH?")) {
        Write-Warn "Not changing PATH. Add this directory to your user PATH to run acq from anywhere: $InstallDir"
        return
    }

    Invoke-InstallCommand "add $InstallDir to the user PATH" {
        $newPath = if ($userPath) { "$userPath;$InstallDir" } else { $InstallDir }
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
        $env:Path = "$env:Path;$InstallDir"
    }
}

if (-not $InstallDir) {
    $InstallDir = Get-DefaultInstallDir
}

if ($Help) {
    Show-Usage
    exit 0
}

Write-Step "Checking Windows preview prerequisites"
Assert-WindowsHost
Assert-WhpEnabled
Ensure-GitBash
Ensure-Msb

Write-Step "Installing acq"
Install-AcqZip
Ensure-Path

Write-Step "Done"
Write-Host "Try it now: acq version"
Write-Host "Next, start a sandbox: acq run opencode C:\path\to\your\project"
