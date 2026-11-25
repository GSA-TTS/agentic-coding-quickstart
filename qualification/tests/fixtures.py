"""Synthetic evidence and temporary Git helpers; never execute a cell oracle."""

from dataclasses import asdict
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from qualification.model import Environment, Outcome, Transcript, Verdict
from qualification.runner import CellResult, transcript_document


def document(verdicts=("PASS",), outcome="PASS", rev="a" * 40):
    env = Environment(
        "Linux", "fixture", "x86_64", "kvm", "msb", "0.7.7", "fixture-image",
        rev, "b" * 64, "none",
    )
    attempts = tuple(Transcript(
        Verdict(verdict), env, ("scripts/qualify-backend-cell", "--backend", "msb"),
        "c" * 64, "synthetic", "2026-11-16T00:00:00+00:00",
    ) for verdict in verdicts)
    return transcript_document(CellResult(Outcome(outcome), attempts))


def ledger_document(entries=()):
    return {"schema_version": 1, "entries": [asdict(e) for e in entries],
            "waivers": [], "accepted_backend_versions": {"msb": "0.7.7"}}


def clean_env():
    env = {k: v for k, v in os.environ.items() if not k.startswith(("GIT_", "PYTHON"))}
    env.update(PYTHONPATH=str(ROOT), PYTHONDONTWRITEBYTECODE="1",
               GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_SYSTEM=os.devnull,
               GIT_NO_REPLACE_OBJECTS="1", GIT_TERMINAL_PROMPT="0")
    return env


def git(repo, *args):
    binary = shutil.which("git")
    if binary is None:
        raise RuntimeError("Git is required for offline regression tests")
    return subprocess.check_output(
        [binary, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
         "-c", "commit.gpgsign=false", "-c", "core.hooksPath=" + os.devnull, *args],
        cwd=repo, env=clean_env(), stderr=subprocess.PIPE, text=True, timeout=15,
    ).strip()


def invoke(repo, *args):
    return subprocess.run(
        [sys.executable, "-B", "-s", "-P", "-m", "qualification.gate", *args],
        cwd=repo, env=clean_env(), capture_output=True, text=True, timeout=30,
    )
