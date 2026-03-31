from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(slots=True)
class ProviderModel:
    id: str
    owned_by: str = ""
    context_length: int | None = None
    max_output_tokens: int | None = None


@dataclass(slots=True)
class ProviderProbeResult:
    provider_id: str
    provider_name: str
    base_url: str
    selected_model: str
    models: list[ProviderModel] = field(default_factory=list)
    auth_ok: bool = True
    supports_models: bool = True
    notes: list[str] = field(default_factory=list)


@dataclass(slots=True)
class Settings:
    project_name: str
    base_url: str
    provider_id: str
    provider_name: str
    model: str
    api_key_env: str
    template: str
    policy_profile: str
    secret_backend: str
    sandbox_name: str
