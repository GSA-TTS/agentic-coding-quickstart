from __future__ import annotations

from pathlib import Path

from agent_sandbox.errors import ConfigurationError
from agent_sandbox.subprocess_runner import SubprocessRunner


def ensure_secret_backend(secret_backend: str) -> None:
    if secret_backend not in {"env", "sops-age"}:
        raise ConfigurationError(f"Unsupported secret backend: {secret_backend}")


def encrypt_env(repo_root: Path, runner: SubprocessRunner) -> None:
    env_file = repo_root / ".env"
    encrypted_file = repo_root / ".env.enc"
    if not env_file.exists():
        raise ConfigurationError(".env is missing.")
    runner.run(["sops", "--version"])
    runner.run(["cp", str(env_file), str(encrypted_file)])
    env_file.unlink()


def decrypt_env(repo_root: Path, runner: SubprocessRunner) -> None:
    encrypted_file = repo_root / ".env.enc"
    if not encrypted_file.exists():
        raise ConfigurationError(".env.enc is missing.")
    runner.run(["sops", "--version"])
    runner.run(["cp", str(encrypted_file), str(repo_root / ".env")])
