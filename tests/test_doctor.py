from __future__ import annotations

from dataclasses import replace

import pytest

from agent_sandbox.doctor import build_doctor_report
from agent_sandbox.models import Settings


@pytest.fixture()
def env_settings() -> Settings:
    return Settings(
        project_name="demo",
        base_url="https://example.gov/v1",
        provider_id="custom",
        provider_name="Custom API",
        model="",
        api_key_env="OPENAI_COMPAT_API_KEY",
        template="docker/sandbox-templates:opencode",
        policy_profile="balanced",
        secret_backend="env",
        sandbox_name="demo-sandbox",
    )


@pytest.fixture()
def sops_settings(env_settings: Settings) -> Settings:
    return replace(env_settings, secret_backend="sops-age")


def test_build_doctor_report_for_env_backend(
    monkeypatch: pytest.MonkeyPatch,
    env_settings: Settings,
) -> None:
    monkeypatch.setattr("agent_sandbox.doctor.shutil.which", lambda name: f"/usr/bin/{name}")

    report = build_doctor_report(env_settings)

    names = [name for name, _ok, _detail in report]
    assert names == ["python>=3.11", "docker", "opencode"]


def test_build_doctor_report_for_sops_backend(
    monkeypatch: pytest.MonkeyPatch,
    sops_settings: Settings,
) -> None:
    monkeypatch.setattr("agent_sandbox.doctor.shutil.which", lambda name: f"/usr/bin/{name}")

    report = build_doctor_report(sops_settings)

    names = [name for name, _ok, _detail in report]
    assert names == ["python>=3.11", "docker", "opencode", "sops", "age"]
