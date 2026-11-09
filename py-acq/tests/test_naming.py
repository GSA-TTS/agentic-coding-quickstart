"""Sandbox naming and workspace-path checks, and their parity with the Bash acq.

The Python checks mirror Bash's ``slugify``, ``derive_name``,
``acq_sandbox_name_check`` (an explicit ``--name``), ``acq_name_form_check``
(a name given to a verb that acts on an existing sandbox) and
``_acq_workspace_path_safe`` (``:`` and control characters in a workspace).
The parity tests source the real ``acq.backends/common.sh`` in a Bash child and
run each function over the same corpus as the Python implementation.

The parity tests run on POSIX only: on Windows the native Python acq accepts a
drive designator (``C:\\...``) that Git Bash refuses with a ``/c/...`` hint, by
design, and the drive rule is covered by the unit tests with the ``WINDOWS``
seam instead.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

from acq_py import cli, errors
from acq_py.commands import common

REPO_ROOT = Path(__file__).resolve().parents[2]
COMMON_SH = REPO_ROOT / "acq.backends" / "common.sh"
BASH = shutil.which("bash")
POSIX = sys.platform != "win32"

needs_bash = pytest.mark.skipif(not POSIX or BASH is None, reason="Bash parity runs on POSIX with bash")
posix_only = pytest.mark.skipif(not POSIX, reason="POSIX paths and symlinks")

# Names: valid ones, the charset edges, Unicode (including letters whose
# Unicode lowercase is ASCII), path forms and ASCII control characters.
NAME_CORPUS = [
    "box", "My_Box-2", "a", "_", "-", "-x", "x-", "", ".", "..", "...", ".hidden",
    "a.b", "a b", "a/b", "../x", "a\\b", "C:", "box:1", "odd.name:1", "a@b",
    "caf\u00e9", "\u0130stanbul", "\u212aelvin", "\uff21", "\u00df",
    "x\ny", "x\ty", "x\ry", "x\x1b]0;t\x07", "x\x7f", "\x01",
]

# Workspace paths for the colon/control-character check.
PATH_CORPUS = [
    "/srv/proj", "/srv/My Proj", "/srv/caf\u00e9", "/srv/\u0130", "/", ".", "..",
    "/srv/a:b", "/srv/proj:ro", "C:/Users/me", "C:\\Users\\me", ":", "/srv/a\\b",
    "/srv/x\ny", "/srv/x\ty", "/srv/x\x1b[31m", "/srv/x\x7f", "/srv/x\x01:y",
]

# Paths for derive_name, relative ones resolved from a symlinked cwd.
DERIVE_CORPUS = [
    "/", "//", ".", "./", "..", "../..", "foo", "foo/", "foo/.", "foo/..",
    "foo/../..", "x/../../y", "/srv/a/b/..", "/srv/a/b/.", "/srv/a/b/", "/..",
    "/srv/My_App", "Caf\u00e9", "\u0130stanbul", "\u212aelvin", "a b",
    "new\nline", "tab\tx", "\\", "foo\\", "/srv/\u00df\u00df",
]

# Characters Bash's [[:cntrl:]] matches only in a UTF-8 locale.
UNICODE_CONTROLS = ["x\u0085y", "x\u009by", "x\u2028y", "x\u2029y"]


def _bash_map(body: str, items: list[str], cwd: Path | None = None, env: dict | None = None) -> list[str]:
    """Run ``body`` once per item (bound to ``$x``) with common.sh sourced.

    Items travel NUL-separated on stdin and results come back NUL-separated, so
    newlines and other control characters survive in both directions.
    """
    script = (
        f'. "{COMMON_SH}" >/dev/null 2>&1\n'
        'while IFS= read -r -d "" x; do\n'
        f"{body}\n"
        'printf "\\0"\n'
        "done\n"
    )
    full_env = {**os.environ, "LC_ALL": "C.UTF-8", **(env or {})}
    data = b"".join(item.encode("utf-8") + b"\0" for item in items)
    proc = subprocess.run(
        [BASH, "-c", script], input=data, capture_output=True, cwd=cwd, env=full_env, check=True, timeout=60
    )
    out = proc.stdout.decode("utf-8", "surrogateescape").split("\0")
    assert out[-1] == "", proc.stderr
    return out[:-1]


def _unicode_controls_for_bash() -> list[str]:
    """UNICODE_CONTROLS when the child Bash's locale classifies them as control
    characters (glibc's C.UTF-8 does), else nothing: outside a UTF-8 locale Bash
    matches only ASCII controls, and Python stays the stricter of the two."""
    probe = _bash_map('case "$x" in *[[:cntrl:]]*) printf y ;; *) printf n ;; esac', UNICODE_CONTROLS)
    return UNICODE_CONTROLS if probe == ["y"] * len(UNICODE_CONTROLS) else []


# The first line of a check's message, or "ok" when it passes.
_CHECK = 'if m=$({call} 2>&1); then printf ok; else printf "%s" "${{m%%$\'\\n\'*}}"; fi'


def _first_line(capsys, rc: int | None) -> str:
    err = capsys.readouterr().err
    return "ok" if rc is None else err.splitlines()[0]


def _bash_first_line(line: str) -> str:
    # Bash prefixes its refusals with "acq: error: "; Python's envelope prose is "acq: ".
    return line.replace("acq: error: ", "acq: ", 1)


# ---------------------------------------------------------------------------
# Parity with the Bash functions.
# ---------------------------------------------------------------------------

@needs_bash
def test_slugify_matches_bash():
    corpus = NAME_CORPUS + DERIVE_CORPUS + ["\u0130", "\u212a", "A\u0130B", "x\u0130\u0130y"]
    assert [common._slugify(x) for x in corpus] == _bash_map('printf "%s" "$(slugify "$x")"', corpus)


@needs_bash
def test_printable_matches_bash():
    corpus = NAME_CORPUS + PATH_CORPUS
    assert [common._printable(x) for x in corpus] == _bash_map('acq_printable "$x"', corpus)


@needs_bash
def test_new_sandbox_name_check_matches_bash(capsys):
    bash = _bash_map(_CHECK.format(call='acq_sandbox_name_check "$x"'), NAME_CORPUS)
    python = [_first_line(capsys, common._new_sandbox_name_failure("create", x, False)) for x in NAME_CORPUS]
    assert python == [_bash_first_line(line) for line in bash]


@needs_bash
def test_name_form_check_matches_bash(capsys):
    corpus = NAME_CORPUS + _unicode_controls_for_bash()
    bash = _bash_map(_CHECK.format(call='acq_name_form_check rm "$x"'), corpus)
    python = [_first_line(capsys, common._name_form_failure("rm", x, False)) for x in corpus]
    assert python == bash


@needs_bash
def test_workspace_path_check_matches_bash(capsys):
    corpus = PATH_CORPUS + _unicode_controls_for_bash()
    bash = _bash_map(_CHECK.format(call='_acq_workspace_path_safe "$x" "$x"'), corpus)
    python = [_first_line(capsys, common._workspace_unsafe("create", x, x, False)) for x in corpus]
    assert python == [_bash_first_line(line) for line in bash]


@needs_bash
def test_derive_name_matches_bash(monkeypatch, tmp_path):
    """Relative paths resolve from a cwd reached through a symlink: ``.`` names
    the logical directory, ``..`` the physical parent, in both implementations."""
    real = tmp_path / "Real Dir" / "proj"
    real.mkdir(parents=True)
    (tmp_path / "lnk").symlink_to(tmp_path / "Real Dir", target_is_directory=True)
    logical = str(tmp_path / "lnk" / "proj")
    monkeypatch.chdir(real)
    monkeypatch.setenv("PWD", logical)
    python = [common._derive_name("opencode", common._logical_abspath(x)) for x in DERIVE_CORPUS]
    bash = _bash_map('printf "%s" "$(derive_name opencode "$x")"', DERIVE_CORPUS, cwd=real, env={"PWD": logical})
    assert python == bash
    assert python[:5] == [
        "opencode-workspace", "opencode-workspace", "opencode-proj", "opencode-proj", "opencode-real-dir"
    ]


def test_unicode_controls_are_refused_in_names_and_paths(capsys):
    for text in UNICODE_CONTROLS:
        assert common._name_form_failure("rm", text, False) == errors.EXIT_FAILURE
        assert common._workspace_unsafe("create", "/srv/" + text, "/srv/" + text, False) == errors.EXIT_FAILURE
    assert "?" in capsys.readouterr().err


# ---------------------------------------------------------------------------
# slugify / derive_name.
# ---------------------------------------------------------------------------

def test_slugify_lowers_only_ascii():
    # str.lower() maps U+0130 to "i" + U+0307 and U+212A (KELVIN SIGN) to "k".
    assert common._slugify("\u0130stanbul") == "stanbul"
    assert common._slugify("\u212aelvin") == "elvin"
    assert common._slugify("A\u0130B") == "a-b"


@posix_only
def test_derive_name_keeps_a_trailing_backslash_on_posix():
    assert common._derive_name("opencode", "/srv/proj/\\") == "opencode-"
    assert common._derive_name("opencode", "/") == "opencode-workspace"


# ---------------------------------------------------------------------------
# Workspace paths.
# ---------------------------------------------------------------------------

def test_colon_scope_on_windows_skips_only_the_drive_designator(monkeypatch):
    monkeypatch.setattr(common, "WINDOWS", True)
    assert common._colon_scope("C:\\Users\\me") == "\\Users\\me"
    assert common._colon_scope("c:/Users/me") == "/Users/me"
    assert common._colon_scope("\\\\?\\C:\\long\\path") == "\\long\\path"
    assert common._colon_scope("\\\\.\\C:\\dev\\path") == "\\dev\\path"
    assert common._colon_scope("//./c:/dev/path") == "/dev/path"
    assert ":" in common._colon_scope("\\\\.\\C:\\a:b")
    assert ":" in common._colon_scope("C:\\a:b")
    assert common._colon_scope("\\\\srv\\share\\p") == "\\\\srv\\share\\p"
    assert common._colon_scope("\\\\srv\\sh:are\\p").count(":") == 1


def test_colon_scope_on_posix_is_the_whole_path(monkeypatch):
    monkeypatch.setattr(common, "WINDOWS", False)
    assert common._colon_scope("C:/Users/me") == "C:/Users/me"


def test_windows_drive_paths_pass_and_other_colons_fail(monkeypatch, capsys):
    monkeypatch.setattr(common, "WINDOWS", True)
    assert common._workspace_unsafe("create", "C:\\Users\\me\\proj", "x", False) is None
    assert common._workspace_unsafe("create", "\\\\?\\C:\\Users\\me", "x", False) is None
    assert common._workspace_unsafe("create", "\\\\.\\C:\\Users\\me", "x", False) is None
    assert common._workspace_unsafe("create", "C:\\Users\\me\\a:b", "C:\\Users\\me\\a:b", False) == 1
    assert "workspace path contains ':'" in capsys.readouterr().err


def _msb_env(monkeypatch, tmp_path):
    monkeypatch.setenv("ACQ_MSB_BIN", "__stub__")
    monkeypatch.setenv("ACQ_MSB_VERSION", "0.7.7")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "1")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "0")
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("MSB_HOME", str(tmp_path / "msb-home"))


def _invoke_json(capsys, *argv: str) -> tuple[int, dict]:
    rc = cli.main(["--json", *argv])
    out = capsys.readouterr().out.strip()
    return rc, json.loads(out.splitlines()[-1])


def _assert_refused(rc: int, doc: dict, text: str) -> None:
    assert rc == errors.EXIT_FAILURE
    assert doc["error"]["code"] == errors.VALIDATION_FAILED
    assert text in doc["error"]["message"]


@pytest.mark.parametrize("path", ["/no/such:dir", "rel:ro", "x\nboth:y"])
def test_create_refuses_a_workspace_path_with_a_colon_or_control(monkeypatch, tmp_path, capsys, path):
    _msb_env(monkeypatch, tmp_path)
    rc, doc = _invoke_json(capsys, "--backend", "msb", "create", "opencode", path, "--name", "box")
    expected = "control character" if "\n" in path else "contains ':'"
    _assert_refused(rc, doc, expected)
    assert "\n" not in doc["error"]["message"]


@pytest.mark.skipif(POSIX, reason="native Windows drive paths")
def test_windows_create_allows_the_drive_colon_and_refuses_any_other(monkeypatch, tmp_path, capsys):
    _msb_env(monkeypatch, tmp_path)
    rc, doc = _invoke_json(capsys, "--backend", "msb", "create", "opencode", str(tmp_path / "no" / "such:dir"))
    _assert_refused(rc, doc, "contains ':'")
    rc, doc = _invoke_json(capsys, "--backend", "msb", "create", "opencode", str(tmp_path / "missing"))
    _assert_refused(rc, doc, "does not exist")


def test_a_ro_suffix_gets_a_hint(monkeypatch, tmp_path, capsys):
    _msb_env(monkeypatch, tmp_path)
    rc, doc = _invoke_json(capsys, "--backend", "msb", "create", "opencode", "proj:ro")
    _assert_refused(rc, doc, "contains ':'")
    assert "no ':ro' suffix" in doc["error"]["remediation"]


@posix_only
def test_create_refuses_a_symlink_whose_target_has_a_colon(monkeypatch, tmp_path, capsys):
    target = tmp_path / "a:b" / "w"
    target.mkdir(parents=True)
    link = tmp_path / "lnk"
    link.symlink_to(target, target_is_directory=True)
    _msb_env(monkeypatch, tmp_path)
    rc, doc = _invoke_json(capsys, "--backend", "msb", "create", "opencode", str(link))
    _assert_refused(rc, doc, f"resolves to {target}")


@posix_only
def test_run_refuses_a_dot_workspace_in_a_colon_directory(monkeypatch, tmp_path, capsys):
    cwd = tmp_path / "a:b"
    cwd.mkdir()
    monkeypatch.chdir(cwd)
    monkeypatch.setenv("PWD", str(cwd))
    _msb_env(monkeypatch, tmp_path)
    rc, doc = _invoke_json(capsys, "--backend", "msb", "run", "opencode", ".")
    _assert_refused(rc, doc, "contains ':'")


# ---------------------------------------------------------------------------
# Sandbox names on the command line.
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("name", ["a.b", ".", "..", "-x", "", "caf\u00e9", "a/b", "x\ny"])
@pytest.mark.parametrize("verb", ["create", "run"])
def test_an_explicit_name_outside_the_charset_is_refused(monkeypatch, tmp_path, capsys, verb, name):
    _msb_env(monkeypatch, tmp_path)
    monkeypatch.chdir(tmp_path)
    rc, doc = _invoke_json(capsys, "--backend", "msb", verb, "opencode", ".", f"--name={name}")
    _assert_refused(rc, doc, "invalid sandbox name")
    assert not (tmp_path / "state").exists() or not list((tmp_path / "state").rglob("*.json"))


def test_an_explicit_name_is_checked_against_the_charset_only(monkeypatch, tmp_path, capsys):
    _msb_env(monkeypatch, tmp_path)
    monkeypatch.chdir(tmp_path)
    rc, doc = _invoke_json(capsys, "--backend", "msb", "create", "opencode", ".", "--name", "My.Box")
    _assert_refused(rc, doc, "invalid sandbox name 'My.Box'")
    rc, doc = _invoke_json(capsys, "--backend", "msb", "create", "opencode", ".", "--name", "My_Box-2")
    assert rc == 0, doc
    assert doc["data"]["name"] == "My_Box-2"


_NAME_FORM_ARGV = [
    ["stop"], ["rm"], ["exec"], ["attach"], ["shell"], ["ports"],
    ["kit", "check"], ["kit", "update"],
]


@pytest.mark.parametrize("name", ["", ".", "..", "a/b", "../x", "a\\b", "x\x1b]0;t\x07", "x\u0085"])
@pytest.mark.parametrize("verb", _NAME_FORM_ARGV, ids=" ".join)
def test_name_form_verbs_refuse_path_shaped_names(monkeypatch, tmp_path, capsys, verb, name):
    _msb_env(monkeypatch, tmp_path)
    rc, doc = _invoke_json(capsys, "--backend", "msb", *verb, name)
    _assert_refused(rc, doc, "refusing sandbox name")
    assert "\x1b" not in json.dumps(doc, ensure_ascii=False)


@pytest.mark.parametrize("argv", [["kit", "apply", "..", "opencode"], ["create", "--recreate", "a/b"]], ids=" ".join)
def test_other_existing_sandbox_verbs_refuse_path_shaped_names(monkeypatch, tmp_path, capsys, argv):
    _msb_env(monkeypatch, tmp_path)
    rc, doc = _invoke_json(capsys, "--backend", "msb", *argv)
    _assert_refused(rc, doc, "refusing sandbox name")


def test_name_form_verbs_refuse_only_path_shaped_names(monkeypatch, tmp_path, capsys):
    _msb_env(monkeypatch, tmp_path)
    rc, doc = _invoke_json(capsys, "--backend", "msb", "stop", "odd/name")
    _assert_refused(rc, doc, "stop: refusing sandbox name 'odd/name'")
    rc, doc = _invoke_json(capsys, "--backend", "msb", "stop", "odd.name:1")
    assert rc == errors.EXIT_FAILURE
    assert doc["error"]["code"] == errors.SANDBOX_NOT_FOUND
