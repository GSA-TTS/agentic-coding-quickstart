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

    EROFS = "denied:sh: 1: cannot create /var/lib/acq/host/.acq-qual-x: Read-only file system"

    def __init__(self, backend, names, state_dir, **knobs):
        self.backend, self.names, self.state_dir = backend, names, state_dir
        self.knobs = {"bind": True, "leak": None, "guest_value": False, "placeholder": True, "kit": True,
                      "ro": True, "echo_only": False, "secrets": True, "create": True, "pid1": True,
                      "mount_opts": "ro,relatime", "write": self.EROFS, "host_dir": True, "host_changes": False,
                      **knobs}
        self.calls: list[list[str]] = []
        self.stdin: list[str | None] = []

    @staticmethod
    def done(rc=0, out=""):
        return SimpleNamespace(returncode=rc, stdout=out, stderr="")

    @property
    def host_dir(self):
        return self.state_dir / "provenance" / self.backend / f"{self.names.sandbox}.abc123.config"

    def secret(self, verb):
        if verb[1] == "set":
            # Both backends bind a non-built-in service only with --host/--env (AGENTS.md).
            if "--host" not in verb or "--env" not in verb:
                return self.done(2)
            if (verb[verb.index("--host") + 1], verb[verb.index("--env") + 1]) != (qbc.CRED_HOST, self.names.secret_env):
                return self.done(2)
        return self.done(0 if self.knobs["secrets"] else 1)

    def __call__(self, argv, *, stdin=None, timeout=None):
        self.calls.append(argv)
        self.stdin.append(stdin)
        k, n = self.knobs, self.names
        verb = argv[2:]
        leak = n.value if k["leak"] == " ".join(verb[:2]) else ""
        if verb[0] == "provider-credential":
            return self.done(0 if k["bind"] or verb[1] != "set" else 1, leak)
        if verb[0] == "secret":
            proc = self.secret(verb)
            return self.done(proc.returncode, leak)
        if verb[0] == "create":
            if k["create"]:
                record = {"name": n.sandbox, **({"ro_host_config": True} if k["ro"] else {})}
                (self.state_dir / self.backend).mkdir(parents=True, exist_ok=True)
                (self.state_dir / self.backend / f"{n.sandbox}.abc123.json").write_text(json.dumps(record))
                if k["host_dir"]:
                    self.host_dir.mkdir(parents=True)
                    (self.host_dir / "agent").write_bytes(b"shell")
            return self.done(0 if k["create"] else 1)
        if verb[0] == "ls":
            return self.done(0, json.dumps({"data": {"sandboxes": [{"name": n.sandbox}]}}))
        if verb[0] == "rm":
            return self.done()
        if verb[0] == "exec":
            return self.guest(verb[-1], " ".join(verb[3:]))
        raise AssertionError(f"unexpected acq call {argv}")

    def guest(self, script, echoed):
        k, n = self.knobs, self.names
        if k["echo_only"]:
            return self.done(0, "[stub exec] " + echoed)
        if "boot=" in script:
            return self.done(0, f"boot={n.seed + 3}\n")
        if "cred=" in script:
            env = f"{n.key_env}=sbx-cs-placeholder" if k["placeholder"] and k["bind"] else ""
            if k["guest_value"]:
                env = f"{n.key_env}={n.value}"
            ph = env.split("=", 1)[1] if env else ""
            pid1 = "pid1=readable" if k["pid1"] else "pid1=unreadable"
            return self.done(0, f"cred={n.seed + 1}\nplaceholder={ph}\nPATH=/usr/bin\n{env}\n{pid1}\n")
        if "kit=" in script:
            return self.done(0, f"kit={n.seed + 2}\n" if k["kit"] else "")
        if "ro=" in script:
            assert qbc.HOST_CONFIG_GUEST_DIR in script and "/proc/mounts" in script
            if k["host_changes"]:
                (self.host_dir / f".acq-qual-{n.nonce}").write_text("x\n")
            opts = f"opts={k['mount_opts']}\n" if k["mount_opts"] else ""
            return self.done(0, f"ro={n.seed + 4}\n{opts}as=root\nwrite={k['write']}\n")
        raise AssertionError(f"unexpected guest script {script}")


class FakeRaw:
    """``sbx secret ls/rm`` for the teardown: one custom secret is ours, the others are the operator's."""

    def __init__(self, names):
        self.removed: list[str] = []
        self.msb_removed: list[str] = []
        self.table = [
            {"scope": "global", "env": "KEY", "placeholder": "sbx-cs-operator", "secret": "<masked>"},
            {"scope": "global", "env": "OPENCODE_GO_API_KEY", "placeholder": "sbx-cs-op2", "secret": "<masked>"},
            "not-an-object", 5, None,  # a malformed table must not crash the teardown
            {"scope": "global", "env": names.key_env, "placeholder": "sbx-cs-ours", "secret": "<masked>"},
        ]

    def __call__(self, argv, *, stdin=None, timeout=None):
        if argv[:3] == ["sbx", "secret", "ls"]:
            return SimpleNamespace(returncode=0, stdout=json.dumps({"custom_secrets": self.table}), stderr="")
        if argv[:4] == ["sbx", "secret", "rm", "--placeholder"]:
            self.removed.append(argv[4])
            return SimpleNamespace(returncode=0, stdout="", stderr="")
        if argv[:3] == ["msb", "remove", "--force"]:
            self.msb_removed.append(argv[3])
            return SimpleNamespace(returncode=0, stdout="", stderr="")
        raise AssertionError(f"unexpected raw call {argv}")


CANARY_LINES = {0: "RESULT: PASS\nRESULT PASS msb=0.7.7 image=i host=h rev=r dir=d\n",
                1: "RESULT: FAIL\nRESULT FAIL msb=0.7.7 image=i host=h rev=r dir=d\n"}


def cell(tmp_path, backend="msb", canary=0, deadline=None, **knobs):
    """``canary`` is an exit status (0 and 1 come with the canary's RESULT line) or ``(status, stdout)``."""
    names = qbc.make_names(backend, NONCE)
    state = tmp_path / "state"
    fake = FakeBackend(backend, names, state, **knobs)
    raw = FakeRaw(names)
    result = canary if isinstance(canary, tuple) else (canary, CANARY_LINES.get(canary, ""))
    c = qbc.Cell(backend, names, str(tmp_path / "ws"), state, fake, raw, lambda timeout: result,
                 *([deadline] if deadline is not None else []))
    return c, fake, raw


def teardown_calls(c, fake):
    n = c.names
    return [["--backend", c.backend, "rm", n.sandbox, "--json"],
            ["--backend", c.backend, "secret", "rm", "-g", n.service, "--json"],
            ["--backend", c.backend, "provider-credential", "rm", n.provider, "--json"]]


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
    assert fake.calls[-3:] == teardown_calls(c, fake)  # teardown always tries every nonce-named removal
    if backend == "sbx":
        assert raw.removed == ["sbx-cs-ours"]  # never the operator's KEY or OPENCODE_GO_API_KEY secret
    else:
        assert raw.msb_removed == [c.names.canary_sandbox]  # in case the canary was killed before cleanup
    secret_set = next(call for call in fake.calls if call[2:4] == ["secret", "set"])
    assert secret_set[secret_set.index("--host") + 1] == "qualify.invalid"
    assert secret_set[secret_set.index("--env") + 1] == c.names.secret_env


def test_the_nonce_names_are_printed_first(tmp_path, capsys):
    c, _fake, _raw = cell(tmp_path, "sbx")
    c.run()
    first = capsys.readouterr().err.splitlines()[0]
    for name in (c.names.sandbox, c.names.service, c.names.provider, c.names.key_env, c.names.secret_env):
        assert name in first
    assert c.names.value not in first


ROFS_EACCES = "denied:sh: 1: cannot create /var/lib/acq/host/.acq-qual-x: Permission denied"


@pytest.mark.parametrize(
    "backend,knobs,canary,failed",
    [
        ("msb", {"bind": False}, 0, ["provider-credential set", "guest credential"]),  # msb today
        ("sbx", {"leak": "provider-credential ls"}, 0, ["provider-credential ls"]),
        ("sbx", {"leak": "secret set"}, 0, ["secret set"]),
        ("sbx", {"guest_value": True}, 0, ["guest credential"]),  # the real value reached the guest
        ("msb", {"placeholder": False}, 0, ["guest credential"]),  # bound on the host, absent in the guest
        ("sbx", {"kit": False}, 0, ["kit apply"]),
        ("msb", {"ro": False}, 0, ["ro mount record"]),  # acq does not record the read-only mount
        ("msb", {"mount_opts": ""}, 0, ["ro mount"]),  # nothing mounted at the trusted-config path
        ("msb", {"mount_opts": "rw,relatime"}, 0, ["ro mount"]),
        ("msb", {"write": "ok"}, 0, ["ro mount"]),  # the guest wrote to it
        ("msb", {"write": ROFS_EACCES}, 0, ["ro mount"]),  # denied, but not by a read-only mount
        ("msb", {"host_dir": False}, 0, ["ro mount"]),  # no host directory behind the mount
        ("msb", {"host_changes": True}, 0, ["ro mount"]),  # the host saw the write
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


@pytest.mark.parametrize("backend", ["msb", "sbx"])
def test_a_secret_set_without_host_and_env_is_what_a_correct_backend_refuses(tmp_path, backend):
    # The fake refuses a non-built-in service without --host/--env, as AGENTS.md says
    # both backends do (sbx would store it and never inject it); the oracle must
    # pass them, so a correct backend is not failed.
    c, fake, _raw = cell(tmp_path, backend)
    assert fake.secret(["secret", "set", "-g", c.names.service, "--json"]).returncode == 2
    assert c.run() == 0


def test_every_control_failure_is_reported_in_one_run(tmp_path):
    # Python msb today: no credential path, no kits, no read-only mount, no secret store.
    c, _fake, _raw = cell(tmp_path, "msb", 0, bind=False, kit=False, ro=False, mount_opts="", write="ok",
                          host_dir=False, secrets=False)
    assert c.run() == 1
    assert c.failures == ["provider-credential set", "guest credential", "kit apply", "ro mount record",
                          "ro mount", "ro mount", "ro mount", "secret set"]


def test_a_backend_that_only_echoes_the_command_cannot_pass(tmp_path):
    c, fake, _raw = cell(tmp_path, "msb", echo_only=True)
    assert c.run() == 1
    assert c.failures == ["exec"]
    assert not any(call[2] == "exec" and "kit=" in call[-1] for call in fake.calls)  # the run stopped


@pytest.mark.parametrize("status", [None, 2, 3, 127, -9, 130, (1, ""), (1, "RESULT PASS msb=x\n"),
                                    (0, ""), (0, "RESULT FAIL msb=x\n"), (None, "RESULT FAIL msb=x\n")])
def test_only_canary_exit_1_with_its_result_fail_line_is_a_failure(tmp_path, status):
    # A FAIL needs the canary's own verdict line, so a bash that died with status 1
    # (a crash, a missing tool) is not reported as msb failing to enforce :ro.
    c, _fake, _raw = cell(tmp_path, "msb", status)
    assert c.run() == 2
    assert c.failures == [] and c.blocked == ["ro-mount canary"]


def test_an_unreadable_pid1_environment_is_a_reported_gap(tmp_path, capsys):
    c, _fake, _raw = cell(tmp_path, "sbx", pid1=False)
    assert c.run() == 2
    assert c.blocked == ["guest credential"]
    assert "/proc/1/environ is unreadable" in capsys.readouterr().err


def test_sbx_does_not_run_the_msb_ro_mount_checks(tmp_path):
    c, _fake, _raw = cell(tmp_path, "sbx", 1, ro=False, mount_opts="", host_dir=False)
    assert c.run() == 0


def test_teardown_removes_what_the_run_may_have_created_even_when_create_fails(tmp_path):
    c, fake, raw = cell(tmp_path, "sbx", create=False)
    assert c.run() == 1 and c.failures == ["create"]
    # the sandbox was never reported created, but an abort can land after the
    # backend made it: teardown still tries to remove it
    assert fake.calls[-3:] == teardown_calls(c, fake)
    assert raw.removed == ["sbx-cs-ours"]


@pytest.mark.parametrize("backend", ["msb", "sbx"])
def test_a_stop_signal_during_teardown_does_not_cut_the_removals_short(tmp_path, backend):
    # The harness's timeout SIGTERM, a second Ctrl+C or a SIGBREAK lands while the
    # first removal runs: every removal still runs, and the handlers come back after.
    import signal

    c, fake, raw = cell(tmp_path, backend)
    stops = [getattr(signal, n) for n in ("SIGINT", "SIGTERM", "SIGBREAK") if hasattr(signal, n)]
    saved = {sig: signal.getsignal(sig) for sig in stops}

    def signalled(argv, **kwargs):
        if argv[2:3] == ["rm"]:
            for sig in stops:
                signal.raise_signal(sig)
        return fake(argv, **kwargs)

    c.acq = signalled
    try:
        signal.signal(signal.SIGTERM, qbc._terminate)
        if hasattr(signal, "SIGBREAK"):
            signal.signal(signal.SIGBREAK, qbc._terminate)
        signal.signal(signal.SIGINT, signal.default_int_handler)
        c.teardown()
        assert signal.getsignal(signal.SIGTERM) is qbc._terminate
        assert signal.getsignal(signal.SIGINT) is signal.default_int_handler
    finally:
        for sig, handler in saved.items():
            signal.signal(sig, handler)
    assert fake.calls == teardown_calls(c, fake)
    if backend == "sbx":
        assert raw.removed == ["sbx-cs-ours"]
    else:
        assert raw.msb_removed == [c.names.canary_sandbox]


def test_a_spent_deadline_stops_the_run_blocks_it_and_still_tears_down(tmp_path, capsys):
    import time

    c, fake, _raw = cell(tmp_path, "msb", deadline=time.time() - 5)
    assert c.run() == 2
    assert c.blocked == ["deadline"] and c.failures == []
    assert fake.calls == teardown_calls(c, fake)  # no step started; every removal attempted
    assert "BLOCKED: deadline" in capsys.readouterr().err


def test_steps_never_get_more_time_than_the_deadline_leaves(tmp_path):
    import time

    c, fake, _raw = cell(tmp_path, "sbx", deadline=time.time() + 30)
    seen = []
    real = fake.__call__

    def spy(argv, *, stdin=None, timeout=None):
        seen.append(timeout)
        return real(argv, stdin=stdin, timeout=timeout)

    c.acq = spy
    assert c.run() == 0
    steps = seen[:-3]
    assert steps and all(t <= 30 for t in steps)  # create would otherwise get 600 s


def test_find_bash_skips_the_wsl_launcher_and_prefers_git_bash(tmp_path):
    # The PATH search uses shutil.which, which on a real Windows host only finds
    # names with a PATHEXT suffix (and may report it as .EXE), so the fakes found
    # through PATH get .exe there and paths compare case-insensitively.
    suffix = ".exe" if sys.platform == "win32" else ""

    def exe(path):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("#!/bin/sh\n")
        path.chmod(0o755)
        return path

    def same(found, expected):
        return found is not None and os.path.normcase(found) == os.path.normcase(str(expected))

    wsl = exe(tmp_path / "Windows" / "System32" / f"bash{suffix}")
    apps = exe(tmp_path / "Users" / "j" / "AppData" / "Local" / "Microsoft" / "WindowsApps" / f"bash{suffix}")
    path = os.pathsep.join([str(wsl.parent), str(apps.parent)])
    assert qbc.find_bash(path, os_name="nt", environ={}) is None
    git = exe(tmp_path / "Program Files" / "Git" / "bin" / "bash.exe")
    assert qbc.find_bash(path, os_name="nt", environ={"ProgramFiles": str(tmp_path / "Program Files")}) == str(git)
    other = exe(tmp_path / "msys64" / "usr" / "bin" / f"bash{suffix}")
    assert same(qbc.find_bash(os.pathsep.join([path, str(other.parent)]), os_name="nt", environ={}), other)
    assert same(qbc.find_bash(str(wsl.parent), os_name="posix"), wsl)  # elsewhere bash is just bash


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


@pytest.mark.skipif(os.name == "nt", reason="the stub shims are POSIX shell scripts")
@pytest.mark.skipif(sys.version_info < (3, 11), reason="the oracle runs the CLI under python -P")
def test_sigterm_mid_create_still_tears_the_sandbox_down(tmp_path):
    # The harness sends SIGTERM when a run outlives its timeout. The oracle must turn
    # it into SystemExit and run teardown, which removes the nonce-named sandbox even
    # though acq never reported it created (the backend made it, then hung).
    import signal
    import time

    home, tmp = tmp_path / "home", tmp_path / "tmp"
    home.mkdir(), tmp.mkdir()
    log, mark = tmp_path / "msb.log", tmp_path / "hung"
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    shim = bin_dir / "msb"
    shim.write_text(
        "#!/bin/sh\n"
        f"echo \"$*\" >> {log}\n"
        f"if [ \"$1\" = exec ] && [ ! -e {mark} ]; then touch {mark}; exec sleep 20; fi\n"
        f"ACQ_MSB_STUB_VERSION=0.7.11 PYTHONPATH={REPO_ROOT / 'py-acq' / 'src'} "
        f"exec {sys.executable} -P -m acq_py._stub_msb \"$@\"\n"
    )
    shim.chmod(0o755)
    env = {"PATH": os.pathsep.join([str(bin_dir), "/usr/bin", "/bin"]), "HOME": str(home), "TMPDIR": str(tmp),
           "XDG_STATE_HOME": str(tmp_path / "state"), "XDG_CONFIG_HOME": str(tmp_path / "cfg")}
    proc = subprocess.Popen([sys.executable, str(ORACLE_PATH), "--backend", "msb"], env=env, cwd=tmp_path,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        for _ in range(600):
            if mark.exists() or proc.poll() is not None:
                break
            time.sleep(0.1)
        assert mark.exists(), "create never reached the backend's readiness exec"
        proc.send_signal(signal.SIGTERM)
        _out, err = proc.communicate(timeout=120)
    finally:
        if proc.poll() is None:
            proc.kill()
    assert proc.returncode == 128 + signal.SIGTERM
    sandbox = err.splitlines()[0].split("sandbox=")[1].split()[0]
    calls = log.read_text().splitlines()
    assert any(c.startswith("create") and sandbox in c for c in calls)
    after = calls[calls.index(next(c for c in calls if c.startswith("exec"))) + 1:]
    assert any(c.startswith("remove") and sandbox in c for c in after), calls
    catalog = home / ".microsandbox" / "catalog.json"
    assert sandbox not in (catalog.read_text() if catalog.exists() else "")
    assert list(tmp.iterdir()) == []  # the private state tree is gone too



def test_canary_env_pins_the_image_and_names_the_sandbox_after_the_run(tmp_path):
    names = qbc.make_names("msb", NONCE)
    env = qbc.canary_env({"PATH": "/usr/bin", "QUALIFY_IMAGE": "evil:latest", "EXPECT_SHA": "x",
                          "QUALIFY_SANDBOX_NAME": "acq-qual-ro-someone-elses", "STEP_TIMEOUT": "900"}, names)
    assert env == {"PATH": "/usr/bin", "STEP_TIMEOUT": "900", "QUALIFY_SANDBOX_NAME": f"acq-qual-ro-{NONCE}"}


def test_a_step_cut_short_by_the_deadline_is_blocked_not_failed(tmp_path):
    import time

    c, fake, _raw = cell(tmp_path, "msb", deadline=time.time() + 600)
    real = fake.__call__

    def slow_create(argv, *, stdin=None, timeout=None):
        if argv[2] == "create":
            c.deadline = time.time() - 1  # the step used up the budget and came back with nothing
            return None
        return real(argv, stdin=stdin, timeout=timeout)

    c.acq = slow_create
    assert c.run() == 2
    assert c.failures == [] and c.blocked == ["deadline"]


def test_a_canary_cut_short_by_the_deadline_is_blocked_not_failed(tmp_path):
    import time

    c, _fake, _raw = cell(tmp_path, "msb", deadline=time.time() + 600)

    def canary(timeout):
        c.deadline = time.time() - 1
        return None, ""

    c.canary = canary
    assert c.run() == 2
    assert c.failures == [] and c.blocked == ["deadline"]


# ---- run_process: a stopped subprocess's whole group gets SIGTERM, then a grace ----


def _trapping_script(tmp_path):
    """A shell that starts a grandchild and records whether its TERM trap ran."""
    script = tmp_path / "child.sh"
    script.write_text(
        "#!/bin/sh\n"
        f"trap 'echo cleaned > {tmp_path}/trap; exit 143' TERM\n"
        f"sleep 60 & echo $! > {tmp_path}/grandchild\n"
        "wait\n"
    )
    return script


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    # a zombie still answers kill(0); it is not running
    try:
        return Path(f"/proc/{pid}/stat").read_text().split()[2] != "Z"
    except OSError:
        return True


@pytest.mark.skipif(os.name == "nt", reason="POSIX process groups")
def test_run_process_stops_the_whole_group_on_timeout_and_lets_its_cleanup_run(tmp_path):
    import time

    script = _trapping_script(tmp_path)
    assert qbc.run_process(["/bin/sh", str(script)], env=dict(os.environ), timeout=1.0, grace=10.0) is None
    assert (tmp_path / "trap").read_text().strip() == "cleaned"  # not SIGKILLed: its trap ran
    pid = int((tmp_path / "grandchild").read_text())
    for _ in range(50):
        if not _alive(pid):
            break
        time.sleep(0.1)
    assert not _alive(pid)  # the grandchild (think: msb create) was stopped too


@pytest.mark.skipif(os.name == "nt", reason="POSIX signals")
def test_run_process_stops_the_group_when_the_oracle_is_interrupted(tmp_path):
    # SIGTERM to the oracle (or Ctrl+C) arrives while it waits on a child: the child
    # group still gets SIGTERM and its grace before the oracle tears down.
    import signal

    script = _trapping_script(tmp_path)

    def interrupt(*_):
        raise SystemExit(143)

    old = signal.signal(signal.SIGALRM, interrupt)
    signal.setitimer(signal.ITIMER_REAL, 0.5)
    try:
        with pytest.raises(SystemExit):
            qbc.run_process(["/bin/sh", str(script)], env=dict(os.environ), timeout=60.0, grace=10.0)
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, old)
    assert (tmp_path / "trap").read_text().strip() == "cleaned"


@pytest.mark.skipif(os.name == "nt", reason="POSIX signals")
def test_run_process_kills_a_group_that_ignores_sigterm_after_the_grace(tmp_path):
    import time

    started = time.monotonic()
    proc = qbc.run_process(["/bin/sh", "-c", "trap '' TERM; sleep 60"], env=dict(os.environ), timeout=0.5, grace=0.5)
    assert proc is None and time.monotonic() - started < 30


def test_run_process_honours_its_timeout_while_waiting_in_slices(monkeypatch):
    # Each wait returns within WAIT_SLICE (so a SIGBREAK handler runs promptly on
    # Windows), yet the step as a whole still gets exactly its timeout.
    import time

    waits = []

    class Spy(subprocess.Popen):
        def communicate(self, input=None, timeout=None):
            waits.append(timeout)
            return super().communicate(input, timeout=timeout)

    monkeypatch.setattr(qbc.subprocess, "Popen", Spy)
    started = time.monotonic()
    proc = qbc.run_process([sys.executable, "-c", "import time; time.sleep(30)"], env=dict(os.environ),
                           timeout=2.5, grace=1.0)
    elapsed = time.monotonic() - started
    assert proc is None
    assert 2.5 <= elapsed < 2.5 + 1.0 + 3.0  # the timeout, then at most the grace and a reap
    assert len(waits) >= 3 and all(w is not None and w <= qbc.WAIT_SLICE for w in waits)


def test_run_process_captures_all_output_of_a_child_slower_than_one_slice():
    script = (
        "import sys, time\n"
        "data = sys.stdin.read()\n"
        "for i in range(4):\n"
        "    print(f'line {i} ' + 'x' * 50000, flush=True)\n"
        "    print(f'err {i}', file=sys.stderr, flush=True)\n"
        "    time.sleep(0.6)\n"
        "print('got ' + data.strip(), flush=True)\n"
    )
    proc = qbc.run_process([sys.executable, "-c", script], env=dict(os.environ), stdin="value\n", timeout=30.0)
    assert proc is not None and proc.returncode == 0
    assert proc.stdout.splitlines() == [f"line {i} " + "x" * 50000 for i in range(4)] + ["got value"]
    assert proc.stderr.splitlines() == [f"err {i}" for i in range(4)]


@pytest.mark.skipif(os.name == "nt", reason="POSIX sessions")
def test_run_process_does_not_wait_on_a_process_that_left_the_group():
    # ``setsid`` puts the sleeper outside the killed group, still holding the pipes.
    import shutil
    import time

    if shutil.which("setsid") is None:
        pytest.skip("setsid is not available")
    started = time.monotonic()
    proc = qbc.run_process(["sh", "-c", "setsid sleep 8 & sleep 30"], env=dict(os.environ), timeout=1, grace=1)
    assert proc is None and time.monotonic() - started < 6
