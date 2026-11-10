# acq.ps1 - Windows launcher for acq through Git Bash.
#
# acq remains a Bash program in the Windows preview path. This launcher finds Git
# for Windows' bash.exe and delegates to the repository-local Bash entry point.

$ErrorActionPreference = "Stop"

# Run from a PowerShell prompt or script (`.\acq.ps1`, or an `acq` alias for it),
# this script runs inside the caller's process and shares its environment, so
# the variables it sets for the programs it starts (NoDefaultCurrentDirectoryInExePath,
# PYTHONPATH, ACQ_PROVIDER_INPUT_DATA_DIR) would stay set in the user's session
# afterwards. The first invocation therefore saves them, runs the launcher as a
# nested call of this same script, and puts them back however that call ends:
# exit, error or Ctrl+C. The nested call sees $acqPs1SavedEnvironment (set in
# this scope, visible to the child scope) and runs the launcher itself. Started
# by acq.cmd, the process is acq's own, so the restore changes nothing there.
if ($null -eq (Get-Variable -Name acqPs1SavedEnvironment -ErrorAction SilentlyContinue)) {
    $acqPs1SavedEnvironment = @{}
    foreach ($name in @('NoDefaultCurrentDirectoryInExePath', 'PYTHONPATH', 'ACQ_PROVIDER_INPUT_DATA_DIR')) {
        $acqPs1SavedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }
    try {
        & $PSCommandPath @args
    }
    finally {
        foreach ($name in $acqPs1SavedEnvironment.Keys) {
            # A $null value removes the variable, as it was before.
            [Environment]::SetEnvironmentVariable($name, $acqPs1SavedEnvironment[$name], 'Process')
        }
        Remove-Variable -Name acqPs1SavedEnvironment -ErrorAction SilentlyContinue
    }
    exit $LASTEXITCODE
}

# Programs started by acq never resolve from the current directory (normally the
# untrusted workspace): cmd.exe, CreateProcess and Python's shutil.which honour
# this for every child process.
$env:NoDefaultCurrentDirectoryInExePath = "1"

# acq.cmd starts this script as
#   powershell.exe -NoLogo -NoProfile -File "<this script>" <arguments>
# Recognising that launch tells acq.ps1 two things: no PowerShell pipeline is
# waiting for the output, and the arguments are exactly what acq.cmd received.
# The first lets the Python branch start Python with an exact command line
# (Invoke-AcqProcess) instead of PowerShell's call operator, which under
# Windows PowerShell 5.1 drops empty arguments, leaves embedded double quotes
# unescaped and mishandles a backslash run before a quote.
# Get-AcqLauncherArgs takes the arguments from the process's argv, which .NET
# splits from the raw command line with the Windows (MSVCRT) rules, rather than
# from PowerShell's binding of $args. It returns $null for any other kind of
# launch, such as `.\acq.ps1` typed at a PowerShell prompt: there PowerShell
# parsed the line itself (and takes a bare `--` as its own end-of-parameters
# marker), and $args is all there is.
function Get-AcqLauncherArgs {
    param([Parameter(Mandatory = $true)][string]$Self)

    $argv = [Environment]::GetCommandLineArgs()
    if ($argv.Count -lt 5) { return $null }
    if ($argv[1] -cne '-NoLogo' -or $argv[2] -cne '-NoProfile' -or $argv[3] -cne '-File') {
        return $null
    }
    # The script named on the command line must be this one: another script
    # started with -File may have called acq.ps1, and its arguments are not ours.
    try {
        $named = [System.IO.Path]::GetFullPath($argv[4])
        $mine = [System.IO.Path]::GetFullPath($Self)
    }
    catch {
        return $null
    }
    if (-not [string]::Equals($named, $mine, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }
    $rest = @()
    for ($i = 5; $i -lt $argv.Count; $i++) {
        $rest += [string]$argv[$i]
    }
    # The unary comma keeps an empty array from being unrolled into $null.
    return , $rest
}

# Quote one argument for a Windows command line so that the MSVCRT parser
# (Python's, and most native programs') gives it back unchanged: an empty
# argument becomes "", and a backslash run is doubled only where it precedes a
# double quote.
function ConvertTo-AcqCommandLineArgument {
    param([AllowEmptyString()][string]$Value)

    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') {
        return $Value
    }
    $slash = [char]92
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq $slash) {
            $backslashes++
            continue
        }
        if ($ch -eq [char]34) {
            [void]$builder.Append($slash, 2 * $backslashes + 1)
        }
        elseif ($backslashes -gt 0) {
            [void]$builder.Append($slash, $backslashes)
        }
        [void]$builder.Append($ch)
        $backslashes = 0
    }
    [void]$builder.Append($slash, 2 * $backslashes)
    [void]$builder.Append('"')
    return $builder.ToString()
}

# Run a native program with an exact command line and return its exit status.
# PowerShell's own call operator would re-quote the arguments (Windows
# PowerShell 5.1 drops empty ones and leaves embedded quotes unescaped). The
# child shares this console and inherits the standard handles, and starts in
# the current PowerShell location, as the call operator would start it.
function Invoke-AcqProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [AllowEmptyString()][string]$ArgumentLine
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = $ArgumentLine
    $startInfo.UseShellExecute = $false
    $startInfo.WorkingDirectory = (Get-Location -PSProvider FileSystem).ProviderPath
    $process = [System.Diagnostics.Process]::Start($startInfo)
    $process.WaitForExit()
    return $process.ExitCode
}

$launcherArgs = Get-AcqLauncherArgs -Self $PSCommandPath

# ACQ_IMPL runtime switch — the coexistence seam (ADR-0047m). On Windows the Bash
# `acq` dispatches via Git Bash; here the Python implementation runs natively:
# the managed runtime `py-acq\runtime\python.exe -m acq_py`, else `python` on
# PATH. Unset / `bash` keeps the existing Git Bash path below; any other value
# fails closed (exit 2). argv and the exit status are forwarded verbatim. The
# value is compared case-sensitively (-cne), as the Bash `acq` compares it, so
# `PYTHON` or `Bash` fails closed here too instead of selecting a branch.
$acqImpl = $env:ACQ_IMPL
if ($acqImpl -and $acqImpl -cne "bash") {
    if ($acqImpl -cne "python") {
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
    if ($null -ne $launcherArgs) {
        # Started by acq.cmd: hand Python the arguments exactly as acq.cmd got
        # them. A separate powershell.exe owns no PowerShell pipeline, so the
        # child writing straight to the inherited handles loses nothing.
        $argumentLine = '-P -m acq_py'
        foreach ($argument in $launcherArgs) {
            $argumentLine += ' ' + (ConvertTo-AcqCommandLineArgument -Value $argument)
        }
        exit (Invoke-AcqProcess -FilePath $acqPythonExe -ArgumentLine $argumentLine)
    }
    # Called from a PowerShell prompt or script: PowerShell has parsed the line
    # (quote a literal '--' there), and the call operator keeps the output in the
    # caller's pipeline, so `acq version --json | ConvertFrom-Json` works.
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

# True when the call operator passes native arguments the legacy way: Windows
# PowerShell 5.1, PowerShell before 7.3, or $PSNativeCommandArgumentPassing set
# to Legacy. That way drops an empty argument and leaves an embedded double
# quote unescaped.
function Test-AcqLegacyNativeArguments {
    $version = $PSVersionTable.PSVersion
    if ($version.Major -lt 7 -or ($version.Major -eq 7 -and $version.Minor -lt 3)) {
        return $true
    }
    return ($PSNativeCommandArgumentPassing -eq 'Legacy')
}

function Convert-ArgumentForGitBash {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Argument)

    if ($Argument.Length -eq 0) {
        return $Argument
    }
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
# The Bash branch reaches bash.exe through the call operator. Where that passes
# arguments the legacy way, an empty argument vanishes and an embedded double
# quote is not escaped, so bash would run a different command than the one
# typed. Refuse such an argument (exit 2, as for any other unsupported input)
# instead of running it changed; the Python branch, started through acq.cmd,
# forwards it exactly.
$sourceArgs = $args
if ($null -ne $launcherArgs) {
    $sourceArgs = $launcherArgs
}
if (Test-AcqLegacyNativeArguments) {
    foreach ($argument in $sourceArgs) {
        $text = [string]$argument
        if ($text.Length -eq 0 -or $text.Contains('"')) {
            [Console]::Error.WriteLine("acq: the Bash implementation cannot be given an empty argument or one containing a double quote from PowerShell $($PSVersionTable.PSVersion): it would be dropped or changed on the way to bash.exe. Set ACQ_IMPL=python, which forwards arguments unchanged.")
            exit 2
        }
    }
}
$convertedArgs = @($sourceArgs | ForEach-Object { Convert-ArgumentForGitBash -Argument $_ })

& $bash --noprofile --norc $bashAcq @convertedArgs
exit $LASTEXITCODE
