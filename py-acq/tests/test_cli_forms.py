"""Bash CLI parity for workspace mounts, opaque agent tails and global images."""
from __future__ import annotations

import json
import os

import pytest

from acq_py import cli, msb, sbx, security, state
from acq_py.commands import lifecycle


@pytest.fixture(params=["msb", "sbx"])
def backend(request, monkeypatch, tmp_path):
    backend = request.param
    for name, version in (("msb", "0.7.11"), ("sbx", "0.51.0")):
        monkeypatch.setenv(f"ACQ_{name.upper()}_BIN", "__stub__")
        monkeypatch.setenv(f"ACQ_{name.upper()}_VERSION", version)
        monkeypatch.setenv(f"ACQ_{name.upper()}_INSTALLED", "1")
    monkeypatch.setenv("ACQ_PROVIDER_KITS", "")
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    return backend


def workspace(tmp_path, name):
    path = tmp_path / name
    path.mkdir()
    return str(path)


def invoke(capsys, backend, *args):
    rc = cli.main(["--backend", backend, "--json", *args])
    out, err = capsys.readouterr()
    return rc, json.loads(out), err


@pytest.mark.parametrize("verb", ["create", "run"])
def test_multiple_mounts_and_state(backend, monkeypatch, tmp_path, capsys, verb):
    primary = workspace(tmp_path, "primary")
    extra = workspace(tmp_path, "extra space")
    last = workspace(tmp_path, "last")
    calls = []
    adapter = msb if backend == "msb" else sbx
    real_create = adapter.create

    def capture(*args, **kwargs):
        calls.append((args, kwargs))
        return real_create(*args, **kwargs)

    monkeypatch.setattr(adapter, "create", capture)
    monkeypatch.setattr(adapter, "launch", lambda *a, **kw: 0)
    # Paths before and after options must retain their order.
    rc, doc, err = invoke(capsys, backend, verb, "shell", primary, extra + ":ro", "--name", "box", last)
    assert rc == 0, (doc, err)
    assert calls[0][1]["extra_workspaces"][:2] == [extra + ":ro", last]
    record = state.record_read(backend, "box")
    assert record["workspace"] == primary
    assert record["extra_workspaces"] == [extra + ":ro", last]
    rc, doc, err = invoke(capsys, backend, "run", "box")
    assert rc == 0, (doc, err)
    assert len(calls) == 1
    rc, doc, err = invoke(capsys, backend, "rm", "box")
    assert rc == 0, (doc, err)
    assert state.record_read(backend, "box") is None
    assert os.path.isdir(extra)


@pytest.mark.parametrize("bad", ["colon", "control", "trusted", "inside", "symlink", "missing"])
@pytest.mark.parametrize("ro", [False, True])
def test_extra_safety_before_backend(backend, monkeypatch, tmp_path, capsys, bad, ro):
    primary = workspace(tmp_path, "primary")
    paths = {
        "colon": str(tmp_path / "bad:mount"), "control": str(tmp_path / "bad\nmount"),
        "trusted": str(tmp_path), "inside": str(tmp_path / "state" / "nested"),
        "missing": str(tmp_path / "absent"),
    }
    if bad == "symlink":
        # A link whose target holds a colon; Windows forbids ':' in a name.
        if os.name == "nt":
            pytest.skip("a directory name cannot contain ':' on Windows")
        target = tmp_path / "bad:target"
        target.mkdir()
        link = tmp_path / "link"
        link.symlink_to(target, target_is_directory=True)
        paths["symlink"] = str(link)
    (tmp_path / "state" / "nested").mkdir(parents=True)
    monkeypatch.setattr(lifecycle, "_create_sandbox", lambda *a, **kw: pytest.fail("unsafe create"))
    rc, doc, _ = invoke(capsys, backend, "create", "shell", primary, paths[bad] + (":ro" if ro else ""))
    assert rc == 1
    assert doc["error"]["code"] == "validation_failed"
    assert "no ':ro' suffix" not in str(doc)


def test_primary_read_only_msb(backend, monkeypatch, tmp_path, capsys):
    if backend != "msb":
        pytest.skip("sbx enforces writable primaries itself")
    primary = workspace(tmp_path, "primary")
    calls = []
    real = msb._run

    def capture(argv, **kw):
        calls.append(argv)
        return real(argv, **kw)

    monkeypatch.setattr(msb, "_run", capture)
    rc, doc, err = invoke(capsys, backend, "create", "shell", primary + ":ro", "--name", "box")
    assert rc == 0, (doc, err)
    create = next(a for a in calls if a[0] == "create")
    host = next(a for a in create if a.endswith(":ro")).split(":ro")[0].rsplit(":", 1)[0]
    assert f"{host}:{msb._guest_path(host)}:ro" in create  # the guest form differs on Windows
    assert os.path.normcase(os.path.realpath(host)) == os.path.normcase(os.path.realpath(primary))
    assert state.record_read(backend, "box")["workspace_read_only"] is True


def test_clone_read_only_primary_refused(backend, tmp_path, capsys):
    if backend != "msb":
        pytest.skip("sbx owns native clone validation")
    primary = workspace(tmp_path, "primary")
    rc, doc, _ = invoke(capsys, backend, "create", "shell", primary + ":ro", "--clone")
    assert rc == 1
    assert "requires a writable primary workspace" in doc["error"]["message"]


def test_msb_mount_destinations(monkeypatch):
    monkeypatch.setenv("ACQ_MSB_BIN", "__stub__")
    calls = []
    real = msb._run

    def capture(argv, **kw):
        calls.append(argv)
        return real(argv, **kw)

    monkeypatch.setattr(msb, "_run", capture)
    msb.create("box", "image", "/primary", egress_kits=[], clone_source="/scratch",
               extra_workspaces=["/other space:ro", "/third"])
    argv = calls[0]
    assert "/scratch:/primary" in argv
    assert "/other space:/other space:ro" in argv
    assert "/third:/third" in argv
    assert argv[argv.index("-w") + 1] == "/primary"


@pytest.mark.parametrize("tail", [["--json", "a b", "a'b", '"quoted"', "$(touch nope)", "", "--"], ["printf", "%s", "a b"]])
def test_agent_tail_fresh_and_reattach(backend, monkeypatch, tmp_path, capsys, tail):
    primary = workspace(tmp_path, "primary")
    calls = []
    adapter = msb if backend == "msb" else sbx
    monkeypatch.setattr(adapter, "_run_stream", lambda argv, **kw: calls.append(argv) or 17)
    for args in (["opencode", primary, "--name", "box"], ["box"], ["opencode", primary, "--name", "box"]):
        rc, doc, err = invoke(capsys, backend, "run", *args, "--", *tail)
        assert rc == 17, (doc, err)
        argv = calls[-1]
        if backend == "msb":
            assert argv[argv.index("--") + 1:] == ["opencode", *tail]
        else:
            command = ["opencode", *tail] if tail[0].startswith("-") else tail
            assert argv == ["run", "--name", "box", "shell", "--", "-lc", 'exec "$@"', "sh", *command]
    assert "agent_args" not in state.record_read(backend, "box")


def test_sbx_non_generic_command_escape(monkeypatch):
    monkeypatch.setattr(state, "record_read", lambda *a: {"agent": "shell"})
    calls = []
    monkeypatch.setattr(sbx, "_run_stream", lambda argv, **kw: calls.append(argv) or 0)
    sbx.launch("box", "/ws", "shell", agent_args=["printf", "%s", "a'b"])
    assert calls == [["run", "--name", "box", "shell", "--", "printf", "%s", "a'b"]]


@pytest.mark.parametrize("global_form", [["--image", "global"], ["--image=global"]])
@pytest.mark.parametrize("local", [False, True])
def test_global_image_precedence(backend, monkeypatch, tmp_path, capsys, global_form, local):
    primary = workspace(tmp_path, "primary")
    monkeypatch.setenv("ACQ_IMAGE", "environment")
    monkeypatch.setenv("ACQ_SUBSTRATE_STATE", '{"*":"ok"}')
    rc, doc, err = invoke(capsys, backend, *global_form, "create", "shell", primary, "--name", "box",
                          *(["--image", "local"] if local else []))
    assert rc == 0, (doc, err)
    assert doc["data"]["image"] == ("local" if local else "global")
    assert os.environ["ACQ_IMAGE"] == "environment"


def test_image_missing(capsys):
    assert cli.main(["--json", "--image"]) == 2
    assert json.loads(capsys.readouterr().out)["error"]["message"] == "--image given with no value"


def test_image_followed_by_double_dash_is_missing(capsys):
    assert cli.main(["--json", "--image", "--", "run", "shell"]) == 2
    assert json.loads(capsys.readouterr().out)["error"]["message"] == "--image given with no value"


def test_sbx_guest_workspace_drops_the_ro_suffix(monkeypatch):
    calls = []
    monkeypatch.setattr(sbx, "_run", lambda argv, **kw: calls.append(argv) or type("P", (), {"returncode": 0, "stdout": "", "stderr": ""})())
    try:
        sbx.create("box", "shell", "/ws:ro")
    except Exception:
        pass
    flat = [a for argv in calls for a in argv]
    assert "ACQ_WORKSPACE=/ws" in flat and "ACQ_WORKSPACE=/ws:ro" not in flat


def test_recorded_extra_overlap_refused(backend, monkeypatch, tmp_path, capsys):
    primary = workspace(tmp_path, "primary")
    extra = workspace(tmp_path, "extra")
    rc, doc, err = invoke(capsys, backend, "create", "shell", primary, extra, "--name", "box")
    assert rc == 0, (doc, err)
    monkeypatch.setenv("ACQ_PROVENANCE_DIR", str(tmp_path / "extra" / "provenance"))
    monkeypatch.setattr(security, "assert_trusted", lambda *a: None)
    rc, doc, _ = invoke(capsys, backend, "run", "box")
    assert rc == 1
    assert "contains acq's" in doc["error"]["message"]
    assert extra in doc["error"]["message"]


@pytest.mark.parametrize("argv", [
    ["create", "--name", "box", "shell", "p", "--image", "img", "q:ro", "--kit", "k", "r"],
    ["create", "shell", "--name", "box", "p", "q:ro", "r"],
    ["run", "--name", "box", "shell", "p", "--image", "img", "q:ro", "r"],
    ["run", "shell", "--name", "box", "p", "q:ro", "r"],
])
def test_interspersed_workspace_order(monkeypatch, argv):
    seen = []
    monkeypatch.setattr(cli, "_dispatch", lambda parser, parsed, *a: seen.append(parsed) or 0)
    assert cli.main(argv) == 0
    assert seen[0].path == "p"
    assert seen[0].extra_paths == ["q:ro", "r"]


def test_clone_only_primary(backend, monkeypatch, tmp_path, capsys):
    primary = workspace(tmp_path, "primary")
    extra = workspace(tmp_path, "extra")
    scratch = workspace(tmp_path, "scratch")
    setup = []
    monkeypatch.setattr(lifecycle.msb_clone, "setup", lambda name, path, exists: setup.append(path) or scratch)
    adapter = msb if backend == "msb" else sbx
    calls = []
    real = adapter.create

    def capture(*args, **kw):
        calls.append((args, kw))
        return real(*args, **kw)

    monkeypatch.setattr(adapter, "create", capture)
    rc, doc, err = invoke(capsys, backend, "create", "shell", primary, extra + ":ro", "--clone", "--name", "box")
    assert rc == 0, (doc, err)
    assert calls[0][1]["extra_workspaces"][0] == extra + ":ro"
    if backend == "msb":
        assert setup == [primary]
        assert calls[0][1]["clone_source"] == scratch
    else:
        assert not setup
        assert calls[0][1]["clone"] is True


def test_reattach_ignores_new_mounts(backend, monkeypatch, tmp_path, capsys):
    primary = workspace(tmp_path, "primary")
    extra = workspace(tmp_path, "extra")
    rc, doc, err = invoke(capsys, backend, "create", "shell", primary, extra + ":ro", "--name", "box")
    assert rc == 0, (doc, err)
    adapter = msb if backend == "msb" else sbx
    monkeypatch.setattr(adapter, "launch", lambda *a, **kw: 0)
    rc, doc, err = invoke(capsys, backend, "run", "shell", "/missing:ro", "/bad:path", "--name", "box", "--clone")
    assert rc == 0, (doc, err)
    assert doc["data"]["action"] == "reattached"
    assert state.record_read(backend, "box")["extra_workspaces"] == [extra + ":ro"]


def test_recreate_preserves_extra_mounts(backend, monkeypatch, tmp_path, capsys):
    if backend != "msb":
        pytest.skip("security recreation is msb only")
    primary = workspace(tmp_path, "primary")
    extra = workspace(tmp_path, "extra")
    state.record_write("msb", "box", agent="shell", workspace=primary, ro_host_config=True,
                       extra_workspaces=[extra + ":ro"], workspace_read_only=True)
    calls = []
    real = msb.create

    def capture(*args, **kw):
        calls.append((args, kw))
        return real(*args, **kw)

    monkeypatch.setattr(msb, "create", capture)
    rc, doc, err = invoke(capsys, backend, "create", "--recreate", "box", "--yes")
    assert rc == 0, (doc, err)
    assert calls[0][1]["extra_workspaces"] == [extra + ":ro"]
    assert calls[0][1]["workspace_read_only"] is True
    assert state.record_read(backend, "box")["extra_workspaces"] == [extra + ":ro"]


def test_msb_specific_image_wins(backend, monkeypatch, tmp_path, capsys):
    primary = workspace(tmp_path, "primary")
    monkeypatch.setenv("ACQ_MSB_IMAGE", "specific")
    rc, doc, err = invoke(capsys, backend, "--image", "global", "create", "shell", primary)
    assert rc == 0, (doc, err)
    assert doc["data"]["image"] == ("specific" if backend == "msb" else "global")
    assert err.count("most-specific wins") == (1 if backend == "msb" else 0)


def test_reattach_race_revalidates_before_create(backend, monkeypatch, tmp_path, capsys):
    monkeypatch.setattr(lifecycle, "_exists_quietly", lambda *a: True)
    monkeypatch.setattr(lifecycle, "_scope_advice", lambda *a: False)
    monkeypatch.setattr(lifecycle, "_create_sandbox", lambda *a, **kw: pytest.fail("unsafe raced create"))
    primary = workspace(tmp_path, "primary")
    rc, doc, _ = invoke(capsys, backend, "run", "shell", primary, "/bad:path", "--name", "gone")
    assert rc == 1
    assert "contains ':'" in doc["error"]["message"]
