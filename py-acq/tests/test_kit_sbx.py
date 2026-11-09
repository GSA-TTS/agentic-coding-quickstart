"""Tier-2 tests for sbx kit application (ADR-0011, ADR-0017, ADR-0037).

Covers ``kit_sbx``: the neutral-to-sbx-v2 translator, compared file by file
with Bash ``kit_translate_to_sbx`` on the bundled kits, the legacy fixtures and
the kitspec parity corpora; the generated git identity and startup barrier
kits, compared with ``_acq_sbx_git_identity_kit`` and
``_acq_sbx_startup_barrier_kit``; and the create/run/kit flow that uses them,
against the deterministic ``__stub__`` sbx.
"""

from __future__ import annotations

import json
import os
import random
import shutil
import stat
import subprocess
from pathlib import Path

import pytest

from acq_py import cli, errors, kit_sbx, kits, kitspec, sbx, state
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
    "tab-skipped": ({"GIT_AUTHOR_NAME": "a\tb", "GIT_AUTHOR_EMAIL": "ok@x.gov"}, "[user]\n\tname = N\n"),
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
    # Translating again replaces the earlier copy.
    (path / "stale").write_text("x", encoding="utf-8")
    assert not (kit_sbx.translated_kit(kit) / "stale").exists()
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
