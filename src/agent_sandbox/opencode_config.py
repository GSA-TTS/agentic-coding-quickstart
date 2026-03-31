from __future__ import annotations

import json
from pathlib import Path

from agent_sandbox.models import ProviderProbeResult, Settings


def build_opencode_config(settings: Settings, probe: ProviderProbeResult) -> dict[str, object]:
    provider_models = {model.id: {"name": model.id} for model in probe.models}
    return {
        "$schema": "https://opencode.ai/config.json",
        "provider": {
            settings.provider_id: {
                "npm": "@ai-sdk/openai-compatible",
                "options": {
                    "baseURL": probe.base_url,
                    "apiKey": f"${{{settings.api_key_env}}}",
                },
                "models": provider_models,
            }
        },
        "model": f"{settings.provider_id}/{probe.selected_model}",
        "agent": {
            "build": {"model": f"{settings.provider_id}/{probe.selected_model}"},
            "plan": {
                "model": f"{settings.provider_id}/{probe.selected_model}",
                "tools": {"write": False, "edit": False, "bash": False},
            },
        },
        "metadata": {
            "provider_name": settings.provider_name,
            "selected_model": probe.selected_model,
        },
    }


def render_opencode_config(repo_root: Path, settings: Settings, probe: ProviderProbeResult) -> Path:
    payload = build_opencode_config(settings, probe)
    path = repo_root / "opencode.json"
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return path
