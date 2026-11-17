"""Uninstall dispatch never migrates state or invokes a real cleanup engine."""

from pathlib import Path
from types import SimpleNamespace

from acq_py import cli
from acq_py.commands import uninstall


def test_catalog_and_help(capsys):
    assert "uninstall" in cli.KNOWN_COMMANDS
    parser = cli.build_parser()
    parsed = parser.parse_args(["uninstall", "--dry-run", "--yes"])
    assert parsed.dry_run and parsed.yes


def test_dispatch_precedes_migration_and_backend(monkeypatch, tmp_path):
    script = tmp_path / "uninstall.command"
    script.write_text("fixture only")
    monkeypatch.setattr(uninstall, "recovery_script", lambda: script)
    monkeypatch.setattr(uninstall.hostexec, "command", lambda name: ["/fixture/bash"])
    seen = []
    monkeypatch.setattr(uninstall.subprocess, "run", lambda args, **kw: seen.append(args) or SimpleNamespace(returncode=0))
    monkeypatch.setattr(cli, "_migration_pre_step", lambda *a: (_ for _ in ()).throw(AssertionError("migration")))
    monkeypatch.setattr(cli, "_user_dirs_pre_step", lambda *a: (_ for _ in ()).throw(AssertionError("user dirs")))
    assert cli.main(["uninstall", "--dry-run", "--confirm-no-sbx-sandboxes"]) == 0
    assert seen == [["/fixture/bash", str(script), "--dry-run", "--confirm-no-sbx-sandboxes"]]


def test_json_and_backend_flags_refused_without_cleanup(monkeypatch):
    monkeypatch.setattr(uninstall, "recovery_script", lambda: (_ for _ in ()).throw(AssertionError("cleanup")))
    assert cli.main(["--json", "uninstall"]) == 2
    assert cli.main(["--backend", "msb", "uninstall"]) == 2


def test_missing_script_fails_closed(monkeypatch, tmp_path):
    monkeypatch.setattr(uninstall, "recovery_script", lambda: tmp_path / "missing")
    assert cli.main(["uninstall"]) == 1


def test_source_checkout_path_exists():
    assert uninstall.recovery_script().name == "run-uninstaller"
    assert uninstall.recovery_script().is_file()


def test_exit_status_is_preserved(monkeypatch, tmp_path):
    script = tmp_path / "uninstall.command"
    script.write_text("fixture")
    monkeypatch.setattr(uninstall, "recovery_script", lambda: script)
    monkeypatch.setattr(uninstall.hostexec, "command", lambda _: ["/fixture/bash"])
    monkeypatch.setattr(uninstall.subprocess, "run", lambda *a, **k: SimpleNamespace(returncode=1))
    assert cli.main(["uninstall", "--yes"]) == 1
