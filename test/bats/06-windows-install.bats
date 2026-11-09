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
  run grep -E 'Enable-WindowsOptionalFeature|Start-Process.*-Verb RunAs|Restart-Computer' \
    "$REPO_ROOT/install.ps1"
  assert_failure
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

@test "windows PowerShell: installer -Help and -DryRun execute when pwsh is available" {
  command -v pwsh >/dev/null 2>&1 || skip "pwsh not available"

  run pwsh -NoLogo -NoProfile -File "$REPO_ROOT/install.ps1" -Help
  assert_success
  assert_output --partial 'install.ps1 - install acq'

  run pwsh -NoLogo -NoProfile -File "$REPO_ROOT/install.ps1" -DryRun
  assert_success
  assert_output --partial '[dry-run]'
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

# acq.ps1 reads its arguments from its own command line only when it sees the
# exact shape acq.cmd starts it with; the two files must agree on that shape.
@test "windows launcher: acq.cmd starts acq.ps1 in the shape acq.ps1 recognises" {
  cmd=$(cat "$REPO_ROOT/acq.cmd")
  launcher=$(cat "$REPO_ROOT/acq.ps1")
  assert_regex "$cmd" '"%ACQ_POWERSHELL%" -NoLogo -NoProfile -File "%ACQ_PS1%" %\*'
  assert_regex "$launcher" "\\\$argv\\[1\\] -cne '-NoLogo' -or \\\$argv\\[2\\] -cne '-NoProfile' -or \\\$argv\\[3\\] -cne '-File'"
}

@test "windows installers: LOCALAPPDATA is used only when fully qualified" {
  installer=$(cat "$REPO_ROOT/install.ps1")
  launcher=$(cat "$REPO_ROOT/acq.ps1")

  assert_regex "$installer" 'function Test-AbsolutePath'
  assert_regex "$installer" 'if \(-not \(Test-AbsolutePath \$base\)\)'
  refute_regex "$installer" 'Join-Path \$env:LOCALAPPDATA'
  assert_regex "$launcher" 'if \(\$env:LOCALAPPDATA -match '
}

# As install.sh refuses a relative --install-dir, install.ps1 refuses an
# -InstallDir that is not fully qualified, before -DryRun or any write.
@test "windows installer: a relative -InstallDir is refused before anything runs" {
  installer=$(cat "$REPO_ROOT/install.ps1")
  assert_regex "$installer" 'if \(\$InstallDir -and -not \(Test-AbsolutePath \$InstallDir\)\)'
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

  local rel
  for rel in rel-inst 'C:rel-inst' '\rel-inst'; do
    run pwsh -NoLogo -NoProfile -File "$REPO_ROOT/install.ps1" -DryRun -InstallDir "$rel"
    assert_failure 1
    assert_output --partial "-InstallDir must be an absolute path, got '$rel'"
    refute_output --partial '[dry-run]'
  done
  # The refused value is echoed with control characters replaced.
  run pwsh -NoLogo -NoProfile -File "$REPO_ROOT/install.ps1" -DryRun -InstallDir $'rel\033]0;t\007x'
  assert_failure 1
  assert_output --partial "got 'rel?]0;t?x'"
  refute_output --partial $'\033'
  # A fully qualified -InstallDir is accepted.
  run pwsh -NoLogo -NoProfile -File "$REPO_ROOT/install.ps1" -DryRun -InstallDir 'C:\acq-test'
  assert_success
  assert_output --partial 'install dir: C:\acq-test'
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
