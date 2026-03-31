from __future__ import annotations

from pathlib import Path

from agent_sandbox.models import ProviderModel, ProviderProbeResult, Settings
from agent_sandbox.opencode_config import build_opencode_config, render_opencode_config


def test_build_opencode_config() -> None:
    settings = Settings(
        project_name="demo",
        base_url="https://example.gov/v1",
        provider_id="gsai",
        provider_name="GSAi",
        model="model-a",
        api_key_env="OPENAI_COMPAT_API_KEY",
        template="docker/sandbox-templates:opencode",
        policy_profile="balanced",
        secret_backend="env",
        sandbox_name="demo-sandbox",
    )
    probe = ProviderProbeResult(
        provider_id="gsai",
        provider_name="GSAi",
        base_url="https://example.gov/v1",
        selected_model="model-a",
        models=[ProviderModel(id="model-a"), ProviderModel(id="model-b")],
    )

    payload = build_opencode_config(settings, probe)

    provider = payload["provider"]["gsai"]
    assert provider["options"]["baseURL"] == "https://example.gov/v1"
    assert provider["options"]["apiKey"] == "${OPENAI_COMPAT_API_KEY}"
    assert payload["model"] == "gsai/model-a"
    assert payload["metadata"]["provider_name"] == "GSAi"


def test_render_opencode_config(tmp_path: Path) -> None:
    settings = Settings(
        project_name="demo",
        base_url="https://example.gov/v1",
        provider_id="gsai",
        provider_name="GSAi",
        model="model-a",
        api_key_env="OPENAI_COMPAT_API_KEY",
        template="docker/sandbox-templates:opencode",
        policy_profile="balanced",
        secret_backend="env",
        sandbox_name="demo-sandbox",
    )
    probe = ProviderProbeResult(
        provider_id="gsai",
        provider_name="GSAi",
        base_url="https://example.gov/v1",
        selected_model="model-a",
        models=[ProviderModel(id="model-a")],
    )

    path = render_opencode_config(tmp_path, settings, probe)

    assert path == tmp_path / "opencode.json"
    assert path.exists()
    assert '"model": "gsai/model-a"' in path.read_text(encoding="utf-8")
