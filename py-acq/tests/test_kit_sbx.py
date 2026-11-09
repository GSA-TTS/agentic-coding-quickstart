"""Tier-2 tests for sbx kit application (ADR-0011, ADR-0017, ADR-0037).

Covers ``kit_sbx``: the neutral-to-sbx-v2 translator, compared file by file
with Bash ``kit_translate_to_sbx`` on the bundled kits, the legacy fixtures and
the kitspec parity corpora; the generated git identity and startup barrier
kits, compared with ``_acq_sbx_git_identity_kit`` and
``_acq_sbx_startup_barrier_kit``; and the create/run/kit flow that uses them,
against the deterministic ``__stub__`` sbx.
"""

from __future__ import annotations

import errno
import json
import os
import random
import shutil
import stat
import subprocess
import time
from pathlib import Path

import pytest

from acq_py import cli, errors, kit_sbx, kits, kitspec, sbx, state

pytestmark = pytest.mark.provider_key  # creates sandboxes: needs a stored provider key
from test_kitspec import EDGE_SPECS, _random_spec, _section_spec

REPO_ROOT = Path(__file__).resolve().parents[2]
KIT_TRANSLATE = REPO_ROOT / "acq.backends" / "kit-translate.sh"
COMMON_SH = REPO_ROOT / "acq.backends" / "common.sh"
SBX_SH = REPO_ROOT / "acq.backends" / "sbx.sh"
BASH = shutil.which("bash")
BUILTINS = ["zscaler-ca-certificate", "usai-provider", "agentic-coding-playbook", "git-ssh-sign"]
POSIX = os.name != "nt"

needs_bash = pytest.mark.skipif(
    BASH is None or not POSIX or shutil.which("awk") is None or shutil.which("base64") is None,
    reason="the Bash parity check needs bash, awk and base64",
)


# ---------------------------------------------------------------------------
# Bash drivers.
# ---------------------------------------------------------------------------

# Translates each KITDIR=OUTDIR pair with Bash kit_translate_to_sbx; a refused
# kit leaves OUTDIR.refused behind.
TRANSLATE_DRIVER = r"""
set -u
. "$KIT_TRANSLATE"
for pair in "$@"; do
  kitdir=${pair%%=*}; out=${pair#*=}
  kit_translate_to_sbx "$kitdir" "$out" >/dev/null 2>"$out.err" || : >"$out.refused"
done
"""

# The generated kits. Their helpers live in common.sh and sbx.sh, which need
# the whole acq environment to source, so each definition is lifted out alone.
GENERATED_DRIVER = r"""
set -u
. "$KIT_TRANSLATE"
lift() { eval "$(awk -v f="$1() {" 'index($0, f) == 1 {on=1} on{print} on&&/^\}/{exit}' "$2")"; }
for f in _acq_host_git_config_value _acq_git_identity_value_is_safe acq_host_git_identity_env \
         acq_host_git_global_config_env; do lift "$f" "$COMMON_SH"; done
for f in _acq_sbx_git_identity_kit _acq_sbx_startup_barrier_kit; do lift "$f" "$SBX_SH"; done
acq_require_base() { :; }
ACQ_SBX_KIT_CACHE=$1
printf 'identity=%s\n' "$(_acq_sbx_git_identity_kit)"
printf 'barrier=%s\n' "$(_acq_sbx_startup_barrier_kit "$2")"
"""


def _bash_env(locale: str = "C", extra: dict | None = None) -> dict:
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "LC_ALL": locale,
           "KIT_TRANSLATE": str(KIT_TRANSLATE), "COMMON_SH": str(COMMON_SH), "SBX_SH": str(SBX_SH),
           "TMPDIR": os.environ.get("TMPDIR", "/tmp"), "HOME": os.environ["HOME"]}
    env.update(extra or {})
    return env


def bash_translate(pairs: list[tuple[Path, Path]], locale: str = "C") -> None:
    assert BASH is not None
    subprocess.run([BASH, "-c", TRANSLATE_DRIVER, "driver", *(f"{k}={o}" for k, o in pairs)],
                   env=_bash_env(locale), check=True, capture_output=True)


def tree(root: Path) -> dict[str, tuple[str, bytes | str]]:
    """Every entry under ``root``: a file's bytes, a symlink's target, or a directory."""
    out: dict[str, tuple[str, bytes | str]] = {}
    for base, dirs, files in os.walk(root):
        for name in [*dirs, *files]:
            path = Path(base) / name
            rel = path.relative_to(root).as_posix()
            if path.is_symlink():
                out[rel] = ("link", os.readlink(path))
            elif path.is_dir():
                out[rel] = ("dir", "")
            else:
                out[rel] = ("file", path.read_bytes())
    return out


def _kit_dirs_from_specs(tmp_path: Path, specs: dict[str, bytes]) -> list[Path]:
    dirs = []
    for name, raw in specs.items():
        kit = tmp_path / "kits" / name
        kit.mkdir(parents=True)
        (kit / "spec.yaml").write_bytes(raw)
        dirs.append(kit)
    return dirs


def assert_translation_parity(tmp_path: Path, kit_dirs: list[Path], locale: str = "C") -> int:
    """Translate each kit with Bash and Python, compare the trees; return how many Python refused."""
    pairs = [(k, tmp_path / "bash" / f"{i:04d}") for i, k in enumerate(kit_dirs)]
    (tmp_path / "bash").mkdir()
    bash_translate(pairs, locale)
    refused = 0
    for kit, bash_out in pairs:
        try:
            spec = kitspec.load_kit(kit)
        except kitspec.KitSpecError:
            refused += 1
            continue
        py_out = tmp_path / "py" / bash_out.name
        py_out.mkdir(parents=True)
        kit_sbx.translate(spec, py_out)
        assert not Path(f"{bash_out}.refused").exists(), kit
        assert tree(py_out) == tree(bash_out), kit
    return refused


# ---------------------------------------------------------------------------
# Golden tests: the translator.
# ---------------------------------------------------------------------------


@needs_bash
@pytest.mark.parametrize("locale", ["C", "C.UTF-8"])
def test_golden_bundled_kits(tmp_path, locale):
    dirs = [kitspec.bundle_kit_dir(name) for name in kitspec.bundle_kit_names()]
    assert assert_translation_parity(tmp_path, dirs, locale) == 0


@needs_bash
def test_golden_legacy_fixtures(tmp_path):
    dirs = [REPO_ROOT / "test" / "fixtures" / d for d in ("kit-valid", "kit-invalid", "empty-kit")]
    assert assert_translation_parity(tmp_path, [d for d in dirs if (d / "spec.yaml").is_file()]) == 0


@needs_bash
def test_golden_hand_written_specs(tmp_path):
    specs = {name: text.encode("utf-8") for name, text in EDGE_SPECS.items()}
    assert assert_translation_parity(tmp_path, _kit_dirs_from_specs(tmp_path, specs)) == 0


@needs_bash
def test_golden_random_corpus(tmp_path):
    rng = random.Random(20261109)
    specs = {f"fuzz-{i:04d}": _random_spec(rng) for i in range(160)}
    specs |= {f"section-{i:04d}": _section_spec(rng) for i in range(160)}
    assert assert_translation_parity(tmp_path, _kit_dirs_from_specs(tmp_path, specs)) < len(specs) // 10


_SPECIAL_SPEC = """\
schemaVersion: "hybrid/v1"
kind: mixin
name: special
displayName: "Display: with colon"
description: -leading dash
caps:
  network:
    allow:
      - "*.npmjs.org"
      - api.example.gov:443
environment:
  PLAIN: value
  QUOTED: "\\tit's  "
  EMPTY: ""
publishedPorts:
  - guest: 3000
    protocol: tcp
    name: web-ui
  - guest: 8080
volumes:
  - path: /data
    size: 1G
  - path: /scratch
    type: tmpfs
    size: 512m
files:
  - path: /home/agent/bin/run.sh
    mode: "0755"
    source: files/home/bin/run.sh
  - path: /home/agent/bin/odd.sh
    mode: "755"
    source: files/home/bin/run.sh
  - path: /workspace/x.sh
    mode: "0700"
    source: files/home/bin/run.sh
  - path: /home/agent/ro.sh
    source: files/home/bin/run.sh
    readonly: true
commands:
  - phase: install
    user: "0"
    command:
      - echo
      - joined argv
  - phase: startup
    user: "1000"
    background: true
    command:
      - sh
      - -c
      - |
        echo one
        echo 'two'
  - phase: initFiles
    command:
      - "true"
      - "#hash"
agentContext: |
  # Title

  Body line.


"""


@needs_bash
def test_golden_every_section_and_payload(tmp_path):
    kit = tmp_path / "kits" / "special"
    (kit / "files" / "home" / "bin").mkdir(parents=True)
    (kit / "spec.yaml").write_text(_SPECIAL_SPEC, encoding="utf-8")
    (kit / "files" / "home" / "bin" / "run.sh").write_bytes(b"#!/bin/sh\necho hi\r\n")
    (kit / "files" / "home" / "empty").mkdir()
    if POSIX:
        os.symlink("bin/run.sh", kit / "files" / "home" / "link.sh")
    assert assert_translation_parity(tmp_path, [kit]) == 0
    text = (tmp_path / "py" / "0000" / "spec.yaml").read_text(encoding="utf-8")
    assert "  - container: 3000\n" in text and "    type: tmpfs\n" in text
    assert "chmod 0755 '/home/agent/bin/run.sh'" in text and "/workspace/x.sh" not in text


@needs_bash
def test_golden_refuses_payload_links_outside_the_kit(tmp_path):
    outside = tmp_path / "secret.txt"
    outside.write_text("secret", encoding="utf-8")
    kit = tmp_path / "kits" / "escape"
    (kit / "files").mkdir(parents=True)
    (kit / "spec.yaml").write_text('schemaVersion: "hybrid/v1"\nname: escape\n', encoding="utf-8")
    os.symlink(outside, kit / "files" / "leak")
    bash_out = tmp_path / "bash-out"
    bash_translate([(kit, bash_out)])
    assert Path(f"{bash_out}.refused").exists()
    with pytest.raises(kit_sbx.KitTranslateError, match="points outside the kit"):
        kit_sbx.translate(kitspec.load_kit(kit), tmp_path / "py-out")


@needs_bash
def test_yaml_quote_matches_bash():
    values = ["", "plain", "-dash", " lead", "trail ", "a b", "x:y", "it's", "a\\b", "é", "a-b", "a#b", "~", "=",
              *(f"a{chr(c)}b" for c in range(33, 127)), *(chr(c) for c in range(33, 127))]
    script = '. "$KIT_TRANSLATE"; for v in "$@"; do _kit_yaml_quote "$v"; printf "\\0"; done'
    assert BASH is not None
    proc = subprocess.run([BASH, "-c", script, "q", *values], env=_bash_env(), check=True, capture_output=True)
    bash_values = proc.stdout.decode("utf-8").split("\0")[:-1]
    assert [kit_sbx.yaml_quote(v) for v in values] == bash_values


def test_translator_warns_on_modes_it_cannot_apply():
    spec = kitspec.parse_spec(_SPECIAL_SPEC.encode("utf-8"))
    warn: list[str] = []
    kit_sbx.render_spec(spec, warn)
    assert any("/workspace/x.sh cannot be applied on sbx" in w for w in warn)
    assert any('mode must be a 0-prefixed octal string like "0755" (got: 755)' in w for w in warn)
    assert kit_sbx.readonly_warning(spec)[0].endswith("marks startup files readonly: /home/agent/ro.sh")


# ---------------------------------------------------------------------------
# Golden tests: the generated kits.
# ---------------------------------------------------------------------------


def _identity_env(monkeypatch, tmp_path, env: dict, gitconfig: str | None) -> dict:
    home = tmp_path / "idhome"
    home.mkdir(exist_ok=True)
    if gitconfig is not None:
        (home / ".gitconfig").write_text(gitconfig, encoding="utf-8")
    full = {"HOME": str(home), "GIT_CONFIG_NOSYSTEM": "1", **env}
    for var in ("GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL", "EMAIL",
                "GIT_CONFIG_GLOBAL", "XDG_CONFIG_HOME"):
        monkeypatch.delenv(var, raising=False)
    for key, value in full.items():
        monkeypatch.setenv(key, value)
    return full


_IDENTITY_CASES = {
    "none": ({}, None),
    "env-only": ({"GIT_AUTHOR_NAME": "Jane O'Neil", "GIT_COMMITTER_EMAIL": "j@x.gov", "EMAIL": "-e@x.gov"}, None),
    "global-config": ({}, "[user]\n\tname = Ann: B #1\n\temail = ann@x.gov\n"),
    "tab-skipped": ({"GIT_AUTHOR_NAME": "a\tb", "GIT_AUTHOR_EMAIL": "ok@x.gov"}, "[user]\n\tname = Nora\n"),
}


@needs_bash
@pytest.mark.skipif(shutil.which("git") is None, reason="needs git")
@pytest.mark.parametrize("case", sorted(_IDENTITY_CASES))
def test_golden_generated_kits(monkeypatch, tmp_path, case):
    env, gitconfig = _IDENTITY_CASES[case]
    full = _identity_env(monkeypatch, tmp_path, env, gitconfig)
    token = "acq-123-1700000000-42-7"
    cache = tmp_path / "bash-cache"
    assert BASH is not None
    proc = subprocess.run([BASH, "-c", GENERATED_DRIVER, "g", str(cache), token],
                          env=_bash_env(extra=full), check=True, capture_output=True, text=True)
    lines = dict(line.split("=", 1) for line in proc.stdout.splitlines())
    built = kit_sbx.git_identity_spec(kit_sbx._session().host_git_identity_env(), kit_sbx.git_global_config_env())
    if case == "none":
        assert lines["identity"] == "" and built is None
    else:
        assert built is not None
        slug, text = built
        assert Path(lines["identity"]).name == f"git-identity-{slug}"
        assert (Path(lines["identity"]) / "spec.yaml").read_text(encoding="utf-8") == text
    assert Path(lines["barrier"]).name == f"startup-barrier-{token}"
    assert (Path(lines["barrier"]) / "spec.yaml").read_text(encoding="utf-8") == kit_sbx.startup_barrier_spec(token)


def test_barrier_token_is_validated():
    assert kit_sbx._BARRIER_TOKEN.fullmatch(kit_sbx.new_barrier_token())
    with pytest.raises(ValueError):
        kit_sbx.startup_barrier_spec("x'; rm -rf /")


# ---------------------------------------------------------------------------
# Private kit directories.
# ---------------------------------------------------------------------------


def test_kit_dirs_are_private_and_refuse_symlinks(monkeypatch, tmp_path):
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    kit = kit_sbx.bundled_kit("opencode", "agent")
    path = kit_sbx.translated_kit(kit)
    assert path.parent.parent == tmp_path / "state" / kit_sbx.KIT_DIR_NAME
    if POSIX:
        for d in (path.parent.parent, path.parent, path):
            assert stat.S_IMODE(d.stat().st_mode) == 0o700
        assert stat.S_IMODE((path / "spec.yaml").stat().st_mode) == 0o600
    # The same content is published once and reused.
    assert kit_sbx.translated_kit(kit) == path
    if POSIX:
        shutil.rmtree(tmp_path / "state" / kit_sbx.KIT_DIR_NAME)
        elsewhere = tmp_path / "elsewhere"
        elsewhere.mkdir()
        os.symlink(elsewhere, tmp_path / "state" / kit_sbx.KIT_DIR_NAME)
        with pytest.raises(kit_sbx.KitTranslateError, match="not a directory acq created"):
            kit_sbx.translated_kit(kit)
        assert list(elsewhere.iterdir()) == []


# ---------------------------------------------------------------------------
# The create / run / kit flow against the stub sbx.
# ---------------------------------------------------------------------------


def _env(monkeypatch, tmp_path, *, version="0.51.0", catalog=None):
    monkeypatch.setenv("ACQ_SBX_BIN", "__stub__")
    monkeypatch.setenv("ACQ_SBX_VERSION", version)
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "1")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "0")
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("SBX_HOME", str(tmp_path / "sbx-home"))
    monkeypatch.setenv(kit_sbx.BARRIER_TIMEOUT_ENV, "5")
    for var in ("GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL", "EMAIL"):
        monkeypatch.delenv(var, raising=False)
    monkeypatch.setattr(kit_sbx, "BARRIER_POLL_S", 0.01)
    if catalog is not None:
        monkeypatch.setenv("ACQ_SBX_STUB_CATALOG", json.dumps(catalog))
    ws = tmp_path / "ws"
    ws.mkdir(exist_ok=True)
    return ws


def _invoke(capsys, *argv):
    rc = cli.main(list(argv))
    out = capsys.readouterr().out.strip()
    return rc, (json.loads(out.splitlines()[-1]) if out else None)


def _spy(monkeypatch) -> list[list[str]]:
    seen: list[list[str]] = []
    real = sbx._run

    def spy(argv, **kwargs):
        seen.append(list(argv))
        return real(argv, **kwargs)

    monkeypatch.setattr(sbx, "_run", spy)
    return seen


def _create_argv(seen):
    (argv,) = [a for a in seen if a[0] == "create"]
    return argv


def _kit_flags(argv: list[str]) -> list[Path]:
    return [Path(argv[i + 1]) for i, a in enumerate(argv[:-1]) if a == "--kit"]


def _kit_names(argv: list[str]) -> list[str]:
    names = []
    for path in _kit_flags(argv):
        if path.name.startswith("startup-barrier-"):
            assert not path.exists()  # removed once sbx create has read it
            names.append("acq-startup-barrier")
            continue
        line = next(x for x in (path / "spec.yaml").read_text(encoding="utf-8").splitlines() if x.startswith("name: "))
        names.append(line[len("name: "):])
    return names


def test_capability_record_declares_kit_apply():
    assert sbx.capability_record()["capabilities"]["kit-apply"] == "required"
    assert cli._supports("sbx", "kit-apply") is True


def test_run_opencode_creates_with_every_kit(monkeypatch, tmp_path, capsys):
    ws = _env(monkeypatch, tmp_path)
    seen = _spy(monkeypatch)
    rc, doc = _invoke(capsys, "--backend", "sbx", "create", "opencode", str(ws), "--name", "oc", "--json")
    assert rc == 0, doc
    assert doc["data"]["kits"] == [*BUILTINS, "opencode"]
    assert (doc["data"]["kit"], doc["data"]["entrypoint"]) == ("opencode", "opencode")
    argv = _create_argv(seen)
    # sbx gets the shell agent: OpenCode comes from the pinned kit, not sbx's own.
    assert argv[1] == "shell"
    assert _kit_names(argv) == [*BUILTINS, "opencode", "acq-startup-barrier"]
    for path in _kit_flags(argv):
        assert path.is_relative_to(tmp_path / "state" / kit_sbx.KIT_DIR_NAME)
    assert kit_sbx.hc_read("oc", "builtin-kits").splitlines() == [
        f"zscaler-ca-certificate {kitspec.builtin_kit_ref('zscaler-ca-certificate')}",
        f"usai-provider {kitspec.builtin_kit_ref('usai-provider')}",
        f"agentic-coding-playbook {kitspec.builtin_kit_ref('agentic-coding-playbook')}",
    ]
    assert kit_sbx.hc_read("oc", "generic-opencode") == "generic-opencode"
    assert kits.kit_applied_read("sbx", "oc")["entrypoint"] == "opencode"
    assert kits.provenance_status("sbx", "oc") == "current"
    rc, doc = _invoke(capsys, "--backend", "sbx", "rm", "oc", "--json")
    assert rc == 0
    assert not kit_sbx.host_config_dir("oc").exists()


def test_other_agents_get_the_builtin_kits(monkeypatch, tmp_path, capsys):
    ws = _env(monkeypatch, tmp_path)
    seen = _spy(monkeypatch)
    rc, doc = _invoke(capsys, "--backend", "sbx", "create", "claude", str(ws), "--name", "cl", "--json")
    assert rc == 0, doc
    assert doc["data"]["kits"] == BUILTINS and doc["data"]["kit"] is None
    argv = _create_argv(seen)
    assert argv[1] == "claude"
    assert _kit_names(argv) == [*BUILTINS, "acq-startup-barrier"]


@pytest.mark.skipif(shutil.which("git") is None, reason="needs git")
def test_create_adds_the_git_identity_kit(monkeypatch, tmp_path, capsys):
    ws = _env(monkeypatch, tmp_path)
    monkeypatch.setenv("GIT_AUTHOR_NAME", "Jane Doe")
    seen = _spy(monkeypatch)
    rc, _ = _invoke(capsys, "--backend", "sbx", "create", "shell", str(ws), "--name", "gi", "--json")
    assert rc == 0
    names = _kit_names(_create_argv(seen))
    assert names[-2].startswith("acq-git-identity-") and names[-1] == "acq-startup-barrier"
    identity = _kit_flags(_create_argv(seen))[-2]
    assert "    GIT_AUTHOR_NAME: Jane Doe\n" in (identity / "spec.yaml").read_text(encoding="utf-8")


def test_startup_barrier_timeout_removes_the_sandbox(monkeypatch, tmp_path, capsys):
    ws = _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_SBX_STUB_BARRIER", "stall")
    monkeypatch.setenv(kit_sbx.BARRIER_TIMEOUT_ENV, "0")
    rc, doc = _invoke(capsys, "--backend", "sbx", "create", "opencode", str(ws), "--name", "slow", "--json")
    assert rc == 1
    assert doc["error"]["code"] == errors.TIMEOUT
    assert "did not finish within 0s" in doc["error"]["message"]
    assert not sbx.exists("slow")
    assert state.record_read("sbx", "slow") is None
    assert not kit_sbx.host_config_dir("slow").exists()


def test_create_fails_closed_when_the_bundle_does_not_verify(monkeypatch, tmp_path, capsys):
    ws = _env(monkeypatch, tmp_path)
    monkeypatch.setattr(kitspec, "verify_bundle", lambda: ["usai-provider/spec.yaml: blob mismatch"])
    seen = _spy(monkeypatch)
    rc, doc = _invoke(capsys, "--backend", "sbx", "run", "opencode", str(ws), "--name", "bad", "--json")
    assert rc == 1
    assert doc["error"]["code"] == errors.VALIDATION_FAILED
    assert "does not match its pinned content" in doc["error"]["message"]
    assert not [a for a in seen if a[0] == "create"]


def test_unfetchable_refs_are_refused_before_create(monkeypatch, tmp_path, capsys):
    ws = _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_EXTRA_KITS", "git+https://github.com/acme/kits.git#ref=abc&dir=k")
    seen = _spy(monkeypatch)
    rc, doc = _invoke(capsys, "--backend", "sbx", "create", "shell", str(ws), "--name", "ex", "--json")
    assert rc == 1
    assert doc["error"]["code"] == errors.UNSUPPORTED
    assert "would have to be fetched" in doc["error"]["message"]
    assert not [a for a in seen if a[0] == "create"]
    assert state.record_read("sbx", "ex") is None


def test_a_kit_that_cannot_be_prepared_stops_the_create(monkeypatch, tmp_path, capsys):
    ws = _env(monkeypatch, tmp_path)

    def broken(_kit):
        raise kit_sbx.KitTranslateError("kit-translate: kit payload symlink points outside the kit: files/x")

    monkeypatch.setattr(kit_sbx, "translated_kit", broken)
    seen = _spy(monkeypatch)
    rc, doc = _invoke(capsys, "--backend", "sbx", "create", "shell", str(ws), "--name", "px", "--json")
    assert rc == 1
    assert doc["error"]["code"] == errors.VALIDATION_FAILED
    assert not [a for a in seen if a[0] == "create"]


def test_cli_kit_record_and_extras(monkeypatch, tmp_path, capsys):
    ws = _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_EXTRA_KITS", kitspec.builtin_kit_ref("git-ssh-sign"))
    rc, _ = _invoke(capsys, "--backend", "sbx", "create", "shell", str(ws), "--name", "rk", "--json")
    assert rc == 0
    assert kit_sbx.hc_read("rk", "extra-kits") == kitspec.builtin_kit_ref("git-ssh-sign")


def test_kit_apply_on_sbx_needs_a_recreate_for_startup_kits(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path, catalog={"box": "running"})
    rc, doc = _invoke(capsys, "--backend", "sbx", "kit", "apply", "box", "opencode", "--json")
    assert rc == 1
    assert doc["error"]["code"] == errors.UNSUPPORTED
    assert "acq rm 'box'" in doc["error"]["remediation"]


def test_kit_apply_on_sbx_adds_the_kit(monkeypatch, tmp_path, capsys):
    _env(monkeypatch, tmp_path, catalog={"box": "running"})
    monkeypatch.setenv("ACQ_SBX_STUB_KIT_ADD", "allow")
    seen = _spy(monkeypatch)
    rc, doc = _invoke(capsys, "--backend", "sbx", "kit", "apply", "box", "opencode", "--json")
    assert rc == 0, doc
    assert doc["data"]["action"] == "applied"
    (add,) = [a for a in seen if a[:2] == ["kit", "add"]]
    assert add[2] == "box" and Path(add[3]).name.startswith("opencode.")


def _seed_sandbox(monkeypatch, tmp_path, capsys, name="hb"):
    ws = _env(monkeypatch, tmp_path)
    rc, _ = _invoke(capsys, "--backend", "sbx", "create", "opencode", str(ws), "--name", name, "--json")
    assert rc == 0


def test_kit_update_refreshes_through_kit_add(monkeypatch, tmp_path, capsys):
    _seed_sandbox(monkeypatch, tmp_path, capsys)
    monkeypatch.setenv("ACQ_SBX_STUB_KIT_ADD", "allow")
    seen = _spy(monkeypatch)
    rc, doc = _invoke(capsys, "--backend", "sbx", "kit", "update", "hb", "--yes", "--json")
    # The sandbox is on the pinned bundle already, so nothing runs.
    assert rc == 0 and doc["data"]["action"] == "noop"
    kits.provenance_remove("sbx", "hb")
    rc, doc = _invoke(capsys, "--backend", "sbx", "kit", "update", "hb", "--yes", "--json")
    assert rc == 0, doc
    assert doc["data"]["action"] == "refreshed"
    assert doc["data"]["kits"] == ["zscaler-ca-certificate", "usai-provider", "agentic-coding-playbook",
                                   "git-ssh-sign", "opencode"]
    adds = [Path(a[3]).name for a in seen if a[:2] == ["kit", "add"]]
    assert len(adds) == 5
    assert kits.provenance_status("sbx", "hb") == "current"


def test_kit_update_reports_a_needed_recreate_once(monkeypatch, tmp_path, capsys):
    _seed_sandbox(monkeypatch, tmp_path, capsys)
    kits.provenance_remove("sbx", "hb")
    rc = cli.main(["--backend", "sbx", "kit", "update", "hb", "--yes", "--json"])
    captured = capsys.readouterr()
    assert rc == 1
    assert json.loads(captured.out)["error"]["code"] == errors.FAILURE
    assert captured.err.count("cannot extend a live sandbox with startup-bearing kits") == 1
    assert kits.provenance_status("sbx", "hb") != "current"


def test_heal_skips_recorded_builtins(monkeypatch, tmp_path, capsys):
    _seed_sandbox(monkeypatch, tmp_path, capsys)
    seen = _spy(monkeypatch)
    kit_set, selection = kit_sbx.select("opencode", [], image_is_default=True)
    result = kit_sbx.ensure_kits_applied("hb", kit_set, selection)
    assert result.ok and not result.healed
    assert not [a for a in seen if a[:2] == ["kit", "add"]]
    kit_sbx.hc_write("hb", "builtin-kits", "zscaler-ca-certificate stale-ref")
    monkeypatch.setenv("ACQ_SBX_STUB_KIT_ADD", "allow")
    result = kit_sbx.ensure_kits_applied("hb", kit_set, selection)
    assert result.ok and result.added == ["zscaler-ca-certificate", "usai-provider", "agentic-coding-playbook"]
    assert kit_sbx._recorded("hb", "zscaler-ca-certificate", kitspec.builtin_kit_ref("zscaler-ca-certificate"))
    assert "stale-ref" not in kit_sbx.hc_read("hb", "builtin-kits")


def test_kit_add_classification(monkeypatch):
    class P:
        def __init__(self, rc, err):
            self.returncode, self.stderr, self.stdout = rc, err, ""

    def fake(proc):
        return lambda argv, **kw: proc

    for rc, err, want in [(0, "", sbx.KIT_ADD_OK), (1, "kit declares setup.startup", sbx.KIT_ADD_RECREATE),
                          (1, "startup commands: please recreate", sbx.KIT_ADD_RECREATE),
                          (1, "recreate ... startup", sbx.KIT_ADD_FAILED), (1, "network down", sbx.KIT_ADD_FAILED)]:
        monkeypatch.setattr(sbx, "_run", fake(P(rc, err)))
        assert sbx.kit_add("box", "/k") == want
    assert sbx.kit_add("box", "") == sbx.KIT_ADD_FAILED


# ---------------------------------------------------------------------------
# Unconfirmed sandboxes are never left attachable.
# ---------------------------------------------------------------------------


def test_barrier_timeout_with_a_failed_rm_refuses_reattach(monkeypatch, tmp_path, capsys):
    ws = _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_SBX_STUB_BARRIER", "stall")
    monkeypatch.setenv(kit_sbx.BARRIER_TIMEOUT_ENV, "0")
    monkeypatch.setenv("ACQ_SBX_STUB_FAIL", "rm")
    rc, doc = _invoke(capsys, "--backend", "sbx", "create", "shell", str(ws), "--name", "stuck", "--json")
    assert rc == 1
    assert "could not be removed" in doc["error"]["message"]
    assert doc["error"]["remediation"].startswith("run 'acq rm stuck'")
    assert sbx.exists("stuck")
    assert state.record_read("sbx", "stuck")["kits_unconfirmed"] is True
    for argv in (("run", "stuck"), ("run", "shell", str(ws), "--name", "stuck"), ("exec", "stuck", "--", "true")):
        rc, doc = _invoke(capsys, "--backend", "sbx", "--json", *argv)
        assert rc == 1 and "never confirmed" in doc["error"]["message"], argv
    monkeypatch.delenv("ACQ_SBX_STUB_FAIL")
    rc, _ = _invoke(capsys, "--backend", "sbx", "rm", "stuck", "--json")
    assert rc == 0 and state.record_read("sbx", "stuck") is None


@pytest.mark.parametrize("rm_fails", [False, True])
def test_interrupted_barrier_wait_leaves_nothing_attachable(monkeypatch, tmp_path, capsys, rm_fails):
    ws = _env(monkeypatch, tmp_path)

    def interrupted(_name, _token):
        if rm_fails:
            monkeypatch.setenv("ACQ_SBX_STUB_FAIL", "rm")
        raise KeyboardInterrupt

    monkeypatch.setattr(kit_sbx, "wait_startup_barrier", interrupted)
    with pytest.raises(KeyboardInterrupt):
        cli.main(["--backend", "sbx", "create", "shell", str(ws), "--name", "intr", "--json"])
    capsys.readouterr()
    monkeypatch.delenv("ACQ_SBX_STUB_FAIL", raising=False)
    record = state.record_read("sbx", "intr")
    if rm_fails:
        assert sbx.exists("intr") and record["kits_unconfirmed"] is True
        rc, doc = _invoke(capsys, "--backend", "sbx", "run", "intr", "--json")
        assert rc == 1 and "never confirmed" in doc["error"]["message"]
    else:
        assert not sbx.exists("intr") and record is None


def test_exec_ready_timeout_with_a_failed_rm_keeps_the_mark(monkeypatch, tmp_path, capsys):
    ws = _env(monkeypatch, tmp_path)
    monkeypatch.setattr(sbx, "exec_ready", lambda _name: False)
    monkeypatch.setenv("ACQ_SBX_READY_TIMEOUT", "0")
    monkeypatch.setenv("ACQ_SBX_STUB_FAIL", "rm")
    rc, doc = _invoke(capsys, "--backend", "sbx", "create", "shell", str(ws), "--name", "nr", "--json")
    assert rc == 1 and "could not be removed" in doc["error"]["message"]
    assert state.record_read("sbx", "nr")["kits_unconfirmed"] is True


def test_a_confirmed_create_clears_the_mark(monkeypatch, tmp_path, capsys):
    ws = _env(monkeypatch, tmp_path)
    rc, _ = _invoke(capsys, "--backend", "sbx", "create", "shell", str(ws), "--name", "ok", "--json")
    assert rc == 0
    assert "kits_unconfirmed" not in state.record_read("sbx", "ok")


# ---------------------------------------------------------------------------
# Shared kit directories: concurrency, the barrier kit, pruning.
# ---------------------------------------------------------------------------


def test_concurrent_translations_never_remove_a_live_directory(monkeypatch, tmp_path):
    import threading

    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    kit_set = [kit_sbx.bundled_kit(name) for name in kitspec.bundle_kit_names()]
    problems: list[str] = []
    seen: set[Path] = set()

    def worker():
        for _ in range(8):
            for kit in kit_set:
                try:
                    path = kit_sbx.translated_kit(kit)
                except Exception as exc:  # noqa: BLE001 - every failure is a finding
                    problems.append(repr(exc))
                    continue
                seen.add(path)
                if not (path / "spec.yaml").is_file():
                    problems.append(f"{path} vanished")

    threads = [threading.Thread(target=worker) for _ in range(6)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert problems == []
    assert len(seen) == len(kit_set)  # one directory per kit, named by content
    assert all((p / "spec.yaml").is_file() for p in seen)
    leftovers = [e.name for e in (tmp_path / "state" / kit_sbx.KIT_DIR_NAME / "v2").iterdir() if e.name.startswith(".")]
    assert leftovers == []


def test_content_names_follow_the_content(monkeypatch, tmp_path):
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    kit = kit_sbx.bundled_kit("opencode")
    first = kit_sbx.translated_kit(kit)
    assert kit_sbx.translated_kit(kit) == first
    other = kit_sbx.Kit(kit.name, kit.role, kitspec.parse_spec(b'schemaVersion: "hybrid/v1"\nname: opencode\n',
                                                                kit_dir=tmp_path), kit.ref)
    assert kit_sbx.translated_kit(other) != first and first.is_dir()


def test_barrier_kit_is_removed_after_create_and_stale_kits_pruned(monkeypatch, tmp_path, capsys):
    ws = _env(monkeypatch, tmp_path)
    root = tmp_path / "state" / kit_sbx.KIT_DIR_NAME
    rc, _ = _invoke(capsys, "--backend", "sbx", "create", "shell", str(ws), "--name", "b1", "--json")
    assert rc == 0
    assert not [e for e in (root / "generated").iterdir() if e.name.startswith("startup-barrier-")]
    stale = root / "v2" / "old-kit.0123456789abcdef"
    stale.mkdir()
    old = 1_000_000_000
    os.utime(stale, (old, old))
    live = sorted((root / "v2").iterdir())
    for path in live:
        if path != stale:
            os.utime(path, (old, old))  # old but in use: refreshed and kept
    rc, _ = _invoke(capsys, "--backend", "sbx", "create", "shell", str(ws), "--name", "b2", "--json")
    assert rc == 0
    assert not stale.exists()
    assert all(p.exists() for p in live if p != stale)


# ---------------------------------------------------------------------------
# Small units.
# ---------------------------------------------------------------------------


def test_private_dir_refuses_another_owner(monkeypatch, tmp_path):
    monkeypatch.setattr(os, "getuid", lambda: os.lstat(tmp_path).st_uid + 1, raising=False)
    with pytest.raises(kit_sbx.KitTranslateError, match="owned by another user"):
        kit_sbx._private_dir(tmp_path / "kits")


@pytest.mark.parametrize("value", ["a\rb", "a\nb", "a\tb", "a\x85b", "a b", "a b", "a\x0bb"])
def test_identity_filter_drops_line_breaks(monkeypatch, value):
    assert not kit_sbx._safe_identity(value)
    monkeypatch.setattr(kit_sbx, "_session", lambda: type("S", (), {
        "host_git_identity_env": staticmethod(lambda: [f"GIT_AUTHOR_NAME={value}", "EMAIL=e@x.gov"]),
        "_host_git_config": staticmethod(lambda key: value),
    }))
    built = kit_sbx.git_identity_spec(
        [r for r in kit_sbx._session().host_git_identity_env() if kit_sbx._safe_identity(r.partition("=")[2])],
        kit_sbx.git_global_config_env())
    assert built is not None and value not in built[1] and "    EMAIL: 'e@x.gov'\n" in built[1]
    assert "GIT_AUTHOR_NAME" not in built[1] and "ACQ_GIT_USER" not in built[1]


@pytest.mark.parametrize("value", ["true", "False", "yes", "off", "~", "null", "123", "0x1F", "1e3", "-2.5",
                                   ".inf", "2026-11-09", "12:30"])
def test_identity_values_yaml_would_coerce_are_quoted(value):
    _slug, text = kit_sbx.git_identity_spec([f"GIT_AUTHOR_NAME={value}"], [])
    assert f"    GIT_AUTHOR_NAME: '{value}'\n" in text


def test_identity_plain_values_stay_bare():
    _slug, text = kit_sbx.git_identity_spec(["GIT_AUTHOR_NAME=Jane Doe", "GIT_COMMITTER_NAME=Nora"], [])
    assert "    GIT_AUTHOR_NAME: Jane Doe\n" in text and "    GIT_COMMITTER_NAME: Nora\n" in text


def test_clear_instance_state(monkeypatch, tmp_path):
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    for key in ("builtin-kits", "extra-kits", "generic-opencode", "install-1", "keep-me"):
        kit_sbx.hc_write("box", key, "x")
    kit_sbx.clear_instance_state("box")
    assert sorted(p.name for p in kit_sbx.host_config_dir("box").iterdir()) == ["keep-me"]
    kit_sbx.clear_instance_state("absent")  # nothing to clear


def test_exec_capture_honours_the_exit_code(monkeypatch):
    class P:
        def __init__(self, rc, out):
            self.returncode, self.stdout, self.stderr = rc, out, ""

    monkeypatch.setattr(sbx, "_run", lambda argv, **kw: P(1, "ready\n"))
    assert sbx.exec_capture("box", "x") is None
    monkeypatch.setattr(sbx, "_run", lambda argv, **kw: P(0, "ready\r\n"))
    assert sbx.exec_capture("box", "x") == "ready\n"

    def slow(argv, **kw):
        raise subprocess.TimeoutExpired(argv, 1)

    monkeypatch.setattr(sbx, "_run", slow)
    assert sbx.exec_capture("box", "x") is None


def test_force_refresh_uses_roles():
    kits_ = [kit_sbx.bundled_kit(n, r) for n, r in (("zscaler-ca-certificate", "support"),
                                                     ("agentic-coding-playbook", "support"),
                                                     ("git-ssh-sign", "support"), ("opencode", "agent"))]
    refs = [(k.ref, k.role, k.name) for k in kits_]
    # No provider kit: Bash's positional count would skip the agent kit.
    selection = kitspec.KitSelection(tuple(kitspec.SelectedKit(*r) for r in refs), 3, 4, None)
    out = kit_sbx._force_refresh_kits(kits_, selection)
    assert [(k.name, label) for k, label in out] == [("git-ssh-sign", "git-ssh-sign kit"), ("opencode", "agent kit")]


def test_interrupted_prune_never_leaves_a_reusable_partial_kit(monkeypatch, tmp_path):
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    kit = kit_sbx.bundled_kit("opencode")
    path = kit_sbx.translated_kit(kit)
    old = 1_000_000_000
    os.utime(path, (old, old))
    real_remove = kit_sbx._remove_tree

    def interrupted(target):
        # Delete one payload file, then stop: an rmtree cut short.
        next(p for p in target.rglob("*") if p.is_file() and p.name != "spec.yaml").unlink()
        raise KeyboardInterrupt

    monkeypatch.setattr(kit_sbx, "_remove_tree", interrupted)
    with pytest.raises(KeyboardInterrupt):
        kit_sbx.prune_stale([])
    monkeypatch.setattr(kit_sbx, "_remove_tree", real_remove)
    v2 = path.parent
    # The partial tree is only under a trash name, never under the kit's name.
    assert not path.exists()
    assert [e.name.startswith(kit_sbx.TRASH_PREFIX) for e in v2.iterdir()] == [True]
    assert kit_sbx.translated_kit(kit) == path and kit_sbx._valid_kit_dir(path, path.name.rsplit(".", 1)[1])
    kit_sbx.prune_stale([path])
    assert [e.name for e in v2.iterdir()] == [path.name]


def test_a_damaged_kit_directory_is_rebuilt_not_reused(monkeypatch, tmp_path):
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    kit = kit_sbx.bundled_kit("opencode")
    path = kit_sbx.translated_kit(kit)
    victim = next(p for p in path.rglob("*") if p.is_file() and p.name != "spec.yaml")
    victim.unlink()  # half-deleted, spec.yaml still there
    assert kit_sbx.translated_kit(kit) == path
    assert victim.is_file()
    assert not [e for e in path.parent.iterdir() if e.name.startswith(".")]


def test_a_concurrent_creates_fresh_copy_survives_a_stale_damaged_verdict(monkeypatch, tmp_path):
    # Two creates find the same damaged directory. B replaces it with its own
    # fresh copy after A has judged it damaged but before A moves it aside. A
    # must put B's copy back (B may be handing it to sbx), not delete it.
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    kit = kit_sbx.bundled_kit("opencode")
    path = kit_sbx.translated_kit(kit)
    reference = tmp_path / "reference"
    shutil.copytree(path, reference, symlinks=True)
    next(p for p in path.rglob("*") if p.is_file() and p.name != "spec.yaml").unlink()
    real_valid = kit_sbx._valid_kit_dir
    b_copy = {}

    def stale_verdict(target, digest=None):
        verdict = real_valid(target, digest)
        if target == path and not b_copy:
            # B, between A's check and A's move: discard the damaged tree and
            # rename its own complete copy into place.
            kit_sbx._discard(path)
            build = tmp_path / "b-build"
            shutil.copytree(reference, build, symlinks=True)
            os.rename(build, path)
            b_copy["ino"] = os.lstat(path).st_ino
        return verdict

    monkeypatch.setattr(kit_sbx, "_valid_kit_dir", stale_verdict)
    assert kit_sbx.translated_kit(kit) == path
    assert b_copy and os.lstat(path).st_ino == b_copy["ino"]
    assert real_valid(path, path.name.rsplit(".", 1)[1])
    assert not [e for e in path.parent.iterdir() if e.name.startswith(".")]


def test_a_moved_aside_copy_is_dropped_when_the_name_is_retaken(monkeypatch, tmp_path):
    # The moved tree turns out complete, so it would be renamed back; the name
    # was taken again meanwhile, so the moved copy is dropped and the new one kept.
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    parent = kit_sbx._subdir("generated")
    dest = parent / "kit"
    dest.mkdir()
    (dest / "spec.yaml").write_text("x", encoding="utf-8")
    real_rename = os.rename

    def rename(src, dst):
        real_rename(src, dst)
        if Path(dst).name.startswith(kit_sbx.TRASH_PREFIX):
            (dest).mkdir()  # another create took the name meanwhile
            (dest / "spec.yaml").write_text("y", encoding="utf-8")

    monkeypatch.setattr(kit_sbx.os, "rename", rename)
    kit_sbx._move_damaged_aside(dest, None)
    assert (dest / "spec.yaml").read_text(encoding="utf-8") == "y"
    assert not [e for e in parent.iterdir() if e.name.startswith(kit_sbx.TRASH_PREFIX)]


def _fill_spec(tmp):
    (tmp / "spec.yaml").write_text("x", encoding="utf-8")


def test_a_failed_rename_with_nothing_at_the_name_raises(monkeypatch, tmp_path):
    # The rename into place fails although nothing sits at the kit's name (a
    # permission error, a Windows antivirus handle, a name too long). That must
    # fail the create, not return a path that does not exist.
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    parent = kit_sbx._subdir("generated")
    real_rename = os.rename

    def rename(src, dst):
        if Path(dst).name == "kit":
            raise PermissionError(errno.EACCES, "denied")
        return real_rename(src, dst)

    monkeypatch.setattr(kit_sbx.os, "rename", rename)
    with pytest.raises(kit_sbx.KitTranslateError, match="could not place a generated kit"):
        kit_sbx._publish(parent, "kit", _fill_spec)
    assert list(parent.iterdir()) == []  # the build directory is cleaned up too


def test_a_rename_retried_after_the_name_was_vacated_places_the_kit(monkeypatch, tmp_path):
    # The first rename fails because a tree sits at the name; by the time it is
    # looked at, another create has moved it away. The rename is retried.
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    parent = kit_sbx._subdir("generated")
    real_rename = os.rename
    failed = []

    def rename(src, dst):
        if Path(dst).name == "kit" and not failed:
            failed.append(True)
            raise FileExistsError(errno.EEXIST, "exists")
        return real_rename(src, dst)

    monkeypatch.setattr(kit_sbx.os, "rename", rename)
    dest = kit_sbx._publish(parent, "kit", _fill_spec)
    assert failed and dest == parent / "kit" and kit_sbx._valid_kit_dir(dest)
    assert [e.name for e in parent.iterdir()] == ["kit"]


def test_prune_sweeps_old_build_directories_only(monkeypatch, tmp_path):
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    v2 = kit_sbx._subdir("v2")
    old_tmp, new_tmp = v2 / ".opencode.abc", v2 / ".opencode.def"
    old_tmp.mkdir()
    new_tmp.mkdir()
    two_hours_ago = time.time() - 7200  # past TMP_AGE_S, well inside STALE_AGE_S
    os.utime(old_tmp, (two_hours_ago, two_hours_ago))
    kit_sbx.prune_stale([])
    assert not old_tmp.exists() and new_tmp.exists()


def test_git_identity_kit_is_content_addressed(monkeypatch, tmp_path):
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setattr(kit_sbx, "_session", lambda: type("S", (), {
        "host_git_identity_env": staticmethod(lambda: ["GIT_AUTHOR_NAME=Jane"]),
        "_host_git_config": staticmethod(lambda key: None),
    }))
    path = kit_sbx.git_identity_kit()
    slug, text = kit_sbx.git_identity_spec(["GIT_AUTHOR_NAME=Jane"], [])
    stem, digest = path.name.rsplit(".", 1)
    assert stem == f"git-identity-{slug}" and kit_sbx._valid_kit_dir(path, digest)
    # An old-format directory under the bare name is never picked up.
    (path.parent / stem).mkdir()
    (path.parent / stem / "spec.yaml").write_text("stale", encoding="utf-8")
    assert kit_sbx.git_identity_kit() == path
    assert (path / "spec.yaml").read_text(encoding="utf-8") == text
