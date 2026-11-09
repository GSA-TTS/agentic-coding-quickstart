"""Tier-2 tests for the committed cell oracle, ``scripts/qualify-backend-cell`` (ADR-0044m).

Offline. The oracle's checks run against an injected fake backend that is fully
compliant by default and breaks one control per test; the script itself also runs
end to end against the bundled stub backends, in a throwaway HOME/XDG tree, to show
that it leaves the caller's acq configuration and state untouched and that a
backend which does not really run guest commands cannot pass.
"""

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
from importlib.machinery import SourceFileLoader
from pathlib import Path
from types import SimpleNamespace

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
ORACLE_PATH = REPO_ROOT / "scripts" / "qualify-backend-cell"


def _load():
    loader = SourceFileLoader("qualify_backend_cell", str(ORACLE_PATH))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    sys.modules[loader.name] = module  # dataclasses resolve annotations through sys.modules
    loader.exec_module(module)
    return module


qbc = _load()
NONCE = "0a1b2c3d"


# ---- names and isolation ------------------------------------------------------


def test_every_backend_side_identifier_is_nonce_scoped():
    # Fixed names (provider 'opencode-go', env 'KEY', service 'SVC') overwrote and then
    # removed an operator's real binding of the same name.
    names = qbc.make_names("sbx", NONCE)
    for ident in (names.sandbox, names.service, names.provider, names.key_env.lower(), names.value):
        assert NONCE in ident.lower()
    assert names.provider != "opencode-go" and names.key_env != "KEY" and names.service != "SVC"
    assert qbc.make_names("sbx").nonce != qbc.make_names("sbx").nonce


def test_isolated_env_redirects_acq_state_and_drops_caller_seams(tmp_path):
    base = {
        "HOME": "/home/operator", "PATH": "/usr/bin", "PYTHONPATH": "/somewhere/else",
        "XDG_STATE_HOME": "/home/operator/.local/state", "XDG_CONFIG_HOME": "/home/operator/.config",
        "ACQ_STATE_DIR": "/home/operator/acq-state", "ACQ_MSB_BIN": "__stub__",
        "ACQ_SECURITY_MOUNT_STATE": '"ok"', "ACQ_PROVIDER_CREDENTIAL_BINDINGS": "{}",
        "ACQ_MSB_READY_TIMEOUT": "90",
    }
    env = qbc.isolated_env(tmp_path, base)
    for var in qbc.ISOLATED_DIRS:
        assert Path(env[var]).is_dir() and Path(env[var]).is_relative_to(tmp_path), var
    assert "ACQ_MSB_BIN" not in env  # a stub seam would turn a live run into a stubbed one
    assert "ACQ_SECURITY_MOUNT_STATE" not in env and "ACQ_PROVIDER_CREDENTIAL_BINDINGS" not in env
    assert env["ACQ_MSB_READY_TIMEOUT"] == "90"  # timing knobs pass through
    assert env["HOME"] == "/home/operator"  # the backend CLIs keep their login and image cache
    assert env["PYTHONPATH"] == str(REPO_ROOT / "py-acq" / "src")


@pytest.mark.skipif(os.name == "nt", reason="POSIX executable bit")
def test_which_ignores_relative_path_entries(tmp_path, monkeypatch):
    planted = tmp_path / "msb"
    planted.write_text("#!/bin/sh\n")
    planted.chmod(0o755)
    monkeypatch.chdir(tmp_path)
    assert qbc.which("msb", path=os.pathsep.join(["", ".", "rel"])) is None
    assert qbc.which("msb", path=str(tmp_path)) == str(planted)


# ---- the checks, against a fake backend --------------------------------------


class FakeBackend:
    """``acq`` as a compliant backend would answer; each knob breaks one control."""

    def __init__(self, backend, names, state_dir, **knobs):
        self.backend, self.names, self.state_dir = backend, names, state_dir
        self.knobs = {"bind": True, "leak": None, "guest_value": False, "placeholder": True, "kit": True,
                      "ro": True, "echo_only": False, "secrets": True, "create": True, **knobs}
        self.calls: list[list[str]] = []
        self.stdin: list[str | None] = []

    @staticmethod
    def done(rc=0, out=""):
        return SimpleNamespace(returncode=rc, stdout=out, stderr="")

    def __call__(self, argv, *, stdin=None, timeout=None):
        self.calls.append(argv)
        self.stdin.append(stdin)
        k, n = self.knobs, self.names
        verb = argv[2:]
        leak = n.value if k["leak"] == " ".join(verb[:2]) else ""
        if verb[0] == "provider-credential":
            return self.done(0 if k["bind"] or verb[1] != "set" else 1, leak)
        if verb[0] == "secret":
            return self.done(0 if k["secrets"] else 1, leak)
        if verb[0] == "create":
            if k["create"]:
                record = {"name": n.sandbox, **({"ro_host_config": True} if k["ro"] else {})}
                (self.state_dir / self.backend).mkdir(parents=True, exist_ok=True)
                (self.state_dir / self.backend / f"{n.sandbox}.abc123.json").write_text(json.dumps(record))
            return self.done(0 if k["create"] else 1)
        if verb[0] == "ls":
            return self.done(0, json.dumps({"data": {"sandboxes": [{"name": n.sandbox}]}}))
        if verb[0] == "rm":
            return self.done()
        if verb[0] == "exec":
            script = verb[-1]
            if k["echo_only"]:
                return self.done(0, "[stub exec] " + " ".join(verb[3:]))
            if "boot=" in script:
                return self.done(0, f"boot={n.seed + 3}\n")
            if "cred=" in script:
                env = f"{n.key_env}=sbx-cs-placeholder" if k["placeholder"] and k["bind"] else ""
                if k["guest_value"]:
                    env = f"{n.key_env}={n.value}"
                ph = env.split("=", 1)[1] if env else ""
                return self.done(0, f"cred={n.seed + 1}\nplaceholder={ph}\nPATH=/usr/bin\n{env}\n")
            if "kit=" in script:
                return self.done(0, f"kit={n.seed + 2}\n" if k["kit"] else "")
        raise AssertionError(f"unexpected acq call {argv}")


class FakeRaw:
    """``sbx secret ls/rm`` for the teardown: one custom secret is ours, one is the operator's."""

    def __init__(self, names):
        self.removed: list[str] = []
        self.table = [
            {"scope": "global", "env": "KEY", "placeholder": "sbx-cs-operator", "secret": "<masked>"},
            {"scope": "global", "env": "OPENCODE_GO_API_KEY", "placeholder": "sbx-cs-op2", "secret": "<masked>"},
            {"scope": "global", "env": names.key_env, "placeholder": "sbx-cs-ours", "secret": "<masked>"},
        ]

    def __call__(self, argv, *, stdin=None, timeout=None):
        if argv[:3] == ["sbx", "secret", "ls"]:
            return SimpleNamespace(returncode=0, stdout=json.dumps({"custom_secrets": self.table}), stderr="")
        if argv[:4] == ["sbx", "secret", "rm", "--placeholder"]:
            self.removed.append(argv[4])
            return SimpleNamespace(returncode=0, stdout="", stderr="")
        raise AssertionError(f"unexpected raw call {argv}")


def cell(tmp_path, backend="msb", canary=0, **knobs):
    names = qbc.make_names(backend, NONCE)
    state = tmp_path / "state"
    fake = FakeBackend(backend, names, state, **knobs)
    raw = FakeRaw(names)
    c = qbc.Cell(backend, names, str(tmp_path / "ws"), state, fake, raw, lambda: canary)
    return c, fake, raw


@pytest.mark.parametrize("backend", ["msb", "sbx"])
def test_a_compliant_backend_passes(tmp_path, backend, capsys):
    c, fake, raw = cell(tmp_path, backend)
    assert c.run() == 0, capsys.readouterr().err
    assert c.failures == [] and c.blocked == []
    verbs = [" ".join(call[2:4]) for call in fake.calls]
    # the credential is bound BEFORE create, so the guest can be checked for it
    assert verbs.index("provider-credential set") < verbs.index("create shell")
    assert all(s in (None, fake.names.value + "\n") for s in fake.stdin)  # the value only ever goes to stdin
    assert all(fake.names.value not in " ".join(call) for call in fake.calls)  # ...never into argv
    if backend == "sbx":
        assert raw.removed == ["sbx-cs-ours"]  # never the operator's KEY or OPENCODE_GO_API_KEY secret


@pytest.mark.parametrize(
    "backend,knobs,canary,failed",
    [
        ("msb", {"bind": False}, 0, ["provider-credential set", "guest credential"]),  # msb today
        ("sbx", {"leak": "provider-credential ls"}, 0, ["provider-credential ls"]),
        ("sbx", {"leak": "secret set"}, 0, ["secret set"]),
        ("sbx", {"guest_value": True}, 0, ["guest credential"]),  # the real value reached the guest
        ("msb", {"placeholder": False}, 0, ["guest credential"]),  # bound on the host, absent in the guest
        ("sbx", {"kit": False}, 0, ["kit apply"]),
        ("msb", {"ro": False}, 0, ["ro mount"]),  # acq did not establish the read-only mount
        ("msb", {}, 1, ["ro-mount canary"]),  # msb does not enforce :ro
        ("msb", {"secrets": False}, 0, ["secret set"]),  # no host-side secret path
    ],
)
def test_each_missing_control_fails_the_cell_and_is_named(tmp_path, backend, knobs, canary, failed, capsys):
    c, _fake, _raw = cell(tmp_path, backend, canary, **knobs)
    assert c.run() == 1
    assert c.failures == failed
    err = capsys.readouterr().err
    assert all(f"FAIL: {step}" in err for step in failed)
    assert c.names.value not in err  # a failure report never carries the value


def test_every_control_failure_is_reported_in_one_run(tmp_path):
    # Python msb today: no credential path, no kits, no read-only mount, no secret store.
    c, _fake, _raw = cell(tmp_path, "msb", 0, bind=False, kit=False, ro=False, secrets=False)
    assert c.run() == 1
    assert c.failures == ["provider-credential set", "guest credential", "kit apply", "ro mount", "secret set"]


def test_a_backend_that_only_echoes_the_command_cannot_pass(tmp_path):
    c, fake, _raw = cell(tmp_path, "msb", echo_only=True)
    assert c.run() == 1
    assert c.failures == ["exec"]
    assert not any(call[2] == "exec" and "kit=" in call[-1] for call in fake.calls)  # the run stopped


@pytest.mark.parametrize("status", [None, 2])
def test_a_canary_that_cannot_conclude_blocks_the_cell(tmp_path, status):
    c, _fake, _raw = cell(tmp_path, "msb", status)
    assert c.run() == 2
    assert c.failures == [] and c.blocked == ["ro-mount canary"]


def test_sbx_does_not_run_the_msb_ro_mount_checks(tmp_path):
    c, _fake, _raw = cell(tmp_path, "sbx", 1, ro=False)
    assert c.run() == 0


def test_teardown_removes_what_the_run_created_even_when_create_fails(tmp_path):
    c, fake, raw = cell(tmp_path, "sbx", create=False)
    assert c.run() == 1 and c.failures == ["create"]
    verbs = [" ".join(call[2:4]) for call in fake.calls]
    assert verbs[-1] == "provider-credential rm" and fake.calls[-1][4] == c.names.provider
    assert raw.removed == ["sbx-cs-ours"]


# ---- the script end to end, against the bundled stubs --------------------------


def _snapshot(root: Path) -> dict[str, bytes]:
    return {str(p.relative_to(root)): p.read_bytes() for p in sorted(root.rglob("*")) if p.is_file()}


@pytest.mark.skipif(os.name == "nt", reason="the stub shims are POSIX shell scripts")
@pytest.mark.skipif(sys.version_info < (3, 11), reason="the oracle runs the CLI under python -P")
@pytest.mark.parametrize("backend,version", [("msb", "0.7.11"), ("sbx", "0.51.0")])
def test_the_script_leaves_the_callers_acq_state_alone_and_a_stub_cannot_pass(tmp_path, backend, version):
    caller = tmp_path / "caller"
    dirs = {v: caller / v.lower() for v in ("HOME", "XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_DATA_HOME",
                                             "XDG_CACHE_HOME", "ACQ_STATE_DIR", "ACQ_SECRET_STORE_DIR", "TMPDIR")}
    for path in dirs.values():
        path.mkdir(parents=True)
    # The operator's own state: a binding the docs use as the example, and config.
    binding = dirs["ACQ_STATE_DIR"] / "provider-credentials" / "opencode-go.json"
    binding.parent.mkdir()
    binding.write_text('{"provider": "opencode-go", "key_env": "OPENCODE_GO_API_KEY"}')
    (dirs["XDG_CONFIG_HOME"] / "acq").mkdir()
    (dirs["XDG_CONFIG_HOME"] / "acq" / "config.yaml").write_text("schema: 1\n")
    before = {v: _snapshot(p) for v, p in dirs.items() if v not in ("HOME", "TMPDIR")}

    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    shim = bin_dir / backend
    shim.write_text(
        f"#!/bin/sh\nACQ_{backend.upper()}_STUB_VERSION={version} PYTHONPATH={REPO_ROOT / 'py-acq' / 'src'} "
        f"exec {sys.executable} -P -m acq_py._stub_{backend} \"$@\"\n"
    )
    shim.chmod(0o755)
    env = {"PATH": os.pathsep.join([str(bin_dir), "/usr/bin", "/bin"]), **{v: str(p) for v, p in dirs.items()}}
    proc = subprocess.run([sys.executable, str(ORACLE_PATH), "--backend", backend], env=env,
                          capture_output=True, text=True, timeout=300, cwd=tmp_path)

    # The stub echoes a command instead of running it in a guest: never a pass.
    assert proc.returncode == 1, proc.stdout + proc.stderr
    assert "FAIL: exec: the guest did not run the probe" in proc.stderr
    after = {v: _snapshot(p) for v, p in dirs.items() if v not in ("HOME", "TMPDIR")}
    assert after == before  # nothing written, replaced or removed in the caller's acq dirs
    assert list(dirs["TMPDIR"].iterdir()) == []  # the private tree is cleaned up
