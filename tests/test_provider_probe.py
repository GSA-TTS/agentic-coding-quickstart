from __future__ import annotations

import json
from dataclasses import replace
from urllib import error, request

import pytest

from agent_sandbox.errors import ProviderProbeError
from agent_sandbox.models import Settings
from agent_sandbox.providers import probe_provider


class DummyResponse:
    def __init__(self, payload: dict[str, object]) -> None:
        self._payload = payload

    def read(self) -> bytes:
        return json.dumps(self._payload).encode("utf-8")

    def __enter__(self) -> DummyResponse:
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        _ = exc_type
        _ = exc
        _ = tb
        return None


@pytest.fixture()
def settings() -> Settings:
    return Settings(
        project_name="demo",
        base_url="https://example.gov/v1",
        provider_id="gsai",
        provider_name="GSAi",
        model="",
        api_key_env="OPENAI_COMPAT_API_KEY",
        template="docker/sandbox-templates:opencode",
        policy_profile="balanced",
        secret_backend="env",
        sandbox_name="demo-sandbox",
    )


def test_probe_provider_selects_first_model(
    monkeypatch: pytest.MonkeyPatch,
    settings: Settings,
) -> None:
    def fake_urlopen(req: request.Request, timeout: int):
        _ = timeout
        assert req.full_url == "https://example.gov/v1/models"
        assert req.headers["Authorization"] == "Bearer abc"
        return DummyResponse(
            {
                "object": "list",
                "data": [
                    {"id": "model-a", "object": "model", "owned_by": "test"},
                    {"id": "model-b", "object": "model", "owned_by": "test"},
                ],
            }
        )

    monkeypatch.setattr("urllib.request.urlopen", fake_urlopen)

    probe = probe_provider(settings, {"OPENAI_COMPAT_API_KEY": "abc"}, 5)

    assert probe.selected_model == "model-a"
    assert len(probe.models) == 2
    assert probe.notes == ["Model not set in config; selected first returned model."]


def test_probe_provider_uses_explicit_model(
    monkeypatch: pytest.MonkeyPatch,
    settings: Settings,
) -> None:
    settings = replace(settings, model="model-b")

    def fake_urlopen(req: request.Request, timeout: int):
        _ = req
        _ = timeout
        return DummyResponse({"data": [{"id": "model-a"}, {"id": "model-b"}]})

    monkeypatch.setattr("urllib.request.urlopen", fake_urlopen)

    probe = probe_provider(settings, {"OPENAI_COMPAT_API_KEY": "abc"}, 5)

    assert probe.selected_model == "model-b"
    assert probe.notes == []


def test_probe_provider_http_error(
    monkeypatch: pytest.MonkeyPatch,
    settings: Settings,
) -> None:
    def fake_urlopen(req: request.Request, timeout: int):
        _ = timeout
        raise error.HTTPError(req.full_url, 401, "Unauthorized", hdrs=None, fp=None)

    monkeypatch.setattr("urllib.request.urlopen", fake_urlopen)

    with pytest.raises(ProviderProbeError, match="HTTP 401"):
        probe_provider(settings, {"OPENAI_COMPAT_API_KEY": "abc"}, 5)


def test_probe_provider_url_error(
    monkeypatch: pytest.MonkeyPatch,
    settings: Settings,
) -> None:
    def fake_urlopen(req: request.Request, timeout: int):
        _ = req
        _ = timeout
        raise error.URLError("connection refused")

    monkeypatch.setattr("urllib.request.urlopen", fake_urlopen)

    with pytest.raises(ProviderProbeError, match="connection refused"):
        probe_provider(settings, {"OPENAI_COMPAT_API_KEY": "abc"}, 5)


def test_probe_provider_invalid_json(
    monkeypatch: pytest.MonkeyPatch,
    settings: Settings,
) -> None:
    class BadResponse:
        def read(self) -> bytes:
            return b"{not-json"

        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb) -> None:
            _ = exc_type
            _ = exc
            _ = tb
            return None

    def fake_urlopen(req: request.Request, timeout: int):
        _ = req
        _ = timeout
        return BadResponse()

    monkeypatch.setattr("urllib.request.urlopen", fake_urlopen)

    with pytest.raises(ProviderProbeError, match="valid JSON"):
        probe_provider(settings, {"OPENAI_COMPAT_API_KEY": "abc"}, 5)


def test_probe_provider_rejects_empty_models(
    monkeypatch: pytest.MonkeyPatch,
    settings: Settings,
) -> None:
    def fake_urlopen(req: request.Request, timeout: int):
        _ = req
        _ = timeout
        return DummyResponse({"data": []})

    monkeypatch.setattr("urllib.request.urlopen", fake_urlopen)

    with pytest.raises(ProviderProbeError, match="zero usable models"):
        probe_provider(settings, {"OPENAI_COMPAT_API_KEY": "abc"}, 5)
