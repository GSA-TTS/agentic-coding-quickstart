from __future__ import annotations

import pytest

from agent_sandbox.errors import ConfigurationError
from agent_sandbox.secrets import decrypt_env, encrypt_env, ensure_secret_backend
from agent_sandbox.subprocess_runner import CommandResult


class FakeRunner:
    def __init__(self) -> None:
        self.commands: list[list[str]] = []

    def run(self, command: list[str], check: bool = True) -> CommandResult:
        _ = check
        self.commands.append(command)
        return CommandResult(command=command, returncode=0, stdout="", stderr="")


def test_ensure_secret_backend_accepts_supported_values() -> None:
    ensure_secret_backend("env")
    ensure_secret_backend("sops-age")


def test_ensure_secret_backend_rejects_unknown_value() -> None:
    with pytest.raises(ConfigurationError, match="Unsupported secret backend"):
        ensure_secret_backend("vault")


def test_encrypt_env_requires_plain_env(repo_root) -> None:
    runner = FakeRunner()
    with pytest.raises(ConfigurationError, match=r"\.env is missing"):
        encrypt_env(repo_root, runner)


def test_encrypt_env_copies_and_deletes_plain_env(repo_root) -> None:
    runner = FakeRunner()
    env_file = repo_root / ".env"
    env_file.write_text("OPENAI_COMPAT_API_KEY=abc\n", encoding="utf-8")

    encrypt_env(repo_root, runner)

    assert runner.commands == [
        ["sops", "--version"],
        ["cp", str(repo_root / ".env"), str(repo_root / ".env.enc")],
    ]
    assert not (repo_root / ".env").exists()


def test_decrypt_env_requires_encrypted_file(repo_root) -> None:
    runner = FakeRunner()
    with pytest.raises(ConfigurationError, match=r"\.env\.enc is missing"):
        decrypt_env(repo_root, runner)


def test_decrypt_env_copies_encrypted_file(repo_root) -> None:
    runner = FakeRunner()
    encrypted = repo_root / ".env.enc"
    encrypted.write_text("fake encrypted content\n", encoding="utf-8")

    decrypt_env(repo_root, runner)

    assert runner.commands == [
        ["sops", "--version"],
        ["cp", str(repo_root / ".env.enc"), str(repo_root / ".env")],
    ]
