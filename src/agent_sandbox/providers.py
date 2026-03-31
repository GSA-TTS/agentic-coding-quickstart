from __future__ import annotations

import json
from urllib import error, request

from agent_sandbox.config import get_api_key, normalize_base_url
from agent_sandbox.errors import ProviderProbeError
from agent_sandbox.models import ProviderModel, ProviderProbeResult, Settings


def _parse_models(payload: dict[str, object]) -> list[ProviderModel]:
    raw_models = payload.get("data", [])
    if not isinstance(raw_models, list):
        raise ProviderProbeError("Provider returned an unexpected /models payload.")
    parsed: list[ProviderModel] = []
    for entry in raw_models:
        if not isinstance(entry, dict):
            continue
        model_id = str(entry.get("id", "")).strip()
        if not model_id:
            continue
        context_length = entry.get("context_length")
        max_output_tokens = entry.get("max_output_tokens")
        parsed.append(
            ProviderModel(
                id=model_id,
                owned_by=str(entry.get("owned_by", "")),
                context_length=int(context_length) if isinstance(context_length, int) else None,
                max_output_tokens=(
                    int(max_output_tokens) if isinstance(max_output_tokens, int) else None
                ),
            )
        )
    if not parsed:
        raise ProviderProbeError("Provider returned zero usable models.")
    return parsed


def probe_provider(
    settings: Settings,
    env: dict[str, str],
    timeout_seconds: int,
) -> ProviderProbeResult:
    base_url = normalize_base_url(settings.base_url)
    if not base_url:
        raise ProviderProbeError("Provider base URL is empty.")
    api_key = get_api_key(env, settings.api_key_env)
    req = request.Request(  # noqa: S310
        f"{base_url}/models",
        headers={
            "Authorization": f"Bearer {api_key}",
            "Accept": "application/json",
            "User-Agent": "agent-sandbox/0.2.0",
        },
        method="GET",
    )
    try:
        with request.urlopen(req, timeout=timeout_seconds) as response:  # noqa: S310
            payload = json.loads(response.read().decode("utf-8"))
    except error.HTTPError as exc:
        message = f"Provider probe failed with HTTP {exc.code}: {exc.reason}"
        raise ProviderProbeError(message) from exc
    except error.URLError as exc:
        raise ProviderProbeError(f"Provider probe failed: {exc.reason}") from exc
    except json.JSONDecodeError as exc:
        raise ProviderProbeError("Provider did not return valid JSON.") from exc
    models = _parse_models(payload)
    selected_model = settings.model or models[0].id
    notes = []
    if not settings.model:
        notes.append("Model not set in config; selected first returned model.")
    return ProviderProbeResult(
        provider_id=settings.provider_id,
        provider_name=settings.provider_name,
        base_url=base_url,
        selected_model=selected_model,
        models=models,
        notes=notes,
    )
