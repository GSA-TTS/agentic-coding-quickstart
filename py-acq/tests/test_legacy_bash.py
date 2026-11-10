"""Tier-2 tests for reading and importing the Bash acq's state (ADR-0041m).

The Bash-written fixtures come from sourcing the real writers in
``acq.backends/common.sh`` into the test's isolated state tree, so the reader is
checked against what Bash actually writes, not a copy of its format. Those
tests need bash on a POSIX host; the hand-written fixtures below them run on
every platform.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

from acq_py import (
    config,
    kits,
    kitspec,
    legacy_bash,
    lock,
    migration,
    provider_creds,
    security,
    state,
)
from acq_py.commands import session

REPO_ROOT = Path(__file__).resolve().parents[2]
COMMON_SH = REPO_ROOT / "acq.backends" / "common.sh"
BASH = shutil.which("bash")
needs_bash = pytest.mark.skipif(BASH is None or os.name != "posix", reason="needs bash on a POSIX host")

SHA = "0123456789abcdef0123456789abcdef01234567"
OTHER_SHA = "fedcba9876543210fedcba9876543210fedcba98"
SOCK = "/home/agent/.acq/ssh-agent.sock"


@pytest.fixture
def tree(tmp_path, monkeypatch):
    """An isolated state tree: Python state, Bash provenance and config all under tmp_path."""
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("ACQ_PROVENANCE_DIR", str(tmp_path / "provenance"))
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path / "config"))
    for var in ("ACQ_STATE_SEED", "ACQ_CONFIG_SEED", "ACQ_KIT_SOURCE_SEED", "ACQ_PROVIDER_CREDENTIAL_SEED",
                "ACQ_KIT_PROVENANCE_SEED", "ACQ_KIT_SOURCES", "ACQ_PROVIDER_CREDENTIAL_BINDINGS"):
        monkeypatch.delenv(var, raising=False)
    return tmp_path


def _bash(script: str, *args: str) -> None:
    assert BASH is not None
    proc = subprocess.run(
        [BASH, "-c", f'source "$1"; shift; {script}', "bash", str(COMMON_SH), *args],
        capture_output=True, timeout=60, env={**os.environ, "LC_ALL": "C"}, check=False,
    )
    assert proc.returncode == 0, proc.stderr.decode()


def _bash_sandbox(tree: Path, name: str = "opencode-proj", agent: str = "opencode") -> Path:
    """Write one msb sandbox's state with the Bash writers; returns its workspace."""
    workspace = tree / "ws" / name
    workspace.mkdir(parents=True)
    kit = tree / "kit"
    kit.mkdir(exist_ok=True)
    _bash(
        'acq_provenance_write msb "$1" "$2" && acq_workspace_record_write msb "$1" "$3" '
        '&& acq_host_config_write msb "$1" ro-host-config 1 '
        '&& acq_host_config_write msb "$1" ssh-auth-sock "$4" '
        '&& ACQ_CLI_KITS=("$5") && acq_cli_kits_write msb "$1"',
        name, agent, str(workspace), SOCK, str(kit),
    )
    return workspace


def _bash_config(key: str, value: str) -> None:
    _bash('_acq_config_write_field "$1" "$2"', key, value)


def _snapshot(*roots: Path) -> dict[str, bytes]:
    out: dict[str, bytes] = {}
    for root in roots:
        for path in sorted(root.rglob("*")):
            if path.is_file():
                out[str(path)] = path.read_bytes()
    return out


def _python_records(tree: Path) -> dict[str, bytes]:
    return _snapshot(tree / "state")


# ---------------------------------------------------------------------------
# Readers against Bash-written state.
# ---------------------------------------------------------------------------

@needs_bash
def test_reader_parses_what_the_bash_writers_write(tree):
    workspace = _bash_sandbox(tree)
    assert legacy_bash.provenance_file("msb", "opencode-proj").is_file()
    assert legacy_bash.sandbox_names("msb") == ["opencode-proj"]
    sandbox = legacy_bash.read_sandbox("msb", "opencode-proj")
    assert sandbox.agent == "opencode"
    assert sandbox.workspace == str(workspace)
    assert sandbox.ro_host_config is True
    assert sandbox.ssh_auth_sock == SOCK
    assert sandbox.applied_ref == kits.CONTROL_PLANE_REF
    assert sandbox.applied_at is not None
    assert legacy_bash.read_cli_kits("msb", "opencode-proj") == ([str(tree / "kit")], [])


@needs_bash
def test_cksum_key_matches_the_bash_writer(tree):
    for name in ("opencode-proj", "a", "x" * 70, "ünïcode"):
        _bash('acq_provenance_write msb "$1" shell', name)
        assert legacy_bash.provenance_file("msb", name).is_file(), name


@needs_bash
@pytest.mark.parametrize("entry", [
    f"github.com/acme/kits@{SHA}|kits",
    "github.com/acme/kits",
    "https://github.com/acme/kits.git@abc|.",
    "github.com/GSA-TTS/agentic-coding-patterns",
    "github.com/acme/kits@bad^ref",
    "github.com/acme/kits|../x",
    "github.com/acme/kits|/abs",
    "https://user@github.com/acme/kits",
    "notarepo",
])
def test_kit_source_entry_parses_like_bash(entry):
    assert BASH is not None
    proc = subprocess.run(
        [BASH, "-c", 'source "$1"; _acq_kit_source_parse_entry "$2"', "bash", str(COMMON_SH), entry],
        capture_output=True, timeout=60, check=False,
    )
    if proc.returncode != 0:
        with pytest.raises(legacy_bash.LegacyParseError):
            legacy_bash.parse_kit_source_entry(entry)
        return
    assert "|".join(legacy_bash.parse_kit_source_entry(entry)) == proc.stdout.decode().strip()


@needs_bash
@pytest.mark.parametrize("pairs", [
    "opencode-go=OPENCODE_GO_API_KEY@models.example.gov",
    "a=A_KEY b=B_KEY@h1.example,h2.example",
    "a=A_KEY@h1.example,",
    "a=A_KEY@,h1.example",
    "a=A_KEY@h1.example,,h2.example",
    "x=USAI_API_KEY",
    "Bad=KEY",
    "a=PATH",
    "a=lower",
    "novalue",
    "a=A@HOST.EXAMPLE",
])
def test_provider_credential_pairs_parse_like_bash(pairs):
    assert BASH is not None
    proc = subprocess.run(
        [BASH, "-c", 'source "$1"; _acq_provider_credential_parse_pairs src "$2"', "bash", str(COMMON_SH), pairs],
        capture_output=True, timeout=60, check=False,
    )
    if proc.returncode != 0:
        with pytest.raises(legacy_bash.LegacyParseError):
            legacy_bash.parse_provider_credential_pairs(pairs)
        return
    want = proc.stdout.decode().split()
    got = [f"{p}={k}" + (f"@{','.join(h)}" if h else "") for p, k, h in
           legacy_bash.parse_provider_credential_pairs(pairs)]
    assert got == want


# ---------------------------------------------------------------------------
# The generation-2 import against Bash-written state.
# ---------------------------------------------------------------------------

def _bash_world(tree: Path) -> Path:
    workspace = _bash_sandbox(tree)
    _bash_config("kit_sources", f"github.com/acme/kits@{SHA}|kits")
    _bash_config("provider_credential_bindings", "opencode-go=OPENCODE_GO_API_KEY@models.example.gov")
    return workspace


@needs_bash
def test_generation_1_tree_imports_bash_state(tree):
    workspace = _bash_world(tree)
    migration.write_generation(migration.RECORDS_GENERATION)

    migration.migrate_tree()

    record = state.record_read("msb", "opencode-proj")
    assert record is not None
    assert record["agent"] == "opencode"
    assert record["workspace"] == str(workspace)
    assert record["ro_host_config"] is True
    assert record["ssh_auth_sock"] == SOCK
    assert kits.provenance_status("msb", "opencode-proj") == "current"
    assert kits.source_record("github.com/acme/kits") == {
        "schema": kits.KIT_SCHEMA, "repository": "github.com/acme/kits", "ref": SHA, "directory": "kits",
    }
    binding = provider_creds.get_binding("opencode-go")
    assert binding is not None
    assert (binding["key_env"], binding["hosts"]) == ("OPENCODE_GO_API_KEY", ["models.example.gov"])
    assert migration.read_generation() == migration.TARGET_GENERATION


@needs_bash
def test_import_is_idempotent_and_leaves_bash_files_unchanged(tree):
    _bash_world(tree)
    bash_before = _snapshot(tree / "provenance", tree / "config")

    migration.migrate_tree()
    first = _python_records(tree)
    migration.write_generation(migration.RECORDS_GENERATION)  # force the import to run again
    migration.migrate_tree()

    assert _python_records(tree) == first
    # Only the schema marker this acq adds may differ in config.yaml.
    bash_after = _snapshot(tree / "provenance", tree / "config")
    cfg = str(config.config_path())
    assert bash_after[cfg].replace(b"schema: 1\n", b"") == bash_before[cfg]
    assert {k: v for k, v in bash_after.items() if k != cfg} == {k: v for k, v in bash_before.items() if k != cfg}


@needs_bash
def test_import_never_clobbers_existing_python_records(tree):
    _bash_world(tree)
    state.record_write("msb", "opencode-proj", agent="claude", workspace="/elsewhere")
    kits.set_source("github.com/acme/kits", OTHER_SHA, "other")
    provider_creds.set_binding("opencode-go", "OTHER_KEY", ["other.example.gov"])
    before = _python_records(tree)

    migration.migrate_tree()

    after = _python_records(tree)
    assert {k: v for k, v in after.items() if k in before} == before
    assert state.record_read("msb", "opencode-proj")["agent"] == "claude"
    # The Bash bundle ref describes the Bash sandbox, not this acq's: not carried over.
    assert kits.provenance_read("msb", "opencode-proj") is None


@needs_bash
def test_records_removed_after_the_import_stay_removed(tree):
    _bash_world(tree)
    migration.migrate_tree()
    state.record_remove("msb", "opencode-proj")
    kits.remove_source("github.com/acme/kits")
    provider_creds.remove_binding("opencode-go")

    migration.migrate_tree()

    assert state.record_read("msb", "opencode-proj") is None
    assert kits.source_record("github.com/acme/kits") is None
    assert provider_creds.get_binding("opencode-go") is None


@needs_bash
def test_imported_ssh_agent_socket_reaches_the_session(tree, monkeypatch):
    _bash_sandbox(tree)
    monkeypatch.setattr(session, "host_git_identity_env", list)
    # Both implementations read the shared host-config key, as the forward's
    # bridge writes it (ADR-0021), so it reaches the session before any import.
    assert session.session_env_for("msb", "opencode-proj") == [f"SSH_AUTH_SOCK={SOCK}"]

    migration.migrate_tree()
    (security.host_config_dir("opencode-proj") / "ssh-auth-sock").unlink()

    # Without the key, the copy the import put in the record still does.
    assert session.session_env_for("msb", "opencode-proj") == [f"SSH_AUTH_SOCK={SOCK}"]


@needs_bash
def test_provider_kit_resolves_against_imported_bash_kit_sources(tree):
    _bash_config("kit_sources", f"github.com/acme/kits@{SHA}|kits")
    _bash_config("provider_kit", "kits/acme-provider")
    with pytest.raises(kitspec.KitSelectionError):
        kitspec.provider_kit_ref({})

    migration.migrate_tree()

    assert kitspec.provider_kit_ref({}) == f"git+https://github.com/acme/kits.git#ref={SHA}&dir=kits/acme-provider"
    assert legacy_bash.provider_kit() == "kits/acme-provider"


# ---------------------------------------------------------------------------
# Hand-written fixtures (every platform).
# ---------------------------------------------------------------------------

def _bash_file(name: str, suffix: str, text: str, backend: str = "msb") -> Path:
    path = legacy_bash._backend_dir(backend) / f"{lock.bash_sandbox_key(name)}{suffix}"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    return path


def _config(text: str) -> None:
    path = config.config_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def test_posix_cksum_known_values():
    assert legacy_bash.posix_cksum(b"") == 4294967295
    assert legacy_bash.posix_cksum(b"opencode-proj") == 2856696754
    assert legacy_bash.sandbox_key("a/b") == f"a_b.{legacy_bash.posix_cksum(b'a/b')}"


def test_env_parse_first_key_wins_and_workspace_needs_host_source(tree):
    _bash_file("box", ".env", "agent=shell\nagent=opencode\nworkspace=/w\nnoequals\n")
    assert legacy_bash.provenance_field("msb", "box", "agent") == "shell"
    assert legacy_bash.workspace_record_read("msb", "box") is None
    _bash_file("box", ".env", "workspace_source=host\nworkspace=/w\n")
    assert legacy_bash.workspace_record_read("msb", "box") == "/w"


def test_unsafe_fields_are_dropped(tree):
    _bash_file("box", ".env", "agent=Bad;x\nworkspace_source=host\nworkspace=relative/dir\n"
               "applied_ref=a b\napplied_at=yesterday\n")
    config_dir = legacy_bash.host_config_dir("msb", "box")
    config_dir.mkdir()
    (config_dir / "ssh-auth-sock").write_text("/home/agent/x;rm -rf ~", encoding="utf-8")
    (config_dir / "ro-host-config").write_text("yes", encoding="utf-8")
    sandbox = legacy_bash.read_sandbox("msb", "box")
    assert (sandbox.agent, sandbox.workspace, sandbox.ssh_auth_sock) == (None, None, None)
    assert (sandbox.applied_ref, sandbox.applied_at, sandbox.ro_host_config) == (None, None, False)
    assert legacy_bash.host_config_read("msb", "box", "../escape") is None


def test_applied_at_accepts_ascii_digits_only(tree):
    # Bash writes applied_at with `date -u`, so only ASCII digits are its form;
    # Python's \d would also accept another script's digits (Arabic-Indic here).
    _bash_file("box", ".env", "applied_at=2026-11-09T01:02:03Z\n")
    assert legacy_bash.read_sandbox("msb", "box").applied_at == "2026-11-09T01:02:03Z"
    _bash_file("box", ".env", "applied_at=٢٠٢٦-11-09T01:02:03Z\n")
    assert legacy_bash.read_sandbox("msb", "box").applied_at is None


def test_agent_falls_back_to_the_host_config_key(tree):
    config_dir = legacy_bash.host_config_dir("msb", "box")
    config_dir.mkdir(parents=True)
    (config_dir / "agent").write_text("claude\n", encoding="utf-8")
    assert legacy_bash.read_sandbox("msb", "box").agent == "claude"


def test_names_that_sanitizing_changed_are_skipped(tree):
    _bash_file("a/b", ".env", "agent=shell\n")  # stored as a_b.<cksum of 'a/b'>
    _bash_file("good", ".kits", "schema=1\n")
    (legacy_bash._backend_dir("msb") / "stray.txt").write_text("x", encoding="utf-8")
    (legacy_bash._backend_dir("msb") / "box.123.env").write_text("agent=shell\n", encoding="utf-8")
    assert legacy_bash.sandbox_names("msb") == ["good"]
    assert legacy_bash.sandbox_names("sbx") == []


def test_cli_kits_relative_refs_are_skipped(tree):
    _bash_file("box", ".kits", "schema=1\nkit=rel/kit\nextra=git+https://h/o/r.git\nkit=/abs\nkit=\n")
    warnings: list[str] = []
    assert legacy_bash.read_cli_kits("msb", "box", warnings.append) == (["/abs"], ["git+https://h/o/r.git"])
    assert warnings and "rel/kit" in warnings[0]
    assert legacy_bash.read_cli_kits("msb", "absent") is None
    # A recorded value that is not a plain path is not quoted back.
    _bash_file("box", ".kits", f"schema=1\nkit=bob:{KEY}@host/kit\n")
    warnings.clear()
    assert legacy_bash.read_cli_kits("msb", "box", warnings.append) == ([], [])
    assert warnings and "<redacted>" in warnings[0] and "S3NTINEL" not in warnings[0]


def test_cli_kits_refs_refused_at_input_are_skipped_without_naming_them(tree):
    sha = "0" * 40
    _bash_file("box", ".kits", f"schema=1\nkit=git+https://h/o/r.git?private_token={KEY}#ref={sha}&dir=k\n"
                               f"extra=git+https://h/o/r.git#ref={sha}&dir=k&token={KEY}\n"
                               f"kit=git+https://h/o/r.git#ref={sha}&dir=k\n")
    warnings: list[str] = []
    assert legacy_bash.read_cli_kits("msb", "box", warnings.append) == ([f"git+https://h/o/r.git#ref={sha}&dir=k"], [])
    assert len(warnings) == 2
    assert all("acq now refuses" in w and "recreate the sandbox" in w for w in warnings)
    assert all("S3NTINEL" not in w and "h/o/r" not in w for w in warnings)


def test_config_key_readers(tree):
    _config("kit_sources: none\nextra_kits: paseo openchamber\n")
    assert legacy_bash.kit_sources() == []
    assert legacy_bash.extra_kits() == ["paseo", "openchamber"]
    assert legacy_bash.provider_kit() is None
    assert legacy_bash.provider_credential_bindings() == []


def test_import_sbx_sandbox_from_hand_written_record(tree, capsys):
    _bash_file("shell-ws", ".env", "schema=1\nbackend=sbx\nagent=shell\napplied_ref=abc\n", backend="sbx")
    legacy_bash.host_config_dir("sbx", "half-made").mkdir(parents=True)

    migration.migrate_tree()

    record = state.record_read("sbx", "shell-ws")
    assert record is not None
    assert (record["agent"], record["workspace"], record["imported_from"]) == ("shell", None, "bash")
    assert "ro_host_config" not in record and "ssh_auth_sock" not in record
    assert kits.provenance_status("sbx", "shell-ws") == "stale"
    assert state.record_read("sbx", "half-made") is None  # a create that never finished
    assert "imported 1 sandbox record(s)" in capsys.readouterr().err


def test_bad_config_lists_wait_at_generation_1_until_fixed(tree, capsys):
    _bash_file("box", ".env", "agent=shell\n")
    _config(f"kit_sources: github.com/acme/kits@{SHA} notarepo\n"
            "provider_credential_bindings: good=GOOD_KEY bad\n")

    for run in range(3):  # every mutating run retries; nothing is dropped for good
        migration.migrate_tree()
        assert kits.list_source_records() == []
        assert provider_creds.get_binding("good") is None
        assert migration.read_generation() == migration.RECORDS_GENERATION
        err = capsys.readouterr().err
        if run == 0:
            assert "kit_sources was not imported" in err
            assert "provider_credential_bindings was not imported" in err
        else:  # the same pending warnings are not printed on every command
            assert "was not imported" not in err
    # The sandbox part completed on the first run and is not run again.
    assert migration.read_import_done() == {"sandboxes"}
    state.record_remove("msb", "box")

    # A change to what is pending warns again, once.
    _config(f"kit_sources: github.com/acme/kits@{SHA} notarepo\nprovider_credential_bindings: good=GOOD_KEY\n")
    migration.migrate_tree()
    err = capsys.readouterr().err
    assert "kit_sources was not imported" in err and "provider_credential_bindings" not in err
    assert provider_creds.get_binding("good")["key_env"] == "GOOD_KEY"
    migration.migrate_tree()
    assert "was not imported" not in capsys.readouterr().err
    assert migration.read_generation() == migration.RECORDS_GENERATION

    _config(f"kit_sources: github.com/acme/kits@{SHA}\nprovider_credential_bindings: good=GOOD_KEY\n")
    migration.migrate_tree()

    assert [r["repository"] for r in kits.list_source_records()] == ["github.com/acme/kits"]
    assert provider_creds.get_binding("good")["key_env"] == "GOOD_KEY"
    assert state.record_read("msb", "box") is None  # removed after its import: stays removed
    assert migration.read_generation() == migration.TARGET_GENERATION
    assert migration.read_import_done() == set()
    assert "was not imported" not in capsys.readouterr().err


def test_doctor_reports_a_pending_import_after_its_warning_stops_printing(tree, capsys):
    from acq_py import doctor

    assert doctor.bash_import_check()["status"] == "pass"  # nothing has run yet
    _bash_file("box", ".env", "agent=shell\n")
    _config(f"kit_sources: github.com/acme/kits@{SHA} notarepo\nprovider_credential_bindings: good=GOOD_KEY\n")
    migration.migrate_tree()
    assert "kit_sources was not imported" in capsys.readouterr().err
    migration.migrate_tree()
    assert "was not imported" not in capsys.readouterr().err  # printed once only

    check = doctor.bash_import_check()
    assert check["status"] == "warn", check
    assert "kit_sources pending" in check["message"]
    assert "sandboxes" not in check["message"].split("(", 1)[1].split(")", 1)[0]  # that part is done
    assert "kit_sources was not imported" in check["message"]
    assert "mutating acq command" in check["remediation"]
    assert doctor.overall_status(doctor.doctor_checks()) != "pass"

    _config(f"kit_sources: github.com/acme/kits@{SHA}\nprovider_credential_bindings: good=GOOD_KEY\n")
    migration.migrate_tree()
    assert doctor.bash_import_check()["status"] == "pass"
    assert migration.read_import_warnings() == []


@pytest.mark.parametrize("entry", [
    f"https://bob:S3NTINEL-tok-1@github.com/acme/kits@{SHA}",
    f"bob:S3NTINEL-tok-1@github.com/acme/kits@{SHA}",
])
def test_a_credential_in_a_bash_kit_source_never_reaches_output_marker_or_doctor(tree, capsys, entry):
    from acq_py import cli, doctor

    _config(f"kit_sources: {entry}\n")
    migration.migrate_tree()
    err = capsys.readouterr().err
    assert "kit_sources was not imported" in err and "entry 1" in err and "<redacted>" in err
    assert "S3NTINEL-tok-1" not in err
    assert "S3NTINEL-tok-1" not in migration.generation_path().read_text(encoding="utf-8")
    assert "S3NTINEL-tok-1" not in json.dumps(doctor.bash_import_check())
    assert cli.main(["doctor", "--json"]) == 0
    out, err = capsys.readouterr()
    assert "kit_sources was not imported" in out
    assert "S3NTINEL-tok-1" not in out + err


KEY = "sk-S3NTINEL-pasted-key-9f2c"


@pytest.mark.parametrize(("bindings", "phrase"), [
    (f"opencode-go={KEY}", "invalid KEY_ENV <redacted> for provider 'opencode-go'"),  # key where the name goes
    (f"opencode-go=OPENCODE_GO_API_KEY=x{KEY}", "has a malformed credential name <redacted>"),
    (KEY, "expected '<providerId>=<KEY_ENV>', got <redacted>"),  # the key on its own
    (f"{KEY}=OPENCODE_GO_API_KEY", "invalid provider id <redacted>"),
    (f"opencode-go=OPENCODE_GO_API_KEY@{KEY}.example", "invalid host <redacted> for provider 'opencode-go'"),
    (f"good=GOOD_KEY opencode-go={KEY}", "entry 2: invalid KEY_ENV <redacted>"),
])
def test_a_key_pasted_into_a_bash_binding_never_reaches_output_marker_or_doctor(tree, capsys, bindings, phrase):
    from acq_py import cli, doctor

    _config(f"provider_credential_bindings: {bindings}\n")
    migration.migrate_tree()
    err = capsys.readouterr().err
    assert "provider_credential_bindings was not imported" in err and phrase in err, err
    assert KEY not in err and "S3NTINEL" not in err
    assert "S3NTINEL" not in migration.generation_path().read_text(encoding="utf-8")
    assert "S3NTINEL" not in json.dumps(doctor.bash_import_check())
    assert cli.main(["doctor", "--json"]) == 0
    out, err = capsys.readouterr()
    assert "provider_credential_bindings was not imported" in out
    assert "S3NTINEL" not in out + err


def test_a_well_formed_but_refused_binding_still_names_its_parts(tree, capsys):
    # A provider claiming another service's env var: both parts have their
    # shape, so the warning can say which ones conflict.
    _config("provider_credential_bindings: acme=GITHUB_TOKEN@models.acme.example\n")
    migration.migrate_tree()
    err = capsys.readouterr().err
    assert "'GITHUB_TOKEN'" in err and "'acme'" in err and "<redacted>" not in err


@pytest.mark.parametrize("ref", ["ghp_S3NTINELtoken0123456789abcdef", "github_pat_S3NTINEL_x",
                                 "glpat-S3NTINEL", "sk-S3NTINEL", "xoxb-S3NTINEL", "S3NTINEL" + "x" * 40])
def test_a_token_shaped_kit_source_ref_never_reaches_output_marker_or_doctor(tree, capsys, ref):
    from acq_py import cli, doctor

    # The bad binding keeps the import pending, so its warnings are kept and doctor shows them.
    _config(f"kit_sources: github.com/acme/kits@{ref}\nprovider_credential_bindings: bad\n")
    migration.migrate_tree()
    err = capsys.readouterr().err
    assert "kit source 'github.com/acme/kits' was not imported: ref <redacted>" in err, err
    assert "S3NTINEL" not in err
    assert "S3NTINEL" not in migration.generation_path().read_text(encoding="utf-8")
    check = doctor.bash_import_check()
    assert "ref <redacted>" in check["message"] and "S3NTINEL" not in json.dumps(check)
    assert cli.main(["doctor", "--json"]) == 0
    out, err = capsys.readouterr()
    assert "S3NTINEL" not in out + err


def test_a_branch_or_short_sha_kit_source_ref_is_still_named(tree, capsys):
    _config("kit_sources: github.com/acme/kits@main github.com/acme/other@0123abc\n")
    migration.migrate_tree()
    err = capsys.readouterr().err
    assert "ref 'main' is not a full commit SHA" in err and "ref '0123abc'" in err


def test_a_token_in_a_bash_kit_source_without_url_form_is_not_quoted(tree, capsys):
    _config(f"kit_sources: github.com/acme/kits@{SHA} {KEY}\n")
    migration.migrate_tree()
    err = capsys.readouterr().err
    assert "entry 2: invalid kit source <redacted>" in err and "S3NTINEL" not in err


def test_an_old_marker_holding_a_credential_is_redacted_when_read(tree):
    from acq_py import doctor

    migration.write_generation(migration.RECORDS_GENERATION, import_done={"sandboxes"}, import_warned="0" * 64)
    doc = json.loads(migration.generation_path().read_text(encoding="utf-8"))
    doc["bash_import_warnings"] = [f"config.yaml kit_sources was not imported: invalid kit source "
                                   f"'https://bob:S3NTINEL-tok-2@github.com/acme/kits@{SHA}'"]
    migration.generation_path().write_text(json.dumps(doc), encoding="utf-8")
    check = doctor.bash_import_check()
    assert "S3NTINEL-tok-2" not in json.dumps(check) and "https://***@github.com" in check["message"]


@pytest.mark.parametrize(("text", "shown"), [
    ("https://u:p@host/r", "https://***@host/r"),
    ("'u:p@host/r@sha'", "'***@host/r@sha'"),
    ("github.com/acme/kits@sha", "github.com/acme/kits@sha"),  # a ref, not userinfo
    ("https://host/r?token=x", "https://host/r?***"),
    ("is the path right?", "is the path right?"),
])
def test_redact_hides_url_credentials_only(text, shown):
    assert legacy_bash.redact(text) == shown


def test_a_marker_from_before_the_warning_text_was_kept_gets_it_without_a_reprint(tree, capsys):
    from acq_py import doctor

    _config(f"kit_sources: github.com/acme/kits@{SHA} notarepo\n")
    migration.migrate_tree()
    capsys.readouterr()
    # As an older acq left it: the digest of the warnings, not their text.
    migration.write_generation(migration.RECORDS_GENERATION, import_done=migration.read_import_done(),
                               import_warned=migration.read_import_warned())
    assert migration.read_import_warnings() == []
    migration.migrate_tree()
    assert "was not imported" not in capsys.readouterr().err
    assert "kit_sources was not imported" in doctor.bash_import_check()["message"]


def test_mutable_empty_refs_and_the_control_plane_are_not_imported(tree, capsys):
    _config("kit_sources: github.com/acme/kits@main github.com/GSA-TTS/agentic-coding-patterns "
            f"github.com/acme/unpinned github.com/acme/pinned@{SHA}\n")
    migration.migrate_tree()
    assert [r["repository"] for r in kits.list_source_records()] == ["github.com/acme/pinned"]
    err = capsys.readouterr().err
    assert "'github.com/acme/kits' was not imported: ref 'main'" in err
    assert "'github.com/acme/unpinned' was not imported: ref ''" in err
    assert migration.read_generation() == migration.TARGET_GENERATION


def test_ro_host_config_with_trailing_newline_is_required(tree):
    _bash_file("box", ".env", "agent=shell\n")
    config_dir = legacy_bash.host_config_dir("msb", "box")
    config_dir.mkdir()
    (config_dir / "ro-host-config").write_bytes(b"1\n\n")
    assert legacy_bash.read_sandbox("msb", "box").ro_host_config is True
    (config_dir / "ro-host-config").write_bytes(b"1\r\n")
    assert legacy_bash.read_sandbox("msb", "box").ro_host_config is False  # as Bash compares it


def test_duplicate_provider_ids_keep_the_last_entry(tree):
    _config("provider_credential_bindings: a=FIRST_KEY@one.example b=B_KEY a=LAST_KEY@two.example\n")
    assert legacy_bash.provider_credential_bindings() == [
        ("a", "LAST_KEY", ["two.example"]), ("b", "B_KEY", []),
    ]
    migration.migrate_tree()
    binding = provider_creds.get_binding("a")
    assert (binding["key_env"], binding["hosts"]) == ("LAST_KEY", ["two.example"])


def test_parse_env_splits_lines_like_awk():
    assert legacy_bash.parse_env("agent=sh\x1cworkspace=/x\nworkspace_source=host\r\n") == {
        "agent": "sh\x1cworkspace=/x", "workspace_source": "host\r",
    }


def test_provenance_is_retried_after_a_crash_between_record_and_provenance(tree, monkeypatch):
    _bash_file("box", ".env", f"agent=shell\napplied_ref={kits.CONTROL_PLANE_REF}\n")

    def crash(*args, **kwargs):
        raise OSError("simulated crash")

    with monkeypatch.context() as m:
        m.setattr(kits, "provenance_import", crash)
        with pytest.raises(migration.MigrationError):
            migration.migrate_tree()
    assert state.record_read("msb", "box")["imported_from"] == "bash"
    assert kits.provenance_read("msb", "box") is None
    assert migration.read_generation() == migration.RECORDS_GENERATION

    migration.migrate_tree()

    assert kits.provenance_status("msb", "box") == "current"
    assert migration.read_generation() == migration.TARGET_GENERATION


def test_the_bash_provider_selection_is_imported(tree):
    # As Bash acq_provenance_write wrote them: an explicit empty selection
    # (--no-provider-kits) omits provider_kits; a list is kept verbatim.
    _bash_file("none", ".env", f"agent=shell\napplied_ref={kits.CONTROL_PLANE_REF}\nprovider_selection=explicit\n")
    _bash_file("list", ".env", "agent=shell\nprovider_selection=explicit\nprovider_kits=/k/a /k/b\n")
    _bash_file("dflt", ".env", "agent=shell\nprovider_selection=default\nprovider_kits=ignored\n")
    _bash_file("bad", ".env", f"agent=shell\napplied_ref={kits.CONTROL_PLANE_REF}\nprovider_selection=all\n")
    migration.migrate_tree()
    assert kits.provider_selection_read("msb", "none") == ("explicit", "")
    assert kits.provenance_status("msb", "none") == "current"
    assert kits.provider_selection_read("msb", "list") == ("explicit", "/k/a /k/b")
    assert kits.provenance_status("msb", "list") == "unknown"  # Bash recorded no bundle ref
    assert kits.provider_selection_read("msb", "dflt") == ("default", "")
    # A value Bash never writes is carried over, so it is refused as Bash
    # acq_provider_selection_load refuses it, instead of reading as "nothing
    # recorded" and applying the current selection.
    assert kits.provenance_status("msb", "bad") == "current"
    with pytest.raises(kits.ProviderSelectionError):
        kits.provider_selection_read("msb", "bad")


@needs_bash
@pytest.mark.parametrize("mode, accepted", [("default", True), ("explicit", True), ("", True), ("all", False)])
def test_bash_refuses_the_selection_values_the_import_refuses(tree, mode, accepted):
    # The oracle: Bash acq_provider_selection_load on the same record.
    _bash_file("box", ".env", f"agent=shell\nprovider_selection={mode}\n")
    assert BASH is not None
    proc = subprocess.run(
        [BASH, "-c", 'source "$1"; acq_provider_selection_load msb box', "bash", str(COMMON_SH)],
        capture_output=True, timeout=60, env={**os.environ, "LC_ALL": "C"}, check=False,
    )
    assert (proc.returncode == 0) is accepted
    migration.migrate_tree()
    if accepted:
        kits.provider_selection_read("msb", "box")
    else:
        with pytest.raises(kits.ProviderSelectionError):
            kits.provider_selection_read("msb", "box")


@pytest.mark.skipif(os.name != "posix" or (hasattr(os, "geteuid") and os.geteuid() == 0),
                    reason="needs POSIX permissions and a non-root user")
def test_an_unreadable_bash_backend_directory_keeps_the_sandbox_import_pending(tree, capsys):
    _bash_file("box", ".env", "agent=shell\nworkspace_source=host\nworkspace=/w/box\n")
    directory = legacy_bash._backend_dir("msb")
    directory.chmod(0o000)
    try:
        with pytest.raises(PermissionError):
            legacy_bash.sandbox_names("msb")
        migration.migrate_tree()
        assert "sandboxes" not in migration.read_import_done()
        assert migration.read_generation() == migration.RECORDS_GENERATION
        assert "msb sandbox records were not imported" in capsys.readouterr().err
    finally:
        directory.chmod(0o755)
    migration.migrate_tree()  # readable again: imported now
    assert state.record_read("msb", "box")["imported_from"] == "bash"
    assert migration.read_generation() == migration.TARGET_GENERATION


@pytest.mark.skipif(os.name != "posix" or (hasattr(os, "geteuid") and os.geteuid() == 0),
                    reason="needs POSIX permissions and a non-root user")
def test_a_pending_backend_never_brings_back_a_record_removed_from_one_that_imported(tree, capsys):
    _bash_file("gone", ".env", "agent=shell\nworkspace_source=host\nworkspace=/w/gone\n", backend="sbx")
    _bash_file("box", ".env", "agent=shell\nworkspace_source=host\nworkspace=/w/box\n")
    directory = legacy_bash._backend_dir("msb")
    directory.chmod(0o000)
    try:
        migration.migrate_tree()
        assert state.record_read("sbx", "gone") is not None
        assert "sandboxes:sbx" in migration.read_import_done()
        state.record_path("sbx", "gone").unlink()  # what 'acq rm gone' does to the record
        migration.migrate_tree()  # msb still unreadable: the part stays pending
        assert state.record_read("sbx", "gone") is None
        assert "sandboxes" not in migration.read_import_done()
    finally:
        directory.chmod(0o755)
    capsys.readouterr()
    migration.migrate_tree()
    assert state.record_read("msb", "box")["imported_from"] == "bash"
    assert state.record_read("sbx", "gone") is None
    assert migration.read_generation() == migration.TARGET_GENERATION


def test_fresh_tree_without_bash_state_is_quiet(tree, capsys):
    migration.migrate_tree()
    assert migration.read_generation() == migration.TARGET_GENERATION
    assert capsys.readouterr().err == ""
    assert not (tree / "state" / "msb").exists()


def test_atomic_create_never_replaces(tree):
    path = tree / "state" / "x.json"
    assert state.atomic_create_text(path, "one\n") is True
    assert state.atomic_create_text(path, "two\n") is False
    assert path.read_text(encoding="utf-8") == "one\n"
    assert [p.name for p in path.parent.iterdir()] == ["x.json"]  # no temp file left


def test_atomic_create_without_hard_links(tree, monkeypatch):
    def no_link(src, dst):
        raise OSError("hard links not supported")

    monkeypatch.setattr(state.os, "link", no_link)
    path = tree / "state" / "y.json"
    assert state.atomic_create_text(path, "one\n") is True
    assert state.atomic_create_text(path, "two\n") is False
    assert path.read_text(encoding="utf-8") == "one\n"


def test_import_binding_validates(tree):
    with pytest.raises(ValueError):
        provider_creds.import_binding("Bad", "KEY", [])
    assert provider_creds.import_binding("ok", "OK_KEY", ["h.example"]) is True
    assert provider_creds.import_binding("ok", "OTHER_KEY", []) is False
    assert json.loads(provider_creds._binding_path("ok").read_text(encoding="utf-8"))["key_env"] == "OK_KEY"


def test_relative_provenance_dir_fails_the_migration_closed(tree, monkeypatch):
    monkeypatch.setenv("ACQ_PROVENANCE_DIR", "relative/dir")
    with pytest.raises(migration.MigrationError) as info:
        migration.migrate_tree()
    assert info.value.code == "migration_failed"
    assert migration.read_generation() == migration.RECORDS_GENERATION
