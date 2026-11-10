"""Shared fixtures for the pytest vector runner.

The CLI-under-test is driven as a subprocess (contract evidence is subprocess-only,
ADR-0039m). ``PYTHONPATH`` is extended here so both the in-process imports and the
subprocess ``python -m acq_py`` resolve the package without an installed copy.
"""

from __future__ import annotations

import io
import json
import os
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
PY_ACQ_SRC = REPO_ROOT / "py-acq" / "src"
VECTORS_DIR = REPO_ROOT / "test" / "vectors"

_sep = os.pathsep
_existing = os.environ.get("PYTHONPATH")
os.environ["PYTHONPATH"] = str(PY_ACQ_SRC) + (_sep + _existing if _existing else "")
sys.path.insert(0, str(PY_ACQ_SRC))

# The checks against the real pinned Patterns tree (the kit egress allowlist and
# the packaged kit bundle) need a checkout of Patterns at the pin, which CI
# provides through ACQ_TEST_PATTERNS_REPO. Capture it before the ACQ_* scrub
# below removes it; it is handed to those tests by the pinned_patterns_repo
# fixture and never put back into the environment acq runs under.
_PINNED_PATTERNS_REPO = os.environ.get("ACQ_TEST_PATTERNS_REPO", "")

# The Windows launcher tests run acq.ps1 under PowerShell 7 too. ACQ_TEST_PWSH
# names a pwsh.exe to use instead of the one on PATH; ACQ_TEST_REQUIRE_PWSH=1
# (set in CI) makes a missing pwsh fail those tests instead of skipping them.
# Captured before the scrub for the same reason, and handed over by the
# pwsh_test_settings fixture.
_TEST_PWSH = os.environ.get("ACQ_TEST_PWSH", "")
_REQUIRE_PWSH = os.environ.get("ACQ_TEST_REQUIRE_PWSH", "") == "1"

# Collection imports acq_py before any function fixture runs. The timeout
# tunables are now read lazily, but clear inherited ACQ_* here as well so a
# developer's shell cannot change anything read during import.
for _var in [v for v in os.environ if v.startswith("ACQ_")]:
    del os.environ[_var]


REAL_HOME = os.path.expanduser("~")
_USER_DIR_VARS = ("XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME")
# Backend-stub homes are consulted before HOME; a developer's export must not leak in.
_BACKEND_HOME_VARS = ("MSB_HOME", "SBX_HOME")


@pytest.fixture
def pinned_patterns_repo() -> Path:
    """The checkout of Patterns at the pin that CI provides, or skip without one.

    Ordinary test runs never fetch, so these checks skip locally unless
    ACQ_TEST_PATTERNS_REPO names such a checkout.
    """
    if not _PINNED_PATTERNS_REPO:
        pytest.skip("pinned Patterns checkout is provided by CI via ACQ_TEST_PATTERNS_REPO")
    return Path(_PINNED_PATTERNS_REPO)


@pytest.fixture(scope="session")
def pwsh_test_settings() -> tuple[str, bool]:
    """``(ACQ_TEST_PWSH, ACQ_TEST_REQUIRE_PWSH == "1")`` as the test run started."""
    return _TEST_PWSH, _REQUIRE_PWSH


@pytest.fixture(autouse=True)
def isolate_user_dirs(tmp_path_factory, monkeypatch):
    """Keep every test away from the developer's real home and acq state.

    Mutating verbs run the state/config migration, which resolves
    ``$XDG_CONFIG_HOME`` / ``$HOME/.config`` and ``$XDG_STATE_HOME``; a test that
    only redirected ``ACQ_STATE_DIR`` would otherwise rewrite a real
    ``~/.config/acq/config.yaml``. ``ACQ_*`` variables inherited from the
    developer's shell (``ACQ_BACKEND``, ``ACQ_IMPL``, adapter overrides) are
    cleared so they cannot change a test's outcome. Subprocess-driven tests
    inherit the redirected environment.
    """
    root = tmp_path_factory.mktemp("user-dirs")
    home = root / "home"
    home.mkdir()
    monkeypatch.setenv("HOME", str(home))
    for var in _USER_DIR_VARS:
        path = root / var.lower()
        path.mkdir()
        monkeypatch.setenv(var, str(path))
    for var in [v for v in os.environ if v.startswith("ACQ_")] + list(_BACKEND_HOME_VARS):
        monkeypatch.delenv(var, raising=False)
    # A developer's real ssh-agent must never be forwarded into a stub sandbox
    # (or change what a create prints): SSH_AUTH_SOCK is the forward's opt-in
    # (ADR-0021). The forward's process-scoped state starts clean in every test.
    monkeypatch.delenv("SSH_AUTH_SOCK", raising=False)
    from acq_py import sbx, ssh_agent

    monkeypatch.setattr(ssh_agent, "_ACTIVE", set())
    monkeypatch.setattr(ssh_agent, "_NOTICE_SHOWN", [False])
    monkeypatch.setattr(ssh_agent, "_GUEST_SOCK_WARNED", [False])
    monkeypatch.setattr(sbx, "_SSH_AGENT_NOTICE_SHOWN", [False])
    # The acq secret store would otherwise pick the host keychain (secret-tool,
    # macOS security, DPAPI) and could overwrite a developer's real credential.
    # Force the file backend under the throwaway root; a test that exercises a
    # keychain backend substitutes fakes explicitly (see test_secretstore.py).
    store = root / "secret-store"
    monkeypatch.setenv("ACQ_SECRET_STORE_DIR", str(store))
    monkeypatch.setenv("DBUS_SESSION_BUS_ADDRESS", f"unix:path={root / 'no-session-bus'}")
    # A kit outside the built-in bundle is fetched with git. Tests must never
    # reach the network: git refuses every transport but a local file:// one,
    # which the kit-fetch tests use with a bare repository fixture.
    monkeypatch.setenv("GIT_ALLOW_PROTOCOL", "file")
    # On a Windows host the store would use real DPAPI even for the throwaway
    # directory; in-process tests stay on the file backend instead, and the
    # Windows path is exercised through its seams (test_secretstore.py).
    from acq_py import secretstore

    monkeypatch.setattr(secretstore, "IS_WINDOWS", False)
    return root


# A throwaway usai key (never a real credential). msb binds provider keys only
# at create, so acq refuses to create a sandbox whose selected provider has no
# stored key (the pre-create credential gate). A test module that creates
# sandboxes marks itself ``provider_key`` to get one in the throwaway acq store
# and in the sbx stub's table.
TEST_USAI_KEY = "test-usai-key-not-a-secret"


@pytest.fixture(autouse=True)
def provider_key(request, isolate_user_dirs):
    if request.node.get_closest_marker("provider_key") is None:
        return None
    from acq_py import secretstore

    secretstore.set_secret("usai", None, TEST_USAI_KEY)
    # sbx injects from its own proxy table, so the stub's table holds the key too.
    request.getfixturevalue("monkeypatch").setenv("ACQ_SBX_STUB_CUSTOM_SECRETS", json.dumps(
        [{"scope": "global", "env": "USAI_API_KEY", "placeholder": "sbx-cs-usai", "targets": ["api.gsa.usai.gov"]}]
    ))
    return TEST_USAI_KEY


@pytest.fixture(autouse=True)
def no_job_objects(monkeypatch):
    """Run bounded backend calls through plain ``subprocess.run``, on every host.

    On Windows ``hostexec.run_captured`` puts a bounded call in a Job object,
    through ``Popen``, which would bypass the many tests that fake
    ``subprocess.run`` to drive a backend. The Job object path has tests of its
    own: they turn it on with the ``real_job_objects`` fixture (the real
    thing, on Windows) or with fakes of their own.
    """
    from acq_py import hostexec

    monkeypatch.setattr(hostexec, "JOB_OBJECTS", False)


@pytest.fixture
def real_job_objects(monkeypatch, no_job_objects):
    """Put back the platform's own Job object setting (on only on Windows)."""
    from acq_py import hostexec

    monkeypatch.setattr(hostexec, "JOB_OBJECTS", sys.platform == "win32")


@pytest.fixture(scope="session")
def vectors_dir() -> Path:
    return VECTORS_DIR


@pytest.fixture(scope="session")
def acq_cmd() -> list[str]:
    return [sys.executable, "-m", "acq_py"]


@pytest.fixture(scope="session")
def python_exe() -> str:
    return sys.executable


class _WindowsNulStdin(io.StringIO):
    """stdin as ``acq ... < NUL`` shows it on Windows: NUL is a character device,
    so ``isatty()`` says True, but no console is behind the handle."""

    def isatty(self):
        return True

    def fileno(self):
        return 0


@pytest.fixture
def windows_nul_stdin(monkeypatch):
    """Install a Windows ``< NUL`` stdin holding ``text``; returns the installer.

    A caller that asks ``sys.stdin.isatty()`` directly sees a terminal; only
    ``hostexec.stream_is_terminal`` sees that no console is attached. A test
    using this fails if its caller reverts to ``isatty()``.
    """
    from acq_py import hostexec

    def install(text: str = "") -> io.StringIO:
        stream = _WindowsNulStdin(text)
        monkeypatch.setattr(sys, "stdin", stream)
        monkeypatch.setattr(hostexec, "_is_windows", lambda: True)
        monkeypatch.setattr(hostexec, "_windows_console", lambda fd: False)
        return stream

    return install
