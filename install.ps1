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
    [string]$Version = "4.2.1", # x-release-please-version
    [string]$InstallDir = "",
    [string]$Source = "",
    [string]$Channel = $(if ($null -ne $env:ACQ_INSTALL_CHANNEL) { $env:ACQ_INSTALL_CHANNEL } else { 'bash' }),
    [string]$PackageUrl = "",
    [string]$MsbPackageId = $env:ACQ_MSB_WINGET_ID,
    [switch]$NoMsb,
    [switch]$NoPath,
    [switch]$RemovePreview,
    [string]$Sha256 = "",
    [switch]$NoAttestation,
    [switch]$NoPrereqCheck,
    [switch]$DryRun,
    [switch]$Yes,
    [switch]$Help
)


function Invoke-StableBashInstall {
# install.ps1 - Windows preview installer for acq.
#
# This installer keeps Windows support deliberately scoped: it installs the acq
# release zip and uses Git Bash to run the existing Bash implementation. It does
# not elevate PowerShell, enable Windows features, or reboot the machine.

[CmdletBinding()]
param(
    [string]$Version = "4.2.1", # x-release-please-version
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

# msb version policy. Keep in lockstep with install.sh and acq.backends/msb.sh:
# a drift here means Windows accepts an msb the rest of acq refuses.
#
# 0.7.0 through 0.7.2 migrate 0.6.x sandbox state one-way, into a form the 0.6.x
# line cannot read. 0.7.3 carries the upstream compatibility fix; acq installs a
# newer fixed release by default. See ADR-0032.
$MsbMinVersion = "0.6.9"
$MsbPinnedVersion = "0.7.7"
$MsbRollbackVersion = "0.6.18"
$MsbBlockedVersionMin = "0.7.0"
$MsbBlockedVersionMax = "0.7.2"
$MsbFixedVersion = "0.7.3"

$MsbReleaseBaseUrl = "https://github.com/superradcompany/microsandbox/releases/download"

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

msb versions: acq accepts $MsbMinVersion up to (not including) $MsbBlockedVersionMin, and
$MsbFixedVersion or newer. msb $MsbBlockedVersionMin-$MsbBlockedVersionMax migrate 0.6.x sandbox state one-way and are
refused. When msb is missing, this installs the pinned $MsbPinnedVersion from its
checksum-verified release bundle rather than the upstream one-line installer,
which always resolves to the newest release.
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
    # The WHP optional-feature flag is not a reliable readiness signal: it is not
    # readable without elevation, and on hosts where the Windows hypervisor is
    # already running (WSL2 / VirtualMachine Platform, VBS, or a virtualized guest)
    # the WHP user-mode API works even when the feature still reports Disabled.
    # Probe the API the way msb does - WHvCreatePartition needs no elevation and
    # reflects whether WHP is actually usable. Returns $true / $false when a
    # verdict is possible, and $null when the state stays undetermined.
    try {
        if (-not ("Whp.Capability" -as [type])) {
            Add-Type -Namespace Whp -Name Capability -MemberDefinition @'
[DllImport("WinHvPlatform.dll")]
public static extern int WHvCreatePartition(out System.IntPtr Partition, uint Access);
[DllImport("WinHvPlatform.dll")]
public static extern int WHvDeletePartition(System.IntPtr Partition);
'@
        }
        $partition = [System.IntPtr]::Zero
        if ([Whp.Capability]::WHvCreatePartition([ref]$partition, 0) -eq 0) {
            [void][Whp.Capability]::WHvDeletePartition($partition)
            return $true
        }
        return $false
    }
    catch {
        # The API probe could not load; fall back to the feature state where the
        # optional-feature check is readable at all (an elevated shell).
    }

    try {
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
    }
    catch {
        # Not elevated, so the feature state is unreadable; leave WHP undetermined.
    }

    return $null
}

function Assert-WhpEnabled {
    if ($DryRun) {
        Write-Host "  [dry-run] check Windows Hypervisor Platform is enabled"
        return
    }

    $result = Test-WhpEnabled
    if ($null -eq $result) {
        Write-Warn "Could not verify Windows Hypervisor Platform directly. 'msb doctor' will confirm host readiness before the first sandbox starts."
        return
    }

    if (-not $result) {
        throw "Windows Hypervisor Platform is not enabled. Enable it through your device or enterprise administrator, reboot if required, then re-run this installer."
    }
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

function Compare-MsbVersion {
    # Returns -1/0/1 comparing two dotted versions by numeric component. Hand-rolled
    # rather than [version] so a build suffix (0.6.18-rc1) cannot throw a parse error
    # mid-install; the numeric prefix of each component is what matters here.
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )

    $l = $Left.Split(".")
    $r = $Right.Split(".")
    for ($i = 0; $i -lt 3; $i++) {
        $lp = 0; $rp = 0
        if ($i -lt $l.Count -and $l[$i] -match '^(\d+)') { $lp = [int]$Matches[1] }
        if ($i -lt $r.Count -and $r[$i] -match '^(\d+)') { $rp = [int]$Matches[1] }
        if ($lp -gt $rp) { return 1 }
        if ($lp -lt $rp) { return -1 }
    }
    return 0
}

function Test-MsbVersionBlocked {
    param([Parameter(Mandatory = $true)][string]$MsbVersion)

    return ((Compare-MsbVersion -Left $MsbVersion -Right $MsbBlockedVersionMin) -ge 0) -and
           ((Compare-MsbVersion -Left $MsbVersion -Right $MsbBlockedVersionMax) -le 0)
}

function Test-MsbVersionFinal {
    param([Parameter(Mandatory = $true)][string]$MsbVersion)

    return -not ($MsbVersion -match '[-+]')
}

function Get-MsbVersion {
    param([Parameter(Mandatory = $true)][string]$MsbPath)

    try {
        $output = & $MsbPath --version 2>&1
    }
    catch {
        return ""
    }
    if ($LASTEXITCODE -ne 0) {
        return ""
    }

    $match = [regex]::Match(($output -join " "), '\d+\.\d+(\.\d+)?([+-]\S*)?')
    if ($match.Success) {
        return $match.Value
    }
    return ""
}

function Get-MsbInstallRoot {
    # Mirrors msb's own resolution: a non-empty MSB_HOME is used verbatim (no
    # .microsandbox suffix appended), otherwise %USERPROFILE%\.microsandbox.
    if (-not [string]::IsNullOrWhiteSpace($env:MSB_HOME)) {
        return [System.IO.Path]::GetFullPath($env:MSB_HOME)
    }
    if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        return (Join-Path ([System.IO.Path]::GetTempPath()) ".microsandbox")
    }
    return [System.IO.Path]::GetFullPath((Join-Path $env:USERPROFILE ".microsandbox"))
}

function Get-MsbBundleName {
    $arch = $env:PROCESSOR_ARCHITECTURE
    if ([string]::IsNullOrWhiteSpace($arch)) { $arch = "AMD64" }
    switch -Regex ($arch.ToUpperInvariant()) {
        "^(ARM64|AARCH64)$" { return "microsandbox-windows-aarch64.zip" }
        "^(AMD64|X64|X86_64)$" { return "microsandbox-windows-x86_64.zip" }
        default { return "" }
    }
}

function Install-MsbPinned {
    # Install an exact msb from its release bundle, verified against that release's
    # published checksums.sha256.
    #
    # This deliberately does NOT call upstream's Windows installer. That script
    # resolves the version from releases/latest, and while it does honor an
    # MSB_INSTALL_VERSION override, driving it would mean piping a remote script
    # into Invoke-Expression and trusting it to respect an environment variable we
    # cannot verify from here. The bundle is two files (msb.exe, libkrunfw.dll), so
    # placing them directly is both simpler and checkable.
    param([Parameter(Mandatory = $true)][string]$MsbVersion)

    $bundle = Get-MsbBundleName
    if (-not $bundle) {
        throw "No msb bundle is published for this Windows architecture ($env:PROCESSOR_ARCHITECTURE). Install msb $MsbVersion manually, then re-run this installer."
    }

    $baseUrl = "$MsbReleaseBaseUrl/v$MsbVersion"
    $installRoot = Get-MsbInstallRoot
    $binDir = Join-Path $installRoot "bin"
    $libDir = Join-Path $installRoot "lib"

    Write-Host "  Installing msb $MsbVersion from $baseUrl/$bundle"
    Write-Host "  (verified against that release's checksums.sha256)"

    if ($DryRun) {
        Write-Host "  [dry-run] download $baseUrl/$bundle and checksums.sha256"
        Write-Host "  [dry-run] verify SHA-256, expand, install msb.exe and libkrunfw.dll into $installRoot"
        return
    }

    $tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("acq-msb-" + [guid]::NewGuid().ToString("N"))
    try {
        New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null
        $zipPath = Join-Path $tmpRoot $bundle
        $sumsPath = Join-Path $tmpRoot "checksums.sha256"

        Invoke-WebRequest -Uri "$baseUrl/$bundle" -OutFile $zipPath
        Invoke-WebRequest -Uri "$baseUrl/checksums.sha256" -OutFile $sumsPath

        $expected = ""
        foreach ($line in (Get-Content -LiteralPath $sumsPath)) {
            if ($line -match "^([0-9a-fA-F]{64})\s+\*?$([regex]::Escape($bundle))\s*$") {
                $expected = $Matches[1].ToLowerInvariant()
                break
            }
        }
        if (-not $expected) {
            throw "checksums.sha256 for msb $MsbVersion has no entry for $bundle."
        }

        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath).Hash.ToLowerInvariant()
        if ($actual -ne $expected) {
            throw "SHA-256 verification failed for $bundle. Expected $expected, got $actual."
        }
        Write-Host "  verified $bundle SHA-256: $actual"

        $extractDir = Join-Path $tmpRoot "extract"
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force

        $msbSource = Join-Path $extractDir "msb.exe"
        $libSource = Join-Path $extractDir "libkrunfw.dll"
        if (-not (Test-Path -LiteralPath $msbSource -PathType Leaf)) {
            throw "release bundle is missing msb.exe"
        }
        if (-not (Test-Path -LiteralPath $libSource -PathType Leaf)) {
            throw "release bundle is missing libkrunfw.dll"
        }

        New-Item -ItemType Directory -Force -Path $binDir | Out-Null
        New-Item -ItemType Directory -Force -Path $libDir | Out-Null

        # Windows cannot overwrite a running image. Fail with a clear instruction
        # rather than a sharing violation from the middle of a copy.
        foreach ($target in @((Join-Path $binDir "msb.exe"), (Join-Path $binDir "microsandbox.exe"))) {
            if (Test-Path -LiteralPath $target -PathType Leaf) {
                try {
                    $stream = [System.IO.File]::Open($target, "Open", "ReadWrite", "None")
                    $stream.Close()
                }
                catch {
                    throw "$target is in use. Stop running sandboxes ('msb ls', then 'msb stop <name>'), close other msb processes, and re-run this installer."
                }
            }
        }

        Copy-Item -LiteralPath $msbSource -Destination (Join-Path $binDir "msb.exe") -Force
        Copy-Item -LiteralPath $msbSource -Destination (Join-Path $binDir "microsandbox.exe") -Force
        Copy-Item -LiteralPath $libSource -Destination (Join-Path $libDir "libkrunfw.dll") -Force

        Write-Host "  Installed msb $MsbVersion to $(Join-Path $binDir 'msb.exe')"
        Add-UserPath -Directory $binDir
    }
    finally {
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Assert-MsbSupported {
    # Verify the active msb after any install or repair. Fails closed: an msb this
    # installer cannot vouch for is worse than none, because acq will refuse it
    # later with a less obvious message.
    param([Parameter(Mandatory = $true)][string]$Context)

    if ($DryRun) { return }

    $msb = Get-Command msb.exe -ErrorAction SilentlyContinue
    if ($null -eq $msb) {
        throw "$Context, but msb.exe was not found on PATH. Open a new PowerShell window and re-run this installer."
    }

    $found = Get-MsbVersion -MsbPath $msb.Source
    if ((-not $found) -or (-not (Test-MsbVersionFinal -MsbVersion $found))) {
        throw "$Context, but msb.exe at $($msb.Source) did not report a supported final version."
    }
    if ((Compare-MsbVersion -Left $found -Right $MsbMinVersion) -lt 0) {
        throw "$Context, but the active msb is $found at $($msb.Source), older than the required $MsbMinVersion."
    }
    if (Test-MsbVersionBlocked -MsbVersion $found) {
        throw "$Context, but the active msb is $found at $($msb.Source), which acq refuses (msb $MsbBlockedVersionMin-$MsbBlockedVersionMax migrate 0.6.x sandbox state one-way). Another msb may be earlier on PATH."
    }

    Write-Host "  Active msb is $found ($($msb.Source))."
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
        Write-Host "  acq accepts msb $MsbMinVersion up to (not including) $MsbBlockedVersionMin, and $MsbFixedVersion or newer."
        Write-Host "  Note: 'irm https://install.microsandbox.dev/windows | iex' installs whatever"
        Write-Host "  release is newest; set MSB_INSTALL_VERSION=v$MsbPinnedVersion to pin it."
        return
    }

    $msb = Get-Command msb.exe -ErrorAction SilentlyContinue
    if ($null -ne $msb) {
        $found = Get-MsbVersion -MsbPath $msb.Source

        if ((-not $found) -or (-not (Test-MsbVersionFinal -MsbVersion $found))) {
            Write-Step "The active msb version is not a supported final release"
            Write-Warn "Found msb at $($msb.Source), but its version output was not a supported final release."
            if (-not (Confirm-Action "Install msb $MsbPinnedVersion now?")) {
                throw "acq needs an msb final release it can verify. Install msb $MsbPinnedVersion, then re-run this installer."
            }
            Install-MsbPinned -MsbVersion $MsbPinnedVersion
            Assert-MsbSupported -Context "msb $MsbPinnedVersion was installed"
            return
        }

        if ((Compare-MsbVersion -Left $found -Right $MsbMinVersion) -lt 0) {
            Write-Step "The active msb version is too old"
            Write-Warn "Found msb $found at $($msb.Source). acq requires msb $MsbMinVersion or newer."
            if (-not (Confirm-Action "Install msb $MsbPinnedVersion now?")) {
                throw "acq requires msb $MsbMinVersion or newer. Install msb $MsbPinnedVersion, then re-run this installer."
            }
            Install-MsbPinned -MsbVersion $MsbPinnedVersion
            Assert-MsbSupported -Context "msb $MsbPinnedVersion was installed"
            return
        }

        if (Test-MsbVersionBlocked -MsbVersion $found) {
            # A blocked msb may ALREADY have migrated the local sandbox catalog
            # one-way. Swapping the binary does not undo that, so this installer
            # does not try: the forward move to the fixed release is the one action
            # that is safe regardless of whether the catalog was migrated, since
            # the fixed line reads both old and migrated catalogs.
            Write-Step "The active msb version is blocked"
            Write-Warn "Found msb $found at $($msb.Source)."
            Write-Warn "acq refuses msb $MsbBlockedVersionMin-$MsbBlockedVersionMax because those releases migrate 0.6.x sandbox state one-way, into a form the 0.6.x line cannot read."
            Write-Host "  Moving forward to msb $MsbFixedVersion fixes this without rolling anything back: it"
            Write-Host "  reads sandbox state this msb already migrated, so no state is rewritten."
            Write-Host "  'msb self update' targets the newest release; acq re-checks that it lands on $MsbFixedVersion or newer."

            if (-not (Confirm-Action "Run 'msb self update' to move to msb $MsbFixedVersion now?")) {
                throw "acq refuses msb $found. Run 'msb self update' (or install msb $MsbPinnedVersion), then re-run this installer. If you roll back instead, run 'msb self downgrade $MsbRollbackVersion' with THIS msb first - an older msb cannot roll back these migrations, and a failed attempt blocks later catalog-opening msb commands."
            }

            Invoke-InstallCommand "msb self update" {
                & $msb.Source self update
                if ($LASTEXITCODE -ne 0) {
                    throw "'msb self update' did not complete. Its output above is authoritative."
                }
            }
            # Verify rather than assume: 'self update' targets whatever is newest,
            # and acq must still reject unsupported results.
            Assert-MsbSupported -Context "'msb self update' completed"
            return
        }

        Write-Host "  msb: $($msb.Source) (v$found)"
        return
    }

    Write-Step "msb is not installed"
    if ($DryRun) {
        if ($MsbPackageId) {
            Write-Host "  [dry-run] would prompt to install msb with WinGet package '$MsbPackageId'"
        }
        else {
            Write-Host "  [dry-run] would prompt to install pinned msb $MsbPinnedVersion from its verified release bundle"
        }
        return
    }

    if ($MsbPackageId) {
        if (-not (Confirm-Action "Install msb with WinGet package '$MsbPackageId' now?")) {
            throw "msb is required. Install msb, then re-run this installer."
        }
        Install-WinGetPackage -Id $MsbPackageId -Name "msb"
        # A WinGet package version is outside our control, so check it like any
        # other: an unsupported version here fails now, with a clear reason.
        Assert-MsbSupported -Context "WinGet installed msb"
        return
    }

    if (-not (Confirm-Action "Install msb $MsbPinnedVersion now?")) {
        throw "msb is required. Install msb $MsbPinnedVersion, then re-run this installer."
    }

    Install-MsbPinned -MsbVersion $MsbPinnedVersion
    Assert-MsbSupported -Context "msb $MsbPinnedVersion was installed"
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
            foreach ($item in @("acq", "acq.backends", "acq.cmd", "acq.ps1", "install.ps1", "README.md", "LICENSE", "package.json", "scripts")) {
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

function Install-ProviderValidatorRuntime {
    # The release ZIP is verified before this runs. The nested runtime still has
    # its own manifest so extraction cannot publish a corrupted embedded Python.
    if ($DryRun) {
        Write-Host "  [dry-run] verify and atomically install the embedded provider validator runtime"
        return
    }

    $runtimeArchive = Join-Path $InstallDir "scripts\provider-input-validator-runtime-windows-x86_64.zip"
    $runtimeManifest = Join-Path $InstallDir "scripts\provider-input-validator-runtime-windows-x86_64.sha256"
    if (-not (Test-Path -LiteralPath $runtimeArchive -PathType Leaf) -or -not (Test-Path -LiteralPath $runtimeManifest -PathType Leaf)) {
        throw "The installed acq release lacks the embedded provider validator runtime. Reinstall an official release."
    }
    $expected = ((Get-Content -LiteralPath $runtimeManifest -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
    if ($expected -notmatch '^[0-9a-f]{64}$') { throw "Invalid embedded provider validator checksum manifest." }
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $runtimeArchive).Hash.ToLowerInvariant()
    if ($actual -ne $expected) { throw "Embedded provider validator SHA-256 verification failed. Expected $expected, got $actual." }

    $dataRoot = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA "acq\provider-input-validator" } else { throw "LOCALAPPDATA is required for the provider validator runtime." }
    $target = Join-Path $dataRoot "provider-input-validator.current"
    $stage = Join-Path $dataRoot (".provider-input-validator.stage-" + [guid]::NewGuid().ToString("N"))
    $backup = Join-Path $dataRoot (".provider-input-validator.previous-" + [guid]::NewGuid().ToString("N"))
    try {
        New-Item -ItemType Directory -Force -Path $dataRoot | Out-Null
        Expand-Archive -LiteralPath $runtimeArchive -DestinationPath $stage -Force
        $python = Join-Path $stage "python.exe"
        if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw "Embedded provider validator runtime is missing python.exe." }
        & $python -c "import jsonschema, yaml; assert jsonschema.__version__ == '4.26.0'; assert yaml.__version__ == '6.0.3'"
        if ($LASTEXITCODE -ne 0) { throw "Embedded provider validator dependency verification failed." }
        if (Test-Path -LiteralPath $target) { Move-Item -LiteralPath $target -Destination $backup }
        try {
            Move-Item -LiteralPath $stage -Destination $target
            if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Recurse -Force }
        }
        catch {
            if (Test-Path -LiteralPath $backup) { Move-Item -LiteralPath $backup -Destination $target }
            throw
        }
    }
    finally {
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Add-UserPath {
    # Offer to put a directory on the user PATH. Shared by the acq install dir and
    # the msb bin dir. Never changes PATH without asking, and honors -NoPath.
    param([Parameter(Mandatory = $true)][string]$Directory)

    if ($NoPath) {
        Write-Warn "Not changing PATH because -NoPath was set."
        Write-Host "  Add this directory to your user PATH: $Directory"
        return
    }

    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $parts = @()
    if ($userPath) {
        $parts = $userPath -split ';' | Where-Object { $_ }
    }

    if ($parts -contains $Directory) {
        Write-Host "  $Directory is already on your user PATH."
        return
    }

    if (-not (Confirm-Action "Add $Directory to your user PATH?")) {
        Write-Warn "Not changing PATH. Add this directory to your user PATH yourself: $Directory"
        return
    }

    Invoke-InstallCommand "add $Directory to the user PATH" {
        $newPath = if ($userPath) { "$userPath;$Directory" } else { $Directory }
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
        $env:Path = "$env:Path;$Directory"
    }
}

function Ensure-Path {
    Add-UserPath -Directory $InstallDir
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
Install-ProviderValidatorRuntime
Ensure-Path

Write-Step "Done"
Write-Host "Try it now: acq version"
Write-Host "Next, start a sandbox: acq run opencode C:\path\to\your\project"

}
$ErrorActionPreference = "Stop"

if ($Channel -cne 'bash' -and $Channel -cne 'python') {
    [Console]::Error.WriteLine("unknown channel '$Channel'"); exit 2
}
if ($Channel -ceq 'bash') {
    $stableParams = @{}
    foreach ($key in $PSBoundParameters.Keys) {
        if ($key -ne 'Channel') { $stableParams[$key] = $PSBoundParameters[$key] }
    }
    Invoke-StableBashInstall @stableParams
    exit $LASTEXITCODE
}
$ReleaseBaseUrl = "https://github.com/GSA-TTS/agentic-coding-quickstart/releases/download/v$Version"
$PackageName = "acq-windows-x64.zip"
$SumsName = "SHA256SUMS"
$ProvenanceName = "provenance.json"
$RuntimeRelative = "py-acq\runtime\python.exe"
$LauncherRelative = "acq-python.cmd"

function Show-Usage {
    @"
install.ps1 - install acq (explicit Python preview)

Downloads and verifies the Windows release archive, installs it under
LOCALAPPDATA in a separate preview root. PATH is not edited. Update by re-running this
installer against a pinned release.

Usage:
  irm <release-url>/install.ps1 | iex
  .\install.ps1 [-InstallDir <path>] [-Source <url|dir>] [-Version <ver>]
                [-Channel <name>] [-DryRun] [-Yes] [-Help]

Options:
  -InstallDir <path>   User-writable install location, as an absolute path.
                       Default: %LOCALAPPDATA%\Programs\acq-python-preview
  -Source <url|dir>    Release source. A URL fetches SHA256SUMS, provenance.json
                       and the zip; a local offline asset set is read in place.
  -Version <ver>       Required explicit X.Y.Z-rc.N preview pin.
  -Channel <name>      bash (default stable route) or python (explicit preview).
  -RemovePreview       Remove digest-matching owned files, preserving modifications.
  -Sha256 <digest>     Expected SHA-256 of SHA256SUMS (64 hex characters).
  -NoAttestation       Skip attestation (also ACQ_INSTALL_NO_ATTESTATION=1).
  -NoPrereqCheck       Skip the post-install sandbox prerequisite report.
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
    if ([Console]::IsInputRedirected -or -not [Environment]::UserInteractive) { return $false }
    # Under -NonInteractive, Read-Host throws even with a console attached; that
    # is a refusal, not a crash.
    try { $answer = Read-Host "$Prompt [y/N]" }
    catch { return $false }
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

function Test-AbsolutePath {
    param([string]$Path)
    # Fully qualified only: drive-rooted (C:\ or C:/) or UNC (\\server\share). A
    # bare name, a drive-relative C:x or a driveless \x resolves against the
    # current directory or drive. A UNC path needs both the server and the
    # share: \\server alone names no directory that can be written to.
    if (-not $Path) { return $false }
    return (($Path -match '^[A-Za-z]:[\\/]') -or ($Path -match '^[\\/]{2}[^\\/]+[\\/][^\\/]'))
}

function Format-Shown {
    param([string]$Value)
    # The value with every character outside printable ASCII replaced by '?', so
    # a value echoed back in a message cannot carry control characters to the
    # terminal (install.sh's `shown` helper).
    return ($Value -replace '[^\x20-\x7E]', '?')
}

function Test-ProcessAlive {
    param([string]$ProcessId)

    # Leftover move-aside dirs and temporary ownership markers are named for the
    # PID of the run that made them. A PID that is still alive may be another
    # install into the same directory, running right now and between moving its
    # files aside and moving the new ones in, so its entries are skipped. A
    # non-numeric suffix is a lookalike, not a leftover. This run's own PID is
    # never treated as alive: a recycled PID would make a leftover look like this
    # run's, and its sweep must not be blocked. PID 1 counts as init rather than
    # an installer, as in install.sh. A reused PID only means the leftover waits
    # for a later run.
    if ($ProcessId -notmatch '\A[0-9]+\z') { return $false }
    # TryParse, not a cast: a suffix too large for Int64 is a leftover name, not
    # a reason to abort the install, and it can never be a live PID.
    $target = 0L
    if (-not [int64]::TryParse($ProcessId, [ref]$target)) { return $false }
    # A value above Int32.MaxValue parses but cannot name a Windows PID, and the
    # Get-Process conversion to Int32 would throw; treat it as not alive.
    if ($target -le 1 -or $target -eq $PID -or $target -gt [int]::MaxValue) { return $false }
    return [bool](Get-Process -Id ([int]$target) -ErrorAction SilentlyContinue)
}

function Get-DefaultInstallDir {
    # LOCALAPPDATA counts only when it is fully qualified, the rule acq applies to
    # XDG_* and HOME (see acq.backends/userdirs.sh): a relative value would
    # resolve against the current directory. Otherwise the profile's Local
    # AppData known folder is used; GetFolderPath asks Windows for it rather than
    # reading the environment.
    $base = $env:LOCALAPPDATA
    if (-not (Test-AbsolutePath $base)) {
        $base = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    }
    if (Test-AbsolutePath $base) {
        return (Join-Path $base "Programs\acq-python-preview")
    }
    throw "LOCALAPPDATA is not set to an absolute path. install.ps1 requires a user profile to install under."
}

function Resolve-Source {
    # Empty -> default release URL. A local directory -> the offline asset set.
    if (-not $Source) {
        return @{ Url = "$ReleaseBaseUrl"; IsUrl = $true }
    }
    if ($Source -match '^http://') { throw 'refusing plaintext HTTP preview source; use HTTPS or an offline directory' }
    if ($Source -match '^https://') {
        $uri = [Uri]$Source
        if ($uri.UserInfo -or $uri.Query -or $uri.Fragment) { throw 'preview source must not contain credentials, query or fragment' }
        return @{ Url = $Source; IsUrl = $true }
    }
    if ($Source -match '^[A-Za-z][A-Za-z0-9+.-]*://') { throw 'unsupported preview source protocol' }
    return @{ Url = $Source; IsUrl = $false }
}

function Get-PreviewAsset {
    param([string]$Url, [string]$Destination)
    # HttpClient supports both Windows PowerShell 5.1 and PowerShell 7. Automatic
    # redirects are disabled: every hop is checked before a request is sent.
    Add-Type -AssemblyName System.Net.Http
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $handler = New-Object Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    if ($handler.PSObject.Properties['SslProtocols']) { $handler.SslProtocols = [Security.Authentication.SslProtocols]::Tls12 }
    $client = New-Object Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(120)
    try {
        $current = [Uri]$Url
        for ($hop = 0; $hop -le 5; $hop++) {
            if ($current.Scheme -cne 'https' -or $current.UserInfo) { throw 'refusing non-HTTPS preview redirect' }
            $response = $client.GetAsync($current).GetAwaiter().GetResult()
            try {
                $status = [int]$response.StatusCode
                if ($status -in @(301, 302, 303, 307, 308)) {
                    if (-not $response.Headers.Location) { throw 'preview redirect has no location' }
                    $current = New-Object Uri($current, $response.Headers.Location)
                    continue
                }
                [void]$response.EnsureSuccessStatusCode()
                [IO.File]::WriteAllBytes($Destination, $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult())
                return
            }
            finally { $response.Dispose() }
        }
        throw 'too many preview redirects'
    }
    finally { $client.Dispose(); $handler.Dispose() }
}

function Get-ExpectedHash {
    param(
        [Parameter(Mandatory = $true)][string]$SumsPath,
        [ValidateNotNullOrEmpty()][string]$Name = $PackageName
    )

    foreach ($line in (Get-Content -LiteralPath $SumsPath)) {
        if ($line -match "^([0-9a-fA-F]{64})\s+\*?$([regex]::Escape($Name))\s*$") {
            return $Matches[1].ToLowerInvariant()
        }
    }
    throw "SHA256SUMS has no entry for $Name; refusing to install an unverified file."
}

function Test-ReleaseAttestation {
    param([string]$Archive, [hashtable]$Resolved)
    if ($NoAttestation -or $env:ACQ_INSTALL_NO_ATTESTATION -eq '1' -or -not $Resolved.IsUrl) { return }
    if ($Resolved.Url -notmatch '^https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/releases/download/[^?#]+$') { return }
    $repo = $Matches[1]
    $gh = Get-Command gh -CommandType Application -ErrorAction SilentlyContinue
    if (-not $gh) {
        Write-Host "  attestation unavailable: gh missing; continuing"
        return
    }
    # gh gained `attestation` in 2.49; an older gh cannot verify, which is the
    # same as having no verifier.
    $help = Start-Process -FilePath $gh.Source -ArgumentList @('attestation', 'verify', '--help') -Wait -PassThru -NoNewWindow -RedirectStandardError "$Archive.gh-help.err" -RedirectStandardOutput "$Archive.gh-help.out"
    if ($help.ExitCode -ne 0) {
        Write-Host "  attestation unavailable: this gh has no 'attestation' command; continuing"
        return
    }
    # Capture native stderr without Windows PowerShell turning it into a
    # terminating error before we can distinguish absence from failed verification.
    $log = "$Archive.attestation.log"
    $process = Start-Process -FilePath $gh.Source -ArgumentList @('attestation', 'verify', ('"' + $Archive + '"'), '--repo', $repo) -Wait -PassThru -NoNewWindow -RedirectStandardError $log -RedirectStandardOutput "$log.out"
    $message = (Get-Content -LiteralPath $log -Raw) + (Get-Content -LiteralPath "$log.out" -Raw)
    # Absence first: some gh releases print "no attestations found" yet exit 0.
    # Success then needs gh's own success line, not just exit status 0.
    if ($message -match 'no attestations found|no attestations associated|HTTP 404: Not Found') {
        Write-Host "  attestation absent for $PackageName; continuing"
    }
    elseif ($process.ExitCode -eq 0 -and $message -cmatch 'Verification succeeded') {
        Write-Host "  verified attestation for $PackageName"
    }
    else { throw "attestation verification failed for ${PackageName}: $message" }
}

function Test-MsbVersion {
    param([string]$Text)
    # Keep the >= 0.6.9 floor and blocked 0.7.0-0.7.2 range in lockstep with
    # install.sh, acq.backends/msb.sh and ADR-0032. Compare components, not suffixes.
    if ($Text -notmatch '(?<![0-9])([0-9]+)\.([0-9]+)\.([0-9]+)(?=\s|$)') { return $false }
    try { $major = [uint64]$Matches[1]; $minor = [uint64]$Matches[2]; $patch = [uint64]$Matches[3] }
    catch { return $false }
    if ($major -eq 0 -and $minor -eq 7 -and $patch -le 2) { return $false }
    return ($major -gt 0 -or $minor -gt 6 -or ($minor -eq 6 -and $patch -ge 9))
}

function Test-WhpAvailable {
    # The API tests actual host capability; a DISM feature flag can disagree
    # when another Windows virtualization component provides the hypervisor.
    try {
        if (-not ('AcqInstaller.Whp' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace AcqInstaller {
    public static class Whp {
        public const uint WHvCapabilityCodeHypervisorPresent = 0;
        [DllImport("WinHvPlatform.dll", ExactSpelling = true)]
        public static extern int WHvGetCapability(uint code, out uint present,
            uint size, out uint written);
    }
}
'@
        }
        [uint32]$present = 0
        [uint32]$written = 0
        $result = [AcqInstaller.Whp]::WHvGetCapability(
            [AcqInstaller.Whp]::WHvCapabilityCodeHypervisorPresent,
            [ref]$present, 4, [ref]$written)
        return ($result -eq 0 -and $written -ge 4 -and $present -ne 0)
    }
    catch { return $false }
}

function Install-PinnedMsb {
    # Same pin and verified bundle layout as ADR-0032 and install.sh. Never
    # execute the upstream installer, which resolves to the newest release.
    $base = 'https://github.com/superradcompany/microsandbox/releases/download/v0.7.7'
    $bundle = 'microsandbox-windows-x86_64.zip'
    $root = $env:MSB_HOME
    if (-not $root) { $root = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.microsandbox' }
    if (-not (Test-AbsolutePath $root)) { throw "MSB_HOME must be absolute" }
    $scratch = Join-Path ([IO.Path]::GetTempPath()) ('acq-msb-' + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $scratch | Out-Null
        $zip = Join-Path $scratch $bundle
        # Pinned here, not read from the release's checksums.sha256, so a tampered
        # download host cannot supply both a bundle and a matching checksum.
        # Checked against v0.7.7's checksums.sha256 and GitHub's asset digest.
        $expected = 'ae526aa2d7bfc230a6e9149d2b7483ac0992462c221a8add85d1429a005575e0'
        Invoke-WebRequest -Uri "$base/$bundle" -OutFile $zip
        if (-not $expected -or (Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash -ine $expected) {
            throw "pinned msb checksum mismatch"
        }
        $extract = Join-Path $scratch 'extract'
        Expand-Archive -LiteralPath $zip -DestinationPath $extract
        Publish-PinnedMsb -Extract $extract -Root $root
    }
    finally { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }
}

function Publish-PinnedMsb {
    param([string]$Extract, [string]$Root)
    foreach ($name in @('msb.exe', 'libkrunfw.dll')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Extract $name) -PathType Leaf)) {
            throw "pinned bundle missing $name"
        }
    }
    $bin = Join-Path $Root 'bin'
    $lib = Join-Path $Root 'lib'
    New-Item -ItemType Directory -Force -Path $bin, $lib | Out-Null
    # Windows cannot overwrite a running image; check before starting to copy.
    foreach ($name in @('msb.exe', 'microsandbox.exe')) {
        $target = Join-Path $bin $name
        if (Test-Path -LiteralPath $target) {
            try {
                $stream = [IO.File]::Open($target, 'Open', 'ReadWrite', 'None')
                $stream.Close()
            }
            catch { throw "$target is in use; close msb processes and retry" }
        }
    }
    Copy-Item -LiteralPath (Join-Path $Extract 'msb.exe') -Destination (Join-Path $bin 'msb.exe') -Force
    Copy-Item -LiteralPath (Join-Path $Extract 'msb.exe') -Destination (Join-Path $bin 'microsandbox.exe') -Force
    Copy-Item -LiteralPath (Join-Path $Extract 'libkrunfw.dll') -Destination $lib -Force
    Write-Host "  installed pinned msb 0.7.7 into $Root"
    Add-UserPath -Directory $bin
}

function Show-Prerequisites {
    Write-Step "Next steps: sandbox prerequisites (one backend is sufficient)"
    $msb = Get-Command msb -CommandType Application -ErrorAction SilentlyContinue
    if ($msb) {
        try {
            $text = (& $msb.Source --version 2>$null | Out-String).Trim()
            if ($LASTEXITCODE -ne 0 -or -not $text) { $text = 'unknown' }
        }
        catch { $text = 'unknown' }
        if (Test-MsbVersion $text) { Write-Host "  msb: found ($text; supported)" }
        else {
            Write-Host "  msb: found ($text; out-of-policy or unknown version)"
            Write-Host "    Fix: re-run install.ps1 in an interactive PowerShell to install the pinned msb, or see docs/howto/msb.md"
        }
    }
    else {
        Write-Host "  msb: missing"
        Write-Host "    Fix: answer yes below, or see docs/howto/msb.md"
        # -Yes consents only to PATH changes, never to backend installation.
        if (-not $Yes -and -not [Console]::IsInputRedirected) {
            if (Confirm-Action "Install pinned msb?") { Install-PinnedMsb }
        }
    }
    if (Get-Command sbx -CommandType Application -ErrorAction SilentlyContinue) { Write-Host "  sbx: found" }
    else {
        Write-Host "  sbx: missing"
        Write-Host "    Fix: brew install docker/tap/sbx && sbx login (on a supported Homebrew host; see docs/howto/sbx.md)"
    }
    if (Test-WhpAvailable) { Write-Host "  hardware virtualization: found (Windows Hypervisor Platform)" }
    else {
        Write-Host "  hardware virtualization: missing (Windows Hypervisor Platform unavailable)"
        Write-Host "    Fix: msb doctor --fix"
        Write-Host "    From an elevated shell: Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -All"
    }
    if (Get-Command git -CommandType Application -ErrorAction SilentlyContinue) { Write-Host "  git: found" }
    else {
        Write-Host "  git: missing"
        Write-Host "    Fix: winget install --id Git.Git -e"
    }
}

function Install-AcqZip {
    $resolved = Resolve-Source

    Write-Step "Installing acq $Version"
    Write-Host "  package:     $PackageName"
    Write-Host "  channel:     $Channel"
    Write-Host "  source:      $($resolved.Url)"
    Write-Host "  install dir: $InstallDir"

    if ($DryRun) {
        if ($resolved.IsUrl) {
            Write-Host "  [dry-run] download $($resolved.Url)/$SumsName, $($resolved.Url)/$ProvenanceName and $($resolved.Url)/$PackageName"
        }
        else {
            Write-Host "  [dry-run] read $($resolved.Url)/$SumsName, $($resolved.Url)/$ProvenanceName and $($resolved.Url)/$PackageName from the offline asset set"
        }
        if ($sha256Given) { Write-Host "  [dry-run] verify SHA256SUMS against -Sha256 before reading entries" }
        Write-Host "  [dry-run] verify $PackageName SHA-256 against $SumsName"
        Write-Host "  [dry-run] require the provenance manifest ($ProvenanceName)"
        Write-Host "  [dry-run] expand $PackageName into $InstallDir"
        Write-Host "  [dry-run] verify the enumerated set (launchers, backend tree, runtime, source, wheelhouse) is present"
        Write-Host "  [dry-run] install $ProvenanceName and separate preview ownership receipt"
        Write-Host "  [dry-run] publish only acq-python.cmd and acq-python.ps1 in the preview bin; PATH unchanged"
        return
    }

    $tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("acq-install-" + [guid]::NewGuid().ToString("N"))
    $markerTmp = $null
    try {
        New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null
        $zipPath = Join-Path $tmpRoot $PackageName
        $sumsPath = Join-Path $tmpRoot $SumsName
        $provenancePath = Join-Path $tmpRoot $ProvenanceName

        if ($resolved.IsUrl) {
            Get-PreviewAsset "$($resolved.Url)/$SumsName" $sumsPath
            try { Get-PreviewAsset "$($resolved.Url)/$ProvenanceName" $provenancePath }
            catch { throw "could not download $($resolved.Url)/$ProvenanceName" }
            Get-PreviewAsset "$($resolved.Url)/$PackageName" $zipPath
        }
        else {
            if (-not (Test-Path -LiteralPath (Join-Path $resolved.Url $SumsName) -PathType Leaf)) {
                throw "offline asset set at $($resolved.Url) has no $SumsName."
            }
            if (-not (Test-Path -LiteralPath (Join-Path $resolved.Url $ProvenanceName) -PathType Leaf)) {
                throw "offline asset set at $($resolved.Url) has no $ProvenanceName."
            }
            if (-not (Test-Path -LiteralPath (Join-Path $resolved.Url $PackageName) -PathType Leaf)) {
                throw "offline asset set at $($resolved.Url) has no $PackageName."
            }
            Copy-Item -LiteralPath (Join-Path $resolved.Url $SumsName) -Destination $sumsPath
            Copy-Item -LiteralPath (Join-Path $resolved.Url $ProvenanceName) -Destination $provenancePath
            Copy-Item -LiteralPath (Join-Path $resolved.Url $PackageName) -Destination $zipPath
        }

        if ($sha256Given) {
            $sumsActual = (Get-FileHash -Algorithm SHA256 -LiteralPath $sumsPath).Hash
            if ($sumsActual -ine $Sha256) { throw "SHA256SUMS pin mismatch; refusing to install" }
            Write-Host "  verified SHA256SUMS pin"
        }
        $expected = Get-ExpectedHash -SumsPath $sumsPath
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath).Hash.ToLowerInvariant()
        if ($actual -ne $expected) {
            throw "SHA-256 verification failed for $PackageName. Expected $expected, got $actual."
        }
        Write-Host "  verified $PackageName SHA-256: $actual"

        Test-ReleaseAttestation -Archive $zipPath -Resolved $resolved

        # As in install.sh, provenance is a required companion asset, and
        # SHA256SUMS lists it, so it is verified like the archive before anything
        # is extracted: an unchecked provenance record would be a claim, not evidence.
        if (-not (Test-Path -LiteralPath $provenancePath -PathType Leaf)) {
            throw "release is missing the provenance manifest ($ProvenanceName)"
        }
        $provExpected = Get-ExpectedHash -SumsPath $sumsPath -Name $ProvenanceName
        $provActual = (Get-FileHash -Algorithm SHA256 -LiteralPath $provenancePath).Hash.ToLowerInvariant()
        if ($provActual -ne $provExpected) {
            throw "checksum mismatch for $ProvenanceName (expected $provExpected, got $provActual)"
        }

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
        # acq.cmd starts acq.ps1, whose default (Python) branch imports acq_py
        # from py-acq\src; its ACQ_IMPL=bash branch runs the `acq` dispatcher,
        # which sources acq.backends\common.sh first. Each is a fail-closed
        # gate, as in install.sh, so an incomplete zip never installs a launcher
        # that cannot start.
        foreach ($required in @("acq-python.ps1", "acq.ps1", "acq", "acq.backends\common.sh", "py-acq\src\acq_py\__init__.py")) {
            if (-not (Test-Path -LiteralPath (Join-Path $sourceDir $required) -PathType Leaf)) {
                throw "release archive is missing $required."
            }
        }
        if (-not (Test-Path -LiteralPath (Join-Path $sourceDir "wheelhouse") -PathType Container)) {
            throw "release archive is missing the dependency wheelhouse (wheelhouse/)"
        }

        # Only the preview bin goes on PATH. The ordinary dispatcher is private,
        # so this directory cannot make an acq.cmd shadow the Bash installation.
        $previewBin = Join-Path $sourceDir 'bin'
        if (Get-Item -LiteralPath $previewBin -Force -ErrorAction SilentlyContinue) { throw 'preview archive must not supply bin; only preview shims may be exposed' }
        New-Item -ItemType Directory -Path $previewBin | Out-Null
        $cmd = '@echo off' + "`r`n" + 'setlocal' + "`r`n" + 'set "ACQ_IMPL=python"' + "`r`n" + '"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -File "%~dp0..\acq.ps1" %*' + "`r`n" + 'exit /b %errorlevel%' + "`r`n"
        Set-Content -LiteralPath (Join-Path $previewBin 'acq-python.cmd') -Value $cmd -Encoding ascii -NoNewline
        Set-Content -LiteralPath (Join-Path $previewBin 'acq-python.ps1') -Value '& (Join-Path $PSScriptRoot "..\acq-python.ps1") @args; exit $LASTEXITCODE' -Encoding ascii
        Copy-Item -LiteralPath $provenancePath -Destination (Join-Path $sourceDir $ProvenanceName)
        $files = @(Get-ChildItem -LiteralPath $sourceDir -Recurse -Force -File)
        foreach ($file in $files) {
            if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'preview archive contains links' }
            $rel = $file.FullName.Substring($sourceDir.Length + 1)
            $target = Join-Path $InstallDir $rel
            Test-PreviewPath $target
            if (Get-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue) {
                if ($previewFiles.path -cnotcontains $rel) { throw "preview archive collides with unknown file: $rel" }
            }
        }
        $manifest = @($files | ForEach-Object {
            @{ path = $_.FullName.Substring($sourceDir.Length + 1); sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
        })
        $receipt = @{ channel = 'python'; version = $Version; source = $resolved.Url; archive = $PackageName;
            sha256 = $actual; checksums_sha256 = (Get-FileHash -LiteralPath $sumsPath -Algorithm SHA256).Hash;
            provenance_sha256 = $provActual; root = $InstallDir; files = $manifest }
        $parent = Split-Path -Parent $InstallDir
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        $publish = Join-Path $parent ('.acq-python-preview-stage-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $publish | Out-Null
        try {
            if (Test-Path -LiteralPath $InstallDir) {
                foreach ($item in @(Get-ChildItem -LiteralPath $InstallDir -Force)) {
                    Copy-Item -LiteralPath $item.FullName -Destination $publish -Recurse
                }
            }
            foreach ($item in @(Get-ChildItem -LiteralPath $sourceDir -Force)) {
                Copy-Item -LiteralPath $item.FullName -Destination $publish -Recurse -Force
            }
            $receipt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $publish '.acq-python-preview-receipt.json') -Encoding utf8
            if (Test-Path -LiteralPath $InstallDir) { Move-Item -LiteralPath $InstallDir -Destination $previewBackup }
            try { Move-Item -LiteralPath $publish -Destination $InstallDir }
            catch {
                if (Test-Path -LiteralPath $previewBackup) { Move-Item -LiteralPath $previewBackup -Destination $InstallDir }
                throw
            }
            if (Test-Path -LiteralPath $previewBackup) { Remove-Item -LiteralPath $previewBackup -Recurse -Force }
        }
        finally {
            if (Test-Path -LiteralPath $publish) { Remove-Item -LiteralPath $publish -Recurse -Force }
        }
        return

        # Publish without destroying anything this installer did not create:
        # -InstallDir can name any directory. Record the exact top-level names
        # the installer owns in a marker file, overwrite only those names, and
        # refuse any other collision. The marker is written before anything
        # moves, so a failed run leaves a directory the next run can finish.
        # Get-Item (not Test-Path) is used for existence so dangling links and
        # junctions are seen too.
        $ownedMarker = ".acq-v1-install"
        # Stage the companion manifest with the archive entries so it gets the
        # same collision protection and ownership record as every release name.
        Copy-Item -LiteralPath $provenancePath -Destination (Join-Path $sourceDir $ProvenanceName) -Force
        if ($InstallDir.Length -gt 3) { $InstallDir = $InstallDir.TrimEnd('\', '/') }  # keep a drive root like C:\
        $existing = Get-Item -LiteralPath $InstallDir -Force -ErrorAction SilentlyContinue
        if ($existing) {
            if ($existing.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "$InstallDir is a symlink or junction; refusing to install through it. Pass -InstallDir with a real directory."
            }
            if (-not $existing.PSIsContainer) {
                throw "$InstallDir exists and is not a directory; move it aside or pass -InstallDir."
            }
        }
        New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
        $markerPath = Join-Path $InstallDir $ownedMarker
        $owned = @()
        $wasMarked = Test-Path -LiteralPath $markerPath -PathType Leaf
        if ($wasMarked) {
            $owned = @(Get-Content -LiteralPath $markerPath | Select-Object -Skip 1)
        }
        $entries = @(Get-ChildItem -LiteralPath $sourceDir -Force)
        foreach ($entry in $entries) {
            $present = Get-Item -LiteralPath (Join-Path $InstallDir $entry.Name) -Force -ErrorAction SilentlyContinue
            if ($present -and ($owned -notcontains $entry.Name)) {
                throw "$InstallDir already contains '$($entry.Name)', which this installer did not create (not listed in $ownedMarker). Move it aside or pass -InstallDir; nothing was changed."
            }
        }
        # Every release name is now absent or already ours; keep previously owned
        # names too (leftovers from an older release are still ours to replace).
        $names = @($owned) + @($entries | ForEach-Object { $_.Name }) | Select-Object -Unique
        # Write the marker to .acq-v1-install.tmp.<pid> and rename it into place,
        # as install.sh does. A run interrupted inside Set-Content then leaves the
        # previous marker intact instead of a truncated one, which the collision
        # check above would read as "these files are not ours" and refuse the
        # next run's own files. The finally block removes the temporary marker if
        # the rename never happens (ADR-0042m).
        #
        # ReplaceFile (File.Replace) and rename (File.Move), not Move-Item -Force:
        # on Windows Move-Item -Force deletes the destination before it moves, so
        # a failed move leaves no marker at all and the next run refuses its own
        # files. Both primitives below fail closed with the old marker in place.
        # File.Replace needs an existing destination, hence the branch for a
        # first install.
        $markerTmp = Join-Path $InstallDir "$ownedMarker.tmp.$PID"
        Set-Content -LiteralPath $markerTmp -Value (@($Version) + $names) -Encoding ascii
        try {
            if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
                [IO.File]::Replace($markerTmp, $markerPath, [NullString]::Value)
            }
            else {
                [IO.File]::Move($markerTmp, $markerPath)
            }
        }
        catch {
            $detail = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
            throw "could not write ${markerPath}: $detail"
        }
        $markerTmp = $null
        # Leftover move-aside dirs and temporary markers hold only acq's own
        # files, but only trust that in a directory that was already marked
        # before this run: a first install must not sweep a name it cannot prove
        # is an interrupted run's. The suffix is a process id, so entries of a
        # live process are skipped (Test-ProcessAlive, above), a non-numeric
        # suffix is a lookalike rather than a leftover, and a reparse point is
        # never followed. The sweep is best effort: a leftover this run cannot
        # remove must not stop the install, or every later one.
        if ($wasMarked) {
            foreach ($stale in @(Get-ChildItem -LiteralPath $InstallDir -Force -Directory -Filter ".acq-previous.*")) {
                if ($stale.Name -notmatch '\A\.acq-previous\.([0-9]+)\z') { continue }
                $stalePid = $Matches[1]
                if (Test-ProcessAlive -ProcessId $stalePid) { continue }
                if ($stale.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                Remove-Item -LiteralPath $stale.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
            foreach ($stale in @(Get-ChildItem -LiteralPath $InstallDir -Force -File -Filter "$ownedMarker.tmp.*")) {
                if ($stale.Name -notmatch ('\A' + [regex]::Escape($ownedMarker) + '\.tmp\.([0-9]+)\z')) { continue }
                $stalePid = $Matches[1]
                if (Test-ProcessAlive -ProcessId $stalePid) { continue }
                if ($stale.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                Remove-Item -LiteralPath $stale.FullName -Force -ErrorAction SilentlyContinue
            }
        }
        $previous = Join-Path $InstallDir ".acq-previous.$PID"
        New-Item -ItemType Directory -Path $previous | Out-Null
        foreach ($entry in $entries) {
            $target = Join-Path $InstallDir $entry.Name
            if (Get-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue) {
                Move-Item -LiteralPath $target -Destination (Join-Path $previous $entry.Name)
            }
            Move-Item -LiteralPath $entry.FullName -Destination $target
        }
        # Only owned entries were moved into $previous, so removing it is safe.
        Remove-Item -LiteralPath $previous -Recurse -Force
    }
    finally {
        if ($markerTmp -and (Test-Path -LiteralPath $markerTmp)) {
            Remove-Item -LiteralPath $markerTmp -Force -ErrorAction SilentlyContinue
        }
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

function Test-PreviewPath {
    param([string]$Path)
    if ($Path -match '(^|[\\/])\.{1,2}([\\/]|$)') { throw 'preview path contains dot components' }
    $part = $Path
    while ($part) {
        $item = Get-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "preview path contains a link: $part" }
        $parent = Split-Path -Parent $part
        if ($parent -eq $part) { break }
        $part = $parent
    }
}

function Test-PreviewOwnership {
    if ($DryRun -and [Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        Write-Host '  [dry-run] native Windows ownership preflight required before download'
        return
    }
    if ($InstallDir.Length -gt 3) { $script:InstallDir = $InstallDir.TrimEnd('\', '/') }
    Test-PreviewPath $InstallDir
    $script:previewBackup = "$InstallDir.acq-python-preview-previous"
    Test-PreviewPath $previewBackup
    if (Test-Path -LiteralPath $previewBackup) {
        $backupReceipt = Join-Path $previewBackup '.acq-python-preview-receipt.json'
        Test-PreviewPath $backupReceipt
        $backupIdentity = Get-Content -LiteralPath $backupReceipt -Raw | ConvertFrom-Json
        if ($backupIdentity.channel -cne 'python' -or $backupIdentity.root -cne $InstallDir) { throw 'unproven preview recovery backup' }
        foreach ($file in @($backupIdentity.files)) {
            if (-not $file.path -or $file.path -match '^[\\/]|:|(^|[\\/])\.{1,2}([\\/]|$)') { throw 'invalid preview backup path' }
            $candidate = Join-Path $previewBackup $file.path
            Test-PreviewPath $candidate
            if (-not (Test-Path -LiteralPath $candidate -PathType Leaf) -or (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash -cne $file.sha256) { throw 'modified preview backup file' }
        }
        foreach ($item in @(Get-ChildItem -LiteralPath (Join-Path $previewBackup 'bin') -Force)) {
            if ($item.Name -cnotin @('acq-python.cmd', 'acq-python.ps1') -or $backupIdentity.files.path -cnotcontains "bin\$($item.Name)") { throw 'foreign command in preview backup' }
        }
        if (Test-Path -LiteralPath $InstallDir) { throw 'preview recovery backup retained; inspect and move it aside before reinstalling' }
        if (-not $DryRun) { Move-Item -LiteralPath $previewBackup -Destination $InstallDir }
    }
    $script:previewReceiptPath = Join-Path $InstallDir '.acq-python-preview-receipt.json'
    $script:previewFiles = @()
    if (Get-Item -LiteralPath $InstallDir -Force -ErrorAction SilentlyContinue) {
        if (-not (Test-Path -LiteralPath $previewReceiptPath -PathType Leaf)) { throw 'preview root has no matching receipt' }
        Test-PreviewPath $previewReceiptPath
        $receipt = Get-Content -LiteralPath $previewReceiptPath -Raw | ConvertFrom-Json
        if ($receipt.channel -cne 'python' -or $receipt.root -cne $InstallDir) { throw 'preview receipt identity mismatch' }
        $script:previewFiles = @($receipt.files)
        foreach ($file in $previewFiles) {
            if (-not $file.path -or $file.path -match '^[\\/]|:|(^|[\\/])\.{1,2}([\\/]|$)') { throw 'invalid preview receipt path' }
            $target = Join-Path $InstallDir $file.path
            Test-PreviewPath $target
            $item = Get-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
            if (-not $RemovePreview -and (-not $item -or $item.PSIsContainer -or (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -cne $file.sha256)) {
                throw "preview file is missing or modified: $($file.path)"
            }
        }
    }
    foreach ($name in @('acq-python.cmd', 'acq-python.ps1')) {
        $rel = "bin\$name"
        $target = Join-Path $InstallDir $rel
        Test-PreviewPath $target
        $item = Get-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
        if ($item -and $previewFiles.path -cnotcontains $rel) { throw "refusing foreign preview command: $name" }
    }
    $bin = Join-Path $InstallDir 'bin'
    if (Test-Path -LiteralPath $bin) {
        foreach ($item in @(Get-ChildItem -LiteralPath $bin -Force)) {
            if ($item.Name -cnotin @('acq-python.cmd', 'acq-python.ps1')) { throw 'preview bin contains an unexpected command' }
        }
    }
}

if ($Help) {
    Show-Usage
    exit 0
}

$sha256Given = ($null -ne $PSBoundParameters -and $PSBoundParameters.Keys -contains 'Sha256') -or $Sha256
if ($sha256Given -and $Sha256 -cnotmatch '\A[0-9a-fA-F]{64}\z') {
    [Console]::Error.WriteLine("error: -Sha256 requires exactly 64 hex characters")
    exit 2
}

# The -Channel flag is the update-channel seam (ADR-0047m). On this fork the only
# channel is `python` (the default); any other value fails closed.
if ($Channel -cne "python") {
    [Console]::Error.WriteLine("unknown channel '$Channel' (only 'python' is supported on this fork)")
    exit 2
}

if (-not $RemovePreview -and (-not $PSBoundParameters.ContainsKey('Version') -or $Version -cnotmatch '\A[0-9]+\.[0-9]+\.[0-9]+-rc\.[0-9]+\z')) {
    [Console]::Error.WriteLine('Python preview requires an explicit -Version X.Y.Z-rc.N pin')
    exit 2
}

# An -InstallDir that is not fully qualified would resolve against the current
# directory (or, for C:x and \x, the current drive), and the PATH entry added
# for it would be relative too. Refuse it before anything else, -DryRun
# included, as install.sh refuses a relative --install-dir. An empty
# -InstallDir '' is refused the same way rather than read as "use the default",
# as install.sh refuses an empty --install-dir. Run as `irm ... | iex`, the text
# runs in the caller's scope, where $PSBoundParameters can be $null, so it is
# checked first; a non-empty -InstallDir is still validated there.
$installDirGiven = ($null -ne $PSBoundParameters -and $PSBoundParameters.ContainsKey('InstallDir')) -or $InstallDir
if ($installDirGiven -and -not (Test-AbsolutePath $InstallDir)) {
    [Console]::Error.WriteLine("error: -InstallDir must be an absolute path, got '$(Format-Shown $InstallDir)'; pass a fully qualified -InstallDir (for example C:\acq) or omit it to use the default")
    exit 1
}

# -Help and -DryRun are read-only/planning paths and must not require a user
# profile. Resolve the install dir lazily: -DryRun falls back to a placeholder
# when no absolute Local AppData folder exists, and only the real install path
# requires one.
if ($DryRun) {
    if (-not $InstallDir) {
        try { $InstallDir = Get-DefaultInstallDir } catch { $InstallDir = "<LOCALAPPDATA>\Programs\acq-python-preview" }
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
Test-PreviewOwnership
if ($RemovePreview) {
    if (-not $previewFiles.Count) { throw 'no matching preview receipt for backout' }
    foreach ($file in $previewFiles) {
        $target = Join-Path $InstallDir $file.path
        if ((Test-Path -LiteralPath $target -PathType Leaf) -and (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ceq $file.sha256) {
            if (-not $DryRun) { Remove-Item -LiteralPath $target }
        }
        else { Write-Warn "preserving modified or missing preview file: $($file.path)" }
    }
    Write-Host 'Preview backout complete; unknown files, receipts and PATH preserved.'
    exit 0
}
$null = Resolve-Source
Install-AcqZip
Write-Host "Preview PATH directory: $InstallDir\bin (PATH was not changed)"

if (-not $DryRun -and -not $NoPrereqCheck) { Write-Host 'Existing sandbox backends were not changed.' }

Write-Step "Done"
Write-Host "Try it now: acq-python version"
