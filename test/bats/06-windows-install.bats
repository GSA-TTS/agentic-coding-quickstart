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
  installer=$(cat "$REPO_ROOT/install.ps1")

  refute_regex "$installer" '(irm|Invoke-RestMethod|Invoke-WebRequest)[^|]*\|[[:space:]]*(iex|Invoke-Expression)'
  refute_regex "$installer" 'install\.microsandbox\.dev'
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
