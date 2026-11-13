"""Regression evidence for Bash-compatible msb environment controls."""

import json
import os
import subprocess
import stat
from pathlib import Path, PureWindowsPath

import pytest

from acq_py import cli, debug, hostexec, msb, msb_options as opts, ssh_agent, state, userdirs


@pytest.fixture
def create_env(monkeypatch, tmp_path):
    for key in os.environ:
        if key.startswith("ACQ_MSB_") or key in ("ACQ_DEBUG", "ACQ_BACKEND", "ACQ_IMAGE", "ACQ_EXTRA_KITS"):
            monkeypatch.delenv(key)
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("ACQ_MSB_BIN", "__stub__")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "1")
    monkeypatch.setenv("ACQ_MSB_VERSION", "0.7.7")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "0")
    monkeypatch.setattr(opts, "host_resolver_lines", lambda: "nameserver 192.168.1.1\n")
    seen = []
    original = msb._run
    def spy(argv, **kwargs):
        seen.append(argv)
        return original(argv, **kwargs)
    monkeypatch.setattr(msb, "_run", spy)
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    return workspace, seen


def create(create_env, capsys):
    workspace, seen = create_env
    rc = cli.main(["--backend", "msb", "create", "shell", str(workspace),
                   "--name", "knobs", "--no-provider-kits", "--json"])
    streams = capsys.readouterr()
    assert rc == 0, streams
    doc = json.loads(streams.out)
    assert doc["data"]["name"] == "knobs"
    return next(a for a in seen if a[0] == "create"), streams.err


@pytest.mark.parametrize("memory,cpus,expected", [
    (None, None, ["-m", "4G", "-c", "2"]),
    ("8g", "4", ["-m", "8g", "-c", "4"]),
    ("", "", []),
    ("4GiB", "0", []),
    ("--bad", "-1", []),
    ("4 G", "two", []),
    ("4G", "0", ["-m", "4G"]),
    ("4GiB", "2", ["-c", "2"]),
    ("1.5G", "00", ["-m", "1.5G", "-c", "00"]),
    ("GM..", "01", ["-m", "GM..", "-c", "01"]),
])
def test_sizing_reaches_create(create_env, monkeypatch, capsys, memory, cpus, expected):
    for key, value in (("ACQ_MSB_MEMORY", memory), ("ACQ_MSB_CPUS", cpus)):
        if value is not None:
            monkeypatch.setenv(key, value)
    argv, err = create(create_env, capsys)
    actual = [t for i, a in enumerate(argv) if a in ("-m", "-c") for t in argv[i:i+2]]
    assert actual == expected
    if memory and "-m" not in expected:
        assert f"acq(msb): warning: ignoring invalid ACQ_MSB_MEMORY='{memory}' (expected e.g. 4G, 4096, 512M)." in err
    else:
        assert "invalid ACQ_MSB_MEMORY" not in err
    if cpus and "-c" not in expected:
        assert f"acq(msb): warning: ignoring invalid ACQ_MSB_CPUS='{cpus}' (expected a positive integer)." in err
    else:
        assert "invalid ACQ_MSB_CPUS" not in err


@pytest.mark.parametrize("value", ["", "always", "if-missing", "never", "NEVER", "--bad"])
def test_pull(create_env, monkeypatch, capsys, value):
    monkeypatch.setenv("ACQ_MSB_PULL", value)
    argv, err = create(create_env, capsys)
    if value in ("always", "if-missing", "never"):
        assert argv[argv.index("--pull") + 1] == value
    else:
        assert "--pull" not in argv
        if value:
            assert f"acq(msb): ignoring invalid ACQ_MSB_PULL='{value}' (expected: always | if-missing | never)" in err


@pytest.mark.parametrize("value,off", [("", False), ("TRUE", False), ("yes", False), ("On", False),
                                     ("1", False), ("0", True), ("false", True), ("NO", True), ("off", True), ("maybe", False)])
def test_dns(create_env, monkeypatch, capsys, value, off):
    monkeypatch.setenv("ACQ_MSB_DNS_NAMESERVER", "9.9.9.9")
    monkeypatch.setenv("ACQ_MSB_DNS_REBIND_PROTECTION", value)
    argv, err = create(create_env, capsys)
    assert argv[argv.index("--dns-nameserver") + 1] == "9.9.9.9"
    assert ("--no-dns-rebind-protection" in argv) == off
    if value == "maybe":
        assert "acq(msb): WARNING: invalid ACQ_MSB_DNS_REBIND_PROTECTION=maybe (expected 1|0|empty); using auto" in err


@pytest.mark.parametrize("ip,off", [("100.63.255.1", False), ("100.64.0.1", True),
                                    ("100.127.255.254", True), ("100.128.0.1", False)])
def test_dns_auto_bounds(create_env, monkeypatch, capsys, ip, off):
    monkeypatch.setattr(opts, "host_resolver_lines", lambda: f"nameserver 8.8.8.8\nnameserver {ip}\n")
    argv, err = create(create_env, capsys)
    assert ("--no-dns-rebind-protection" in argv) == off
    assert ("host resolvers are in 100.64/10 (ZPA)" in err) == off
    assert "--dns-nameserver" not in argv


def test_dns_explicit_keep_overrides_cgnat(monkeypatch, capsys):
    monkeypatch.setattr(opts, "host_resolver_lines", lambda: "nameserver 100.64.0.1")
    monkeypatch.setenv("ACQ_MSB_DNS_REBIND_PROTECTION", "1")
    assert "--no-dns-rebind-protection" not in opts.dns_flags()
    assert capsys.readouterr().err == ""
    monkeypatch.setenv("ACQ_MSB_DNS_REBIND_PROTECTION", "invalid")
    assert "--no-dns-rebind-protection" in opts.dns_flags()
    assert "WARNING: invalid ACQ_MSB_DNS_REBIND_PROTECTION=invalid" in capsys.readouterr().err


@pytest.mark.parametrize("key,value", [("ACQ_MSB_UPSTREAM_CA_FILE", "relative.pem"),
                                      ("ACQ_MSB_UPSTREAM_CA_CERT", "/abs/a.pem:relative.pem"),
                                      ("ACQ_MSB_UPSTREAM_CA_CERT", "C:/certs/ca.pem")])
@pytest.mark.parametrize("json_mode", [False, True])
def test_ca_refusals(monkeypatch, capsys, key, value, json_mode):
    monkeypatch.setenv(key, value)
    with pytest.raises(userdirs.UserDirError) as exc:
        userdirs.check_path_overrides()
    assert cli.main(["ls", *(["--json"] if json_mode else [])]) == 1
    out, err = capsys.readouterr()
    if json_mode:
        doc = json.loads(out)
        assert doc["error"]["code"] == "validation_failed"
        assert doc["error"]["message"] == exc.value.message
    else:
        assert not out
        assert err == f"acq: {exc.value.message}\n{exc.value.remediation}\n"


def test_explicit_ca_split_missing_and_suppression(create_env, monkeypatch, tmp_path, capsys):
    a, b = tmp_path / "a.pem", tmp_path / "b.pem"
    a.write_text("root a")
    b.write_text("root b")
    ca_paths = [msb._guest_path(str(p)) for p in (a, b, tmp_path / "missing")]
    monkeypatch.setenv("ACQ_MSB_UPSTREAM_CA_CERT", f"{ca_paths[0]}:\t{ca_paths[1]}\n{ca_paths[2]}")
    argv, err = create(create_env, capsys)
    actual = [argv[i+1] for i, a in enumerate(argv) if a == "--tls-upstream-ca-cert"]
    assert actual == [opts.ca_host_path(p) for p in ca_paths[:2]]
    assert "path not readable, skipping:" in err
    monkeypatch.setenv("ACQ_MSB_NO_UPSTREAM_CA", "0")
    assert opts.upstream_ca_flags() == []
    monkeypatch.delenv("ACQ_MSB_NO_UPSTREAM_CA")
    monkeypatch.setenv("ACQ_MSB_NO_TLS_INTERCEPT", "1")
    assert "--tls-intercept" not in msb.egress_flags([])
    assert "--tls-upstream-ca-cert" not in msb.egress_flags([])


@pytest.mark.parametrize("kind", ["empty", "directory", "symlink", "parent-symlink"])
def test_ca_unsafe_inputs(monkeypatch, tmp_path, kind):
    target = tmp_path / "target"
    target.write_text("CA")
    path = tmp_path / "bad"
    if kind == "empty": path.touch()
    elif kind == "directory": path.mkdir()
    elif kind == "symlink": path.symlink_to(target)
    else:
        path.symlink_to(tmp_path, target_is_directory=True)
        path = path / "target"
    monkeypatch.setenv("ACQ_MSB_UPSTREAM_CA_CERT", msb._guest_path(str(path)))
    monkeypatch.setenv("ACQ_MSB_UPSTREAM_CA_AUTODETECT", "0")
    assert opts.upstream_ca_flags() == []


@pytest.fixture
def mac_ca(monkeypatch, tmp_path):
    monkeypatch.setattr(opts.sys, "platform", "darwin")
    monkeypatch.setattr(hostexec, "which", lambda _: "/usr/bin/security")
    monkeypatch.setenv("ACQ_MSB_UPSTREAM_CA_CERT", "")
    monkeypatch.delenv("ACQ_MSB_NO_UPSTREAM_CA", raising=False)
    monkeypatch.delenv("ACQ_MSB_UPSTREAM_CA_AUTODETECT", raising=False)
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.delenv("ACQ_MSB_UPSTREAM_CA_FILE", raising=False)
    calls = []
    def run(argv, **kwargs):
        calls.append(argv)
        return subprocess.CompletedProcess(argv, 0, "-----BEGIN CERTIFICATE-----\nCA\n", "")
    monkeypatch.setattr(hostexec, "run_captured", run)
    return calls


def test_ca_mac_export_and_override(mac_ca, monkeypatch, tmp_path):
    default = state.state_dir() / "msb/host-upstream-cas.pem"
    assert opts.upstream_ca_flags() == ["--tls-upstream-ca-cert", str(default)]
    assert default.read_text().startswith("-----BEGIN CERTIFICATE-----")
    assert mac_ca == [["/usr/bin/security", "find-certificate", "-a", "-p"]]
    out = tmp_path / "custom.pem"
    monkeypatch.setenv("ACQ_MSB_UPSTREAM_CA_FILE", str(out))
    assert opts.upstream_ca_flags() == ["--tls-upstream-ca-cert", str(out)]
    assert not list(tmp_path.glob("custom.pem.*"))


@pytest.mark.parametrize("value", ["", "0", "false", "NO", "off"])
def test_ca_auto_off(mac_ca, monkeypatch, value):
    monkeypatch.setenv("ACQ_MSB_UPSTREAM_CA_AUTODETECT", value)
    assert opts.upstream_ca_flags() == []
    assert not mac_ca


def test_ca_explicit_wins_and_missing_falls_back(mac_ca, monkeypatch, tmp_path, capsys):
    pem = tmp_path / "explicit"
    pem.write_text("CA")
    # Exercise explicit files with the real host path rules, then simulate the
    # macOS-only fallback. A simulated Darwin platform cannot read /c/... on NT.
    with monkeypatch.context() as native:
        if os.name == "nt":
            native.setattr(opts.sys, "platform", "win32")
        value = msb._guest_path(str(pem))
        native.setenv("ACQ_MSB_UPSTREAM_CA_CERT", value)
        assert opts.upstream_ca_flags() == ["--tls-upstream-ca-cert", opts.ca_host_path(value)]
        assert not mac_ca
        pem.unlink()
        native.setenv("ACQ_MSB_UPSTREAM_CA_AUTODETECT", "0")
        assert opts.upstream_ca_flags() == []
        assert "path not readable, skipping:" in capsys.readouterr().err
    monkeypatch.setenv("ACQ_MSB_UPSTREAM_CA_CERT", "/missing-explicit.pem")
    assert opts.upstream_ca_flags()
    assert len(mac_ca) == 1


@pytest.mark.parametrize("status,text", [(1, "BEGIN CERTIFICATE"), (0, "garbage")])
def test_ca_bad_export_keeps_previous(mac_ca, monkeypatch, tmp_path, capsys, status, text):
    out = tmp_path / "bundle.pem"
    out.write_text("previous")
    monkeypatch.setenv("ACQ_MSB_UPSTREAM_CA_FILE", str(out))
    monkeypatch.setattr(hostexec, "run_captured", lambda argv: subprocess.CompletedProcess(argv, status, text, ""))
    assert opts.upstream_ca_flags() == []
    assert out.read_text() == "previous"
    assert "could not export host CAs" in capsys.readouterr().err
    assert not list(tmp_path.glob("bundle.pem.*"))


def test_ca_export_refuses_symlink_destination(mac_ca, monkeypatch, tmp_path):
    target = tmp_path / "target"
    target.write_text("original")
    link = tmp_path / "link"
    link.symlink_to(target)
    monkeypatch.setenv("ACQ_MSB_UPSTREAM_CA_FILE", str(link))
    assert opts.upstream_ca_flags() == []
    assert not mac_ca
    assert target.read_text() == "original"


def test_workspace_override_record_and_session(create_env, monkeypatch, tmp_path, capsys):
    directory = tmp_path / "other"
    directory.mkdir()
    link = tmp_path / "link"
    link.symlink_to(directory, target_is_directory=True)
    monkeypatch.setenv("ACQ_MSB_WORKSPACE", str(link))
    argv, _ = create(create_env, capsys)
    guest = msb._guest_path(str(directory.resolve()))
    mount = f"{create_env[0]}:{msb._guest_path(str(create_env[0]))}"
    assert argv[argv.index("-w") + 1] == guest
    assert argv[argv.index("--volume") + 1] == mount
    assert state.record_read("msb", "knobs")["workspace"] == str(create_env[0])
    assert state.record_read("msb", "knobs")["guest_workspace"] == guest
    assert ssh_agent.recorded_workspaces("knobs") == [str(create_env[0])]
    monkeypatch.delenv("ACQ_MSB_WORKSPACE")
    seen = []
    monkeypatch.setattr(msb, "_run_stream", lambda argv, **kw: seen.append(argv) or 0)
    msb._session("knobs", ["true"], workspace="/old", env=[], tty=False, json_mode=True)
    assert seen[0][seen[0].index("-w") + 1] == guest
    if os.name == "nt":
        return  # Windows requests no read-only mount, so it never qualifies for recreate
    monkeypatch.setenv("ACQ_SECURITY_MOUNT_STATE", json.dumps({"knobs": "missing"}))
    assert cli.main(["--backend", "msb", "create", "--recreate", "knobs", "--yes", "--json"]) == 0
    recreated = [a for a in create_env[1] if a[0] == "create"][-1]
    assert recreated[recreated.index("--volume") + 1] == mount
    assert recreated[recreated.index("-w") + 1] == guest
    assert state.record_read("msb", "knobs")["workspace"] == str(create_env[0])
    assert state.record_read("msb", "knobs")["guest_workspace"] == guest


def test_debug_off_and_nonempty_toggle(monkeypatch, capsys):
    monkeypatch.delenv("ACQ_DEBUG", raising=False)
    debug.trace_command(["msb", "list"])
    assert capsys.readouterr() == ("", "")
    monkeypatch.setenv("ACQ_DEBUG", "0")
    debug.trace_command(["msb", "list"])
    out, err = capsys.readouterr()
    assert out == ""
    assert __import__('re').fullmatch(r"acq\[debug \d\d:\d\d:\d\d\]: msb list\n", err)


def test_debug_redacts_urls_env_values_and_guest_scripts(monkeypatch, capsys):
    monkeypatch.setenv("ACQ_DEBUG", "1")
    monkeypatch.setenv("USAI_API_KEY", "private-value")
    debug.trace_command(["msb", "create", "private-value", "https://u:password@host/path?token=query",
                         "--env", "TOKEN=another-secret", "--", "guest-script-secret"],
                        {"GITHUB_TOKEN": "child-secret"})
    out, err = capsys.readouterr()
    assert not out
    for value in ("private-value", "password", "query", "another-secret", "guest-script-secret", "child-secret"):
        assert value not in err
    assert "https://***@host/path?***" in err


def test_debug_wired_to_captured_and_foreground(monkeypatch, capsys):
    monkeypatch.setenv("ACQ_DEBUG", "1")
    monkeypatch.setattr(hostexec.subprocess, "run", lambda argv, **kw: subprocess.CompletedProcess(argv, 0))
    hostexec.run_captured(["msb", "list"])
    monkeypatch.setattr(hostexec, "_start_session", lambda *args: (object(), None))
    monkeypatch.setattr(hostexec, "_wait_session", lambda *args: (0, None))
    hostexec._run_session(["msb", "exec", "--", "secret-command"], None)
    out, err = capsys.readouterr()
    assert not out
    assert "msb list" in err and "msb exec" in err
    assert "secret-command" not in err


@pytest.mark.parametrize("source,target", [("/c/certs/root.pem", "C:/certs/root.pem"),
                                          ("/unc/server/share/root.pem", "//server/share/root.pem"),
                                          ("//server/share/root.pem", "//server/share/root.pem")])
@pytest.mark.parametrize("unsafe", [None, "symlink", "junction"])
def test_ca_windows_host_form(monkeypatch, source, target, unsafe):
    monkeypatch.setattr(opts.sys, "platform", "win32")
    monkeypatch.setenv("ACQ_MSB_UPSTREAM_CA_CERT", source)
    monkeypatch.delenv("ACQ_MSB_NO_UPSTREAM_CA", raising=False)
    checked = []
    class WindowsFixturePath(PureWindowsPath):
        def lstat(self):
            assert self == PureWindowsPath(target)
            return os.stat_result((stat.S_IFREG | 0o644, 0, 0, 1, 0, 0, 2, 0, 0, 0))
        def is_symlink(self):
            checked.append(self)
            return unsafe == "symlink" and self == PureWindowsPath(target).parent
        def is_junction(self):
            return unsafe == "junction" and self == PureWindowsPath(target).parent
    userdirs.check_ca_paths()
    monkeypatch.setattr(opts, "Path", WindowsFixturePath)
    monkeypatch.setattr(opts.os, "access", lambda path, mode: path == PureWindowsPath(target))
    assert opts.upstream_ca_flags() == ([] if unsafe else ["--tls-upstream-ca-cert", target])
    native = PureWindowsPath(target)
    assert checked == ([native, native.parent] if unsafe else [native, *native.parents])


def test_ca_unreadable_file(monkeypatch, tmp_path):
    pem = tmp_path / "unreadable.pem"
    pem.write_text("CA")
    monkeypatch.setenv("ACQ_MSB_UPSTREAM_CA_CERT", msb._guest_path(str(pem)))
    monkeypatch.setenv("ACQ_MSB_UPSTREAM_CA_AUTODETECT", "0")
    monkeypatch.setattr(opts.os, "access", lambda *args: False)
    assert opts.upstream_ca_flags() == []


@pytest.mark.parametrize("platform,tool", [("linux", "/usr/bin/security"), ("darwin", None)])
def test_ca_autodetect_platform_and_tool(monkeypatch, platform, tool):
    monkeypatch.setenv("ACQ_MSB_UPSTREAM_CA_CERT", "")
    monkeypatch.setattr(opts.sys, "platform", platform)
    monkeypatch.setattr(hostexec, "which", lambda _: tool)
    assert opts.upstream_ca_flags() == []


def test_ca_export_io_failures(mac_ca, monkeypatch, tmp_path, capsys):
    out = tmp_path / "not-a-dir" / "root.pem"
    out.parent.write_text("file")
    monkeypatch.setenv("ACQ_MSB_UPSTREAM_CA_FILE", str(out))
    assert opts.upstream_ca_flags() == []
    assert "cannot create upstream-CA dir" in capsys.readouterr().err
    monkeypatch.setenv("ACQ_MSB_UPSTREAM_CA_FILE", str(tmp_path / "root.pem"))
    def fail(**kwargs): raise OSError("no space")
    monkeypatch.setattr(opts.tempfile, "mkstemp", fail)
    assert opts.upstream_ca_flags() == []
    assert "cannot create temp file" in capsys.readouterr().err


def test_workspace_windows_override(monkeypatch):
    monkeypatch.setattr(msb, "WINDOWS", True)
    monkeypatch.setenv("ACQ_MSB_WORKSPACE", "C:/Users/me/project")
    monkeypatch.setattr(msb.os.path, "realpath", lambda value: value)
    assert msb.workspace_override() == "/c/Users/me/project"


def test_debug_create_keeps_json_stdout(create_env, monkeypatch, capsys):
    monkeypatch.setenv("ACQ_DEBUG", "1")
    _argv, err = create(create_env, capsys)
    assert "acq[debug " in err and " create " in err


@pytest.mark.parametrize("argument", [
    "user:trace-sentinel@github.com/org/repo?foo=bar",
    "trace-sentinel=value",
    "https://user:password@host/path#token=trace-sentinel",
    "https://host/path?foo=bar#token=trace-sentinel",
    "user:equals-secret=tail@github.com/org/repo?foo=bar",
])
@pytest.mark.parametrize("prefix", [[], ["--env"], ["--password"]])
def test_debug_sanitizes_every_branch(monkeypatch, capsys, argument, prefix):
    monkeypatch.setenv("ACQ_DEBUG", "1")
    debug.trace_command(["msb", *prefix, argument], {"ACCESS_TOKEN": "trace-sentinel"})
    err = capsys.readouterr().err
    assert "trace-sentinel" not in err
    assert "user:password" not in err
    assert "equals-secret" not in err


def test_debug_redacts_complete_environment_value_before_assignment_mask(monkeypatch, capsys):
    monkeypatch.setenv("ACQ_DEBUG", "1")
    debug.trace_command(["msb", "--env", "equals-secret=tail=value"],
                        {"ACCESS_TOKEN": "equals-secret=tail"})
    assert "equals-secret" not in capsys.readouterr().err


@pytest.mark.parametrize("key", ["APIKEY", "USAI_KEY", "OPENAI_KEY", "ACCESS_KEY"])
def test_debug_key_spellings(monkeypatch, capsys, key):
    monkeypatch.setenv("ACQ_DEBUG", "1")
    debug.trace_command(["msb", "key-sentinel"], {key: "key-sentinel"})
    assert "key-sentinel" not in capsys.readouterr().err


@pytest.mark.parametrize("argv,visible", [
    (["msb", "create", "-c", "2"], "-c 2"),
    (["sh", "-c", "echo shell-sentinel"], "-c '***'"),
    (["sh", "-c", "42"], "-c '***'"),
    (["sh", "-c", "echo shell-sentinel=value"], "-c '***'"),
    (["/bin/bash", "--noprofile", "-c", "echo shell-sentinel=value"], "-c '***'"),
])
def test_debug_cpu_count_and_shell_scripts(monkeypatch, capsys, argv, visible):
    monkeypatch.setenv("ACQ_DEBUG", "1")
    debug.trace_command(argv)
    err = capsys.readouterr().err
    assert visible in err
    assert "shell-sentinel" not in err


@pytest.mark.parametrize("root", ["/var", "/tmp", "/etc"])
@pytest.mark.parametrize("unsafe", [None, "file", "parent"])
def test_ca_macos_system_aliases(monkeypatch, root, unsafe):
    monkeypatch.setattr(opts.sys, "platform", "darwin")
    alias = Path(root)
    canonical = Path("/private") / alias.name
    path = alias / "acq-certs" / "root.pem"
    real = canonical / "acq-certs" / "root.pem"
    resolve = Path.resolve
    monkeypatch.setattr(Path, "resolve", lambda p, **kw: canonical if p == alias else resolve(p, **kw))
    linked = {alias}
    if unsafe:
        linked.add(real if unsafe == "file" else real.parent)
    checked = []
    def is_link(p):
        checked.append(p)
        return p in linked
    monkeypatch.setattr(Path, "is_symlink", is_link)
    monkeypatch.setattr(Path, "is_junction", lambda p: False)
    assert opts._safe_path(path) == (unsafe is None)
    assert real in checked
