"""Tier-2 tests for msb kit application and the read-only trusted config (ADR-0011, ADR-0017, ADR-0033, ADR-0035).

Covers ``kit_msb`` (the port of the Bash msb adapter's kit path), the real
read-only-mount probe in ``security``, and the create/run/recreate flow that
uses them, against the deterministic ``__stub__`` msb. Where the Bash adapter
produces the same artifact (the startup script, the ``msb exec`` env flags),
the two are compared directly.
"""

from __future__ import annotations

import json
import os
import shutil
import stat
import subprocess
import sys
from pathlib import Path

import pytest

from acq_py import cli, errors, kit_msb, kits, kitspec, msb, security, state

pytestmark = pytest.mark.provider_key  # creates msb sandboxes: needs a stored provider key

REPO_ROOT = Path(__file__).resolve().parents[2]
BASH = shutil.which("bash")
BUILTINS = ["zscaler-ca-certificate", "usai-provider", "agentic-coding-playbook", "git-ssh-sign"]
GUEST = security.HOST_CONFIG_GUEST_DIR
GUARDS = list(msb.GIT_GUARD_ENV)

needs_bash = pytest.mark.skipif(
    BASH is None or os.name == "nt" or shutil.which("awk") is None or shutil.which("base64") is None,
    reason="the Bash parity check needs bash, awk and base64",
)


def _env(monkeypatch, tmp_path, *, version="0.7.7", catalog=None, windows=False):
    # The read-only mount is requested on POSIX hosts only. In-process tests
    # choose the host class through the module seam, so the POSIX path is also
    # exercised on a Windows runner (and the Windows path on POSIX).
    monkeypatch.setattr(security, "WINDOWS", windows)
    monkeypatch.setenv("ACQ_MSB_BIN", "__stub__")
    monkeypatch.setenv("ACQ_MSB_VERSION", version)
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "1")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "0")
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("MSB_HOME", str(tmp_path / "msb-home"))
    monkeypatch.setenv("ACQ_MSB_RO_INSPECT_RETRY_SLEEP", "0")
    if catalog is not None:
        monkeypatch.setenv("ACQ_MSB_STUB_CATALOG", json.dumps(catalog))
    ws = tmp_path / "ws"
    ws.mkdir(exist_ok=True)
    return ws


def _invoke(capsys, *argv):
    rc = cli.main(list(argv))
    out = capsys.readouterr().out.strip()
    return rc, (json.loads(out.splitlines()[-1]) if out else None)


def _spy(monkeypatch) -> list[list[str]]:
    seen: list[list[str]] = []
    real = msb._run

    def spy(argv, **kwargs):
        seen.append(list(argv))
        return real(argv, **kwargs)

    monkeypatch.setattr(msb, "_run", spy)
    return seen


def _create_argv(seen):
    (argv,) = [a for a in seen if a[0] == "create"]
    return argv


def _catalog(tmp_path) -> dict:
    path = tmp_path / "msb-home" / ".microsandbox" / "catalog.json"
    return json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}


def _kit(tmp_path, name, body, files=None) -> kit_msb.Kit:
    root = tmp_path / "kits" / name
    root.mkdir(parents=True)
    (root / "spec.yaml").write_text(f'schemaVersion: "hybrid/v1"\nkind: mixin\nname: {name}\n{body}', encoding="utf-8")
    for rel, text in (files or {}).items():
        (root / rel).parent.mkdir(parents=True, exist_ok=True)
        (root / rel).write_text(text, encoding="utf-8")
    return kit_msb.Kit(name, "extra", kitspec.load_kit(root))


class _Guest:
    """Records ``msb.kit_exec``/``msb.copy`` calls; every step succeeds unless told otherwise."""

    def __init__(self, monkeypatch, fail=lambda argv: False):
        self.execs: list[tuple[list[str], list[str]]] = []
        self.copies: list[tuple[str, str]] = []
        monkeypatch.setattr(msb, "kit_exec", self._exec)
        monkeypatch.setattr(msb, "copy", lambda src, dst: self.copies.append((src, dst)) or 0)
        self._fail = fail

    def _exec(self, name, flags, argv):
        self.execs.append((list(flags), list(argv)))
        return not self._fail(argv)

    def commands(self):
        """The kit commands run (agent-user setup, file placement and mkdir steps left out)."""
        steps = (kit_msb._PLACE_SCRIPT, 'mkdir -p "$@"', kit_msb._AGENT_USER_SCRIPT)
        return [(f, a) for f, a in self.execs if not (a[:2] == ["sh", "-c"] and a[2] in steps)]


# ---------------------------------------------------------------------------
# create / run apply the built-in kits on msb.
# ---------------------------------------------------------------------------


def test_run_opencode_applies_every_builtin_kit_then_the_agent_kit(monkeypatch, tmp_path, capsys):
    ws = _env(monkeypatch, tmp_path)
    seen = _spy(monkeypatch)
    rc, doc = _invoke(capsys, "--backend", "msb", "create", "opencode", str(ws), "--name", "box", "--json")
    assert rc == 0, doc
    assert doc["data"]["kits"] == [*BUILTINS, "opencode"]
    assert (doc["data"]["kit"], doc["data"]["entrypoint"]) == ("opencode", "opencode")
    copied = [a[2].split(":", 1)[1] for a in seen if a[0] == "copy"]
    assert "/home/agent/usai-config/model-catalog-snapshot.json" in copied  # usai-provider
    assert "/home/agent/playbook-clone.sh" in copied  # agentic-coding-playbook
    assert "/home/agent/.config/git/ssh-signing-key-command" in copied  # git-ssh-sign
    assert "/home/agent/opencode-install.sh" in copied  # opencode
    # The CA kit's msb shortcut replaces its files and commands with host CA trust.
    assert "/home/agent/zscaler-ca.crt" not in copied
    assert "--trust-host-cas" in _create_argv(seen)
    assert kits.kit_applied_read("msb", "box")["kit"] == "opencode"
    assert kits.provenance_status("msb", "box") == "current"


def test_shell_gets_the_builtins_without_an_agent_kit(monkeypatch, tmp_path, capsys):
    ws = _env(monkeypatch, tmp_path)
    rc, doc = _invoke(capsys, "--backend", "msb", "create", "shell", str(ws), "--name", "sh", "--json")
    assert rc == 0
    assert doc["data"]["kits"] == BUILTINS and doc["data"]["kit"] is None


def test_verify_bundle_is_called_and_fails_closed(monkeypatch, tmp_path, capsys):
    ws = _env(monkeypatch, tmp_path)
    seen = _spy(monkeypatch)
    calls = []
    monkeypatch.setattr(kitspec, "verify_bundle", lambda: calls.append(1) or ["opencode: spec.yaml does not match the pinned content"])
    rc, doc = _invoke(capsys, "--backend", "msb", "run", "opencode", str(ws), "--name", "box", "--json")
    assert rc == 1
    assert doc["error"]["code"] == errors.VALIDATION_FAILED
    assert "does not match its pinned content" in doc["error"]["message"]
    assert calls == [1]
    assert not [a for a in seen if a[0] == "create"]


def test_verify_bundle_runs_on_every_create(monkeypatch, tmp_path, capsys):
    ws = _env(monkeypatch, tmp_path)
    real, calls = kitspec.verify_bundle, []
    monkeypatch.setattr(kitspec, "verify_bundle", lambda: calls.append(1) or real())
    assert _invoke(capsys, "--backend", "msb", "create", "shell", str(ws), "--name", "a", "--json")[0] == 0
    # Once in the read-only preflight before the GitHub-token prompt, and again
    # in the locked create that applies the kits.
    assert calls == [1, 1]


@pytest.mark.parametrize(("config", "code"), [
    # An opt-in catalog kit is fetched at the control-plane pin; the test
    # environment allows no network transport, so the fetch fails closed.
    ("extra_kits: openchamber\n", errors.FAILURE),
    # A local provider kit directory is not applied by the Python acq.
    ("provider_kit: ./local-provider\n", errors.UNSUPPORTED),
])
def test_configured_kits_that_cannot_be_fetched_are_refused(monkeypatch, tmp_path, capsys, config, code):
    ws = _env(monkeypatch, tmp_path)
    path = Path(os.environ["XDG_CONFIG_HOME"]) / "acq" / "config.yaml"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(config, encoding="utf-8")
    seen = _spy(monkeypatch)
    rc, doc = _invoke(capsys, "--backend", "msb", "create", "shell", str(ws), "--name", "a", "--json")
    assert rc == 1
    assert doc["error"]["code"] == code
    assert not [a for a in seen if a[0] == "create"]


def test_configured_unknown_extra_kit_fails_selection(monkeypatch, tmp_path, capsys):
    ws = _env(monkeypatch, tmp_path)
    path = Path(os.environ["XDG_CONFIG_HOME"]) / "acq" / "config.yaml"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("extra_kits: nope\n", encoding="utf-8")
    rc, doc = _invoke(capsys, "--backend", "msb", "create", "shell", str(ws), "--name", "a", "--json")
    assert rc == 1
    assert doc["error"]["code"] == errors.VALIDATION_FAILED
    assert "unknown kit 'nope'" in doc["error"]["message"]


def test_a_failed_builtin_kit_warns_and_withholds_provenance(monkeypatch, tmp_path, capsys):
    ws = _env(monkeypatch, tmp_path)
    real = kit_msb.apply_kit
    monkeypatch.setattr(kit_msb, "apply_kit", lambda n, kit, *a, **k: False if kit.name == "git-ssh-sign" else real(n, kit, *a, **k))
    rc = cli.main(["--backend", "msb", "create", "opencode", str(ws), "--name", "box", "--json"])
    out, err = capsys.readouterr()
    assert rc == 0
    doc = json.loads(out)
    assert doc["data"]["kits_incomplete"] == ["git-ssh-sign"]
    # Never a false "current": the record carries the provider selection only.
    assert kits.provenance_status("msb", "box") == "unknown"
    assert "applied_ref" not in kits.provenance_read("msb", "box")


def test_a_failed_agent_kit_fails_the_create_and_removes_the_guest(monkeypatch, tmp_path, capsys):
    ws = _env(monkeypatch, tmp_path)
    real = kit_msb.apply_kit
    monkeypatch.setattr(kit_msb, "apply_kit", lambda n, kit, *a, **k: False if kit.name == "opencode" else real(n, kit, *a, **k))
    rc, doc = _invoke(capsys, "--backend", "msb", "create", "opencode", str(ws), "--name", "box", "--json")
    assert rc == 1 and doc["error"]["code"] == errors.FAILURE
    assert "box" not in _catalog(tmp_path)
    assert state.record_read("msb", "box") is None


# ---------------------------------------------------------------------------
# The read-only host-config mount.
# ---------------------------------------------------------------------------


def test_create_mounts_the_host_config_read_only_and_records_it_once_confirmed(monkeypatch, tmp_path, capsys):
    ws = _env(monkeypatch, tmp_path)
    seen = _spy(monkeypatch)
    rc, doc = _invoke(capsys, "--backend", "msb", "create", "shell", str(ws), "--name", "box", "--json")
    assert rc == 0 and doc["data"]["ro_host_config"] is True
    argv = _create_argv(seen)
    hcfg = os.path.realpath(security.host_config_dir("box"))
    assert ["--volume", f"{hcfg}:{GUEST}:ro"] == argv[argv.index(f"{hcfg}:{GUEST}:ro") - 1:][:2]
    if os.name != "nt":
        assert stat.S_IMODE(os.stat(hcfg).st_mode) == 0o711
    # Confirmed before the record was written: inspect, then the two guest probes.
    after = seen[seen.index(argv) + 1:]
    assert ["inspect", "box", "--format", "json"] in after
    assert any(".acq-ro-probe" in " ".join(a) for a in after)
    assert state.record_read("msb", "box")["ro_host_config"] is True
    assert kit_msb.hc_has("box", "ro-host-config")  # the record Bash's gate reads


def test_create_below_the_ro_floor_asks_for_no_mount_and_records_none(monkeypatch, tmp_path, capsys):
    ws = _env(monkeypatch, tmp_path, version="0.7.6")
    seen = _spy(monkeypatch)
    rc, doc = _invoke(capsys, "--backend", "msb", "create", "shell", str(ws), "--name", "box", "--json")
    assert rc == 0 and doc["data"]["ro_host_config"] is False
    assert not any(t.endswith(f"{GUEST}:ro") for t in _create_argv(seen))
    assert not [a for a in seen if a[0] == "inspect"]
    assert not state.record_read("msb", "box").get("ro_host_config")


@pytest.mark.parametrize("knob", ["ACQ_MSB_STUB_MOUNT_RW", "ACQ_MSB_STUB_RO_WRITABLE"])
def test_an_unconfirmed_mount_removes_the_new_sandbox(monkeypatch, tmp_path, capsys, knob):
    ws = _env(monkeypatch, tmp_path)
    monkeypatch.setenv(knob, "box")
    rc, doc = _invoke(capsys, "--backend", "msb", "create", "opencode", str(ws), "--name", "box", "--json")
    assert rc == 1 and doc["error"]["code"] == errors.SECURITY_EXCEPTION
    assert "box" not in _catalog(tmp_path)
    assert state.record_read("msb", "box") is None


def test_rm_removes_the_host_config_directory(monkeypatch, tmp_path, capsys):
    ws = _env(monkeypatch, tmp_path)
    assert _invoke(capsys, "--backend", "msb", "create", "shell", str(ws), "--name", "box", "--json")[0] == 0
    assert security.host_config_dir("box").is_dir()
    assert _invoke(capsys, "--backend", "msb", "rm", "box", "--json")[0] == 0
    assert not security.host_config_dir("box").exists()
    assert kits.provenance_read("msb", "box") is None


# ---------------------------------------------------------------------------
# The real probe and the gate.
# ---------------------------------------------------------------------------

_SEC = {"schema": 1, "name": "sec", "backend": "msb", "agent": "shell", "workspace": "/w", "ro_host_config": True}


def _seed_sec():
    path = state.record_path("msb", "sec")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(_SEC), encoding="utf-8")


def test_probe_confirms_a_stub_created_mount(monkeypatch, tmp_path, capsys):
    ws = _env(monkeypatch, tmp_path)
    assert _invoke(capsys, "--backend", "msb", "create", "shell", str(ws), "--name", "box", "--json")[0] == 0
    assert security.probe_mount("box") == ("ok", "")
    assert security.mount_state("msb", "box") == "ok"


def test_probe_reports_a_sandbox_without_the_mount_missing(monkeypatch, tmp_path):
    _env(monkeypatch, tmp_path, catalog={"sec": "running"})
    state_, reason = security.probe_mount("sec")
    assert state_ == "missing" and "no mount" in reason


def test_seam_cannot_force_ok_without_the_stub_backend(monkeypatch, tmp_path):
    _env(monkeypatch, tmp_path, catalog={"sec": "running"})
    _seed_sec()
    monkeypatch.setenv("ACQ_SECURITY_MOUNT_STATE", '"ok"')
    # The same fake msb, named by a command line instead of the stub sentinel:
    # acq now treats it as a real msb, so the seam no longer applies.
    monkeypatch.setenv("ACQ_MSB_BIN", f'"{sys.executable}" -P -m acq_py._stub_msb')
    assert security.mount_state("msb", "sec") == "missing"
    with pytest.raises(security.SecurityException):
        security.assert_trusted(_SEC, "msb", "sec")
    monkeypatch.setenv("ACQ_MSB_BIN", "__stub__")
    assert security.mount_state("msb", "sec") == "ok"  # the seam, in stub mode only


def test_seam_does_not_apply_to_a_real_sbx(monkeypatch):
    monkeypatch.setenv("ACQ_SECURITY_MOUNT_STATE", '"ok"')
    assert security.mount_state("sbx", "x") == "unknown"


def test_probe_below_the_floor_is_unknown_and_asks_for_an_upgrade(monkeypatch, tmp_path):
    _env(monkeypatch, tmp_path, version="0.7.6", catalog={"sec": "running"})
    state_, reason = security.probe_mount("sec")
    assert state_ == "unknown" and "0.7.7" in reason
    with pytest.raises(security.SecurityException) as info:
        security.assert_trusted(_SEC, "msb", "sec")
    assert "upgrade msb to 0.7.7" in (info.value.remediation or "")


def test_inspect_with_no_active_config_is_retried_then_unknown(monkeypatch, tmp_path):
    _env(monkeypatch, tmp_path, catalog={"sec": "running"})
    monkeypatch.setenv("ACQ_MSB_STUB_INSPECT_RAW", '{"active_config": null}')
    monkeypatch.setenv("ACQ_MSB_RO_INSPECT_RETRIES", "2")
    seen = _spy(monkeypatch)
    state_, reason = security.probe_mount("sec")
    assert state_ == "unknown" and "active_config is null" in reason
    assert len([a for a in seen if a[0] == "inspect"]) == 2


_HOST = "/h/cfg"


def _mount(guest=GUEST, host=_HOST, readonly=True, kind="Bind"):
    return (guest, {"guest": guest, "host": host, "type": kind, "options": {"readonly": readonly}})


@pytest.mark.parametrize(
    ("entries", "reason"),
    [
        ([], "no mount"),
        ([_mount(), _mount()], "more than one"),
        ([_mount(kind="Volume")], "not a Bind"),
        ([_mount(readonly=False)], "as read-only"),
        ([_mount(host="/elsewhere")], "not backed by"),
        ([_mount(), _mount(guest="/", host="/x", readonly=False)], "overlaps"),
        ([_mount(), _mount(guest=GUEST + "/kit-files", host="/x", readonly=False)], "overlaps"),
    ],
)
def test_the_mount_record_check_fails_closed(entries, reason):
    with pytest.raises(ValueError, match=reason):
        msb._check_ro_mount(entries, GUEST, [_HOST])


def test_the_mount_record_check_accepts_the_one_read_only_bind():
    msb._check_ro_mount([_mount(), _mount(guest="/w", host="/w", readonly=False)], GUEST, [_HOST])


def test_run_reattach_goes_through_the_real_probe(monkeypatch, tmp_path, capsys):
    ws = _env(monkeypatch, tmp_path)
    assert _invoke(capsys, "--backend", "msb", "create", "shell", str(ws), "--name", "box", "--json")[0] == 0
    monkeypatch.setenv("ACQ_MSB_STUB_MOUNT_RW", "box")  # msb now reports the mount writable
    rc, doc = _invoke(capsys, "--backend", "msb", "run", "box", "--json")
    assert rc == 1 and doc["error"]["code"] == errors.SECURITY_EXCEPTION
    assert "as read-only" in doc["error"]["message"]


# ---------------------------------------------------------------------------
# Recreate.
# ---------------------------------------------------------------------------


def test_recreate_then_run_succeeds(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    _seed_sec()
    rc, doc = _invoke(capsys, "--backend", "msb", "create", "--recreate", "sec", "--yes", "--json")
    assert rc == 0 and doc["data"]["recreated"] is True and doc["data"]["ro_host_config"] is True
    monkeypatch.setattr(msb, "launch", lambda *a, **k: 0)
    rc, doc = _invoke(capsys, "--backend", "msb", "run", "sec", "--json")
    assert rc == 0 and doc["data"]["action"] == "reattached"


def test_recreate_below_the_floor_refuses_before_removing_the_guest(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path, version="0.7.6")
    _seed_sec()
    removed = []
    monkeypatch.setattr(msb, "remove", lambda name: removed.append(name))
    rc, doc = _invoke(capsys, "--backend", "msb", "create", "--recreate", "sec", "--yes", "--json")
    assert rc == 1 and doc["error"]["code"] == errors.VALIDATION_FAILED
    assert "upgrade msb" in doc["error"]["remediation"]
    assert removed == []


def test_recreate_requires_the_read_only_mount_where_the_platform_has_it(monkeypatch, tmp_path, capsys):
    # The version check before the old guest goes passes; the create's own
    # detection then disagrees, so the new guest has no mount. Recorded that
    # way, the sandbox would stop requiring the mount for good.
    _env(monkeypatch, tmp_path)
    _seed_sec()
    monkeypatch.setattr(security, "ro_mount_supported", lambda: False)
    applied = []
    monkeypatch.setattr(kit_msb, "ensure_kits_applied", lambda *a, **k: applied.append(1) or kit_msb.ApplyResult())
    rc, doc = _invoke(capsys, "--backend", "msb", "create", "--recreate", "sec", "--yes", "--json")
    assert rc == 1 and doc["error"]["code"] == errors.VALIDATION_FAILED, doc
    assert "without its read-only trusted-config mount" in doc["error"]["message"]
    assert applied == []
    assert "sec" not in _catalog(tmp_path)
    assert "the new guest was removed" in doc["error"]["message"]
    assert state.record_read("msb", "sec")["ro_host_config"] is True  # still eligible for a retry


def _fail_remove(monkeypatch):
    """Removing the new guest fails and leaves it listed (the seeded record has no old guest)."""
    calls = []

    def remove(name):
        calls.append(name)
        raise msb.MsbError(errors.FAILURE, f"msb remove failed for sandbox '{name}'")

    monkeypatch.setattr(msb, "remove", remove)
    return calls


def test_recreate_says_when_the_new_guest_without_the_mount_could_not_be_removed(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    _seed_sec()
    monkeypatch.setattr(security, "ro_mount_supported", lambda: False)
    calls = _fail_remove(monkeypatch)
    rc, doc = _invoke(capsys, "--backend", "msb", "create", "--recreate", "sec", "--yes", "--json")
    assert rc == 1 and doc["error"]["code"] == errors.VALIDATION_FAILED, doc
    assert calls == ["sec"]
    assert "sec" in _catalog(tmp_path)  # the new guest is still there
    message = doc["error"]["message"]
    assert "the new guest could not be removed" in message
    assert "was removed" not in message
    assert state.record_read("msb", "sec")["ro_host_config"] is True


def test_recreate_kit_failure_warns_when_the_new_guest_could_not_be_removed(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    _seed_sec()
    _fail_remove(monkeypatch)
    monkeypatch.setattr(kit_msb, "ensure_kits_applied", lambda *a, **k: kit_msb.ApplyResult(agent_user=False))
    rc = cli.main(["--backend", "msb", "create", "--recreate", "sec", "--yes", "--json"])
    captured = capsys.readouterr()
    assert rc == 1
    assert "the new guest could not be removed" in captured.err
    assert state.record_read("msb", "sec")["ro_host_config"] is True


# ---------------------------------------------------------------------------
# The agent user is set up before every kit-set apply.
# ---------------------------------------------------------------------------


def _agent_user_step(argv) -> bool:
    return argv[:2] == ["sh", "-c"] and len(argv) > 2 and argv[2] == kit_msb._AGENT_USER_SCRIPT


def test_ensure_sets_up_the_agent_user_as_root_before_any_kit(monkeypatch, tmp_path):
    _env(monkeypatch, tmp_path)
    guest = _Guest(monkeypatch)
    a = _kit(tmp_path, "a", "commands:\n  - phase: startup\n    command:\n      - env\n")
    result = kit_msb.ensure_kits_applied("box", [a], ro_required=False)
    assert result.agent_user is True and result.applied == ["a"]
    flags, argv = guest.execs[0]
    assert flags == ["-u", "0"] and _agent_user_step(argv)
    assert "useradd -M -d /home/agent" in argv[2] and "test -w /home/agent" in argv[2]


def test_a_failed_agent_user_setup_is_reported_and_the_kits_still_attempted(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    _Guest(monkeypatch, fail=_agent_user_step)
    a = _kit(tmp_path, "a", "commands:\n  - phase: startup\n    command:\n      - env\n")
    result = kit_msb.ensure_kits_applied("box", [a], ro_required=False)
    assert result.agent_user is False and result.applied == ["a"]  # a heal goes on, as in Bash
    assert "writable agent home" in capsys.readouterr().err


def test_create_fails_when_the_agent_user_cannot_be_set_up(monkeypatch, tmp_path, capsys):
    ws = _env(monkeypatch, tmp_path)
    _Guest(monkeypatch, fail=_agent_user_step)
    rc, doc = _invoke(capsys, "--backend", "msb", "create", "shell", str(ws), "--name", "box", "--json")
    assert rc == 1 and doc["error"]["code"] == errors.FAILURE, doc
    assert "agent user" in doc["error"]["message"]
    assert "box" not in _catalog(tmp_path)
    assert state.record_read("msb", "box") is None


# ---------------------------------------------------------------------------
# Files, read-only staging.
# ---------------------------------------------------------------------------

_RO_KIT = """files:
  - path: /home/agent/.local/bin/start.sh
    mode: "0755"
    source: files/start.sh
    readonly: true
  - path: /home/agent/conf/plain.txt
    mode: "0644"
    source: files/plain.txt
commands:
  - phase: startup
    user: "1000"
    command:
      - sh
      - /home/agent/.local/bin/start.sh
"""


def test_readonly_file_is_staged_on_the_mount_and_commands_use_it(monkeypatch, tmp_path):
    _env(monkeypatch, tmp_path)
    guest = _Guest(monkeypatch)
    kit = _kit(tmp_path, "ro", _RO_KIT, {"files/start.sh": "echo hi\n", "files/plain.txt": "x\n"})
    gate = kit_msb.RoGate("box", True, check=lambda n: ("ok", ""))
    assert kit_msb.apply_kit("box", kit, [], gate, force=False)
    staged_guest = kit_msb.ro_guest_path("/home/agent/.local/bin/start.sh")
    assert staged_guest.startswith(f"{GUEST}/kit-files/home-agent-local-bin-start-sh.")
    host = security.host_config_dir("box") / "kit-files" / staged_guest.rsplit("/", 1)[1]
    assert host.read_text(encoding="utf-8") == "echo hi\n"
    if os.name != "nt":
        assert stat.S_IMODE(host.stat().st_mode) == 0o555
        assert stat.S_IMODE(host.parent.stat().st_mode) == 0o711
    else:
        assert not os.access(host, os.W_OK)  # the read-only attribute
    # Only the plain file is copied into the guest; the command runs the staged copy.
    assert [dst for _src, dst in guest.copies] == ["box:/home/agent/conf/plain.txt"]
    ((_flags, argv),) = guest.commands()
    assert argv == ["sh", staged_guest]


def test_readonly_file_never_falls_back_when_the_mount_is_unconfirmed(monkeypatch, tmp_path):
    _env(monkeypatch, tmp_path)
    guest = _Guest(monkeypatch)
    kit = _kit(tmp_path, "ro", _RO_KIT, {"files/start.sh": "echo hi\n", "files/plain.txt": "x\n"})
    gate = kit_msb.RoGate("box", True, check=lambda n: ("missing", "msb does not record it read-only"))
    with pytest.raises(kit_msb.KitApplyFailed, match="no guest-copy fallback"):
        kit_msb.apply_kit("box", kit, [], gate, force=False)
    assert not any(dst.endswith("start.sh") for _src, dst in guest.copies)
    assert guest.commands() == []


def test_readonly_file_on_a_legacy_sandbox_is_copied_with_a_warning(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    guest = _Guest(monkeypatch)
    kit = _kit(tmp_path, "ro", _RO_KIT, {"files/start.sh": "echo hi\n", "files/plain.txt": "x\n"})
    assert kit_msb.apply_kit("box", kit, [], kit_msb.RoGate("box", False), force=False)
    assert "box:/home/agent/.local/bin/start.sh" in [dst for _src, dst in guest.copies]
    assert "no read-only host-config record" in capsys.readouterr().err
    assert guest.commands()[0][1] == ["sh", "/home/agent/.local/bin/start.sh"]


def test_file_placement_verifies_chmods_and_chowns_the_top_directory(monkeypatch, tmp_path):
    _env(monkeypatch, tmp_path)
    guest = _Guest(monkeypatch)
    kit = _kit(tmp_path, "f", _RO_KIT, {"files/start.sh": "a\n", "files/plain.txt": "b\n"})
    kit_msb.apply_kit("box", kit, [], kit_msb.RoGate("box", False), force=False)
    places = [a for _f, a in guest.execs if a[:3] == ["sh", "-c", kit_msb._PLACE_SCRIPT]]
    assert places[0][4:] == ["/home/agent/.local/bin/start.sh", "0755", "/home/agent/.local"]
    assert places[1][4:] == ["/home/agent/conf/plain.txt", "0644", "/home/agent/conf"]
    mkdir = [a for _f, a in guest.execs if a[:3] == ["sh", "-c", 'mkdir -p "$@"']]
    assert mkdir == [["sh", "-c", 'mkdir -p "$@"', "sh", "/home/agent/.local/bin", "/home/agent/conf"]]


def test_a_file_that_never_lands_fails_the_kit_after_one_retry(monkeypatch, tmp_path):
    _env(monkeypatch, tmp_path)
    guest = _Guest(monkeypatch, fail=lambda argv: argv[2] == kit_msb._PLACE_SCRIPT)
    kit = _kit(tmp_path, "f", _RO_KIT, {"files/start.sh": "a\n", "files/plain.txt": "b\n"})
    with pytest.raises(kit_msb.KitApplyFailed, match="could not place"):
        kit_msb.apply_kit("box", kit, [], kit_msb.RoGate("box", False), force=False)
    assert len(guest.copies) == 2 and guest.commands() == []


def test_a_source_outside_the_kit_is_skipped(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    guest = _Guest(monkeypatch)
    (tmp_path / "secret.txt").write_text("s", encoding="utf-8")
    kit = _kit(tmp_path, "f", "files:\n  - path: /home/agent/x\n    source: files/link\n")
    (kit.spec.kit_dir / "files").mkdir()
    (kit.spec.kit_dir / "files" / "link").symlink_to(tmp_path / "secret.txt")
    assert kit_msb.apply_kit("box", kit, [], kit_msb.RoGate("box", False), force=False)
    assert guest.copies == []
    assert "not a regular file inside the kit directory" in capsys.readouterr().err


# ---------------------------------------------------------------------------
# Commands: phase semantics and users.
# ---------------------------------------------------------------------------

_CMD_KIT = """commands:
  - phase: install
    user: "0"
    command:
      - sh
      - -c
      - echo install
  - phase: initFiles
    user: "1000"
    command:
      - init
  - phase: startup
    user: agent
    background: true
    command:
      - daemon
      - --serve
  - phase: startup
    command:
      - node
      - /x.mjs
  - phase: startup
    user: bob
    command:
      - whoami
"""


def test_commands_run_in_order_with_their_phase_and_user(monkeypatch, tmp_path):
    _env(monkeypatch, tmp_path)
    guest = _Guest(monkeypatch)
    kit = _kit(tmp_path, "c", _CMD_KIT)
    assert kit_msb.apply_kit("box", kit, ["X=1"], kit_msb.RoGate("box", False), force=False)
    env = ["-e", "X=1", *[t for g in GUARDS for t in ("-e", g)]]
    assert guest.commands() == [
        (["-u", "0", *env], ["sh", "-c", "echo install"]),
        (["-u", "agent", "-e", "HOME=/home/agent", *env], ["init"]),
        (["-u", "agent", "-e", "HOME=/home/agent", *env], ["sh", "-c", 'nohup "$@" >/dev/null 2>&1 & exit 0', "sh", "daemon", "--serve"]),
        (env, ["sh", "-c", '"$@"', "sh", "node", "/x.mjs"]),
        (["-u", "bob", *env], ["whoami"]),
    ]


def test_install_runs_once_per_guest_unless_forced(monkeypatch, tmp_path):
    _env(monkeypatch, tmp_path)
    guest = _Guest(monkeypatch)
    kit = _kit(tmp_path, "c", _CMD_KIT)

    def installs():
        return [a for _f, a in guest.commands() if a == ["sh", "-c", "echo install"]]

    for _ in range(2):
        kit_msb.apply_kit("box", kit, [], kit_msb.RoGate("box", False), force=False)
    assert len(installs()) == 1
    kit_msb.apply_kit("box", kit, [], kit_msb.RoGate("box", False), force=True)
    assert len(installs()) == 2
    kit_msb.clear_instance_state("box")  # a new guest under the same name
    kit_msb.apply_kit("box", kit, [], kit_msb.RoGate("box", False), force=False)
    assert len(installs()) == 3


def test_a_failed_command_is_reported_and_its_install_marker_not_written(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path)
    guest = _Guest(monkeypatch, fail=lambda argv: argv == ["sh", "-c", "echo install"])
    kit = _kit(tmp_path, "c", _CMD_KIT)
    assert not kit_msb.apply_kit("box", kit, [], kit_msb.RoGate("box", False), force=False)
    assert "install command of kit 'c' failed" in capsys.readouterr().err
    assert len(guest.commands()) == 5  # the other commands still ran, as in Bash
    hcfg = security.host_config_dir("box")
    assert not hcfg.exists() or not [p for p in hcfg.iterdir() if p.name.startswith("install-")]


def test_shortcut_kit_skips_files_and_commands(monkeypatch, tmp_path):
    _env(monkeypatch, tmp_path)
    guest = _Guest(monkeypatch)
    spec = kitspec.load_bundled_kit("zscaler-ca-certificate")
    assert kit_msb.apply_kit("box", kit_msb.Kit("zscaler-ca-certificate", "support", spec), [], kit_msb.RoGate("box", False), force=False)
    assert guest.execs == [] and guest.copies == []


# ---------------------------------------------------------------------------
# Environment (ADR-0033).
# ---------------------------------------------------------------------------


def test_env_merge_last_kit_wins_first_fixes_order_and_guards_stay_owned(monkeypatch, tmp_path):
    a = _kit(tmp_path, "a", "environment:\n  X: one\n  GIT_TERMINAL_PROMPT: \"1\"\n")
    b = _kit(tmp_path, "b", "environment:\n  X: two\n  Y: three\n")
    merged = kit_msb.merge_env([a, b])
    assert merged == ["X=two", "GIT_TERMINAL_PROMPT=1", "Y=three"]
    # b never runs with a's guard opt-out; a keeps its own and gets no acq guards.
    assert kit_msb.command_env(merged, kit_msb.own_guards(b)) == ["X=two", "Y=three", *GUARDS]
    assert kit_msb.command_env(merged, kit_msb.own_guards(a)) == ["X=two", "Y=three", "GIT_TERMINAL_PROMPT=1"]
    spec = kitspec.load_bundled_kit("zscaler-ca-certificate")
    assert kit_msb.merge_env([kit_msb.Kit("z", "support", spec)]) == []


def test_ensure_rebuilds_the_persisted_kit_env_from_the_current_kits(monkeypatch, tmp_path):
    _env(monkeypatch, tmp_path)
    guest = _Guest(monkeypatch)
    a = _kit(tmp_path, "a", "environment:\n  X: one\ncommands:\n  - phase: startup\n    command:\n      - env\n")
    b = _kit(tmp_path, "b", "environment:\n  X: two\n")
    assert kit_msb.hc_append("box", "kit-env", "STALE=1")
    result = kit_msb.ensure_kits_applied("box", [a, b], ro_required=False)
    assert result.applied == ["a", "b"] and result.incomplete == []
    text = (security.host_config_dir("box") / "kit-env").read_text(encoding="utf-8")
    assert text == "X=one\nX=two\n"  # replayed last-value-wins, as Bash
    # a's command already saw b's value: the merge happens before the first kit.
    ((flags, _argv),) = guest.commands()
    assert flags[:2] == ["-e", "X=two"]


def test_apply_single_layers_the_kit_env_over_the_persisted_env(monkeypatch, tmp_path):
    _env(monkeypatch, tmp_path)
    guest = _Guest(monkeypatch)
    kit_msb.hc_append("box", "kit-env", "X=old")
    kit_msb.hc_append("box", "kit-env", "Z=kept")
    kit = _kit(tmp_path, "s", "environment:\n  X: new\ncommands:\n  - phase: startup\n    command:\n      - env\n")
    assert kit_msb.apply_single("box", kit, ro_required=False)
    ((flags, _argv),) = guest.commands()
    assert flags[:4] == ["-e", "X=new", "-e", "Z=kept"]


# ---------------------------------------------------------------------------
# Startup script (ADR-0017).
# ---------------------------------------------------------------------------


def test_startup_script_quotes_kit_data_and_only_the_first_kit_stakes_it(tmp_path):
    a = _kit(tmp_path, "a", "commands:\n  - phase: startup\n    command:\n      - echo\n      - \"it's\"\n"
             "  - phase: startup\n    user: \"1000\"\n    background: true\n    command:\n      - daemon\n")
    b = _kit(tmp_path, "b", "commands:\n  - phase: startup\n    command:\n      - b-only\n")
    script = kit_msb.startup_script([a, b], [], ro_mount=False)
    assert script is not None and script.startswith("#!/bin/sh\n# acq-generated msb startup script")
    assert "b-only" not in script
    first, second = script.splitlines()[5:7]
    assert first.endswith(" sh -c 'exec \"$@\"' sh 'echo' 'it'\\''s'")
    assert "nohup sh -c" in second and second.startswith("if command -v runuser")
    assert kit_msb.startup_script([_kit(tmp_path, "none", "")], [], ro_mount=False) is None


def test_create_registers_the_startup_script_and_removes_the_staged_file(monkeypatch, tmp_path, capsys):
    ws = _env(monkeypatch, tmp_path)
    seen = _spy(monkeypatch)
    bodies = {}
    real = msb.create

    def create(*args, **kwargs):
        flags = kwargs["kit_flags"]
        path = Path(flags[flags.index("--script-path") + 1].split(":", 1)[1])
        bodies["path"], bodies["text"] = path, path.read_text(encoding="utf-8")
        return real(*args, **kwargs)

    monkeypatch.setattr(msb, "create", create)
    assert _invoke(capsys, "--backend", "msb", "create", "opencode", str(ws), "--name", "box", "--json")[0] == 0
    argv = _create_argv(seen)
    assert argv[argv.index("--script-path") + 1].startswith(f"{kit_msb.STARTUP_SCRIPT_NAME}:")
    # Bash parity: the first kit with startup commands (the CA kit) stakes it.
    assert "update-ca-certificates" in bodies["text"]
    if os.name != "nt":
        assert stat.S_IMODE(bodies["path"].parent.stat().st_mode) == 0o700
    assert not bodies["path"].exists()


# ---------------------------------------------------------------------------
# Bash parity.
# ---------------------------------------------------------------------------

_BASH_PRELUDE = r"""
ACQ_SOURCE_ONLY=1 . "$REPO/acq"
type _acq_msb_generate_startup_script >/dev/null 2>&1 || . "$REPO/acq.backends/msb.sh"
_acq_msb_version() { echo 0.7.7; }
"""


def _bash(tmp_path, script: str, *args: str) -> str:
    env = {k: v for k, v in os.environ.items() if not k.startswith("ACQ_")}
    env |= {"REPO": str(REPO_ROOT), "BATS_TEST_NAME": "kit-msb-parity", "LC_ALL": "C", "ACQ_STATE_DIR": str(tmp_path / "bash-state")}
    assert BASH is not None
    return subprocess.run([BASH, "-c", _BASH_PRELUDE + script, "x", *args], env=env, capture_output=True,
                          check=True, cwd=tmp_path).stdout.decode("utf-8")


@needs_bash
@pytest.mark.parametrize("name", ["zscaler-ca-certificate", "opencode", "agentic-coding-playbook", "custom"])
def test_startup_script_matches_bash(tmp_path, name):
    if name == "custom":
        kit = _kit(tmp_path, "custom", _RO_KIT + "  - phase: startup\n    user: bob\n    background: true\n    command:\n      - x\n      - \"a'b\"\n",
                   {"files/start.sh": "a\n", "files/plain.txt": "b\n"})
    else:
        kit = kit_msb.Kit(name, "support", kitspec.load_bundled_kit(name))
    merged = ["X=1", "GIT_TERMINAL_PROMPT=1", "Y=two words"]
    spec = str(kit.spec.kit_dir / "spec.yaml")
    bash = _bash(tmp_path, '_m=("${@:2}"); _acq_msb_generate_startup_script "$1" /dev/stdout _m', spec, *merged)
    assert kit_msb.startup_script([kit], merged, ro_mount=True) == bash


@needs_bash
@pytest.mark.parametrize("user", ["", "0", "root", "1000", "agent", "bob"])
@pytest.mark.parametrize("own", [[], ["GIT_TERMINAL_PROMPT=1"], ["GIT_ASKPASS=/x"]])
def test_exec_flags_match_bash(tmp_path, user, own):
    merged = ["A=1", "GIT_ASKPASS=/other", "B=x y"]
    script = (
        '_u="$1"; _n="$2"; shift 2; _o=(); _m=();'
        ' while [ "$_n" -gt 0 ]; do _o+=("$1"); shift; _n=$((_n-1)); done; _m=("$@");'
        ' _acq_msb_exec_flags_into uf ef "$_u" _m _o; printf "%s\\n" "${uf[@]}" "${ef[@]}"'
    )
    bash = _bash(tmp_path, script, user, str(len(own)), *own, *merged).splitlines()
    assert kit_msb.exec_flags(user, kit_msb.command_env(merged, own)) == bash


@needs_bash
def test_ro_guest_path_matches_bash(tmp_path):
    path = "/home/agent/.local/bin/My-Start_v2.sh"
    bash = _bash(tmp_path, '_acq_msb_stage_readonly_file box "$1" "$2"', path, str(REPO_ROOT / "LICENSE"))
    assert bash.strip() == kit_msb.ro_guest_path(path)


# ---------------------------------------------------------------------------
# Review fixes.
# ---------------------------------------------------------------------------


def test_restaging_a_readonly_file_replaces_the_0555_copy(monkeypatch, tmp_path):
    _env(monkeypatch, tmp_path)
    src = tmp_path / "start.sh"
    src.write_text("one\n", encoding="utf-8")
    guest = kit_msb.stage_readonly_file("box", "/home/agent/start.sh", src)
    src.write_text("two\n", encoding="utf-8")
    assert kit_msb.stage_readonly_file("box", "/home/agent/start.sh", src) == guest  # no EACCES
    dest = security.host_config_dir("box") / "kit-files" / guest.rsplit("/", 1)[1]
    assert dest.read_text(encoding="utf-8") == "two\n"
    if os.name != "nt":
        assert stat.S_IMODE(dest.stat().st_mode) == 0o555
    else:
        assert not os.access(dest, os.W_OK)  # the read-only attribute
    assert sorted(p.name for p in dest.parent.iterdir()) == [dest.name]  # no temp file left


def test_reapplying_a_readonly_kit_succeeds(monkeypatch, tmp_path):
    _env(monkeypatch, tmp_path)
    _Guest(monkeypatch)
    kit = _kit(tmp_path, "ro", _RO_KIT, {"files/start.sh": "echo hi\n", "files/plain.txt": "x\n"})
    for _ in range(2):  # create, then kit update / kit apply / recreate
        assert kit_msb.apply_kit("box", kit, [], kit_msb.RoGate("box", True, check=lambda n: ("ok", "")), force=True)


def test_create_on_an_image_without_the_agent_user_confirms_the_mount(monkeypatch, tmp_path, capsys):
    # The probe runs before the kits set up the agent user, so it must not need one.
    ws = _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_MSB_STUB_NO_AGENT_USER", "box")
    rc = cli.main(["--backend", "msb", "create", "shell", str(ws), "--name", "box", "--json"])
    doc = json.loads(capsys.readouterr().out)
    assert rc == 0, doc
    assert doc["data"]["ro_host_config"] is True
    assert state.record_read("msb", "box")["ro_host_config"] is True


def test_kit_kits_are_recorded_and_reapplied_by_kit_update_and_recreate(monkeypatch, tmp_path, capsys):
    ws = _env(monkeypatch, tmp_path)
    ref = kitspec.builtin_kit_ref("opencode")
    rc, doc = _invoke(capsys, "--backend", "msb", "create", "shell", str(ws), "--name", "box", "--kit", "opencode", "--json")
    assert rc == 0 and doc["data"]["kits"][-1] == "opencode"
    assert kit_msb.cli_kits_read("box") == ([ref], [])
    kits.provenance_remove("msb", "box")  # make the bundle "unknown" so update reapplies
    rc, doc = _invoke(capsys, "--backend", "msb", "kit", "update", "box", "--yes", "--json")
    assert rc == 0 and doc["data"]["kits"] == [*BUILTINS, "opencode"]
    # Recreate rebuilds from the same record (here after the guest was lost out of band).
    catalog = tmp_path / "msb-home" / ".microsandbox" / "catalog.json"
    catalog.write_text("{}", encoding="utf-8")
    assert security.mount_state("msb", "box") == "unknown"
    rc, doc = _invoke(capsys, "--backend", "msb", "create", "--recreate", "box", "--yes", "--json")
    assert rc == 0 and doc["data"]["kits"][-1] == "opencode"
    assert _invoke(capsys, "--backend", "msb", "rm", "box", "--json")[0] == 0
    assert kit_msb.cli_kits_read("box") == ([], [])


def test_recorded_extra_kits_replace_the_environment(monkeypatch, tmp_path):
    _env(monkeypatch, tmp_path)
    ref = kitspec.builtin_kit_ref("git-ssh-sign")
    kit_msb.cli_kits_write("box", [kit_msb.Kit("git-ssh-sign", "extra", kitspec.load_bundled_kit("git-ssh-sign"), ref)])
    path = kit_msb._cli_kits_path("box")
    path.write_text(path.read_text(encoding="utf-8") + "kit=relative/kit\n", encoding="utf-8")
    assert kit_msb.cli_kits_read("box") == ([], [ref])  # the relative ref is skipped
    monkeypatch.setenv("ACQ_EXTRA_KITS", "would-need-a-fetch")
    names = [k.name for k in kit_msb.select("shell", [], image_is_default=True, extras=[ref])]
    assert names == BUILTINS  # the recorded extra replaced the env; deduped against the built-in


# ---------------------------------------------------------------------------
# Windows: no read-only mount, and recreate does not refuse or loop.
# ---------------------------------------------------------------------------


def test_windows_create_asks_for_no_mount_and_records_none(monkeypatch, tmp_path, capsys):
    ws = _env(monkeypatch, tmp_path, windows=True)
    seen = _spy(monkeypatch)
    rc, doc = _invoke(capsys, "--backend", "msb", "create", "shell", str(ws), "--name", "box", "--json")
    assert rc == 0 and doc["data"]["ro_host_config"] is False
    assert not any(t.endswith(f"{GUEST}:ro") for t in _create_argv(seen))
    assert not [a for a in seen if a[0] == "inspect"]
    assert not state.record_read("msb", "box").get("ro_host_config")


def test_windows_gate_refuses_a_recorded_mount_and_names_the_platform(monkeypatch, tmp_path):
    _env(monkeypatch, tmp_path, catalog={"sec": "running"}, windows=True)
    with pytest.raises(security.SecurityException) as info:
        security.assert_trusted(_SEC, "msb", "sec")
    assert security.PLATFORM_PROBLEM in info.value.message
    assert "upgrade msb" not in (info.value.remediation or "")  # an upgrade would not help
    assert "--recreate sec" in (info.value.remediation or "")


def test_windows_recreate_proceeds_without_claiming_the_mount_and_does_not_loop(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path, windows=True)
    _seed_sec()
    seen = _spy(monkeypatch)
    rc, doc = _invoke(capsys, "--backend", "msb", "create", "--recreate", "sec", "--yes", "--json")
    assert rc == 0 and doc["data"]["recreated"] is True and doc["data"]["ro_host_config"] is False
    assert not any(t.endswith(f"{GUEST}:ro") for t in _create_argv(seen))
    assert not state.record_read("msb", "sec").get("ro_host_config")
    monkeypatch.setattr(msb, "launch", lambda *a, **k: 0)
    rc, doc = _invoke(capsys, "--backend", "msb", "run", "sec", "--json")
    assert rc == 0 and doc["data"]["action"] == "reattached"
    # A second recreate is refused: nothing is missing any more.
    rc, doc = _invoke(capsys, "--backend", "msb", "create", "--recreate", "sec", "--yes", "--json")
    assert rc == 1 and doc["error"]["code"] == errors.VALIDATION_FAILED


def test_windows_recreate_tells_a_human_the_mount_was_not_established(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path, windows=True)
    _seed_sec()
    assert cli.main(["--backend", "msb", "create", "--recreate", "sec", "--yes"]) == 0
    out = capsys.readouterr().out
    assert "recreated sandbox 'sec'" in out and "was not established" in out


def test_restaging_on_windows_clears_the_read_only_attribute_first(monkeypatch, tmp_path):
    _env(monkeypatch, tmp_path)
    monkeypatch.setattr(kit_msb, "WINDOWS", True)
    calls = []
    real_chmod = os.chmod
    monkeypatch.setattr(os, "chmod", lambda p, m, **kw: calls.append((str(p), m)) or real_chmod(p, m, **kw))
    src = tmp_path / "s.sh"
    src.write_text("a\n", encoding="utf-8")
    guest = kit_msb.stage_readonly_file("box", "/home/agent/s.sh", src)
    dest = str(security.host_config_dir("box") / "kit-files" / guest.rsplit("/", 1)[1])
    assert (dest, stat.S_IWRITE) not in calls  # nothing to clear the first time
    kit_msb.stage_readonly_file("box", "/home/agent/s.sh", src)
    assert (dest, stat.S_IWRITE) in calls
