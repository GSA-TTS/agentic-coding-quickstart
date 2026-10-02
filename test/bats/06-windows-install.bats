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

  # Under Git Bash, $REPO_ROOT is a POSIX path (/c/...); a native Windows pwsh
  # cannot Join-Path that into a readable path. Convert to a Windows path where
  # cygpath exists (Git Bash), else keep the POSIX path (macOS/Linux pwsh).
  if command -v cygpath >/dev/null 2>&1; then
    repo_root_win=$(cygpath -w "$REPO_ROOT")
  else
    repo_root_win="$REPO_ROOT"
  fi

  run pwsh -NoLogo -NoProfile -Command '
    foreach ($file in @("install.ps1", "acq.ps1")) {
      $tokens = $null
      $errors = $null
      $null = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path "'"$repo_root_win"'" $file),
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

@test "windows installer: msb WinGet package id is configurable and version-checked" {
  installer=$(cat "$REPO_ROOT/install.ps1")

  assert_regex "$installer" '\$MsbPackageId = \$env:ACQ_MSB_WINGET_ID'
  # A WinGet package's version is outside our control, so that path must verify
  # what it got rather than trusting the package.
  assert_regex "$installer" 'Assert-MsbSupported -Context "WinGet installed msb"'
}

@test "windows installer: does not install msb by piping a remote script to iex" {
  # install.ps1 previously ran `irm https://install.microsandbox.dev/windows | iex`
  # with no version check, so a Windows host could land on a blocked release. That
  # installer resolves the version at run time and cannot be pinned, so the only
  # verifiable option is placing the release bundle ourselves.
  #
  # Asserted over CODE only. The URL legitimately survives in guidance text
  # (Write-Host), and acq's OWN documented bootstrap is an `irm ... | iex` inside
  # the usage here-string -- a whole-file regex would match both and prove nothing.
  # Strip the here-string block and the output helpers, then assert on what runs.
  code=$(awk '
    /@"/   { inheredoc = 1 }
    /^"@/  { inheredoc = 0; next }
    inheredoc { next }
    /^[[:space:]]*#/ { next }
    /Write-(Host|Warn|Step|Warning)/ { next }
    { print }
  ' "$REPO_ROOT/install.ps1")

  refute_regex "$code" '(irm|Invoke-RestMethod|Invoke-WebRequest)[^|]*\|[[:space:]]*(iex|Invoke-Expression)'
  refute_regex "$code" 'install\.microsandbox\.dev'
  # What replaced it: the pinned bundle, verified against the release's own
  # checksums before anything is copied into place.
  assert_regex "$code" 'function Install-MsbPinned'
  assert_regex "$code" '\$baseUrl/checksums\.sha256'
  assert_regex "$code" 'SHA-256 verification failed'
  assert_regex "$code" 'Get-FileHash -Algorithm SHA256'
}

@test "windows installer: msb version policy stays in lockstep with install.sh" {
  # Four files carry this policy (install.sh, install.ps1, acq.backends/msb.sh,
  # scripts/verify-msb-pin) because three must run standalone. Drift means Windows
  # accepts an msb the rest of acq refuses, so pin the Windows copy to install.sh's.
  for var in MSB_MIN_VERSION:MsbMinVersion \
             MSB_PINNED_VERSION:MsbPinnedVersion \
             MSB_BLOCKED_VERSION_MIN:MsbBlockedVersionMin \
             MSB_BLOCKED_VERSION_MAX:MsbBlockedVersionMax \
             MSB_FIXED_VERSION:MsbFixedVersion; do
    sh_name=${var%%:*}
    ps_name=${var##*:}
    sh_value=$(sed -n "s/^$sh_name=\"\([^\"]*\)\".*/\1/p" "$REPO_ROOT/install.sh")
    ps_value=$(sed -n "s/^\\\$$ps_name = \"\([^\"]*\)\".*/\1/p" "$REPO_ROOT/install.ps1")

    [ -n "$sh_value" ] || fail "install.sh does not define $sh_name"
    assert_equal "$ps_value" "$sh_value"
  done
}

@test "windows PowerShell: msb version parser preserves suffix policy" {
  command -v pwsh >/dev/null 2>&1 || skip "pwsh not available"

  stub="$BATS_TEST_TMPDIR/msb"
  printf '%s\n' '#!/usr/bin/env sh' 'printf "%s\n" "$MSB_VERSION_OUTPUT"' >"$stub"
  chmod +x "$stub"

  run env MSB_STUB_PATH="$stub" pwsh -NoLogo -NoProfile -Command '
    $script = Get-Content -Raw -LiteralPath "'"$REPO_ROOT"'/install.ps1"
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($script, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { $errors | ForEach-Object { $_.ToString() }; exit 1 }
    foreach ($name in @("Get-MsbVersion", "Test-MsbVersionFinal")) {
      $fn = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
      if ($null -eq $fn) { "missing $name"; exit 1 }
      . ([scriptblock]::Create($fn.Extent.Text))
    }
    $cases = @(
      @{ Output = "msb 0.7.3-rc1"; Parsed = "0.7.3-rc1"; Final = $false },
      @{ Output = "msb 0.7.3+build.1"; Parsed = "0.7.3+build.1"; Final = $false },
      @{ Output = "msb 0.7.3 linux-arm64"; Parsed = "0.7.3"; Final = $true }
    )
    foreach ($case in $cases) {
      $env:MSB_VERSION_OUTPUT = $case.Output
      $parsed = Get-MsbVersion -MsbPath $env:MSB_STUB_PATH
      "parsed=$parsed final=$(Test-MsbVersionFinal -MsbVersion $parsed)"
      if ($parsed -ne $case.Parsed) { "expected parsed=$($case.Parsed)"; exit 1 }
      if ((Test-MsbVersionFinal -MsbVersion $parsed) -ne $case.Final) { "expected final=$($case.Final)"; exit 1 }
    }
  '

  assert_success
  assert_output --partial 'parsed=0.7.3-rc1 final=False'
  assert_output --partial 'parsed=0.7.3+build.1 final=False'
  assert_output --partial 'parsed=0.7.3 final=True'
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

@test "windows launcher and installer: reject the WSL bash shim in favor of Git Bash" {
  for f in "$REPO_ROOT/acq.ps1" "$REPO_ROOT/install.ps1"; do
    script=$(cat "$f")
    assert_regex "$script" 'Test-IsWslShim'
    assert_regex "$script" 'System32\\bash\.exe'
    assert_regex "$script" 'SysWOW64\\bash\.exe'
    assert_regex "$script" 'Test-IsWslShim -Path \$fromPath\.Source'
  done
}

@test "windows installer: probes WHP via the API, not just the feature flag" {
  installer=$(cat "$REPO_ROOT/install.ps1")

  assert_regex "$installer" 'WHvCreatePartition'
  assert_regex "$installer" 'WHvDeletePartition'
  assert_regex "$installer" 'WinHvPlatform\.dll'
  assert_regex "$installer" 'return \$null'
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
