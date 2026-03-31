from __future__ import annotations

import json
from pathlib import Path

import pytest

from agent_sandbox.config import (
    config_dir,
    config_file,
    default_sandbox_name,
    find_repo_root,
    get_api_key,
    initialize_config,
    load_env_file,
    load_provider_lock,
    load_settings,
    merged_env,
    normalize_base_url,
    provider_lock_file,
    write_provider_lock,
)
from agent_sandbox.errors import ConfigurationError
from agent_sandbox.models import ProviderModel, ProviderProbeResult


def test_find_repo_root_walks_up(repo_root: Path) -> None:
    nested = repo_root / "a" / "b" / "c"
    nested.mkdir(parents=True)
    assert find_repo_root(nested) == repo_root


def test_config_paths(repo_root: Path) -> None:
    assert config_dir(repo_root) == repo_root / ".agent-sandbox"
    assert config_file(repo_root) == repo_root / ".agent-sandbox" / "config.toml"
    assert provider_lock_file(repo_root) == repo_root / ".agent-sandbox" / "provider-lock.json"


def test_normalize_https_base_url() -> None:
    assert normalize_base_url("https://example.gov/v1/") == "https://example.gov/v1"


def test_normalize_localhost_http() -> None:
    assert normalize_base_url("http://localhost:8000/v1/") == "http://localhost:8000/v1"


def test_normalize_empty_base_url() -> None:
    assert normalize_base_url("   ") == ""


def test_normalize_invalid_non_https_url() -> None:
    with pytest.raises(ConfigurationError, match="must use https"):
        normalize_base_url("http://example.gov/v1")


def test_load_env_file(tmp_path: Path) -> None:
    env_file = tmp_path / ".env"
    env_file.write_text(
        "A=1\n# comment\nINVALID LINE\nB='two'\nC = \"three\"\n\n",
        encoding="utf-8",
    )
    assert load_env_file(env_file) == {"A": "1", "B": "two", "C": "three"}


def test_merged_env_prefers_process_env(
    monkeypatch: pytest.MonkeyPatch,
    repo_root: Path,
) -> None:
    (repo_root / ".env").write_text("A=from-file\nB=only-file\n", encoding="utf-8")
    monkeypatch.setenv("A", "from-env")
    monkeypatch.setenv("C", "only-env")

    result = merged_env(repo_root)

    assert result["A"] == "from-env"
    assert result["B"] == "only-file"
    assert result["C"] == "only-env"


def test_default_sandbox_name() -> None:
    assert default_sandbox_name("My Project") == "my-project-sandbox"


def test_default_sandbox_name_empty_after_cleaning() -> None:
    assert default_sandbox_name("!!!") == "project-sandbox"


def test_initialize_and_load_settings_round_trip(
    monkeypatch: pytest.MonkeyPatch,
    repo_root: Path,
) -> None:
    monkeypatch.setenv("OPENAI_COMPAT_BASE_URL", "https://api.example.gov/v1")
    monkeypatch.setenv("OPENAI_COMPAT_PROVIDER_ID", "usai")
    monkeypatch.setenv("OPENAI_COMPAT_PROVIDER_NAME", "USAI")
    monkeypatch.setenv("OPENAI_COMPAT_MODEL", "model-z")

    settings = initialize_config(repo_root)
    loaded = load_settings(repo_root)

    assert settings.project_name == "demo-repo"
    assert loaded.base_url == "https://api.example.gov/v1"
    assert loaded.provider_id == "usai"
    assert loaded.provider_name == "USAI"
    assert loaded.model == "model-z"
    assert loaded.sandbox_name == "demo-repo-sandbox"


def test_load_settings_initializes_when_missing(
    monkeypatch: pytest.MonkeyPatch,
    repo_root: Path,
) -> None:
    monkeypatch.setenv("OPENAI_COMPAT_BASE_URL", "https://api.example.gov/v1")
    settings = load_settings(repo_root)

    assert settings.base_url == "https://api.example.gov/v1"
    assert (repo_root / ".agent-sandbox" / "config.toml").exists()


def test_write_and_load_provider_lock_round_trip(repo_root: Path) -> None:
    probe = ProviderProbeResult(
        provider_id="gsai",
        provider_name="GSAi",
        base_url="https://example.gov/v1",
        selected_model="model-a",
        models=[
            ProviderModel(id="model-a", owned_by="test", context_length=8192),
            ProviderModel(id="model-b", owned_by="test", max_output_tokens=2048),
        ],
        notes=["ok"],
    )

    write_provider_lock(repo_root, probe)
    loaded = load_provider_lock(repo_root)

    assert loaded is not None
    assert loaded.provider_id == "gsai"
    assert loaded.selected_model == "model-a"
    assert [model.id for model in loaded.models] == ["model-a", "model-b"]
    assert loaded.notes == ["ok"]


def test_load_provider_lock_returns_none_when_missing(repo_root: Path) -> None:
    assert load_provider_lock(repo_root) is None


def test_provider_lock_file_contains_json(repo_root: Path) -> None:
    probe = ProviderProbeResult(
        provider_id="gsai",
        provider_name="GSAi",
        base_url="https://example.gov/v1",
        selected_model="model-a",
        models=[ProviderModel(id="model-a")],
    )
    write_provider_lock(repo_root, probe)

    lock_path = repo_root / ".agent-sandbox" / "provider-lock.json"
    payload = json.loads(lock_path.read_text(encoding="utf-8"))
    assert payload["provider_id"] == "gsai"
    assert payload["selected_model"] == "model-a"


def test_get_api_key_returns_value() -> None:
    assert get_api_key({"OPENAI_COMPAT_API_KEY": "abc123"}, "OPENAI_COMPAT_API_KEY") == "abc123"


def test_get_api_key_raises_when_missing() -> None:
    with pytest.raises(ConfigurationError, match="Required API key is missing"):
        get_api_key({}, "OPENAI_COMPAT_API_KEY")
