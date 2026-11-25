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
    [string]$Sha256 = "",
    [switch]$NoAttestation,
    [switch]$NoPrereqCheck,
    [switch]$DryRun,
    [switch]$Yes,
    [switch]$Help
)

$ErrorActionPreference = "Stop"
$ReleaseBaseUrl = "https://github.com/GSA-TTS/agentic-coding-quickstart/releases/download/v$Version"
$PackageName = "acq-windows-x64.zip"
$SumsName = "SHA256SUMS"
$ProvenanceName = "provenance.json"
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
  -InstallDir <path>   User-writable install location, as an absolute path.
                       Default: %LOCALAPPDATA%\Programs\acq
  -Source <url|dir>    Release source. A URL fetches SHA256SUMS, provenance.json
                       and the zip; a local offline asset set is read in place.
  -Version <ver>       Release version to install. Default: $Version
  -Channel <name>      Update channel to install (default: python; the only
                       channel supported on this fork).
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
        return (Join-Path $base "Programs\acq")
    }
    throw "LOCALAPPDATA is not set to an absolute path. install.ps1 requires a user profile to install under."
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
        Write-Host "  [dry-run] install $ProvenanceName into $InstallDir and record it in .acq-v1-install"
        Write-Host "  [dry-run] offer to add $InstallDir to your user PATH"
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
            Invoke-WebRequest -Uri "$($resolved.Url)/$SumsName" -OutFile $sumsPath
            try { Invoke-WebRequest -Uri "$($resolved.Url)/$ProvenanceName" -OutFile $provenancePath }
            catch { throw "could not download $($resolved.Url)/$ProvenanceName" }
            Invoke-WebRequest -Uri "$($resolved.Url)/$PackageName" -OutFile $zipPath
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
        foreach ($required in @("acq.ps1", "acq", "acq.backends\common.sh", "py-acq\src\acq_py\__init__.py")) {
            if (-not (Test-Path -LiteralPath (Join-Path $sourceDir $required) -PathType Leaf)) {
                throw "release archive is missing $required."
            }
        }
        if (-not (Test-Path -LiteralPath (Join-Path $sourceDir "wheelhouse") -PathType Container)) {
            throw "release archive is missing the dependency wheelhouse (wheelhouse/)"
        }

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
if ($Channel -ne "python") {
    [Console]::Error.WriteLine("unknown channel '$Channel' (only 'python' is supported on this fork)")
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
        try { $InstallDir = Get-DefaultInstallDir } catch { $InstallDir = "<LOCALAPPDATA>\Programs\acq" }
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

if (-not $DryRun -and -not $NoPrereqCheck) { Show-Prerequisites }

Write-Step "Done"
Write-Host "Try it now: acq version"
