from __future__ import annotations

import shutil
import sys

from agent_sandbox.models import Settings


def build_doctor_report(settings: Settings) -> list[tuple[str, bool, str]]:
    checks = [
        ("python>=3.11", sys.version_info >= (3, 11), sys.version.split()[0]),
        ("docker", shutil.which("docker") is not None, shutil.which("docker") or "missing"),
        ("opencode", shutil.which("opencode") is not None, shutil.which("opencode") or "missing"),
    ]
    if settings.secret_backend == "sops-age":
        checks.extend(
            [
                ("sops", shutil.which("sops") is not None, shutil.which("sops") or "missing"),
                ("age", shutil.which("age") is not None, shutil.which("age") or "missing"),
            ]
        )
    return checks
