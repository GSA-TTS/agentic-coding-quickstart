from __future__ import annotations

import json
import os
import re
import tomllib
from dataclasses import asdict
from pathlib import Path

from agent_sandbox.constants import (
    CONFIG_DIR_NAME,
    CONFIG_FILE_NAME,
    DEFAULT_CONFIG_TEXT,
    DEFAULT_POLICY_PROFILE,
    DEFAULT_SECRET_BACKEND,
    DEFAULT_TEMPLATE,
    PROVIDER_LOCK_FILE_NAME,
)
from agent_sandbox.errors import ConfigurationError
from agent_sandbox.models import ProviderModel, ProviderProbeResult, Settings

_ENV_LINE = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$")


def find_repo_root(start: Path) -> Path:
    current = start.resolve()
    for candidate in [current, *current.parents]:
        if (candidate / ".git").exists():
            return candidate
    return current


def config_dir(repo_root: Path) -> Path:
    return repo_root / CONFIG_DIR_NAME


def config_file(repo_root: Path) -> Path:
    return config_dir(repo_root) / CONFIG_FILE_NAME


def provider_lock_file(repo_root: Path) -> Path:
    return config_dir(repo_root) / PROVIDER_LOCK_FILE_NAME


def default_sandbox_name(project_name: str) -> str:
    cleaned = re.sub(r"[^a-zA-Z0-9-]+", "-", project_name).strip("-").lower()
    return f"{cleaned or 'project'}-sandbox"


def load_env_file(env_file: Path) -> dict[str, str]:
    if not env_file.exists():
        return {}
    parsed: dict[str, str] = {}
    for raw_line in env_file.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        match = _ENV_LINE.match(line)
        if not match:
            continue
        key, value = match.groups()
        parsed[key] = value.strip().strip('"').strip("'")
    return parsed


def merged_env(repo_root: Path) -> dict[str, str]:
    file_values = load_env_file(repo_root / ".env")
    merged = {**file_values, **os.environ}
    return {key: value for key, value in merged.items() if value is not None}


def ensure_project_dirs(repo_root: Path) -> None:
    (config_dir(repo_root) / "logs").mkdir(parents=True, exist_ok=True)


def normalize_base_url(base_url: str) -> str:
    trimmed = base_url.strip().rstrip("/")
    if not trimmed:
        return ""
    localhost = trimmed.startswith("http://localhost") or trimmed.startswith("http://127.0.0.1")
    if localhost:
        return trimmed
    if not trimmed.startswith("https://"):
        raise ConfigurationError("Provider URL must use https:// unless it is localhost.")
    return trimmed


def initialize_config(repo_root: Path) -> Settings:
    ensure_project_dirs(repo_root)
    env = merged_env(repo_root)
    project_name = repo_root.name
    raw_base_url = env.get("OPENAI_COMPAT_BASE_URL", "")
    settings = Settings(
        project_name=project_name,
        base_url=normalize_base_url(raw_base_url) if raw_base_url else "",
        provider_id=env.get("OPENAI_COMPAT_PROVIDER_ID", "custom"),
        provider_name=env.get("OPENAI_COMPAT_PROVIDER_NAME", "Custom API"),
        model=env.get("OPENAI_COMPAT_MODEL", ""),
        api_key_env="OPENAI_COMPAT_API_KEY",
        template=DEFAULT_TEMPLATE,
        policy_profile=DEFAULT_POLICY_PROFILE,
        secret_backend=DEFAULT_SECRET_BACKEND,
        sandbox_name=default_sandbox_name(project_name),
    )
    write_settings(repo_root, settings)
    return settings


def write_settings(repo_root: Path, settings: Settings) -> None:
    ensure_project_dirs(repo_root)
    rendered = DEFAULT_CONFIG_TEXT.format(
        project_name=settings.project_name,
        base_url=settings.base_url,
        provider_id=settings.provider_id,
        provider_name=settings.provider_name,
        model=settings.model,
        template=settings.template,
        policy_profile=settings.policy_profile,
        secret_backend=settings.secret_backend,
        sandbox_name=settings.sandbox_name,
    )
    config_file(repo_root).write_text(rendered, encoding="utf-8")


def load_settings(repo_root: Path) -> Settings:
    path = config_file(repo_root)
    if not path.exists():
        return initialize_config(repo_root)
    data = tomllib.loads(path.read_text(encoding="utf-8"))
    provider = data.get("provider", {})
    sandbox = data.get("sandbox", {})
    project = data.get("project", {})
    project_name = str(project.get("name", repo_root.name))
    base_url = str(provider.get("base_url", ""))
    return Settings(
        project_name=project_name,
        base_url=normalize_base_url(base_url) if base_url else "",
        provider_id=str(provider.get("provider_id", "custom")),
        provider_name=str(provider.get("provider_name", "Custom API")),
        model=str(provider.get("model", "")),
        api_key_env=str(provider.get("api_key_env", "OPENAI_COMPAT_API_KEY")),
        template=str(sandbox.get("template", DEFAULT_TEMPLATE)),
        policy_profile=str(sandbox.get("policy_profile", DEFAULT_POLICY_PROFILE)),
        secret_backend=str(sandbox.get("secret_backend", DEFAULT_SECRET_BACKEND)),
        sandbox_name=str(sandbox.get("name", default_sandbox_name(project_name))),
    )


def write_provider_lock(repo_root: Path, probe: ProviderProbeResult) -> None:
    ensure_project_dirs(repo_root)
    payload = {
        "provider_id": probe.provider_id,
        "provider_name": probe.provider_name,
        "base_url": probe.base_url,
        "selected_model": probe.selected_model,
        "auth_ok": probe.auth_ok,
        "supports_models": probe.supports_models,
        "notes": probe.notes,
        "models": [asdict(model) for model in probe.models],
    }
    serialized = json.dumps(payload, indent=2, sort_keys=True) + "\n"
    provider_lock_file(repo_root).write_text(serialized, encoding="utf-8")


def load_provider_lock(repo_root: Path) -> ProviderProbeResult | None:
    path = provider_lock_file(repo_root)
    if not path.exists():
        return None
    data = json.loads(path.read_text(encoding="utf-8"))
    models = [ProviderModel(**entry) for entry in data.get("models", [])]
    return ProviderProbeResult(
        provider_id=str(data["provider_id"]),
        provider_name=str(data["provider_name"]),
        base_url=str(data["base_url"]),
        selected_model=str(data["selected_model"]),
        models=models,
        auth_ok=bool(data.get("auth_ok", True)),
        supports_models=bool(data.get("supports_models", True)),
        notes=[str(item) for item in data.get("notes", [])],
    )


def get_api_key(env: dict[str, str], env_name: str) -> str:
    value = env.get(env_name, "").strip()
    if not value:
        raise ConfigurationError(f"Required API key is missing: {env_name}")
    return value
