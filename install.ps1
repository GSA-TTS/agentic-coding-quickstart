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

# msb version policy. Keep in lockstep with install.sh and acq.backends/msb.sh:
# a drift here means Windows accepts an msb the rest of acq refuses.
#
# 0.7.0 through 0.7.2 migrate 0.6.x sandbox state one-way, into a form the 0.6.x
# line cannot read. 0.7.3 carries the upstream compatibility fix. See ADR-0031.
$MsbMinVersion = "0.6.9"
$MsbPinnedVersion = "0.6.18"
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

    $match = [regex]::Match(($output -join " "), '\d+\.\d+(\.\d+)?')
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
    if (-not $found) {
        throw "$Context, but msb.exe at $($msb.Source) did not report a parseable version."
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

        if (-not $found) {
            Write-Step "The active msb version could not be determined"
            Write-Warn "Found msb at $($msb.Source), but its version output was not parseable."
            if (-not (Confirm-Action "Install msb $MsbPinnedVersion now?")) {
                throw "acq needs an msb version it can verify. Install msb $MsbPinnedVersion, then re-run this installer."
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
            Write-Host "  'msb self update' targets the newest release, which currently IS $MsbFixedVersion."

            if (-not (Confirm-Action "Run 'msb self update' to move to msb $MsbFixedVersion now?")) {
                throw "acq refuses msb $found. Run 'msb self update' (or install msb $MsbPinnedVersion), then re-run this installer. If you roll back instead, run 'msb self downgrade $MsbPinnedVersion' with THIS msb first - an older msb cannot roll back these migrations, and a failed attempt blocks every later msb command."
            }

            Invoke-InstallCommand "msb self update" {
                & $msb.Source self update
                if ($LASTEXITCODE -ne 0) {
                    throw "'msb self update' did not complete. Its output above is authoritative."
                }
            }
            # Verify rather than assume: 'self update' targets whatever is newest,
            # which is only the fixed release for as long as that stays true.
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
Ensure-Path

Write-Step "Done"
Write-Host "Try it now: acq version"
Write-Host "Next, start a sandbox: acq run opencode C:\path\to\your\project"
