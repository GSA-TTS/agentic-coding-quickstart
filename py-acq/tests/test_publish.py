"""Tier-2 tests for port publishing (ADR-0014, ADR-0015, ADR-0034).

``--publish HOST:GUEST`` on create/run, the msb create-time ``-p`` composition,
and ``acq ports NAME --publish``. Each test pins one behaviour of the Bash acq
(``acq.backends/common.sh`` ``extract_publish_flags``, ``acq.backends/msb.sh``
``_acq_msb_port_flags_from_records`` and ``acq_backend_ports``). Host ports are
never probed for real unless a test opens and closes its own listener; the
background tunnel processes are replaced by test doubles, except in the
teardown tests, which kill real sleeping processes they started themselves.
"""

from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
from types import SimpleNamespace

import pytest

from acq_py import cli, errors, kitspec, msb, publish, security, state
from acq_py.commands import lifecycle

PROVIDER = pytest.mark.provider_key


def _msb_env(monkeypatch, tmp_path, *, catalog=None):
    monkeypatch.setattr(security, "WINDOWS", False)
    monkeypatch.setenv("ACQ_MSB_BIN", "__stub__")
    monkeypatch.setenv("ACQ_MSB_VERSION", "0.7.7")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "1")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "0")
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("MSB_HOME", str(tmp_path / "msb-home"))
    monkeypatch.setenv("ACQ_MSB_RO_INSPECT_RETRY_SLEEP", "0")
    monkeypatch.setenv("ACQ_MSB_HOST_PROBE_STUB", "1")
    for name in ("ACQ_BACKEND", "ACQ_MSB_STUB_CATALOG", "ACQ_MSB_STUB_PORTS", "ACQ_MSB_HOST_PORTS_BUSY",
                 "ACQ_MSB_HOST_PROBE_UNKNOWN", "ACQ_MSB_FORCE_SERVE_PORT"):
        monkeypatch.delenv(name, raising=False)
    if catalog is not None:
        monkeypatch.setenv("ACQ_MSB_STUB_CATALOG", json.dumps(catalog))
    ws = tmp_path / "ws"
    ws.mkdir(exist_ok=True)
    return ws


def _sbx_env(monkeypatch, tmp_path, *, catalog=None):
    _msb_env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_SBX_BIN", "__stub__")
    monkeypatch.setenv("ACQ_SBX_VERSION", "0.51.0")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "1")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "0")
    monkeypatch.setenv("SBX_HOME", str(tmp_path / "sbx-home"))
    if catalog is not None:
        monkeypatch.setenv("ACQ_SBX_STUB_CATALOG", json.dumps(catalog))
    return tmp_path / "ws"


def _invoke(capsys, *argv):
    rc = cli.main(list(argv))
    captured = capsys.readouterr()
    out = captured.out.strip()
    doc = json.loads(out.splitlines()[-1]) if out else None
    return rc, doc, captured.err


def _spy(monkeypatch, module) -> list[list[str]]:
    seen: list[list[str]] = []
    real = module._run

    def spy(argv, **kwargs):
        seen.append(list(argv))
        return real(argv, **kwargs)

    monkeypatch.setattr(module, "_run", spy)
    return seen


def _kit(*ports: tuple[str, str]):
    """A kit double carrying ``(guest, host)`` published ports."""
    pp = tuple(kitspec.PublishedPort(guest, "tcp", "", host) for guest, host in ports)
    return SimpleNamespace(spec=SimpleNamespace(published_ports=pp))


# ---------------------------------------------------------------------------
# Create-time values (_acq_validate_publish_pair).
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("values,problem", [
    (["6868"], "--publish '6868' is not HOST:GUEST: both sides are required"),
    ([""], "--publish '' is not HOST:GUEST: both sides are required"),
    (["a:80"], "--publish 'a:80': 'a' is not a port number (1..65535)"),
    ([":80"], "--publish ':80': '' is not a port number (1..65535)"),
    (["1:2:3"], "--publish '1:2:3': '2:3' is not a port number (1..65535)"),
    (["0080:80"], "--publish '0080:80': '0080' has a leading zero; write it plainly"),
    (["0:80"], "--publish '0:80': '0' has a leading zero; write it plainly"),
    (["65536:80"], "--publish '65536:80': '65536' is out of range (1..65535)"),
    (["80:1234567"], "--publish '80:1234567': '1234567' is out of range (1..65535)"),
    (["８０:80"], "--publish '８０:80': '８０' is not a port number (1..65535)"),
    (["7000:80", "7001:80"], "--publish: guest port 80 is already mapped to host port 7000; "
                             "drop one of the two --publish flags"),
    ([None], "--publish given with no value (expected HOST:GUEST)"),
])
def test_create_values_are_checked_with_the_bash_rules(values, problem):
    _pairs, problems = publish.validate_create_pairs(values)
    assert problems == [problem]


def test_valid_create_values_pass_in_order():
    pairs, problems = publish.validate_create_pairs(["6868:6767", "1:65535"])
    assert (pairs, problems) == (["6868:6767", "1:65535"], [])


@PROVIDER
@pytest.mark.parametrize("flag", [["--publish", "6868"], ["--publish=0080:80"], ["--publish"]])
def test_a_malformed_publish_creates_nothing(monkeypatch, tmp_path, capsys, flag):
    ws = _msb_env(monkeypatch, tmp_path)
    seen = _spy(monkeypatch, msb)
    rc, doc, _ = _invoke(capsys, "--backend", "msb", "create", "shell", str(ws), "--name", "p1", *flag, "--json")
    assert rc == 1 and doc["error"]["code"] == errors.VALIDATION_FAILED
    assert not [a for a in seen if a[0] == "create"]
    assert state.record_read("msb", "p1") is None


@PROVIDER
@pytest.mark.parametrize("verb", ["create", "run"])
def test_publish_is_refused_on_sbx_naming_the_post_hoc_verb(monkeypatch, tmp_path, capsys, verb):
    ws = _sbx_env(monkeypatch, tmp_path)
    rc, doc, _ = _invoke(capsys, "--backend", "sbx", verb, "shell", str(ws), "--publish", "6868:6767", "--json")
    assert rc == 1
    assert doc["error"]["code"] == errors.UNSUPPORTED
    assert doc["error"]["message"] == publish.SBX_REFUSAL
    assert "acq ports NAME --publish HOST:GUEST" in doc["error"]["remediation"]
    assert state.record_read("sbx", "shell-ws") is None


def test_publish_with_recreate_is_a_usage_error(monkeypatch, tmp_path, capsys):
    _msb_env(monkeypatch, tmp_path)
    rc, doc, _ = _invoke(capsys, "--backend", "msb", "create", "--recreate", "box", "--publish", "1:2", "--json")
    assert rc == 2 and doc["error"]["code"] == "usage"


# ---------------------------------------------------------------------------
# msb create-time -p flags (_acq_msb_port_flags_from_records).
# ---------------------------------------------------------------------------


@PROVIDER
def test_create_publish_becomes_a_create_time_mapping(monkeypatch, tmp_path, capsys):
    ws = _msb_env(monkeypatch, tmp_path)
    seen = _spy(monkeypatch, msb)
    rc, doc, err = _invoke(capsys, "--backend", "msb", "create", "shell", str(ws), "--name", "pub",
                           "--publish", "6868:6767", "--publish=7000:7001", "--json")
    assert rc == 0, err
    (create,) = [a for a in seen if a[0] == "create"]
    assert [create[i + 1] for i, a in enumerate(create) if a == "-p"] == ["6868:6767", "7000:7001"]
    assert "--publish" not in " ".join(create)
    assert doc["data"]["ports"] == [{"host_port": 6868, "guest_port": 6767, "origin": "create"},
                                    {"host_port": 7000, "guest_port": 7001, "origin": "create"}]
    assert "acq(msb): note: --publish 6868:6767: no applied kit declares guest port 6767; publishing it anyway." in err
    rc, doc, _ = _invoke(capsys, "--backend", "msb", "ports", "pub", "--json")
    assert rc == 0
    assert doc["data"]["ports"] == [{"host_port": 6868, "guest_port": 6767, "origin": "create"},
                                    {"host_port": 7000, "guest_port": 7001, "origin": "create"}]


@PROVIDER
def test_a_contended_publish_host_port_fails_the_create(monkeypatch, tmp_path, capsys):
    ws = _msb_env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_MSB_HOST_PORTS_BUSY", "6868")
    seen = _spy(monkeypatch, msb)
    rc, doc, _ = _invoke(capsys, "--backend", "msb", "create", "shell", str(ws), "--name", "busy",
                         "--publish", "6868:6767", "--json")
    assert rc == 1 and doc["error"]["code"] == errors.FAILURE
    assert "host port 6868 (for guest port 6767) is already in use on 127.0.0.1" in doc["error"]["message"]
    assert not [a for a in seen if a[0] == "create"]
    assert state.record_read("msb", "busy") is None


def test_a_kit_port_with_no_host_gets_a_free_port_not_the_guest_port(monkeypatch):
    monkeypatch.setenv("ACQ_MSB_HOST_PROBE_STUB", "1")
    flags, mappings = publish.create_port_flags("box", [_kit(("4096", ""))], [])
    host = mappings[0]["host_port"]
    assert flags == ["-p", f"{host}:4096"] and host != 4096 and 20000 <= host <= 59999


def test_two_sandboxes_from_one_kit_get_different_host_ports(monkeypatch):
    monkeypatch.setenv("ACQ_MSB_HOST_PROBE_STUB", "1")
    first = publish.create_port_flags("a", [_kit(("4096", ""))], [])[1][0]["host_port"]
    second = publish.create_port_flags("b", [_kit(("4096", ""))], [])[1][0]["host_port"]
    assert first != second


def test_a_kit_pinned_host_port_is_honoured(monkeypatch):
    monkeypatch.setenv("ACQ_MSB_HOST_PROBE_STUB", "1")
    assert publish.create_port_flags("box", [_kit(("3000", "3000"))], [])[0] == ["-p", "3000:3000"]


@pytest.mark.parametrize("kit_host", ["", "3000"])
def test_publish_overrides_a_kit_entry(monkeypatch, capsys, kit_host):
    monkeypatch.setenv("ACQ_MSB_HOST_PROBE_STUB", "1")
    flags, _ = publish.create_port_flags("box", [_kit(("3000", kit_host))], ["6868:3000"])
    assert flags == ["-p", "6868:3000"]
    assert "no applied kit declares" not in capsys.readouterr().err


def test_two_kits_publishing_one_guest_port_collapse_to_one_flag(monkeypatch):
    monkeypatch.setenv("ACQ_MSB_HOST_PROBE_STUB", "1")
    flags, _ = publish.create_port_flags("box", [_kit(("3000", "3100")), _kit(("3000", "3200"))], [])
    assert flags == ["-p", "3200:3000"]


def test_a_contended_kit_pinned_host_port_fails_and_is_not_substituted(monkeypatch):
    monkeypatch.setenv("ACQ_MSB_HOST_PORTS_BUSY", "3000")
    monkeypatch.setenv("ACQ_MSB_HOST_PROBE_STUB", "1")
    with pytest.raises(publish.PublishError) as info:
        publish.create_port_flags("box", [_kit(("3000", "3000"))], [])
    assert "acq will not substitute a different port" in info.value.message


def test_one_host_port_for_two_guest_ports_fails(monkeypatch):
    monkeypatch.setenv("ACQ_MSB_HOST_PROBE_STUB", "1")
    with pytest.raises(publish.PublishError) as info:
        publish.create_port_flags("box", [], ["7000:3000", "7000:4000"])
    assert "host port 7000 is requested for more than one guest port (again for guest port 4000)" \
        in info.value.message


def test_a_busy_chosen_port_is_skipped(monkeypatch):
    monkeypatch.setenv("ACQ_MSB_HOST_PROBE_STUB", "1")
    monkeypatch.setattr(publish, "_PICK_BASE", 0)
    upcoming = publish._PICK_FLOOR + (next(publish._PICK_SEQ) + 1)
    monkeypatch.setenv("ACQ_MSB_HOST_PORTS_BUSY", str(upcoming))
    _, mappings = publish.create_port_flags("box", [_kit(("4096", ""))], [])
    assert mappings[0]["host_port"] == upcoming + 1


def test_a_chosen_port_never_reuses_one_this_create_maps(monkeypatch):
    monkeypatch.setenv("ACQ_MSB_HOST_PROBE_STUB", "1")
    monkeypatch.setattr(publish, "_PICK_BASE", 0)
    upcoming = publish._PICK_FLOOR + (next(publish._PICK_SEQ) + 1)
    _, mappings = publish.create_port_flags("box", [_kit(("4096", ""))], [f"{upcoming}:3000"])
    assert {m["guest_port"]: m["host_port"] for m in mappings} == {3000: upcoming, 4096: upcoming + 1}


def test_no_free_port_fails_the_create(monkeypatch):
    monkeypatch.setenv("ACQ_MSB_FORCE_SERVE_PORT", "30000")
    monkeypatch.setenv("ACQ_MSB_HOST_PORTS_BUSY", "30000")
    with pytest.raises(publish.PublishError) as info:
        publish.create_port_flags("box", [_kit(("4096", ""))], [])
    assert "could not find a free host port for guest port 4096" in info.value.message


def test_an_unprobeable_host_is_said_once_and_ports_are_still_published(monkeypatch, capsys):
    monkeypatch.setenv("ACQ_MSB_HOST_PROBE_UNKNOWN", "1")
    flags, _ = publish.create_port_flags("box", [_kit(("3000", "3000"), ("4096", ""))], ["6868:6767"])
    assert flags.count("-p") == 3
    assert capsys.readouterr().err.count("cannot probe host port availability") == 1


def test_the_probe_reads_a_real_listener(monkeypatch):
    for name in ("ACQ_MSB_HOST_PROBE_STUB", "ACQ_MSB_HOST_PROBE_UNKNOWN", "ACQ_MSB_HOST_PORTS_BUSY"):
        monkeypatch.delenv(name, raising=False)
    listener = socket.socket()
    try:
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        port = listener.getsockname()[1]
        assert publish.host_port_status(port) == "busy"
    finally:
        listener.close()
    assert publish.host_port_status(port) in ("free", "unknown")


def test_a_kit_with_volumes_is_still_refused_but_ports_are_not():
    from acq_py import kit_msb

    kit_msb._check_creatable("ports", SimpleNamespace(volumes=(), published_ports=(object(),)))
    with pytest.raises(msb.MsbError) as info:
        kit_msb._check_creatable("vol", SimpleNamespace(volumes=(object(),), published_ports=()))
    assert info.value.code == errors.UNSUPPORTED and "volumes" in info.value.message


# ---------------------------------------------------------------------------
# Re-attach: --publish is create-time only (note_publish_ignored_on_reattach).
# ---------------------------------------------------------------------------


@PROVIDER
def test_publish_on_a_reattach_says_it_is_ignored(monkeypatch, tmp_path, capsys):
    ws = _msb_env(monkeypatch, tmp_path)
    assert _invoke(capsys, "--backend", "msb", "create", "shell", str(ws), "--name", "re", "--json")[0] == 0
    monkeypatch.setattr(lifecycle, "_launch_after_envelope", lambda *a, **k: 0)
    rc, _, err = _invoke(capsys, "--backend", "msb", "run", "shell", str(ws), "--name", "re",
                         "--publish", "6868:6767", "--json")
    assert rc == 0
    assert publish.reattach_note("re") in err
    rc, _, err = _invoke(capsys, "--backend", "msb", "run", "re", "--publish", "6868:6767", "--json")
    assert rc == 0
    assert publish.reattach_note("re") in err
    assert "ports re --publish HOST:GUEST" in publish.reattach_note("re")


# ---------------------------------------------------------------------------
# Recreate keeps the old guest's mappings.
# ---------------------------------------------------------------------------


def test_recreate_keeps_the_declared_create_time_mappings(monkeypatch):
    monkeypatch.setattr(msb, "exists", lambda name: True)
    monkeypatch.setattr(msb, "ports", lambda name: [
        {"host_port": 6868, "guest_port": 6767, "origin": "create"},
        {"host_port": 9000, "guest_port": 22, "origin": "post-hoc"},
    ])
    assert lifecycle._declared_create_ports("box") == (("6767", 6868),)


def test_a_preferred_host_port_is_kept_when_free(monkeypatch):
    monkeypatch.setenv("ACQ_MSB_HOST_PROBE_STUB", "1")
    flags, _ = publish.create_port_flags("box", [_kit(("4096", ""))], [], {"4096": 6868})
    assert flags == ["-p", "6868:4096"]


def test_a_busy_preferred_host_port_falls_back_to_a_free_one(monkeypatch, capsys):
    monkeypatch.setenv("ACQ_MSB_HOST_PROBE_STUB", "1")
    monkeypatch.setenv("ACQ_MSB_HOST_PORTS_BUSY", "6868")
    _, mappings = publish.create_port_flags("box", [_kit(("4096", ""))], [], {"4096": 6868})
    assert mappings[0]["host_port"] not in (6868, 4096)
    assert "host port 6868, which guest port 4096 had before the recreate, is in use now" in capsys.readouterr().err


def test_a_preference_never_overrides_a_kit_pinned_host_port(monkeypatch):
    monkeypatch.setenv("ACQ_MSB_HOST_PROBE_STUB", "1")
    flags, _ = publish.create_port_flags("box", [_kit(("3000", "3000"))], [], {"3000": 6868})
    assert flags == ["-p", "3000:3000"]


def test_a_preference_for_a_guest_port_no_kit_declares_is_dropped(monkeypatch, capsys):
    monkeypatch.setenv("ACQ_MSB_HOST_PROBE_STUB", "1")
    assert publish.create_port_flags("box", [], [], {"6767": 6868}) == ([], [])
    assert "no applied kit declares" not in capsys.readouterr().err


@PROVIDER
@pytest.mark.parametrize("busy_after_remove", [False, True])
def test_recreate_survives_a_kept_port_taken_after_the_old_guest_is_removed(
        monkeypatch, tmp_path, capsys, busy_after_remove):
    from acq_py import kit_msb

    _msb_env(monkeypatch, tmp_path, catalog={"sec": "running"})
    monkeypatch.setenv("ACQ_MSB_STUB_PORTS", json.dumps({"sec": [
        {"host_port": 6868, "guest_port": 4096}, {"host_port": 7000, "guest_port": 7001}]}))
    path = state.record_path("msb", "sec")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"schema": 1, "name": "sec", "backend": "msb", "agent": "shell",
                                "workspace": "/w", "ro_host_config": True}), encoding="utf-8")
    spec_dir = tmp_path / "kits" / "web"
    spec_dir.mkdir(parents=True)
    (spec_dir / "spec.yaml").write_text('schemaVersion: "hybrid/v1"\nkind: mixin\nname: web\n'
                                        "publishedPorts:\n  - guest: 4096\n", encoding="utf-8")
    web = kit_msb.Kit("web", "extra", kitspec.load_kit(spec_dir), fetched=True)
    real_plan = lifecycle._plan_msb_kits

    def plan_with_web(*args, **kwargs):
        plan, code = real_plan(*args, **kwargs)
        return (lifecycle.dataclasses.replace(plan, kits=[*plan.kits, web]) if plan else None), code

    monkeypatch.setattr(lifecycle, "_plan_msb_kits", plan_with_web)
    monkeypatch.setattr(kit_msb, "ensure_kits_applied",
                        lambda name, kits, **kw: kit_msb.ApplyResult(applied=[k.name for k in kits]))
    real_remove = msb.remove

    def remove(name):
        real_remove(name)
        monkeypatch.delenv("ACQ_MSB_STUB_CATALOG")  # the stub's catalog file now says the guest is gone
        if busy_after_remove:
            monkeypatch.setenv("ACQ_MSB_HOST_PORTS_BUSY", "6868")

    monkeypatch.setattr(msb, "remove", remove)
    seen = _spy(monkeypatch, msb)
    rc, doc, err = _invoke(capsys, "--backend", "msb", "create", "--recreate", "sec", "--yes", "--json")
    assert rc == 0, err
    (create,) = [a for a in seen if a[0] == "create"]
    (mapping,) = [create[i + 1] for i, a in enumerate(create) if a == "-p"]  # 7001 is no kit's: dropped
    host, guest = mapping.split(":")
    assert guest == "4096"
    if busy_after_remove:
        assert host != "6868" and "is in use now; a free port is chosen instead" in err
    else:
        assert host == "6868"


def test_recreate_maps_afresh_when_the_old_ports_cannot_be_read(monkeypatch, capsys):
    monkeypatch.setattr(msb, "exists", lambda name: True)

    def broken(name):
        raise msb.MsbError(errors.FAILURE, "could not read declared ports")

    monkeypatch.setattr(msb, "ports", broken)
    assert lifecycle._declared_create_ports("box") == ()
    assert "maps its ports afresh" in capsys.readouterr().err
    monkeypatch.setattr(msb, "exists", lambda name: False)
    assert lifecycle._declared_create_ports("box") == ()


# ---------------------------------------------------------------------------
# acq ports NAME --publish (acq_backend_ports, ADR-0015).
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("value,problem", [
    ("8080", "ports: --publish must be HOST:GUEST, got '8080'"),
    ("a:80", "ports: invalid port 'a' in 'a:80' (want integer 1..65535)"),
    ("80:", "ports: invalid port '' in '80:' (want integer 1..65535)"),
    ("70000:80", "ports: port '70000' out of range in '70000:80' (want 1..65535)"),
    ("0:80", "ports: port '0' out of range in '0:80' (want 1..65535)"),
])
def test_post_hoc_values_are_checked_before_anything_runs(monkeypatch, tmp_path, capsys, value, problem):
    _msb_env(monkeypatch, tmp_path, catalog={"box": "running"})
    monkeypatch.setattr(publish, "_spawn", lambda argv: pytest.fail("spawned for an invalid value"))
    rc, doc, _ = _invoke(capsys, "--backend", "msb", "ports", "box", "--publish", "1:2", "--publish", value, "--json")
    assert rc == 1 and doc["error"] == {**doc["error"], "code": errors.VALIDATION_FAILED, "message": problem}
    assert not (tmp_path / "state" / "ports").exists()


def test_post_hoc_publish_with_no_value_is_refused(monkeypatch, tmp_path, capsys):
    _msb_env(monkeypatch, tmp_path, catalog={"box": "running"})
    rc, doc, _ = _invoke(capsys, "--backend", "msb", "ports", "box", "--publish", "--json")
    assert rc == 1 and doc["error"]["code"] == errors.VALIDATION_FAILED


class _Proc:
    """A background process double: alive unless told otherwise."""

    _next = 4242

    def __init__(self, argv, alive=True):
        self.argv = argv
        self.alive = alive
        _Proc._next += 1
        self.pid = _Proc._next

    def poll(self):
        return None if self.alive else 1

    def wait(self, timeout=None):
        return 0


def _tunnel_env(monkeypatch, tmp_path, *, serve_alive=True, ssh_alive=True, listener=True):
    _msb_env(monkeypatch, tmp_path, catalog={"box": "running"})
    for var in ("ACQ_MSB_SERVE_SETTLE", "ACQ_MSB_FORWARD_SETTLE"):
        monkeypatch.setenv(var, "0")
    monkeypatch.setenv("ACQ_MSB_FORCE_SERVE_PORT", "31337")
    key = tmp_path / "state" / "ssh" / "msb_id_ed25519"
    key.parent.mkdir(parents=True)
    key.write_text("k", encoding="utf-8")
    key.with_name("msb_id_ed25519.pub").write_text("p", encoding="utf-8")
    spawned: list[_Proc] = []
    killed: list[int] = []

    def spawn(argv):
        is_serve = "serve" in argv
        proc = _Proc(argv, serve_alive if is_serve else ssh_alive)
        spawned.append(proc)
        return proc

    monkeypatch.setattr(publish, "_spawn", spawn)
    monkeypatch.setattr(publish, "_kill", killed.append)
    monkeypatch.setattr(publish, "_listener_ready", lambda port: listener)
    monkeypatch.setattr(publish.hostexec, "command", lambda name: [f"/usr/bin/{name}"])
    return spawned, killed


def test_post_hoc_publish_opens_a_serve_and_a_tunnel_and_records_them(monkeypatch, tmp_path, capsys):
    spawned, _ = _tunnel_env(monkeypatch, tmp_path)
    rc, doc, _ = _invoke(capsys, "--backend", "msb", "ports", "box", "--publish", "8080:3000", "--json")
    assert rc == 0
    serve, ssh = spawned
    assert serve.argv[-7:] == ["ssh", "serve", "box", "--host", "127.0.0.1", "--port", "31337"]
    assert ssh.argv[0] == "/usr/bin/ssh"
    assert ssh.argv[1:5] == ["-p", "31337", "-N", "-n"]
    for opt in ("IdentitiesOnly=yes", "BatchMode=yes", "NumberOfPasswordPrompts=0",
                "StrictHostKeyChecking=accept-new", "ExitOnForwardFailure=yes"):
        assert opt in ssh.argv
    assert ["-F", "none"] == ssh.argv[5:7]
    assert ssh.argv[-3:] == ["-L", "127.0.0.1:8080:127.0.0.1:3000", "root@127.0.0.1"]
    assert doc["data"]["ports"] == [{"host_port": 8080, "guest_port": 3000, "origin": "post-hoc",
                                     "serve_port": 31337}]
    pids = tmp_path / "state" / "ports" / "box.pids"
    assert pids.read_text(encoding="utf-8") == f"{serve.pid} {ssh.pid} 31337 8080:3000\n"
    rc, doc, _ = _invoke(capsys, "--backend", "msb", "ports", "box", "--json")
    assert {"host_port": 8080, "guest_port": 3000, "origin": "post-hoc"} in doc["data"]["ports"]


def test_post_hoc_publish_human_output_matches_bash(monkeypatch, tmp_path, capsys):
    _tunnel_env(monkeypatch, tmp_path)
    rc, _, err = _invoke(capsys, "--backend", "msb", "ports", "box", "--publish", "8080:3000")
    assert rc == 0
    assert err.splitlines() == [
        "acq(msb): published host 127.0.0.1:8080 -> sandbox box 127.0.0.1:3000",
        "acq(msb):   via 'msb ssh serve' on 127.0.0.1:31337 + ssh -L (ADR-0015).",
        "acq(msb):   tear down with 'acq rm box' (or 'acq stop box').",
    ]


@pytest.mark.parametrize("kwargs,message", [
    ({"serve_alive": False}, "'msb ssh serve' on 127.0.0.1:31337 exited immediately"),
    ({"ssh_alive": False}, "ssh -L 127.0.0.1:8080 -> 127.0.0.1:3000 failed to establish"),
    ({"listener": False}, "ssh -L did not open host listener 127.0.0.1:8080"),
])
def test_a_tunnel_that_does_not_come_up_fails_and_records_nothing(monkeypatch, tmp_path, capsys, kwargs, message):
    spawned, killed = _tunnel_env(monkeypatch, tmp_path, **kwargs)
    rc, doc, _ = _invoke(capsys, "--backend", "msb", "ports", "box", "--publish", "8080:3000", "--json")
    assert rc == 1 and message in doc["error"]["message"]
    assert not (tmp_path / "state" / "ports" / "box.pids").exists()
    if "serve_alive" not in kwargs:
        assert {p.pid for p in spawned} <= set(killed)  # the serve is never left running


def test_repeated_publish_is_all_or_nothing(monkeypatch, tmp_path, capsys):
    spawned, killed = _tunnel_env(monkeypatch, tmp_path)
    monkeypatch.setattr(publish, "_listener_ready", lambda port: port == 8080)
    rc, _, _ = _invoke(capsys, "--backend", "msb", "ports", "box", "--publish", "8080:3000",
                       "--publish", "8081:3001", "--json")
    assert rc == 1
    assert {p.pid for p in spawned} <= set(killed)
    assert not (tmp_path / "state" / "ports" / "box.pids").exists()
    monkeypatch.setattr(publish, "_listener_ready", lambda port: True)
    rc, doc, _ = _invoke(capsys, "--backend", "msb", "ports", "box", "--publish", "8080:3000",
                         "--publish", "8081:3001", "--json")
    assert rc == 0 and [p["host_port"] for p in doc["data"]["ports"]] == [8080, 8081]
    lines = (tmp_path / "state" / "ports" / "box.pids").read_text(encoding="utf-8").splitlines()
    assert [line.split()[3] for line in lines] == ["8080:3000", "8081:3001"]


def test_the_key_is_made_once_with_ssh_keygen(monkeypatch, tmp_path):
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setattr(publish.hostexec, "command", lambda name: [f"/usr/bin/{name}"])
    calls: list[list[str]] = []

    def run(argv):
        calls.append(argv)
        publish.ssh_key().write_text("k", encoding="utf-8")
        return 0

    publish._ensure_key(run)
    publish._ensure_key(run)
    assert calls == [["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(publish.ssh_key())]]
    if os.name == "posix":
        assert publish.ssh_key().parent.stat().st_mode & 0o777 == 0o700


def test_a_failed_authorize_fails_the_publish(monkeypatch, tmp_path, capsys):
    _tunnel_env(monkeypatch, tmp_path)
    (tmp_path / "state" / "ssh" / "msb_id_ed25519.pub").unlink()  # the stub refuses a missing file
    rc, doc, _ = _invoke(capsys, "--backend", "msb", "ports", "box", "--publish", "8080:3000", "--json")
    assert rc == 1 and "'msb ssh authorize' failed" in doc["error"]["message"]


def test_an_unsafe_name_never_reaches_the_state_path(monkeypatch, tmp_path, capsys):
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    assert publish.pidfile("../x") is None
    assert publish.pidfile("-x") is None
    assert "refusing unsafe sandbox name '../x'" in capsys.readouterr().err
    publish.teardown("../x")
    assert publish.posthoc_ports("../x") == []


def test_listing_reads_a_bash_written_record(monkeypatch, tmp_path):
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    pids = tmp_path / "state" / "ports" / "box.pids"
    pids.parent.mkdir(parents=True)
    pids.write_text("11 12 30001 8080:3000\n\ngarbage\n13 14 30002 9090:4000\n", encoding="utf-8")
    assert publish.posthoc_ports("box") == [
        {"host_port": 8080, "guest_port": 3000, "origin": "post-hoc"},
        {"host_port": 9090, "guest_port": 4000, "origin": "post-hoc"},
    ]


def _sleeper() -> subprocess.Popen:
    return subprocess.Popen([sys.executable, "-c", "import time; time.sleep(120)"],
                            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


@pytest.mark.parametrize("verb", ["stop", "rm"])
def test_stop_and_rm_tear_the_tunnels_down(monkeypatch, tmp_path, capsys, verb):
    _msb_env(monkeypatch, tmp_path, catalog={"box": "running"})
    serve, ssh = _sleeper(), _sleeper()
    try:
        pids = tmp_path / "state" / "ports" / "box.pids"
        pids.parent.mkdir(parents=True)
        pids.write_text(f"{serve.pid} {ssh.pid} 30001 8080:3000\n", encoding="utf-8")
        rc, _, _ = _invoke(capsys, "--backend", "msb", verb, "box", "--json")
        assert rc == 0
        assert serve.wait(timeout=30) is not None and ssh.wait(timeout=30) is not None
        assert not pids.exists()
    finally:
        for proc in (serve, ssh):
            if proc.poll() is None:
                proc.kill()
                proc.wait(timeout=30)


def test_teardown_without_a_record_is_a_no_op(monkeypatch, tmp_path):
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    publish.teardown("box")
    assert not (tmp_path / "state" / "ports").exists()


def test_teardown_never_signals_pid_0_or_1(monkeypatch, tmp_path):
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    sent: list[int] = []
    monkeypatch.setattr(publish.os, "kill", lambda pid, sig: sent.append(pid))
    pids = tmp_path / "state" / "ports" / "box.pids"
    pids.parent.mkdir(parents=True)
    pids.write_text("0 1 30001 8080:3000\n-5 777 30002 1:2\n", encoding="utf-8")
    publish.teardown("box")
    assert sent == [777]


def test_sbx_post_hoc_publish_is_sbx_s_own(monkeypatch, tmp_path, capfd):
    _sbx_env(monkeypatch, tmp_path, catalog={"box": "running"})
    seen = []
    real = lifecycle.sbx._run_stream

    def spy(argv, **kwargs):
        seen.append(list(argv))
        return real(argv, **kwargs)

    monkeypatch.setattr(lifecycle.sbx, "_run_stream", spy)
    rc, doc, err = _invoke(capfd, "--backend", "sbx", "ports", "box", "--publish", "8080:3000", "--json")
    assert rc == 0
    assert seen == [["ports", "box", "--publish", "8080:3000"]]
    assert doc["data"] == {"name": "box", "requested": ["8080:3000"]}
    assert "[stub ports] published 8080:3000" in err
    monkeypatch.setenv("ACQ_SBX_STUB_FAIL", "ports")
    rc, doc, _ = _invoke(capfd, "--backend", "sbx", "ports", "box", "--publish", "8080:3000", "--json")
    assert rc == 1 and doc["error"]["code"] == errors.FAILURE
