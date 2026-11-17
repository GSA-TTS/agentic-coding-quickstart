"""Delegate POSIX removal to the offline recovery engine before migration."""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

from .. import errors, hostexec
from . import common


def recovery_script() -> Path:
    """Resolve release-packaged recovery or the trusted source checkout."""
    package = Path(__file__).resolve().parent.parent
    packaged = package / "uninstall.command"
    root = package.parents[2]
    if (package == root / "py-acq" / "src" / "acq_py"
            and (root / "py-acq/pyproject.toml").is_file()
            and (root / "scripts/run-uninstaller").is_file()):
        return root / "scripts/run-uninstaller"
    return packaged


def run_uninstall(parsed, emit_json: bool, backend_override: str | None) -> int:
    """Never resolve a backend, migrate state, install, or download a runtime."""
    if os.name == "nt":
        return common._operational_failure(
            "uninstall", errors.UNSUPPORTED, "Guided uninstall supports macOS/Linux only.",
            "Use the platform's manual removal procedure; no files were removed.", emit_json,
        )
    if emit_json or backend_override is not None:
        return common._usage_failure("uninstall", "Use uninstall without --json or --backend.", emit_json)
    script = recovery_script()
    if not script.is_file():
        return common._operational_failure(
            "uninstall", errors.FAILURE, "Offline recovery script is missing.",
            "Download uninstall.command from the release assets.", False,
        )
    args = [*hostexec.command("bash"), str(script)]
    if parsed.dry_run:
        args.append("--dry-run")
    if parsed.yes:
        args.append("--yes")
    if parsed.confirm_no_sbx_sandboxes:
        args.append("--confirm-no-sbx-sandboxes")
    # Foreground output and terminal prompts belong to the shared wizard.
    return hostexec.exit_status(subprocess.run(args, check=False).returncode)
