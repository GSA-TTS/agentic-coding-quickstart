"""Windows-native preview ownership and recovery at installer function seams.

Linux PowerShell can parse these paths but cannot prove Windows filesystem,
reparse-point or Windows PowerShell 5.1 argument behavior.
"""
from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
import zipfile
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
pytestmark = pytest.mark.skipif(sys.platform != "win32", reason="native Windows installer filesystem required")


def _ps(tmp_path, code):
    script = tmp_path / "case.ps1"
    installer = str(ROOT / "install.ps1").replace("'", "''")
    script.write_text(f"""
$ErrorActionPreference = 'Stop'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile('{installer}',[ref]$tokens,[ref]$errors)
if ($errors.Count) {{ throw 'installer parse failed' }}
# Load only preview functions, not embedded stable functions or top-level install.
foreach ($node in $ast.EndBlock.Statements) {{
 if ($node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ne 'Invoke-StableBashInstall') {{
  . ([scriptblock]::Create($node.Extent.Text))
 }}
}}
{code}
""", encoding="utf-8")
    powershell = Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe"
    return subprocess.run([str(powershell), "-NoLogo", "-NoProfile", "-File", str(script)], capture_output=True, timeout=60)


def _release(tmp_path):
    release = tmp_path / "release"
    release.mkdir()
    archive = release / "acq-windows-x64.zip"
    contents = {
        "acq": b"fake Bash\n", "acq.backends/common.sh": b"fake backend\n",
        "py-acq/runtime/python.exe": b"fake runtime\n",
        "py-acq/src/acq_py/__init__.py": b"", "wheelhouse/placeholder.whl": b"fake wheel\n",
    }
    for name in ("acq.ps1", "acq-python.ps1", "acq-python.cmd"):
        contents[name] = (ROOT / name).read_bytes()
    with zipfile.ZipFile(archive, "w") as z:
        for name, body in contents.items():
            z.writestr(name, body)
    provenance = release / "provenance.json"
    provenance.write_text('{"schema":1,"note":"offline fixture"}')
    (release / "SHA256SUMS").write_text("".join(
        f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n" for p in (archive, provenance)))
    return release


def _variables(root, release):
    def quote(p):
        return str(p).replace("'", "''")
    return f"""
$InstallDir='{quote(root)}'; $Source='{quote(release)}'; $Version='5.0.0-rc.1'
$Channel='python'; $PackageName='acq-windows-x64.zip'; $SumsName='SHA256SUMS'
$ProvenanceName='provenance.json'; $RuntimeRelative='py-acq\\runtime\\python.exe'
$LauncherRelative='acq-python.cmd'; $NoAttestation=$true; $DryRun=$false
$RemovePreview=$false; $sha256Given=$false
"""


def test_windows_preview_unknown_and_modified_files_survive_backout(tmp_path):
    release = _release(tmp_path)
    root = tmp_path / "preview"
    code = _variables(root, release) + """
Test-PreviewOwnership; Install-AcqZip
Set-Content (Join-Path $InstallDir 'unknown.txt') 'keep'
Test-PreviewOwnership; Install-AcqZip
Set-Content (Join-Path $InstallDir 'acq-python.ps1') 'modified'
$RemovePreview=$true; Test-PreviewOwnership
foreach ($file in $previewFiles) {
 $target=Join-Path $InstallDir $file.path
 if ((Test-Path -LiteralPath $target -PathType Leaf) -and (Get-FileHash $target -Algorithm SHA256).Hash -ceq $file.sha256) { Remove-Item -LiteralPath $target }
}
"""
    result = _ps(tmp_path, code)
    assert result.returncode == 0, result.stderr.decode(errors="replace")
    assert (root / "unknown.txt").read_text().strip() == "keep"
    assert (root / "acq-python.ps1").read_text().strip() == "modified"
    assert not (root / "bin/acq-python.cmd").exists()


def test_windows_preview_failed_owned_publication_restores_receipt(tmp_path):
    release = _release(tmp_path)
    root = tmp_path / "preview"
    code = _variables(root, release) + """
Test-PreviewOwnership; Install-AcqZip
$before=Get-Content $previewReceiptPath -Raw
Set-Content (Join-Path $InstallDir 'unknown.txt') 'keep'
function Move-Item {
 param([string]$LiteralPath,[string]$Destination)
 if ((Split-Path -Leaf $LiteralPath) -like '.acq-python-preview-stage-*') { throw 'injected publish failure' }
 Microsoft.PowerShell.Management\\Move-Item -LiteralPath $LiteralPath -Destination $Destination
}
try { Test-PreviewOwnership; Install-AcqZip; throw 'missing expected failure' }
catch { if ($_.Exception.Message -notlike '*injected publish failure*') { throw } }
if ((Get-Content $previewReceiptPath -Raw) -cne $before) { throw 'receipt changed' }
if ((Get-Content (Join-Path $InstallDir 'unknown.txt')).Trim() -ne 'keep') { throw 'unknown file changed' }
"""
    result = _ps(tmp_path, code)
    assert result.returncode == 0, result.stderr.decode(errors="replace")


def test_windows_preview_backup_only_recovery(tmp_path):
    release = _release(tmp_path)
    root = tmp_path / "preview"
    code = _variables(root, release) + """
Test-PreviewOwnership; Install-AcqZip
Set-Content (Join-Path $InstallDir 'unknown.txt') 'keep'
Move-Item -LiteralPath $InstallDir -Destination $previewBackup
Test-PreviewOwnership; Install-AcqZip
if (Test-Path $previewBackup) { throw 'backup remains' }
if ((Get-Content (Join-Path $InstallDir 'unknown.txt')).Trim() -ne 'keep') { throw 'unknown file lost' }
"""
    result = _ps(tmp_path, code)
    assert result.returncode == 0, result.stderr.decode(errors="replace")


def test_windows_preview_unproven_backup_refused_without_restore(tmp_path):
    release = _release(tmp_path)
    root = tmp_path / "preview"
    backup = Path(str(root) + ".acq-python-preview-previous")
    backup.mkdir()
    (backup / ".acq-python-preview-receipt.json").write_text(json.dumps({"channel":"bash","root":str(root)}))
    result = _ps(tmp_path, _variables(root, release) + "Test-PreviewOwnership")
    assert result.returncode != 0
    assert backup.exists() and not root.exists()


def test_windows_preview_foreign_command_refused_before_install(tmp_path):
    release = _release(tmp_path)
    root = tmp_path / "preview"
    code = _variables(root, release) + """
Test-PreviewOwnership; Install-AcqZip
$receipt=Get-Content $previewReceiptPath -Raw | ConvertFrom-Json
$receipt.files=@($receipt.files | Where-Object { $_.path -cne 'bin\\acq-python.cmd' })
if ($receipt.files.path -contains 'bin\\acq-python.cmd') { throw 'receipt entry was not removed' }
$receipt | ConvertTo-Json -Depth 5 | Set-Content $previewReceiptPath
try { Test-PreviewOwnership; throw 'missing expected refusal' }
catch { if ($_.Exception.Message -notlike '*foreign preview command*') { throw } }
"""
    result = _ps(tmp_path, code)
    assert result.returncode == 0, result.stderr.decode(errors="replace")


def test_windows_preview_archive_cannot_supply_ordinary_command_bin(tmp_path):
    release = _release(tmp_path)
    root = tmp_path / "preview"
    archive = release / "acq-windows-x64.zip"
    with zipfile.ZipFile(archive, "a") as z:
        z.writestr("bin/acq.cmd", "foreign ordinary command")
    provenance = release / "provenance.json"
    (release / "SHA256SUMS").write_text("".join(f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n" for p in (archive, provenance)))
    result = _ps(tmp_path, _variables(root, release) + "Test-PreviewOwnership; Install-AcqZip")
    assert result.returncode != 0 and b"must not supply bin" in result.stderr
    assert not root.exists()


def test_windows_preview_trailing_separator_reinstall_and_backout_identity(tmp_path):
    release = _release(tmp_path)
    root = tmp_path / "preview"
    code = _variables(root, release) + """
$InstallDir=$InstallDir+'\\'
if (-not $InstallDir.EndsWith('\\')) { throw 'separator was not appended' }
Test-PreviewOwnership; Install-AcqZip
$InstallDir=$InstallDir+'\\'
Test-PreviewOwnership; Install-AcqZip
$RemovePreview=$true; Test-PreviewOwnership
if ($previewBackup.StartsWith($InstallDir+'\\')) { throw 'backup is a child' }
foreach ($file in $previewFiles) {
 $target=Join-Path $InstallDir $file.path
 if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ceq $file.sha256) { Remove-Item -LiteralPath $target }
}
if (Test-Path (Join-Path $InstallDir 'bin\\acq-python.cmd')) { throw 'backout did not remove command' }
"""
    result = _ps(tmp_path, code)
    assert result.returncode == 0, result.stderr.decode(errors="replace")
