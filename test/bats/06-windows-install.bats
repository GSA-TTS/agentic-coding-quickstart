#!/usr/bin/env bats

# Tests for the acq v1 Windows installer (install.ps1) — ADR-0042m. Windows x64
# only: a checksum-verified acq-windows-x64.zip installed under LOCALAPPDATA, with
# consent-gated user PATH and no elevation. The functional install path needs a
# Windows host; these tests assert the source invariants and exercise -Help and
# -DryRun under pwsh when available.

load './helper.bash'

setup() {
  acq_setup_stubs
}

teardown() {
  acq_teardown_stubs
}

@test "windows installer: release version marker stays in sync with install.sh" {
  sh_version=$(sed -n 's/^DEFAULT_VERSION="\([^"]*\)".*/\1/p' "$REPO_ROOT/install.sh")
  ps_version=$(sed -n 's/^    \[string\]\$Version = "\([^"]*\)".*/\1/p' "$REPO_ROOT/install.ps1")

  assert_equal "$ps_version" "$sh_version"
}

@test "windows installer: verifies the zip against SHA256SUMS before writing" {
  installer=$(cat "$REPO_ROOT/install.ps1")

  assert_regex "$installer" 'function Get-ExpectedHash'
  assert_regex "$installer" 'Get-FileHash -Algorithm SHA256'
  assert_regex "$installer" 'SHA-256 verification failed'
  assert_regex "$installer" 'SHA256SUMS has no entry'
}

@test "windows installer: PATH is consent-gated and never inferred non-interactively" {
  installer=$(cat "$REPO_ROOT/install.ps1")

  assert_regex "$installer" 'function Confirm-Action'
  assert_regex "$installer" '\[Console\]::IsInputRedirected'
  assert_regex "$installer" 'SetEnvironmentVariable\("Path"'
}

@test "windows installer: never elevates" {
  local code
  code=$(sed '/^[[:space:]]*Write-Host /d' "$REPO_ROOT/install.ps1")
  refute_regex "$code" 'Enable-WindowsOptionalFeature|Start-Process.*-Verb RunAs|Restart-Computer'
  # A printed command is allowed; an executable one must still trip the guard.
  assert_regex "$code"$'\nEnable-WindowsOptionalFeature -Online' 'Enable-WindowsOptionalFeature'
}

@test "windows installer: never pipes a remote script to iex" {
  # The usage here-string documents the `irm … | iex` bootstrap; that prose must
  # not read as the installer itself piping a remote script to iex. Strip the
  # here-string body, comments, and Write-* helpers, then assert on what runs.
  code=$(awk '
    /@"/   { inheredoc = 1 }
    /^"@/  { inheredoc = 0; next }
    inheredoc { next }
    /^[[:space:]]*#/ { next }
    /Write-(Host|Warn|Warning)/ { next }
    { print }
  ' "$REPO_ROOT/install.ps1")

  refute_regex "$code" '(irm|Invoke-RestMethod|Invoke-WebRequest)[^|]*\|[[:space:]]*(iex|Invoke-Expression)'
  refute_regex "$code" 'install\.microsandbox\.dev'
}

@test "windows installer: installs a checksum-verified zip under LOCALAPPDATA" {
  installer=$(cat "$REPO_ROOT/install.ps1")

  assert_regex "$installer" 'acq-windows-x64\.zip'
  assert_regex "$installer" 'LOCALAPPDATA.*Programs\\acq'
  assert_regex "$installer" 'Expand-Archive'
  assert_regex "$installer" 'py-acq\\runtime\\python\.exe'
}

# acq.cmd starts acq.ps1, whose default (Python) branch needs py-acq\src; its
# ACQ_IMPL=bash branch runs the Bash `acq`, which sources acq.backends\common.sh
# before anything else. A zip missing any of them must fail closed, as in
# install.sh.
@test "windows installer: gates the launchers, the backend tree and the source" {
  installer=$(cat "$REPO_ROOT/install.ps1")

  assert_regex "$installer" '"acq\.ps1", "acq", "acq\.backends\\common\.sh", "py-acq\\src\\acq_py\\__init__\.py"'
  assert_regex "$installer" 'throw "release archive is missing \$required\."'
}

@test "windows installer: requires provenance from URL and offline sources before extraction" {
  local installer check_line extract_line
  installer=$(cat "$REPO_ROOT/install.ps1")

  grep -qF '$ProvenanceName = "provenance.json"' "$REPO_ROOT/install.ps1"
  grep -qF '$provenancePath = Join-Path $tmpRoot $ProvenanceName' "$REPO_ROOT/install.ps1"
  grep -qF 'Invoke-WebRequest -Uri "$($resolved.Url)/$ProvenanceName" -OutFile $provenancePath' "$REPO_ROOT/install.ps1"
  grep -qF 'throw "could not download $($resolved.Url)/$ProvenanceName"' "$REPO_ROOT/install.ps1"
  grep -qF 'Test-Path -LiteralPath (Join-Path $resolved.Url $ProvenanceName) -PathType Leaf' "$REPO_ROOT/install.ps1"
  grep -qF 'throw "offline asset set at $($resolved.Url) has no $ProvenanceName"' "$REPO_ROOT/install.ps1"
  grep -qF 'Copy-Item -LiteralPath (Join-Path $resolved.Url $ProvenanceName) -Destination $provenancePath' "$REPO_ROOT/install.ps1"
  grep -qF 'Test-Path -LiteralPath $provenancePath -PathType Leaf' "$REPO_ROOT/install.ps1"
  grep -qF 'throw "release is missing the provenance manifest ($ProvenanceName)"' "$REPO_ROOT/install.ps1"
  # Like install.sh, the manifest is verified against its SHA256SUMS entry
  # before extraction; keep the two installers' verification scope equal.
  assert_regex "$installer" 'Get-ExpectedHash -SumsPath \$sumsPath -Name \$ProvenanceName'
  assert_regex "$installer" 'Get-FileHash -Algorithm SHA256 -LiteralPath \$provenancePath'
  assert_regex "$installer" 'checksum mismatch for \$ProvenanceName'
  check_line=$(grep -nF 'throw "release is missing the provenance manifest' "$REPO_ROOT/install.ps1" | cut -d: -f1)
  extract_line=$(grep -nF 'Expand-Archive -LiteralPath $zipPath' "$REPO_ROOT/install.ps1" | cut -d: -f1)
  [ -n "$check_line" ] && [ -n "$extract_line" ] && [ "$check_line" -lt "$extract_line" ]
}

@test "windows installer: requires a wheelhouse directory before publishing" {
  local check_line publish_line
  grep -qF 'Test-Path -LiteralPath (Join-Path $sourceDir "wheelhouse") -PathType Container' "$REPO_ROOT/install.ps1"
  grep -qF 'throw "release archive is missing the dependency wheelhouse (wheelhouse/)"' "$REPO_ROOT/install.ps1"
  check_line=$(grep -nF 'throw "release archive is missing the dependency wheelhouse' "$REPO_ROOT/install.ps1" | cut -d: -f1)
  publish_line=$(grep -nF 'New-Item -ItemType Directory -Force -Path $InstallDir' "$REPO_ROOT/install.ps1" | cut -d: -f1)
  [ -n "$check_line" ] && [ -n "$publish_line" ] && [ "$check_line" -lt "$publish_line" ]
}

@test "windows installer: stages provenance before enumerating owned release names" {
  local copy_line entries_line marker_line
  copy_line=$(grep -nF 'Copy-Item -LiteralPath $provenancePath -Destination (Join-Path $sourceDir $ProvenanceName) -Force' "$REPO_ROOT/install.ps1" | cut -d: -f1)
  entries_line=$(grep -nF '$entries = @(Get-ChildItem -LiteralPath $sourceDir -Force)' "$REPO_ROOT/install.ps1" | cut -d: -f1)
  marker_line=$(grep -nF 'Set-Content -LiteralPath $markerPath' "$REPO_ROOT/install.ps1" | cut -d: -f1)
  [ -n "$copy_line" ] && [ -n "$entries_line" ] && [ -n "$marker_line" ]
  [ "$copy_line" -lt "$entries_line" ] && [ "$entries_line" -lt "$marker_line" ]
  grep -qF '$names = @($owned) + @($entries | ForEach-Object { $_.Name })' "$REPO_ROOT/install.ps1"
  grep -qF 'Move-Item -LiteralPath $entry.FullName -Destination $target' "$REPO_ROOT/install.ps1"
}

@test "windows installer: dry-run describes provenance and the complete enumerated set" {
  local plan
  plan=$(sed -n '/^    if (\$DryRun) {/,/^        return/p' "$REPO_ROOT/install.ps1")
  grep -qF '[dry-run] download $($resolved.Url)/$SumsName, $($resolved.Url)/$ProvenanceName and $($resolved.Url)/$PackageName' <<< "$plan"
  grep -qF '[dry-run] read $($resolved.Url)/$SumsName, $($resolved.Url)/$ProvenanceName and $($resolved.Url)/$PackageName from the offline asset set' <<< "$plan"
  grep -qF 'require the provenance manifest ($ProvenanceName)' <<< "$plan"
  grep -qF 'launchers, backend tree, runtime, source, wheelhouse' <<< "$plan"
  grep -qF 'install $ProvenanceName into $InstallDir and record it in .acq-v1-install' <<< "$plan"
}

@test "windows PowerShell: installer -Help and -DryRun execute when pwsh is available" {
  command -v pwsh >/dev/null 2>&1 || skip "pwsh not available"

  run pwsh -NoLogo -NoProfile -File "$REPO_ROOT/install.ps1" -Help
  assert_success
  assert_output --partial 'install.ps1 - install acq'

  run pwsh -NoLogo -NoProfile -File "$REPO_ROOT/install.ps1" -DryRun
  assert_success
  assert_output --partial '[dry-run]'
  assert_output --partial '/provenance.json'
  assert_output --partial 'require the provenance manifest (provenance.json)'
  assert_output --partial 'launchers, backend tree, runtime, source, wheelhouse'
  assert_output --partial 'install provenance.json into'
  assert_output --partial 'record it in .acq-v1-install'

  run pwsh -NoLogo -NoProfile -File "$REPO_ROOT/install.ps1" -DryRun -Source 'offline-assets'
  assert_success
  assert_output --partial '[dry-run] read offline-assets/SHA256SUMS, offline-assets/provenance.json and offline-assets/acq-windows-x64.zip from the offline asset set'
  refute_output --partial '[dry-run] download'
}

@test "windows PowerShell: installer parses when pwsh is available" {
  command -v pwsh >/dev/null 2>&1 || skip "pwsh not available"

  if command -v cygpath >/dev/null 2>&1; then
    repo_root_win=$(cygpath -w "$REPO_ROOT")
  else
    repo_root_win="$REPO_ROOT"
  fi

  run pwsh -NoLogo -NoProfile -Command '
    $tokens = $null
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile(
      (Join-Path "'"$repo_root_win"'" "install.ps1"),
      [ref]$tokens,
      [ref]$errors
    )
    if ($errors.Count) {
      $errors | ForEach-Object { $_.ToString() }
      exit 1
    }
  '
  assert_success
}

@test "windows PowerShell: acq.ps1 parses when pwsh is available" {
  command -v pwsh >/dev/null 2>&1 || skip "pwsh not available"

  if command -v cygpath >/dev/null 2>&1; then
    repo_root_win=$(cygpath -w "$REPO_ROOT")
  else
    repo_root_win="$REPO_ROOT"
  fi

  run pwsh -NoLogo -NoProfile -Command '
    $tokens = $null
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile(
      (Join-Path "'"$repo_root_win"'" "acq.ps1"),
      [ref]$tokens,
      [ref]$errors
    )
    if ($errors.Count) {
      $errors | ForEach-Object { $_.ToString() }
      exit 1
    }
  '
  assert_success
}

# The Bash acq rejects any ACQ_IMPL but the exact strings bash and python, so
# the launcher must not let PowerShell's case-insensitive -ne/-eq accept
# PYTHON or Bash. The check runs before anything Windows-specific, so pwsh on
# any host exercises it.
@test "windows launcher: ACQ_IMPL is compared case-sensitively" {
  launcher=$(cat "$REPO_ROOT/acq.ps1")
  refute_regex "$launcher" '\$acqImpl -(ne|eq|ieq|ine) '
  assert_regex "$launcher" '\$acqImpl -cne "bash"'
  assert_regex "$launcher" '\$acqImpl -cne "python"'

  command -v pwsh >/dev/null 2>&1 || return 0
  local impl
  for impl in PYTHON Python BASH Bash; do
    run env ACQ_IMPL="$impl" pwsh -NoLogo -NoProfile -File "$REPO_ROOT/acq.ps1" version
    assert_failure 2
    assert_output --partial "unsupported ACQ_IMPL '$impl'"
  done
}

# On Windows an unset ACQ_IMPL selects the Python implementation (ADR-0048m),
# never the Bash one. The selection and the interpreter checks that come before
# any Windows-only step run under pwsh on any host: a relative ACQ_RUNTIME is
# refused, and with no managed runtime and no drive-rooted PATH entry the
# launcher fails closed with the remedies instead of starting Bash.
@test "windows launcher: an unset ACQ_IMPL selects the Python implementation" {
  launcher=$(cat "$REPO_ROOT/acq.ps1")
  assert_regex "$launcher" 'if \(-not \$acqImpl\) \{'
  assert_regex "$launcher" 'set ACQ_IMPL=bash to use the Bash implementation through Git Bash'

  command -v pwsh >/dev/null 2>&1 || return 0
  [ ! -e "$REPO_ROOT/py-acq/runtime" ] || skip "a managed runtime is staged in this checkout"
  local pwsh_bin launcher_path="$REPO_ROOT/acq.ps1" no_python_path="/nonexistent-acq-bin"
  pwsh_bin=$(command -v pwsh)
  if command -v cygpath >/dev/null 2>&1; then
    launcher_path=$(cygpath -w "$launcher_path")
    no_python_path="$(cygpath -u "${SYSTEMROOT:-C:\Windows}")/System32"
  fi

  run env -u ACQ_IMPL ACQ_RUNTIME='python.exe' "$pwsh_bin" -NoLogo -NoProfile -File "$launcher_path" version
  assert_failure 1
  assert_output --partial "ACQ_RUNTIME must be an absolute path to python.exe, got 'python.exe'"

  run env -u ACQ_IMPL -u ACQ_RUNTIME PATH="$no_python_path" "$pwsh_bin" -NoLogo -NoProfile -File "$launcher_path" version
  assert_failure 1
  assert_output --partial 'no Python 3.12 or newer was found to run acq'
  assert_output --partial 'set ACQ_IMPL=bash'
  refute_output --partial 'patterns kit ref'
}

# Run inside the caller's PowerShell session (`& .\acq.ps1`), acq.ps1 shares
# its environment; the variables it sets for the programs it starts must be put
# back when it returns. NoDefaultCurrentDirectoryInExePath is set before the
# ACQ_IMPL check, so pwsh on any host exercises the restore.
@test "windows launcher: acq.ps1 run in a session puts its environment changes back" {
  launcher=$(cat "$REPO_ROOT/acq.ps1")
  assert_regex "$launcher" "foreach \\(\\\$name in @\\('NoDefaultCurrentDirectoryInExePath', 'PYTHONPATH', 'ACQ_PROVIDER_INPUT_DATA_DIR'\\)\\)"

  command -v pwsh >/dev/null 2>&1 || return 0
  # pwsh needs a Windows path under Git Bash; an MSYS /d/... path is not a script it can find.
  local launcher_path="$REPO_ROOT/acq.ps1"
  if command -v cygpath >/dev/null 2>&1; then
    launcher_path=$(cygpath -w "$launcher_path")
  fi
  run env ACQ_IMPL=bogus pwsh -NoLogo -NoProfile -NonInteractive -Command "
    \$env:NoDefaultCurrentDirectoryInExePath = 'kept'
    \$env:PYTHONPATH = 'kept-too'
    & '$launcher_path' version
    Write-Output (\"AFTER code=\$LASTEXITCODE nodefault=\$env:NoDefaultCurrentDirectoryInExePath pythonpath=\$env:PYTHONPATH\")
  "
  assert_output --partial "unsupported ACQ_IMPL 'bogus'"
  assert_output --partial "AFTER code=2 nodefault=kept pythonpath=kept-too"
}

# acq.ps1 reads its arguments from its own command line only when it sees the
# exact shape acq.cmd starts it with; the two files must agree on that shape.
@test "windows launcher: acq.cmd starts acq.ps1 in the shape acq.ps1 recognises" {
  cmd=$(cat "$REPO_ROOT/acq.cmd")
  launcher=$(cat "$REPO_ROOT/acq.ps1")
  assert_regex "$cmd" '"%ACQ_POWERSHELL%" -NoLogo -NoProfile -File "%ACQ_PS1%" %\*'
  assert_regex "$launcher" "\\\$argv\\[1\\] -cne '-NoLogo' -or \\\$argv\\[2\\] -cne '-NoProfile' -or \\\$argv\\[3\\] -cne '-File'"
}

# Windows PowerShell 5.1's call operator drops an empty argument and leaves an
# embedded double quote unescaped, so the Bash branch (which still uses it)
# must refuse such an argument with exit 2 rather than run a changed command.
@test "windows launcher: the Bash branch refuses arguments legacy passing would change" {
  launcher=$(cat "$REPO_ROOT/acq.ps1")
  assert_regex "$launcher" 'function Test-AcqLegacyNativeArguments'
  assert_regex "$launcher" '\$version\.Major -lt 7 -or \(\$version\.Major -eq 7 -and \$version\.Minor -lt 3\)'
  assert_regex "$launcher" "\\\$text\\.Length -eq 0 -or \\\$text\\.Contains\\('\"'\\)"
  assert_regex "$launcher" 'Set ACQ_IMPL=python, which forwards arguments unchanged'
  # The refusal runs before the call operator starts bash.exe.
  check_line=$(grep -n 'if (Test-AcqLegacyNativeArguments) {' "$REPO_ROOT/acq.ps1" | head -n 1 | cut -d: -f1)
  bash_line=$(grep -n '^& \$bash --noprofile --norc' "$REPO_ROOT/acq.ps1" | head -n 1 | cut -d: -f1)
  [ -n "$check_line" ] && [ -n "$bash_line" ] && [ "$check_line" -lt "$bash_line" ]
}

@test "windows installers: LOCALAPPDATA is used only when fully qualified" {
  installer=$(cat "$REPO_ROOT/install.ps1")
  launcher=$(cat "$REPO_ROOT/acq.ps1")

  assert_regex "$installer" 'function Test-AbsolutePath'
  assert_regex "$installer" 'if \(-not \(Test-AbsolutePath \$base\)\)'
  refute_regex "$installer" 'Join-Path \$env:LOCALAPPDATA'
  assert_regex "$launcher" 'function Test-AcqAbsolutePath'
  assert_regex "$launcher" 'if \(Test-AcqAbsolutePath -Path \$env:LOCALAPPDATA\)'
}

# As install.sh refuses a relative --install-dir, install.ps1 refuses an
# -InstallDir that is not fully qualified, before -DryRun or any write.
@test "windows installer: a relative -InstallDir is refused before anything runs" {
  installer=$(cat "$REPO_ROOT/install.ps1")
  # Bound at all, not merely non-empty: -InstallDir '' is refused too. Under
  # `irm ... | iex` $PSBoundParameters can be $null, so it is checked first.
  local bound_rule unc_rule
  bound_rule='$installDirGiven = ($null -ne $PSBoundParameters -and $PSBoundParameters.ContainsKey('\''InstallDir'\'')) -or $InstallDir'
  grep -qF -- "$bound_rule" "$REPO_ROOT/install.ps1"
  grep -qF -- 'if ($installDirGiven -and -not (Test-AbsolutePath $InstallDir))' "$REPO_ROOT/install.ps1"
  # No unguarded use of $PSBoundParameters.
  [ "$(grep -c 'PSBoundParameters\.ContainsKey' "$REPO_ROOT/install.ps1")" = 1 ]
  # A UNC path needs a share after the server.
  unc_rule='($Path -match '\''^[\\/]{2}[^\\/]+[\\/][^\\/]'\'')'
  grep -qF -- "$unc_rule" "$REPO_ROOT/install.ps1"
  assert_regex "$installer" '-InstallDir must be an absolute path, got .\$\(Format-Shown \$InstallDir\).'
  # The check sits before the -DryRun branch, so a dry run refuses it too.
  check_line=$(grep -n 'Test-AbsolutePath \$InstallDir' "$REPO_ROOT/install.ps1" | head -n 1 | cut -d: -f1)
  dryrun_line=$(grep -n '^if (\$DryRun) {' "$REPO_ROOT/install.ps1" | head -n 1 | cut -d: -f1)
  [ -n "$check_line" ] && [ -n "$dryrun_line" ] && [ "$check_line" -lt "$dryrun_line" ]
}

@test "windows PowerShell: a relative -InstallDir is refused when pwsh is available" {
  command -v pwsh >/dev/null 2>&1 || skip "pwsh not available"
  mkdir -p "$STUBDIR/work"
  cd "$STUBDIR/work" || return 1

  local rel installer="$REPO_ROOT/install.ps1"
  # MSYS2_ARG_CONV_EXCL below stops Git Bash rewriting every argument, the
  # script path included, so pass pwsh the script's Windows path explicitly.
  if command -v cygpath >/dev/null 2>&1; then
    installer=$(cygpath -w "$installer")
  fi
  # An empty value and a UNC server with no share are refused like a relative one.
  # MSYS2_ARG_CONV_EXCL keeps Git Bash from rewriting the //server argument.
  for rel in rel-inst 'C:rel-inst' '\rel-inst' '' '\\server' '\\server\' '//server'; do
    MSYS2_ARG_CONV_EXCL='*' run pwsh -NoLogo -NoProfile -File "$installer" -DryRun -InstallDir "$rel"
    assert_failure 1
    assert_output --partial "-InstallDir must be an absolute path, got '$rel'"
    refute_output --partial '[dry-run]'
  done
  # The refused value is echoed with control characters replaced.
  run pwsh -NoLogo -NoProfile -File "$installer" -DryRun -InstallDir $'rel\033]0;t\007x'
  assert_failure 1
  assert_output --partial "got 'rel?]0;t?x'"
  refute_output --partial $'\033'
  # A fully qualified -InstallDir is accepted.
  run pwsh -NoLogo -NoProfile -File "$installer" -DryRun -InstallDir 'C:\acq-test'
  assert_success
  assert_output --partial 'install dir: C:\acq-test'
  MSYS2_ARG_CONV_EXCL='*' run pwsh -NoLogo -NoProfile -File "$installer" -DryRun -InstallDir '\\server\share\acq'
  assert_success
  assert_output --partial 'install dir: \\server\share\acq'
  run ls -A "$STUBDIR/work"
  assert_output ''
}

@test "windows PowerShell: a relative LOCALAPPDATA never names the install dir" {
  command -v pwsh >/dev/null 2>&1 || skip "pwsh not available"
  mkdir -p "$STUBDIR/work"
  cd "$STUBDIR/work" || return 1

  run env LOCALAPPDATA=rel-local pwsh -NoLogo -NoProfile -File "$REPO_ROOT/install.ps1" -DryRun
  assert_success
  assert_output --partial '[dry-run]'
  refute_output --partial 'rel-local'
}

@test "windows installer: SHA256SUMS pin is strict and checked before reading entries" {
  local installer pin_line read_line
  installer=$(cat "$REPO_ROOT/install.ps1")
  assert_regex "$installer" '\[string\]\$Sha256'
  grep -qF "\\A[0-9a-fA-F]{64}\\z" "$REPO_ROOT/install.ps1"
  assert_regex "$installer" '\$sumsActual -ine \$Sha256'
  pin_line=$(grep -n 'if (\$sumsActual -ine' "$REPO_ROOT/install.ps1" | cut -d: -f1)
  read_line=$(grep -n '\$expected = Get-ExpectedHash' "$REPO_ROOT/install.ps1" | cut -d: -f1)
  [ "$pin_line" -lt "$read_line" ]
  command -v pwsh >/dev/null 2>&1 || return 0
  run pwsh -NoProfile -File "$REPO_ROOT/install.ps1" -Sha256 invalid -DryRun
  assert_failure 2
}

@test "windows installer: attestation uses PATH gh and fails closed except absence" {
  local installer
  installer=$(cat "$REPO_ROOT/install.ps1")
  assert_regex "$installer" 'Get-Command gh -CommandType Application'
  assert_regex "$installer" "'attestation', 'verify'"
  assert_regex "$installer" 'verified attestation'
  assert_regex "$installer" 'attestation absent'
  assert_regex "$installer" 'throw "attestation verification failed'
  # An old gh without the subcommand is "no verifier"; success needs gh's own line.
  assert_regex "$installer" "'attestation', 'verify', '--help'"
  assert_regex "$installer" "-cmatch 'Verification succeeded'"
  assert_regex "$installer" 'ACQ_INSTALL_NO_ATTESTATION'
  assert_regex "$installer" '\$NoAttestation.*-not \$Resolved.IsUrl'
}

@test "windows installer: prerequisites probe WHP capability and never use DISM state" {
  local installer
  installer=$(cat "$REPO_ROOT/install.ps1")
  assert_regex "$installer" 'WHvGetCapability'
  assert_regex "$installer" 'WHvCapabilityCodeHypervisorPresent = 0'
  assert_regex "$installer" '\$result -eq 0 -and \$written -ge 4 -and \$present -ne 0'
  refute_regex "$installer" 'Get-WindowsOptionalFeature|dism.exe'
  assert_regex "$installer" '-not \$Yes -and -not \[Console\]::IsInputRedirected'
  assert_regex "$installer" '-not \$DryRun -and -not \$NoPrereqCheck'
  assert_regex "$installer" 'see docs/howto/msb.md'
  # The pinned msb digest is embedded, never read from a downloaded checksum file.
  assert_regex "$installer" "\\\$expected = 'ae526aa2d7bfc230a6e9149d2b7483ac0992462c221a8add85d1429a005575e0'"
  refute_regex "$installer" 'checksums\.sha256"? -OutFile'
  # Consent is refused, not crashed, when the host cannot prompt.
  assert_regex "$installer" '\[Environment\]::UserInteractive'
  assert_regex "$installer" 'catch \{ return \$false \}'
  assert_regex "$installer" 'msb doctor --fix'
  assert_regex "$installer" 'Get-Command git -CommandType Application'
  assert_regex "$installer" 'Get-Command sbx -CommandType Application'
}
