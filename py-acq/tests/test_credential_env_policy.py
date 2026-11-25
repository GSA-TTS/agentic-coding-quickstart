"""Credential-name regressions: synthetic values, no control-variable execution."""

import json
import os
import subprocess

import pytest

from acq_py import errors, hostexec, msb, provider_creds, secretstore

CONTROL_NAMES = (
    "MSB_HOME", "SBX_HOME", "ACQ_STATE_DIR", "ACQ_MSB_BIN", "XDG_CONFIG_HOME",
    "DYLD_INSERT_LIBRARIES", "DYLD_FRAMEWORK_PATH", "LD_AUDIT", "PYTHONPATH",
    "PYTHONHOME", "GIT_CONFIG_GLOBAL", "GIT_SSH_COMMAND", "BASH_ENV", "SHELL",
    "USER", "LANG", "LC_ALL", "COMSPEC", "SYSTEMROOT", "HTTP_PROXY", "SSL_CERT_FILE",
)


@pytest.mark.parametrize("name", CONTROL_NAMES)
def test_control_name_rejected_at_validation_and_preflight(name):
    assert not provider_creds.key_env_ok(name)
    assert provider_creds.validate_binding("custom", name, ["api.example.gov"]) is not None
    with pytest.raises(msb.MsbError) as caught:
        msb.secret_preflight("global", "custom", "api.example.gov", name)
    assert caught.value.code == errors.VALIDATION_FAILED


@pytest.mark.parametrize("name", CONTROL_NAMES)
def test_control_name_cannot_override_child_environment(monkeypatch, name):
    calls = []

    def capture(*args, **kwargs):
        calls.append(True)
        return subprocess.CompletedProcess([], 0)

    monkeypatch.setattr(hostexec, "run_captured", capture)
    monkeypatch.setattr(msb, "msb_command", lambda: ["unused-backend"])
    with pytest.raises(msb.MsbError) as caught:
        msb._run(["start", "box"], secret_env={name: "synthetic"})
    assert caught.value.code == errors.VALIDATION_FAILED
    assert not calls


@pytest.mark.parametrize("name", CONTROL_NAMES)
@pytest.mark.parametrize("operation", [msb._start_env, msb.start, msb.reconcile_bindings])
def test_unsafe_held_record_fails_before_backend(monkeypatch, name, operation):
    path = msb.held_path("box")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({
        "schema": msb.HELD_SCHEMA, "sandbox": "box", "complete": True,
        "services": ["custom"], "bindings": {
            name: {"service": "custom", "host": "api.example.gov", "scope": "global"},
        },
    }))
    calls = []
    monkeypatch.setattr(hostexec, "run_captured", lambda *a, **kw: calls.append(True))
    with pytest.raises(msb.MsbError) as caught:
        operation("box")
    assert caught.value.code == errors.STATE_SCHEMA_UNSUPPORTED
    assert not calls


@pytest.mark.parametrize("name", CONTROL_NAMES)
def test_unsafe_endpoint_refused_not_silently_skipped(monkeypatch, name):
    secretstore.meta_store("custom", None, "api.example.gov", name)
    monkeypatch.setattr(msb, "_bind_candidates", lambda box: ["custom"])
    monkeypatch.setattr(msb.provider_input, "delivery_ids", lambda *a: [])
    with pytest.raises(msb.MsbError) as caught:
        msb.secret_bindings("box")
    assert caught.value.code == errors.VALIDATION_FAILED


@pytest.mark.parametrize("name", CONTROL_NAMES)
def test_unsafe_provider_record_does_not_resolve(name):
    # Seed legacy records without invoking a writer's validation.
    path = provider_creds._binding_path("custom")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"schema": 1, "provider": "custom", "key_env": name,
                                "hosts": ["api.example.gov"]}))
    assert provider_creds.provider_env_hosts("custom") is None


@pytest.mark.parametrize("service,name", [
    ("usai", "USAI_API_KEY"), ("github", "GITHUB_TOKEN"), ("github", "GH_TOKEN"),
    ("gitlab", "GITLAB_TOKEN"), ("custom", "API_KEY"), ("custom", "CUSTOM_ENV"),
    ("custom", "OPENCODE_GO_API_KEY"),
])
def test_safe_names_reach_child_without_mutating_parent(monkeypatch, service, name):
    assert provider_creds.validate_binding(service, name, ["api.example.gov"]) is None
    msb.secret_preflight("global", service, "api.example.gov", name)
    monkeypatch.delenv(name, raising=False)
    present = []

    def capture(*args, **kwargs):
        present.append(name in kwargs["env"])
        return subprocess.CompletedProcess([], 0)

    monkeypatch.setattr(hostexec, "run_captured", capture)
    monkeypatch.setattr(msb, "msb_command", lambda: ["unused-backend"])
    assert msb._run(["start", "box"], secret_env={name: "synthetic"}).returncode == 0
    assert present == [True]
    assert name not in os.environ


def test_safe_invocation_pin_overrides_unsafe_durable_pin(monkeypatch):
    path = provider_creds._binding_path("custom")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"schema": 1, "provider": "custom", "key_env": "MSB_HOME",
                                "hosts": ["api.example.gov"]}))
    monkeypatch.setenv(provider_creds.BINDINGS_ENV, "custom=CUSTOM_API_KEY@api.example.gov")
    assert msb.service_binding("custom").env == "CUSTOM_API_KEY"


def test_unsafe_invocation_pin_cannot_fall_back_to_safe_durable_pin(monkeypatch):
    provider_creds.set_binding("custom", "CUSTOM_API_KEY", ["api.example.gov"])
    monkeypatch.setenv(provider_creds.BINDINGS_ENV, "custom=MSB_HOME@api.example.gov")
    with pytest.raises(msb.MsbError) as caught:
        msb.service_binding("custom")
    assert caught.value.code == errors.VALIDATION_FAILED


@pytest.mark.parametrize("source", ["endpoint", "provider", "invocation", "held"])
def test_control_binding_refeed_never_invokes_modify(monkeypatch, source):
    if source == "endpoint":
        secretstore.meta_store("custom", None, "api.example.gov", "MSB_HOME")
    elif source == "invocation":
        monkeypatch.setenv(provider_creds.BINDINGS_ENV, "custom=MSB_HOME@api.example.gov")
    elif source == "provider":
        path = provider_creds._binding_path("custom")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({"schema": 1, "provider": "custom", "key_env": "MSB_HOME",
                                    "hosts": ["api.example.gov"]}))
    else:
        secretstore.meta_store("custom", None, "api.example.gov", "CUSTOM_API_KEY")
        msb.HeldRecord("box", {"MSB_HOME": {
            "service": "custom", "host": "api.example.gov", "scope": "global",
        }}, complete=True).save()
    monkeypatch.setattr(msb, "_running_targets", lambda scope: ["box"])
    monkeypatch.setattr(msb, "_selection_withholds", lambda *args: False)
    monkeypatch.setattr(secretstore, "resolve", lambda *args: "synthetic")
    calls = []
    monkeypatch.setattr(msb, "_modify", lambda *a, **kw: calls.append(True))
    with pytest.raises(msb.MsbError):
        msb.secret_feed("global", "custom", "synthetic")
    assert not calls
