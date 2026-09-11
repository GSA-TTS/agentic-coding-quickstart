#!/usr/bin/env bats

load './helper.bash'

setup() {
  acq_setup_stubs
}

teardown() {
  acq_teardown_stubs
}

@test "windows installer: release version marker stays in sync with install.sh" {
  sh_version=$(sed -n 's/^DEFAULT_RELEASE_VERSION="\([^"]*\)".*/\1/p' "$REPO_ROOT/install.sh")
  ps_version=$(sed -n 's/^    \[string\]\$Version = "\([^"]*\)".*/\1/p' "$REPO_ROOT/install.ps1")

  assert_equal "$ps_version" "$sh_version"
}

@test "windows PowerShell: installer help and dry-run execute when pwsh is available" {
  command -v pwsh >/dev/null 2>&1 || skip "pwsh not available"

  run pwsh -NoLogo -NoProfile -File "$REPO_ROOT/install.ps1" -Help
  assert_success
  assert_output --partial 'install.ps1 - install acq for Windows preview hosts'

  run pwsh -NoLogo -NoProfile -File "$REPO_ROOT/install.ps1" -DryRun -NoMsb -NoPath
  assert_success
  assert_output --partial '[dry-run] check host is Windows'
  assert_output --partial '[dry-run] download'
}

@test "windows PowerShell: launcher and installer parse when pwsh is available" {
  command -v pwsh >/dev/null 2>&1 || skip "pwsh not available"

  run pwsh -NoLogo -NoProfile -Command '
    foreach ($file in @("install.ps1", "acq.ps1")) {
      $tokens = $null
      $errors = $null
      $null = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path "'"$REPO_ROOT"'" $file),
        [ref]$tokens,
        [ref]$errors
      )
      if ($errors.Count) {
        $errors | ForEach-Object { $_.ToString() }
        exit 1
      }
    }
  '
  assert_success
}

@test "windows installer: does not enable WHP or elevate" {
  run grep -E 'Enable-WindowsOptionalFeature|Start-Process.*-Verb RunAs|Restart-Computer' \
    "$REPO_ROOT/install.ps1"

  assert_failure
}

@test "windows installer: verifies WHP before install" {
  installer=$(cat "$REPO_ROOT/install.ps1")

  assert_regex "$installer" 'Assert-WhpEnabled'
  assert_regex "$installer" 'HypervisorPlatform'
  assert_regex "$installer" 'Windows Hypervisor Platform is not enabled'
}

@test "windows installer: installs Git for Windows via WinGet" {
  installer=$(cat "$REPO_ROOT/install.ps1")

  assert_regex "$installer" 'Install-WinGetPackage -Id "Git\.Git" -Name "Git for Windows"'
  assert_regex "$installer" 'winget install --id \$Id --exact'
}

@test "windows installer: msb package id is configurable" {
  installer=$(cat "$REPO_ROOT/install.ps1")

  assert_regex "$installer" '\$MsbPackageId = \$env:ACQ_MSB_WINGET_ID'
  assert_regex "$installer" 'irm https://install\.microsandbox\.dev/windows \| iex'
}

@test "windows installer: installed layout includes Windows launcher files" {
  installer=$(cat "$REPO_ROOT/install.ps1")

  assert_regex "$installer" '"acq", "acq\.backends", "acq\.cmd", "acq\.ps1", "install\.ps1"'
}

@test "windows launcher: converts Windows paths before Git Bash handoff" {
  launcher=$(cat "$REPO_ROOT/acq.ps1")

  assert_regex "$launcher" 'Find-GitBash'
  assert_regex "$launcher" 'Convert-ArgumentForGitBash'
  assert_regex "$launcher" 'if \(\$Argument -match.*\[A-Za-z\]:'
  assert_regex "$launcher" 'function Test-IsUncPath'
  assert_regex "$launcher" 'return \$slash \+ \$slash'
  assert_regex "$launcher" 'TrimStart\(\[char\]92\)'
  assert_regex "$launcher" 'Test-IsUncPath -Path \$Matches\[2\]'
  refute_regex "$launcher" 'MSYS2_ARG_CONV_EXCL = "\*"'
  assert_regex "$launcher" '& \$bash --noprofile --norc \$bashAcq @convertedArgs'
}

@test "windows cmd shim: delegates to PowerShell launcher without policy bypass" {
  shim=$(cat "$REPO_ROOT/acq.cmd")

  assert_regex "$shim" 'powershell\.exe -NoLogo -NoProfile -File "%ACQ_PS1%" %\*'
  refute_regex "$shim" 'ExecutionPolicy Bypass'
}

@test "release workflow: publishes Windows preview assets" {
  workflow=$(cat "$REPO_ROOT/.github/workflows/release.yml")

  assert_regex "$workflow" 'acq-windows-x64\.zip'
  assert_regex "$workflow" 'cp install\.ps1 dist/install\.ps1'
  assert_regex "$workflow" 'cp acq acq\.cmd acq\.ps1 install\.ps1 LICENSE README\.md package\.json'
  assert_regex "$workflow" 'sha256sum install\.sh install\.ps1 acq-windows-x64\.zip > SHA256SUMS'
  assert_regex "$workflow" 'dist/acq-windows-x64\.zip'
}
