from __future__ import annotations

from pathlib import Path

import pytest

from agent_sandbox.models import ProviderModel, ProviderProbeResult, Settings


@pytest.fixture()
def repo_root(tmp_path: Path) -> Path:
    repo = tmp_path / "demo-repo"
    repo.mkdir()
    (repo / ".git").mkdir()
    return repo


@pytest.fixture()
def sample_settings() -> Settings:
    return Settings(
        project_name="demo-repo",
        base_url="https://example.gov/v1",
        provider_id="gsai",
        provider_name="GSAi",
        model="model-a",
        api_key_env="OPENAI_COMPAT_API_KEY",
        template="docker/sandbox-templates:opencode",
        policy_profile="balanced",
        secret_backend="env",
        sandbox_name="demo-repo-sandbox",
    )


@pytest.fixture()
def sample_probe() -> ProviderProbeResult:
    return ProviderProbeResult(
        provider_id="gsai",
        provider_name="GSAi",
        base_url="https://example.gov/v1",
        selected_model="model-a",
        models=[
            ProviderModel(id="model-a", owned_by="test", context_length=8192),
            ProviderModel(id="model-b", owned_by="test", context_length=16384),
        ],
        notes=["selected explicitly"],
    )
