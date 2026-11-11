"""Tier-2 tests for the SHA-pinned kit fetch (``kit_fetch``) and its use by both backends.

No test reaches the network: the conftest allows git only its ``file``
transport, and the remote kits here live in a bare repository fixture fetched
over ``file://`` (the scheme allowlist is widened for that alone), the way the
Bash bats tests serve ``kit_translate_fetch`` from a local repository.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path

import pytest

from acq_py import (
    cli,
    errors,
    kit_fetch,
    kit_msb,
    kit_sbx,
    kits,
    kitspec,
    legacy_bash,
    msb,
    sbx,
    security,
    state,
)

GIT = shutil.which("git")
pytestmark = pytest.mark.skipif(GIT is None, reason="needs git")

TEAM_SPEC = """schemaVersion: "hybrid/v1"
kind: mixin
name: team-kit
displayName: Team Kit
description: A kit fetched from a team repository
caps:
  network:
    allow:
      - team.example.test
files:
  - path: /home/agent/team.txt
    mode: "0644"
    source: files/team.txt
"""


def _fixture_env() -> dict[str, str]:
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update({"GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull})
    return env


def _git(*args: str) -> str:
    assert GIT is not None
    proc = subprocess.run([GIT, *args], env=_fixture_env(), check=True, capture_output=True, text=True)
    return proc.stdout.strip()


def _write(root: Path, rel: str, text: str) -> None:
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def _commit(src: Path, message: str) -> str:
    _git("-C", str(src), "add", "-A")
    _git("-C", str(src), "-c", "user.name=Fixture", "-c", "user.email=fixture@example.test",
         "-c", "commit.gpgsign=false", "commit", "-q", "-m", message)
    return _git("-C", str(src), "rev-parse", "HEAD")


@dataclass
class KitRepo:
    bare: Path
    pin: str
    pin2: str

    @property
    def url(self) -> str:
        return self.bare.as_uri()

    def ref(self, directory: str = "kits/team", commit: str | None = None) -> str:
        return f"git+{self.url}#ref={commit or self.pin}&dir={directory}"


@pytest.fixture
def kit_repo(tmp_path_factory, monkeypatch) -> KitRepo:
    if os.name == "nt":
        # The fixture commits symlinks and executable modes, which a default
        # Windows checkout does not create (KNOWN_FAILURE_MODES section 55).
        pytest.skip("the kit repository fixture needs POSIX symlinks and modes")
    monkeypatch.setattr(kit_fetch, "SCHEMES", ("https", "file"))
    root = tmp_path_factory.mktemp("kitsrc")
    src = root / "src"
    src.mkdir()
    _git("init", "-q", str(src))
    _write(src, "kits/team/spec.yaml", TEAM_SPEC)
    _write(src, "kits/team/files/team.txt", "first\n")
    _write(src, "kits/team/files/tool", "#!/bin/sh\n")
    (src / "kits/team/files/tool").chmod(0o755)
    (src / "kits/team/files/link").symlink_to("tool")
    _write(src, "kits/team/.gitattributes", "files/team.txt export-ignore\n")
    _write(src, "kits/escape/spec.yaml", TEAM_SPEC.replace("team-kit", "escape-kit"))
    (src / "kits/escape/files").mkdir(parents=True)
    (src / "kits/escape/files/out").symlink_to("../../team/spec.yaml")
    _write(src, "kits/native/spec.yaml", 'schemaVersion: "2"\nkind: mixin\nname: native-kit\n')
    _write(src, "kits/badname/spec.yaml", TEAM_SPEC.replace("name: team-kit", "name: ../team"))
    _write(src, "kits/ports/spec.yaml", TEAM_SPEC.replace("name: team-kit", "name: ports-kit")
           + "publishedPorts:\n  - guest: 8080\n")
    provider = src / "kits/provider"
    shutil.copytree(kitspec.BUNDLE_DIR / "usai-provider", provider)
    facts = provider / "provider-input" / "facts.json"
    doc = json.loads(facts.read_text(encoding="utf-8"))
    doc.update({"host": "evil.example.test", "baseUrl": "https://evil.example.test/api/v1",
                "modelsUrl": "https://evil.example.test/api/v1/models"})
    facts.write_text(json.dumps(doc), encoding="utf-8")
    pin = _commit(src, "first")
    _write(src, "kits/team/files/team.txt", "second\n")
    pin2 = _commit(src, "second")
    bare = root / "kits.git"
    _git("clone", "-q", "--bare", str(src), str(bare))
    return KitRepo(bare, pin, pin2)


class _GitSpy:
    """Counts kit_fetch's git fetches and records the environment of each."""

    def __init__(self, monkeypatch, rewrite=None):
        self.fetches: list[dict[str, str]] = []
        real = kit_fetch._git

        def spy(git, args, *, env, timeout):
            if "fetch" in args:
                self.fetches.append(dict(env))
                if rewrite is not None:
                    args = rewrite(list(args))
            return real(git, args, env=env, timeout=timeout)

        monkeypatch.setattr(kit_fetch, "_git", spy)


# ---------------------------------------------------------------------------
# The ref grammar (Bash kit_translate_fetch, plus the stricter Python rules).
# ---------------------------------------------------------------------------

SHA = "0123456789abcdef0123456789abcdef01234567"
GOOD = f"git+https://github.com/acme/kits.git#ref={SHA}&dir=kits/one"


def test_a_pinned_https_ref_parses():
    ref = kit_fetch.parse_ref(GOOD)
    assert (ref.url, ref.commit, ref.directory) == ("https://github.com/acme/kits.git", SHA, "kits/one")


def test_the_dir_spelling_is_normalized():
    ref = kit_fetch.parse_ref(f"git+https://h.example/r.git#ref={'f' * 40}&dir=././kits//./one/.")
    assert (ref.commit, ref.directory) == ("f" * 40, "kits/one")
    assert kit_fetch.parse_ref(f"git+https://h.example/r.git#ref={SHA}&dir=.").directory == ""


@pytest.mark.parametrize(("ref", "code", "phrase"), [
    (f"git+https://user:hunter2-token@github.com/acme/kits.git#ref={SHA}&dir=k", errors.VALIDATION_FAILED,
     "credential-bearing"),
    (f"git+https://hunter2-token@github.com/acme/kits.git#ref={SHA}&dir=k", errors.VALIDATION_FAILED,
     "credential-bearing"),
    ("git+https://github.com/acme/kits.git#ref=main&dir=k", errors.KIT_REF_NOT_PINNED, "not pinned"),
    ("git+https://github.com/acme/kits.git#ref=0123456&dir=k", errors.KIT_REF_NOT_PINNED, "not pinned"),
    (f"git+https://github.com/acme/kits.git#ref={SHA.upper()}&dir=k", errors.KIT_REF_NOT_PINNED, "not pinned"),
    (f"git+https://github.com/acme/kits.git#ref={SHA}0&dir=k", errors.KIT_REF_NOT_PINNED, "not pinned"),
    (f"git+http://github.com/acme/kits.git#ref={SHA}&dir=k", errors.VALIDATION_FAILED, "https only"),
    (f"git+ssh://github.com/acme/kits.git#ref={SHA}&dir=k", errors.VALIDATION_FAILED, "https only"),
    (f"git+https://github.com/acme/kits.git?private_token=hunter2-token#ref={SHA}&dir=k",
     errors.VALIDATION_FAILED, "its URL has a query string"),
    (f"git+https://github.com/acme/kits.git#ref={SHA}&dir=k&token=hunter2-token",
     errors.VALIDATION_FAILED, "parameter other than ref= and dir="),
    (f"git+https://github.com/acme/kits.git#hunter2-token&ref={SHA}&dir=k",
     errors.VALIDATION_FAILED, "parameter other than ref= and dir="),
    (f"git+https://github.com/acme/kits.git#ref={SHA}&&dir=k", errors.VALIDATION_FAILED,
     "parameter other than ref= and dir="),
    (f"git+https://github.com/acme/k%2e%2e/kits.git#ref={SHA}&dir=k", errors.VALIDATION_FAILED, "does not accept"),
    (f"git+https://github.com/acme/../kits.git#ref={SHA}&dir=k", errors.VALIDATION_FAILED, "does not accept"),
    (f"git+https://github.com/acme/kits.git#ref={SHA}&dir=../escape", errors.VALIDATION_FAILED, "unsafe kit dir"),
    (f"git+https://github.com/acme/kits.git#ref={SHA}&dir=/abs", errors.VALIDATION_FAILED, "unsafe kit dir"),
    (f"git+https://github.com/acme/kits.git#ref={SHA}&dir=a$(id)", errors.VALIDATION_FAILED, "holds a character outside"),
    (f"git+https://github.com/acme/kits.git#ref={SHA}", errors.VALIDATION_FAILED, "malformed"),
    ("git+https://github.com/acme/kits.git", errors.VALIDATION_FAILED, "malformed"),
    (f"git+file:///srv/kits.git#ref={SHA}&dir=k", errors.VALIDATION_FAILED, "https only"),
])
def test_unsafe_or_unpinned_refs_are_refused(ref, code, phrase):
    with pytest.raises(kit_fetch.KitFetchError) as info:
        kit_fetch.parse_ref(ref)
    assert info.value.code == code
    assert phrase in info.value.message
    assert "hunter2" not in info.value.message + info.value.remediation


def test_ref_display_redacts_like_bash_kit_ref_display():
    assert kit_fetch.ref_display("git+https://u:tok@h.example/r.git#ref=x&dir=k") == "git+https://***@h.example/r.git#ref=x&dir=k"
    assert kit_fetch.ref_display("git+https://h.example/r.git?private_token=tok#ref=x") == "git+https://h.example/r.git?***#ref=x"
    assert kit_fetch.ref_display("u:tok@h.example/r") == "***@h.example/r"
    assert kit_fetch.ref_display(GOOD) == GOOD
    assert kit_fetch.ref_display("git+https://h.example/r.git#ref=x&dir=k&token=tok") == "git+https://h.example/r.git#ref=x&dir=k&***"


def _probes() -> list[tuple[str, str, str]]:
    """test/fixtures/kit-ref-probes.tsv, which test/bats/170-kit-ref-shape.bats reads too."""
    path = Path(__file__).resolve().parents[2] / "test" / "fixtures" / "kit-ref-probes.tsv"
    rows = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if line and not line.startswith("#"):
            verdict, shown, ref = line.split("\t")
            rows.append((verdict, shown, ref))
    return rows


def test_remote_ref_problem_and_ref_display_agree_with_the_shared_probes():
    rows = _probes()
    assert len(rows) >= 20
    for verdict, shown, ref in rows:
        problem = kits.remote_ref_problem(ref)
        assert ("refuse" if problem else "pass") == verdict, ref
        assert kit_fetch.ref_display(ref) == shown, ref
        assert "SEKRIT" not in (problem or "")


@pytest.mark.parametrize("ref", [
    f"git+https://kits.example/acme/kits.git#ref={SHA}?token=hunter2-token&dir=k",
    f"git+https://kits.example/acme/kits.git#ref={SHA};token=hunter2-token&dir=k",
    f"git+https://kits.example/acme/kits.git#ref={SHA}#token=hunter2-token&dir=k",
    f"git+https://kits.example/acme/kits.git#ref={SHA}&ref=hunter2-token&dir=k",
    f"git+https://kits.example/acme/kits.git#ref={SHA}&dir=k?x=hunter2-token",
])
def test_a_ref_or_dir_value_with_odd_characters_or_a_repeat_is_refused(ref):
    for kwargs in ({"cli_kits": [ref], "env": {}}, {"env": {"ACQ_EXTRA_KITS": ref}},
                   {"env": {"ACQ_PROVIDER_KITS": ref}}):
        with pytest.raises(kitspec.KitSelectionError) as info:
            kitspec.select_kits(None, ready=lambda _agent: False, **kwargs)
        assert "remote kit ref refused" in str(info.value) and "hunter2" not in str(info.value)
    with pytest.raises(kit_fetch.KitFetchError) as fetch_info:
        kit_fetch.parse_ref(ref)
    assert "hunter2" not in fetch_info.value.message + fetch_info.value.remediation


@pytest.mark.parametrize("ref", [
    f"git+https://kits.example/acme/kits.git?private_token=hunter2-token#ref={SHA}&dir=k",
    f"git+https://kits.example/acme/kits.git#ref={SHA}&dir=k&token=hunter2-token",
])
def test_a_query_or_extra_fragment_parameter_is_refused_without_naming_the_ref(ref):
    # Named neither in the message nor the remediation: not the host, not the
    # parameter, not the value.
    with pytest.raises(kit_fetch.KitFetchError) as info:
        kit_fetch.parse_ref(ref)
    text = info.value.message + info.value.remediation
    assert "remote kit ref refused" in info.value.message
    for part in ("hunter2", "token", "kits.example"):
        assert part not in text


@pytest.mark.parametrize("ref", [
    f"git+https://kits.example/acme/kits.git?private_token=hunter2-token#ref={SHA}&dir=k",
    f"git+https://kits.example/acme/kits.git#ref={SHA}&dir=k&token=hunter2-token",
])
def test_select_kits_refuses_a_query_or_extra_parameter_at_input(ref):
    for kwargs in ({"cli_kits": [ref], "env": {}}, {"env": {"ACQ_EXTRA_KITS": f"/kits/fine {ref}"}}):
        with pytest.raises(kitspec.KitSelectionError) as info:
            kitspec.select_kits(None, ready=lambda _agent: False, **kwargs)
        assert "remote kit ref refused" in str(info.value)
        assert "hunter2" not in str(info.value) and "kits.example" not in str(info.value)


def test_canonical_refs_and_local_paths_with_query_or_hash_characters_pass_selection(tmp_path):
    odd = tmp_path / ("odd#name" if os.name == "nt" else "odd?name#1")  # Windows forbids '?' in a name
    odd.mkdir()
    selection = kitspec.select_kits(None, cli_kits=[str(odd), GOOD], env={}, ready=lambda _agent: False)
    assert [k.ref for k in selection.kits if k.role == "cli"] == [str(odd), GOOD]
    assert kits.remote_ref_problem(str(odd)) is None and kits.remote_ref_problem(GOOD) is None


# ---------------------------------------------------------------------------
# Fetch, verify, materialize.
# ---------------------------------------------------------------------------


def test_fetch_materializes_the_pinned_tree_and_reuses_it(kit_repo, monkeypatch):
    spy = _GitSpy(monkeypatch)
    kit = kit_fetch.fetch(kit_repo.ref(), "msb")
    # The pinned commit's content, not the later one; export-ignore files are
    # kept (checkout-index, not git archive), as are modes and links.
    assert (kit / "files" / "team.txt").read_text(encoding="utf-8") == "first\n"
    assert os.access(kit / "files" / "tool", os.X_OK)
    assert (kit / "files" / "link").is_symlink()
    cache = Path(os.environ["XDG_CACHE_HOME"]) / "acq" / "kits" / kit_fetch.PY_DIR
    assert cache in kit.parents
    assert len(spy.fetches) == 1
    assert kit_fetch.fetch(kit_repo.ref(), "msb") == kit  # a later command reuses it
    other = kit_fetch.fetch(kit_repo.ref("kits/native"), "msb")  # same commit, another kit: no new fetch
    assert (other / "spec.yaml").is_file()
    assert len(spy.fetches) == 1
    later = kit_fetch.fetch(kit_repo.ref(commit=kit_repo.pin2), "msb")
    assert (later / "files" / "team.txt").read_text(encoding="utf-8") == "second\n"
    assert len(spy.fetches) == 2


def test_the_sbx_cache_is_separate_and_honours_its_override(kit_repo, tmp_path, monkeypatch):
    monkeypatch.setenv("ACQ_SBX_KIT_CACHE", str(tmp_path / "sbx-cache"))
    kit = kit_fetch.fetch(kit_repo.ref(), "sbx")
    assert tmp_path / "sbx-cache" / kit_fetch.PY_DIR in kit.parents
    monkeypatch.setenv("ACQ_SBX_KIT_CACHE", "relative/cache")
    with pytest.raises(kit_fetch.KitFetchError, match="must be an absolute path"):
        kit_fetch.fetch(kit_repo.ref(), "sbx")


def test_a_cached_kit_is_reused_offline(kit_repo, monkeypatch):
    first = kit_fetch.fetch(kit_repo.ref(), "msb")
    kit_repo.bare.rename(kit_repo.bare.with_name("gone.git"))
    assert kit_fetch.fetch(kit_repo.ref(), "msb") == first


def test_a_revision_other_than_the_pin_is_refused_and_not_cached(kit_repo, monkeypatch):
    # The server answers with another commit (Bash's WRONG_REVISION case).
    _GitSpy(monkeypatch, rewrite=lambda args: [kit_repo.pin2 if a == kit_repo.pin else a for a in args])
    with pytest.raises(kit_fetch.KitFetchError) as info:
        kit_fetch.fetch(kit_repo.ref(), "msb")
    assert info.value.code == errors.VALIDATION_FAILED
    assert "does not match the pinned commit" in info.value.message
    monkeypatch.undo()
    monkeypatch.setattr(kit_fetch, "SCHEMES", ("https", "file"))
    spy = _GitSpy(monkeypatch)
    kit = kit_fetch.fetch(kit_repo.ref(), "msb")  # nothing unverified was kept: it fetches again
    assert len(spy.fetches) == 1
    assert (kit / "files" / "team.txt").read_text(encoding="utf-8") == "first\n"


def test_a_damaged_cached_source_is_fetched_again(kit_repo, monkeypatch):
    kit_fetch.fetch(kit_repo.ref(), "msb")
    _base, src, tree = kit_fetch._cache_dirs("msb")
    for entry in src.iterdir():
        (entry / kit_fetch.VERIFIED_MARKER).write_text("0" * 40 + "\n", encoding="utf-8")
    for entry in tree.iterdir():
        shutil.rmtree(entry)
    spy = _GitSpy(monkeypatch)
    assert (kit_fetch.fetch(kit_repo.ref(), "msb") / "spec.yaml").is_file()
    assert len(spy.fetches) == 1


def test_a_failed_fetch_fails_closed_without_git_output(kit_repo, monkeypatch):
    spy = _GitSpy(monkeypatch)
    missing = kit_repo.bare.with_name("missing.git").as_uri()
    with pytest.raises(kit_fetch.KitFetchError) as info:
        kit_fetch.fetch(f"git+{missing}#ref={kit_repo.pin}&dir=kits/team", "msb")
    assert info.value.code == errors.FAILURE
    assert "details suppressed" in info.value.message
    assert "fatal" not in info.value.message and "does not appear" not in info.value.message
    # The anonymous attempt read no git config files; only the retry read the user's.
    assert [e.get("GIT_CONFIG_GLOBAL") == os.devnull for e in spy.fetches] == [True, False]
    assert all(e["GIT_TERMINAL_PROMPT"] == "0" and "GIT_ASKPASS" not in e for e in spy.fetches)
    _base, src, _tree = kit_fetch._cache_dirs("msb")
    assert list(src.iterdir()) == []


def test_the_retry_uses_the_users_git_config(kit_repo, monkeypatch):
    # An enterprise mirror reached only through the user's URL rewrite: the
    # anonymous attempt (no config files) fails, the retry with config succeeds.
    alias = kit_repo.bare.with_name("alias.git").as_uri()
    gitconfig = Path(os.environ["HOME"]) / ".gitconfig"
    gitconfig.write_text(f'[url "{kit_repo.url}"]\n\tinsteadOf = {alias}\n', encoding="utf-8")
    spy = _GitSpy(monkeypatch)
    kit = kit_fetch.fetch(f"git+{alias}#ref={kit_repo.pin}&dir=kits/team", "msb")
    assert (kit / "spec.yaml").is_file()
    assert len(spy.fetches) == 2


def test_the_users_global_hooks_never_run_in_the_cache(kit_repo, tmp_path, monkeypatch):
    # The retry reads the user's config. A by-commit shallow fetch runs the
    # reference-transaction hook, so a global core.hooksPath would run it in
    # acq's cache repository unless the fetch overrides it.
    hooks = tmp_path / "hooks"
    hooks.mkdir()
    marker = tmp_path / "hook-ran"
    (hooks / "reference-transaction").write_text(f"#!/bin/sh\n: > '{marker}'\n", encoding="utf-8")
    (hooks / "reference-transaction").chmod(0o755)
    alias = kit_repo.bare.with_name("alias.git").as_uri()
    gitconfig = Path(os.environ["HOME"]) / ".gitconfig"
    gitconfig.write_text(f'[core]\n\thooksPath = {hooks}\n[url "{kit_repo.url}"]\n\tinsteadOf = {alias}\n',
                         encoding="utf-8")
    spy = _GitSpy(monkeypatch)
    kit = kit_fetch.fetch(f"git+{alias}#ref={kit_repo.pin}&dir=kits/team", "msb")
    assert (kit / "spec.yaml").is_file()
    assert len(spy.fetches) == 2  # the retry, with the user's config, did the fetch
    assert not marker.exists()


def test_the_attempt_without_config_may_use_only_kit_url_transports(kit_repo, monkeypatch):
    spy = _GitSpy(monkeypatch)
    missing = kit_repo.bare.with_name("missing.git").as_uri()
    with pytest.raises(kit_fetch.KitFetchError):
        kit_fetch.fetch(f"git+{missing}#ref={kit_repo.pin}&dir=kits/team", "msb")
    # The conftest allows git only "file"; the product never widens that.
    assert [e.get("GIT_ALLOW_PROTOCOL") for e in spy.fetches] == ["file", "file"]
    monkeypatch.setattr(kit_fetch, "SCHEMES", ("https",))
    assert kit_fetch._allowed_protocols(None) == "https"
    assert kit_fetch._allowed_protocols("https:ssh:file") == "https"
    assert kit_fetch._allowed_protocols("file") == "acq-none"
    monkeypatch.delenv("GIT_ALLOW_PROTOCOL")
    assert kit_fetch._env(user_config=False)["GIT_ALLOW_PROTOCOL"] == "https"
    # The retry leaves the transport to the user (an insteadOf rewrite may use ssh).
    assert "GIT_ALLOW_PROTOCOL" not in kit_fetch._env(user_config=True)


@pytest.mark.skipif(not hasattr(os, "getuid"), reason="POSIX ownership check")
def test_a_cache_directory_owned_by_another_user_is_refused(kit_repo, monkeypatch):
    kit_fetch._cache_dirs("msb")  # created by this user
    real = os.getuid()
    monkeypatch.setattr(kit_fetch.os, "getuid", lambda: real + 1)
    with pytest.raises(kit_fetch.KitFetchError, match="owned by another user"):
        kit_fetch.fetch(kit_repo.ref(), "msb")


def test_a_cached_tree_without_its_complete_marker_is_rebuilt(kit_repo, monkeypatch):
    kit = kit_fetch.fetch(kit_repo.ref(), "msb")
    (kit.parent / kit_fetch.COMPLETE_MARKER).unlink()  # e.g. a crash before the marker
    (kit / "files" / "team.txt").write_text("tampered\n", encoding="utf-8")
    (kit / "planted").write_text("x\n", encoding="utf-8")
    spy = _GitSpy(monkeypatch)
    again = kit_fetch.fetch(kit_repo.ref(), "msb")
    assert again == kit
    assert (again / "files" / "team.txt").read_text(encoding="utf-8") == "first\n"
    assert not (again / "planted").exists()
    assert (again.parent / kit_fetch.COMPLETE_MARKER).is_file()
    assert spy.fetches == []  # rebuilt from the verified source, no new fetch


def test_inherited_git_redirects_and_config_injection_do_not_reach_the_cache(kit_repo, tmp_path, monkeypatch):
    other = tmp_path / "other"
    _git("init", "-q", str(other))
    before = (other / ".git" / "config").read_text(encoding="utf-8")
    hooks = tmp_path / "hooks"
    hooks.mkdir()
    marker = tmp_path / "hook-ran"
    for hook in ("post-checkout", "reference-transaction", "post-index-change"):
        (hooks / hook).write_text(f"#!/bin/sh\n: > '{marker}'\n", encoding="utf-8")
        (hooks / hook).chmod(0o755)
    monkeypatch.setenv("GIT_DIR", str(other / ".git"))
    monkeypatch.setenv("GIT_WORK_TREE", str(other))
    monkeypatch.setenv("GIT_INDEX_FILE", str(other / ".git" / "index"))
    monkeypatch.setenv("GIT_CONFIG_PARAMETERS", f"'core.hookspath'='{hooks}'")
    monkeypatch.setenv("GIT_CONFIG_COUNT", "1")
    monkeypatch.setenv("GIT_CONFIG_KEY_0", "core.hooksPath")
    monkeypatch.setenv("GIT_CONFIG_VALUE_0", str(hooks))
    monkeypatch.setenv("GIT_ASKPASS", str(hooks / "post-checkout"))
    kit = kit_fetch.fetch(kit_repo.ref(), "msb")
    assert (kit / "spec.yaml").is_file()
    assert (other / ".git" / "config").read_text(encoding="utf-8") == before
    assert not (other / ".git" / "index").exists()
    assert not marker.exists()


def test_a_missing_kit_directory_is_refused(kit_repo):
    with pytest.raises(kit_fetch.KitFetchError, match="remote kit directory not found"):
        kit_fetch.fetch(kit_repo.ref("kits/missing"), "msb")


def test_a_payload_link_out_of_the_kit_is_refused_and_not_published(kit_repo):
    with pytest.raises(kit_fetch.KitFetchError) as info:
        kit_fetch.fetch(kit_repo.ref("kits/escape"), "msb")
    assert "symlink" in info.value.message
    _base, _src, tree = kit_fetch._cache_dirs("msb")
    assert [p for p in tree.iterdir() if not p.name.startswith(".")] == []
    assert list(tree.iterdir()) == []


def test_a_linked_cache_directory_is_refused(kit_repo, tmp_path):
    root = kit_fetch.cache_root("msb")
    root.mkdir(parents=True)
    elsewhere = tmp_path / "elsewhere"
    elsewhere.mkdir()
    (root / kit_fetch.PY_DIR).symlink_to(elsewhere, target_is_directory=True)
    with pytest.raises(kit_fetch.KitFetchError, match="not a directory acq created"):
        kit_fetch.fetch(kit_repo.ref(), "msb")
    assert list(elsewhere.iterdir()) == []


def test_git_missing_and_a_hung_git_fail_closed(kit_repo, monkeypatch):
    monkeypatch.setattr(kit_fetch.hostexec, "which", lambda name, path=None: None)
    with pytest.raises(kit_fetch.KitFetchError, match="git is required"):
        kit_fetch.fetch(kit_repo.ref(), "msb")
    monkeypatch.undo()
    monkeypatch.setattr(kit_fetch, "SCHEMES", ("https", "file"))

    def hung(*_args, **kwargs):
        raise subprocess.TimeoutExpired(["git"], kwargs.get("timeout", 0))

    monkeypatch.setattr(kit_fetch.subprocess, "run", hung)
    with pytest.raises(kit_fetch.KitFetchError) as info:
        kit_fetch.fetch(kit_repo.ref(), "msb")
    assert info.value.code == errors.TIMEOUT


@pytest.mark.parametrize(("directory", "code", "phrase"), [
    ("kits/native", errors.UNSUPPORTED, "not a neutral hybrid/v1 kit"),
    ("kits/badname", errors.VALIDATION_FAILED, "unsafe or missing name"),
])
def test_load_refuses_kits_it_cannot_name_or_apply(kit_repo, directory, code, phrase):
    with pytest.raises(kit_fetch.KitFetchError) as info:
        kit_fetch.load(kit_repo.ref(directory), "msb")
    assert (info.value.code, phrase in info.value.message) == (code, True)


# ---------------------------------------------------------------------------
# Both backends apply fetched kits.
# ---------------------------------------------------------------------------


def _invoke(capsys, *argv):
    rc = cli.main(list(argv))
    captured = capsys.readouterr()
    out = captured.out.strip()
    return rc, (json.loads(out.splitlines()[-1]) if out else None), captured.err


def _msb_env(monkeypatch, tmp_path) -> Path:
    monkeypatch.setattr(security, "WINDOWS", False)
    monkeypatch.setenv("ACQ_MSB_BIN", "__stub__")
    monkeypatch.setenv("ACQ_MSB_VERSION", "0.7.7")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "1")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "0")
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("MSB_HOME", str(tmp_path / "msb-home"))
    monkeypatch.setenv("ACQ_MSB_RO_INSPECT_RETRY_SLEEP", "0")
    ws = tmp_path / "ws"
    ws.mkdir(exist_ok=True)
    return ws


def _sbx_env(monkeypatch, tmp_path) -> Path:
    monkeypatch.setenv("ACQ_SBX_BIN", "__stub__")
    monkeypatch.setenv("ACQ_SBX_VERSION", "0.51.0")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "1")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "0")
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("SBX_HOME", str(tmp_path / "sbx-home"))
    monkeypatch.setenv(kit_sbx.BARRIER_TIMEOUT_ENV, "5")
    monkeypatch.setattr(kit_sbx, "BARRIER_POLL_S", 0.01)
    ws = tmp_path / "ws"
    ws.mkdir(exist_ok=True)
    return ws


def _spy(monkeypatch, module) -> list[list[str]]:
    seen: list[list[str]] = []
    real = module._run

    def spy(argv, **kwargs):
        seen.append(list(argv))
        return real(argv, **kwargs)

    monkeypatch.setattr(module, "_run", spy)
    return seen


@pytest.mark.provider_key
def test_msb_create_applies_a_fetched_extra_kit_with_its_own_egress(kit_repo, monkeypatch, tmp_path, capsys):
    ws = _msb_env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_EXTRA_KITS", kit_repo.ref())
    seen = _spy(monkeypatch, msb)
    rc, doc, err = _invoke(capsys, "--backend", "msb", "create", "shell", str(ws), "--name", "fx", "--json")
    assert rc == 0, err
    assert "team-kit" in doc["data"]["kits"]
    (create,) = [a for a in seen if a[0] == "create"]
    assert "allow@team.example.test" in create  # read from the fetched spec, not the built-in table
    # Recorded for later heals (a git+https ref reads back; this file:// one is test-only).
    record = legacy_bash.cli_kits_file("msb", "fx").read_text(encoding="utf-8")
    assert f"extra={kit_repo.ref()}\n" in record
    assert kit_repo.ref() not in " ".join(create)  # msb never sees the ref itself


@pytest.mark.provider_key
def test_msb_heal_uses_the_cached_kit_when_the_source_is_gone(kit_repo, monkeypatch, tmp_path):
    _msb_env(monkeypatch, tmp_path)
    first = kit_msb.select("shell", [kit_repo.ref()], image_is_default=False, extras=[])
    kit_repo.bare.rename(kit_repo.bare.with_name("gone.git"))
    again = kit_msb.select("shell", [kit_repo.ref()], image_is_default=False, extras=[])
    assert [k.name for k in again] == [k.name for k in first]
    assert again[-1].fetched and again[-1].spec.kit_dir == first[-1].spec.kit_dir


@pytest.mark.provider_key
def test_msb_publishes_a_fetched_kit_s_ports_on_a_free_host_port(kit_repo, monkeypatch, tmp_path, capsys):
    ws = _msb_env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_MSB_HOST_PROBE_STUB", "1")
    seen = _spy(monkeypatch, msb)
    rc, doc, err = _invoke(capsys, "--backend", "msb", "create", "shell", str(ws), "--name", "fp",
                           "--kit", kit_repo.ref("kits/ports"), "--json")
    assert rc == 0, err
    (create,) = [a for a in seen if a[0] == "create"]
    (mapping,) = [create[i + 1] for i, a in enumerate(create) if a == "-p"]
    host, guest = mapping.split(":")
    assert guest == "8080" and host != "8080"
    assert doc["data"]["ports"] == [{"host_port": int(host), "guest_port": 8080, "origin": "create"}]


@pytest.mark.provider_key
def test_sbx_create_hands_sbx_only_the_translated_fetched_kit(kit_repo, monkeypatch, tmp_path, capsys):
    ws = _sbx_env(monkeypatch, tmp_path)
    seen = _spy(monkeypatch, sbx)
    rc, doc, err = _invoke(capsys, "--backend", "sbx", "create", "shell", str(ws), "--name", "fs",
                           "--kit", kit_repo.ref(), "--json")
    assert rc == 0, err
    assert "team-kit" in doc["data"]["kits"]
    (create,) = [a for a in seen if a[0] == "create"]
    kit_dirs = [Path(create[i + 1]) for i, a in enumerate(create[:-1]) if a == "--kit"]
    team = [d for d in kit_dirs if d.name.startswith("team-kit.")]
    assert len(team) == 1 and kit_sbx.kit_root() in team[0].parents
    assert (team[0] / "files" / "team.txt").read_text(encoding="utf-8") == "first\n"
    assert not [a for a in create if "git+" in a or kit_repo.url in a]
    assert state.record_read("sbx", "fs") is not None


@pytest.mark.provider_key
@pytest.mark.parametrize("backend", ["msb", "sbx"])
def test_a_credential_bearing_ref_is_refused_and_never_echoed(monkeypatch, tmp_path, capsys, backend):
    ws = (_msb_env if backend == "msb" else _sbx_env)(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_EXTRA_KITS", f"git+https://user:hunter2-token@github.com/acme/kits.git#ref={SHA}&dir=k")
    seen = _spy(monkeypatch, msb if backend == "msb" else sbx)
    rc, doc, err = _invoke(capsys, "--backend", backend, "create", "shell", str(ws), "--name", "cr", "--json")
    assert rc == 1 and doc["error"]["code"] == errors.VALIDATION_FAILED
    assert "credential-bearing" in doc["error"]["message"]
    assert "hunter2" not in json.dumps(doc) + err
    assert not [a for a in seen if a[0] == "create"]


@pytest.mark.provider_key
def test_a_fetched_provider_kit_cannot_choose_where_the_key_goes(kit_repo, monkeypatch, tmp_path, capsys):
    # A provider kit fetched from a source faces the same pin check as the
    # bundled one: its facts name another host, so the create is refused.
    ws = _msb_env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_PROVIDER_KITS", kit_repo.ref("kits/provider"))
    seen = _spy(monkeypatch, msb)
    rc, doc, _err = _invoke(capsys, "--backend", "msb", "create", "shell", str(ws), "--name", "pv", "--json")
    assert rc == 1 and doc["error"]["code"] == errors.VALIDATION_FAILED
    assert "evil.example.test" in doc["error"]["message"] and "pinned hosts" in doc["error"]["message"]
    assert not [a for a in seen if a[0] == "create"]


@pytest.mark.parametrize("backend", ["msb", "sbx"])
def test_midlife_apply_fetches_and_checks_external_ref(backend, kit_repo, monkeypatch, tmp_path, capsys):
    (_msb_env if backend == "msb" else _sbx_env)(monkeypatch, tmp_path)
    monkeypatch.setenv(f"ACQ_{backend.upper()}_STUB_CATALOG", '{"box":"running"}')
    module = msb if backend == "msb" else sbx
    seen = _spy(monkeypatch, module)
    rc, doc, err = _invoke(capsys, "--backend", backend, "kit", "apply", "box", kit_repo.ref(), "--json")
    assert rc == 0, (doc, err)
    assert doc["data"] == {"sandbox": "box", "backend": backend, "kit": kit_repo.ref(),
                           "entrypoint": "", "applied": True, "action": "applied"}
    assert kits.kit_applied_read(backend, "box") is None
    assert not any(a[0] == "create" for a in seen)
    if backend == "msb":
        assert any(a[0] == "exec" for a in seen)
        assert not any("--script-path" in a for a in seen)
    else:
        add = next(a for a in seen if a[:2] == ["kit", "add"])
        assert kit_repo.ref() not in add
        assert kitspec.load_kit(add[-1]).field("schemaVersion") == "2"


@pytest.mark.parametrize("backend", ["msb", "sbx"])
@pytest.mark.parametrize("entrypoint", ["", "team-agent"])
def test_midlife_external_apply_confirms_to_human(backend, entrypoint, monkeypatch, tmp_path, capsys):
    (_msb_env if backend == "msb" else _sbx_env)(monkeypatch, tmp_path)
    monkeypatch.setenv(f"ACQ_{backend.upper()}_STUB_CATALOG", '{"box":"running"}')
    kit_dir = tmp_path / "human-kit"
    spec = TEAM_SPEC + (f"agent:\n  entrypoint: {entrypoint}\n" if entrypoint else "")
    _write(kit_dir, "spec.yaml", spec)
    _write(kit_dir, "files/team.txt", "hello\n")
    assert cli.main(["--backend", backend, "kit", "apply", "box", str(kit_dir)]) == 0
    suffix = f" (entrypoint {entrypoint})" if entrypoint else ""
    assert capsys.readouterr().out == f"applied kit 'team-kit' to sandbox 'box'{suffix}.\n"
    assert kits.kit_applied_read(backend, "box") is None


def test_midlife_external_startup_kit_requires_sbx_recreate(monkeypatch, tmp_path, capsys):
    _sbx_env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_SBX_STUB_CATALOG", '{"box":"running"}')
    kit_dir = tmp_path / "startup-kit"
    _write(kit_dir, "spec.yaml", TEAM_SPEC +
           "commands:\n  - phase: startup\n    command:\n      - echo\n      - ready\n")
    _write(kit_dir, "files/team.txt", "hello\n")
    seen = _spy(monkeypatch, sbx)
    rc, doc, err = _invoke(capsys, "--backend", "sbx", "kit", "apply", "box", str(kit_dir), "--json")
    assert rc == 1, err
    assert doc["error"]["code"] == errors.UNSUPPORTED
    assert "startup commands" in doc["error"]["message"]
    assert "recreate" in doc["error"]["remediation"]
    assert "session/context" in doc["error"]["remediation"]
    assert any(a[:2] == ["kit", "add"] for a in seen)
    assert not any(a[0] in {"create", "remove", "exec"} for a in seen)
    assert kits.kit_applied_read("sbx", "box") is None


@pytest.mark.parametrize("ref,code", [
    ("git+https://github.com/acme/kits#ref=main&dir=kit", "kit_ref_not_pinned"),
    ("git+https://github.com/acme/kits?token=private#ref=main&dir=kit", "validation_failed"),
    ("git+https://github.com/acme/kits#ref=main&dir=kit&token=private", "validation_failed"),
    ("git+https://user:private@github.com/acme/kits#ref=main&dir=kit", "validation_failed"),
])
def test_midlife_apply_refuses_unsafe_or_unpinned_ref(ref, code, monkeypatch, tmp_path, capsys):
    _msb_env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_MSB_STUB_CATALOG", '{"box":"running"}')
    monkeypatch.setattr(kit_fetch, "_git", lambda *a, **k: pytest.fail("refusal must precede git"))
    rc, doc, err = _invoke(capsys, "--backend", "msb", "kit", "apply", "box", ref, "--json")
    assert rc == 1 and doc["error"]["code"] == code
    assert "private" not in json.dumps(doc) + err
