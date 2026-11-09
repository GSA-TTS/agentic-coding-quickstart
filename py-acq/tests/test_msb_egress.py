"""Tier-2 tests for the msb create-time egress policy (ADR-0018, ADR-0019, ADR-0038m §46).

Non-contract evidence (ADR-0039m): these drive ``cli.main`` in-process against
the deterministic ``__stub__`` msb and record the argv the adapter hands to the
backend, so they prove which flags are emitted and that a policy acq cannot
compute refuses the create before msb runs. Enforcement itself (a blocked host
actually being blocked) needs a live msb and is out of scope here.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

from acq_py import cli, errors, kit_msb, kits, kitspec, msb, state

pytestmark = pytest.mark.provider_key  # creates msb sandboxes: needs a stored provider key

REPO_ROOT = Path(__file__).resolve().parents[2]
CANONICAL_HOSTS = REPO_ROOT / "acq.backends" / "msb-balanced-hosts.txt"

_EGRESS_ENV = (
    "ACQ_NETWORK_TIER",
    "ACQ_NETWORK_TIER_CONFIRM_OPEN",
    "ACQ_MSB_BALANCED_EGRESS",
    "ACQ_MSB_BALANCED_HOSTS_FILE",
    "ACQ_PROVIDER_KITS",
)


def _env(monkeypatch, tmp_path, *, catalog=None):
    monkeypatch.setenv("ACQ_MSB_BIN", "__stub__")
    monkeypatch.setenv("ACQ_MSB_VERSION", "0.7.7")
    monkeypatch.setenv("ACQ_MSB_INSTALLED", "1")
    monkeypatch.setenv("ACQ_SBX_INSTALLED", "0")
    monkeypatch.setenv("ACQ_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("MSB_HOME", str(tmp_path / "msb-home"))
    for name in ("ACQ_BACKEND", "ACQ_MSB_STUB_CATALOG", "ACQ_IMAGE", "ACQ_MSB_IMAGE", "ACQ_MSB_STUB_FAIL", *_EGRESS_ENV):
        monkeypatch.delenv(name, raising=False)
    if catalog is not None:
        catalog_path = tmp_path / "msb-home" / ".microsandbox" / "catalog.json"
        catalog_path.parent.mkdir(parents=True, exist_ok=True)
        catalog_path.write_text(json.dumps(catalog), encoding="utf-8")
    (tmp_path / "ws").mkdir(exist_ok=True)


@pytest.fixture
def calls(monkeypatch):
    """Record every argv the msb adapter runs (create, exec, remove, ...)."""
    seen: list[list[str]] = []
    original = msb._run

    def spy(argv, **kwargs):
        seen.append(list(argv))
        return original(argv, **kwargs)

    monkeypatch.setattr(msb, "_run", spy)
    return seen


def _invoke(capsys, *argv):
    rc = cli.main(list(argv))
    out = capsys.readouterr().out.strip()
    doc = json.loads(out.splitlines()[-1]) if out else None
    return rc, doc


def _create(capsys, tmp_path, agent="opencode", name="box"):
    return _invoke(capsys, "--backend", "msb", "create", agent, str(tmp_path / "ws"), "--name", name, "--json")


def _create_argv(seen):
    creates = [argv for argv in seen if argv and argv[0] == "create"]
    assert len(creates) == 1, creates
    return creates[0]


def _net_rules(argv):
    return [argv[i + 1] for i, token in enumerate(argv) if token == "--net-rule"]


def _assert_refused_before_create(rc, doc, seen, code=errors.VALIDATION_FAILED):
    assert rc == errors.EXIT_FAILURE
    assert doc["error"]["code"] == code
    assert not [argv for argv in seen if argv and argv[0] == "create"]


# ---------------------------------------------------------------------------
# Emitted flags
# ---------------------------------------------------------------------------

def test_default_create_emits_balanced_deny_by_default_policy(monkeypatch, tmp_path, capsys, calls):
    _env(monkeypatch, tmp_path)
    rc, _doc = _create(capsys, tmp_path)
    assert rc == 0
    argv = _create_argv(calls)

    # Deny-by-default egress only (ADR-0019), DNS allowed, TLS interception on.
    assert argv[argv.index("--net-default-egress") + 1] == "deny"
    assert "--net-default" not in argv
    assert "--tls-intercept" in argv
    rules = _net_rules(argv)
    assert "allow@dns" in rules
    # The built-in kits' own hosts (usai-provider, agentic-coding-playbook).
    for host in ("api.gsa.usai.gov", "api.github.com", "codeload.github.com", "github.com"):
        assert f"allow@{host}" in rules
    # The balanced baseline, translated as the Bash adapter does.
    assert "allow@pypi.org:tcp:443" in rules
    assert "allow@*.github.com:tcp:443" in rules  # `**.github.com` -> msb suffix
    assert "allow@*.digicert.com:tcp:80" in rules  # `crl*.` broadened to the parent
    assert not any("example.com" in rule for rule in rules)
    # Every flag precedes the positional image.
    assert argv[-1] == state.record_read("msb", "box")["image"]


def test_strict_tier_drops_the_baseline_but_keeps_deny_default(monkeypatch, tmp_path, capsys, calls):
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_NETWORK_TIER", "strict")
    assert _create(capsys, tmp_path)[0] == 0
    argv = _create_argv(calls)
    assert argv[argv.index("--net-default-egress") + 1] == "deny"
    assert _net_rules(argv) == [
        "allow@api.gsa.usai.gov",
        "allow@api.github.com",
        "allow@codeload.github.com",
        "allow@github.com",
        "allow@registry.npmjs.org",  # the bundled opencode kit's pinned binary
        "allow@dns",
    ]


def test_deprecated_alias_off_maps_to_strict(monkeypatch, tmp_path, capsys, calls):
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_MSB_BALANCED_EGRESS", "0")
    assert _create(capsys, tmp_path)[0] == 0
    assert "allow@pypi.org:tcp:443" not in _net_rules(_create_argv(calls))


def test_open_tier_requires_confirmation(monkeypatch, tmp_path, capsys, calls):
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_NETWORK_TIER", "open")
    _assert_refused_before_create(*_create(capsys, tmp_path), calls)

    monkeypatch.setenv("ACQ_NETWORK_TIER_CONFIRM_OPEN", "1")
    assert _create(capsys, tmp_path, name="box2")[0] == 0
    argv = _create_argv(calls)
    assert "--net-default-egress" not in argv
    assert "allow@api.gsa.usai.gov" in _net_rules(argv)


def test_run_and_shell_agent_also_get_the_policy(monkeypatch, tmp_path, capsys, calls):
    _env(monkeypatch, tmp_path)
    rc, _doc = _invoke(capsys, "--backend", "msb", "run", "shell", str(tmp_path / "ws"), "--name", "sh", "--json")
    assert rc == 0
    argv = _create_argv(calls)
    assert argv[argv.index("--net-default-egress") + 1] == "deny"


def test_provider_kit_override_changes_the_kit_hosts(monkeypatch, tmp_path, capsys, calls):
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_PROVIDER_KITS", "")
    assert kit_msb.egress_names(kit_msb.resolve(kitspec.select_kits(None))) == [
        "zscaler-ca-certificate", "agentic-coding-playbook", "git-ssh-sign",
    ]
    assert _create(capsys, tmp_path)[0] == 0
    assert "allow@api.gsa.usai.gov" not in _net_rules(_create_argv(calls))


def test_egress_kit_order_mirrors_the_bash_kit_list(monkeypatch):
    monkeypatch.delenv("ACQ_PROVIDER_KITS", raising=False)
    assert kit_msb.egress_names(kit_msb.resolve(kitspec.select_kits("opencode", env={}))) == [
        "zscaler-ca-certificate",
        "usai-provider",
        "agentic-coding-playbook",
        "git-ssh-sign",
        "opencode",
    ]


# ---------------------------------------------------------------------------
# Fail closed: a policy acq cannot compute refuses the create before msb runs.
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("tier", ["stirct", "none", "allow", "OPEN-ish"])
def test_invalid_tier_is_refused(monkeypatch, tmp_path, capsys, calls, tier):
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_NETWORK_TIER", tier)
    _assert_refused_before_create(*_create(capsys, tmp_path), calls)


def test_missing_baseline_is_refused(monkeypatch, tmp_path, capsys, calls):
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_MSB_BALANCED_HOSTS_FILE", str(tmp_path / "absent.txt"))
    _assert_refused_before_create(*_create(capsys, tmp_path), calls)


def test_relative_baseline_path_is_refused(monkeypatch, tmp_path, capsys, calls):
    # A relative path resolves against the cwd, which may be an agent-writable
    # workspace; refuse it even when such a file exists and is well formed.
    _env(monkeypatch, tmp_path)
    (tmp_path / "hosts.txt").write_text("pypi.org:443\n", encoding="utf-8")
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("ACQ_MSB_BALANCED_HOSTS_FILE", "hosts.txt")
    _assert_refused_before_create(*_create(capsys, tmp_path), calls)


def test_relative_baseline_path_uses_the_shared_refusal_text(monkeypatch):
    # The adapter's own check words the refusal as Bash's shared override check
    # does (acq.backends/userdirs.sh _acq_userdirs_override_problem).
    monkeypatch.setenv("ACQ_MSB_BALANCED_HOSTS_FILE", "hosts.txt")
    with pytest.raises(msb.MsbError) as info:
        msb._balanced_rules()
    assert info.value.code == errors.VALIDATION_FAILED
    assert info.value.message == "ACQ_MSB_BALANCED_HOSTS_FILE must be an absolute path, got 'hosts.txt'"
    assert info.value.remediation == (
        "set ACQ_MSB_BALANCED_HOSTS_FILE to an absolute path, or unset it to use the default"
    )


def test_group_keyword_baseline_cannot_reopen_egress(monkeypatch, tmp_path):
    for name in _EGRESS_ENV:
        monkeypatch.delenv(name, raising=False)
    hosts = tmp_path / "hosts.txt"
    hosts.write_text("any:443\npublic\n", encoding="utf-8")
    monkeypatch.setenv("ACQ_MSB_BALANCED_HOSTS_FILE", str(hosts))
    with pytest.raises(msb.MsbError) as info:
        msb.egress_flags(["usai-provider"])
    assert info.value.code == errors.VALIDATION_FAILED


def test_empty_baseline_is_refused(monkeypatch, tmp_path, capsys, calls):
    _env(monkeypatch, tmp_path)
    empty = tmp_path / "hosts.txt"
    empty.write_text("# only comments\n\n   \n", encoding="utf-8")
    monkeypatch.setenv("ACQ_MSB_BALANCED_HOSTS_FILE", str(empty))
    _assert_refused_before_create(*_create(capsys, tmp_path), calls)


def test_unknown_provider_kit_is_refused(monkeypatch, tmp_path, capsys, calls):
    _env(monkeypatch, tmp_path)
    monkeypatch.setenv("ACQ_PROVIDER_KITS", "someone-elses-provider")
    # Outside the bundle, the provider kit would have to be fetched: refused.
    _assert_refused_before_create(*_create(capsys, tmp_path), calls, errors.UNSUPPORTED)


def test_stale_kit_allowlist_is_refused(monkeypatch, tmp_path, capsys, calls):
    _env(monkeypatch, tmp_path)
    monkeypatch.setattr(kits, "KIT_NETWORK_ALLOW_REF", "0" * 40)
    _assert_refused_before_create(*_create(capsys, tmp_path), calls)


def test_recreate_refuses_before_removing_the_old_sandbox(monkeypatch, tmp_path, capsys, calls):
    _env(monkeypatch, tmp_path, catalog={"sec": "running"})
    record = {"schema": 1, "name": "sec", "backend": "msb", "agent": "opencode", "workspace": "/w", "ro_host_config": True}
    path = state.record_path("msb", "sec")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(record), encoding="utf-8")
    monkeypatch.setenv("ACQ_SECURITY_MOUNT_STATE", json.dumps({"sec": "missing"}))
    monkeypatch.setenv("ACQ_NETWORK_TIER", "bogus")

    rc, doc = _invoke(capsys, "--backend", "msb", "create", "--recreate", "sec", "--yes", "--json")
    _assert_refused_before_create(rc, doc, calls)
    assert not [argv for argv in calls if argv and argv[0] == "remove"]
    assert msb.exists("sec")


# ---------------------------------------------------------------------------
# Argv safety: an allowlist value can never become a flag or extra arguments.
# ---------------------------------------------------------------------------

# msb reads a single-label target as a group keyword; `allow@any` reopens egress.
_MSB_GROUP_KEYWORDS = ["any", "public", "private", "multicast", "host", "dns"]

_HOSTILE_HOSTS = [
    *_MSB_GROUP_KEYWORDS,
    "localhost",
    "-evil.example.com",
    "--net-default-egress",
    "evil.example.com --net-default-egress allow",
    "evil.example.com\t--privileged",
    "evil.example.com\n--net-rule",
    "evil.example.com\x00",
    "*.com",
    "*",
    "évil.example.com",
    "a..b.com",
    ".example.com",
    "example.com.",
    "@example.com",
    "",
]


@pytest.mark.parametrize("suffix", ["", ":443"])
@pytest.mark.parametrize("host", _HOSTILE_HOSTS)
def test_hostile_kit_host_is_refused(monkeypatch, tmp_path, capsys, calls, host, suffix):
    _env(monkeypatch, tmp_path)
    monkeypatch.setitem(kits.KIT_NETWORK_ALLOW, "usai-provider", (host + suffix,))
    _assert_refused_before_create(*_create(capsys, tmp_path), calls)


@pytest.mark.parametrize(
    "line",
    [
        "-evil.example.com:443",
        "evil.example.com --privileged:443",
        "evil.example.com:0443",
        "evil.example.com:70000",
        "evil.example.com:443 --net-default-egress allow",
        "evil.example.com:44 3",
        "*.com:443",
        "*:443",
        "any:443",
        "public",
        "private:443",
        "multicast",
        "host:53",
        "dns",
    ],
)
def test_hostile_baseline_line_is_refused(monkeypatch, tmp_path, capsys, calls, line):
    _env(monkeypatch, tmp_path)
    hosts = tmp_path / "hosts.txt"
    hosts.write_text(f"pypi.org:443\n{line}\n", encoding="utf-8")
    monkeypatch.setenv("ACQ_MSB_BALANCED_HOSTS_FILE", str(hosts))
    _assert_refused_before_create(*_create(capsys, tmp_path), calls)


def test_every_emitted_rule_is_one_well_formed_token(monkeypatch, tmp_path, capsys, calls):
    _env(monkeypatch, tmp_path)
    assert _create(capsys, tmp_path)[0] == 0
    argv = _create_argv(calls)
    token = re.compile(r"allow@(dns|(\*\.)?[A-Za-z0-9_.-]+(:tcp:[1-9][0-9]*)?)")
    rules = _net_rules(argv)
    assert rules and all(token.fullmatch(rule) for rule in rules), rules
    # Each `--net-rule` consumes exactly the next token; nothing else leaks in.
    flags = [t for t in argv[1:-1] if t.startswith("-")]
    assert set(flags) <= {
        "--name", "--volume", "-w", "-m", "-c", "--net-rule", "--net-default-egress", "--tls-intercept",
        "--script-path", "--trust-host-cas", "--env", "--secret",
    }


# ---------------------------------------------------------------------------
# Parity with the Bash adapter's single source of truth.
# ---------------------------------------------------------------------------

def test_packaged_baseline_matches_the_bash_baseline():
    packaged = msb.BALANCED_HOSTS_FILE.read_bytes()
    if packaged != CANONICAL_HOSTS.read_bytes():
        pytest.fail(
            f"{msb.BALANCED_HOSTS_FILE} differs from {CANONICAL_HOSTS}; "
            "copy the canonical file over the packaged one"
        )


def _bash_rules(tmp_path, kit_allow: dict[str, tuple[str, ...]]) -> list[str]:
    """The Bash adapter's balanced rules followed by each kit's rules."""
    specs = []
    for kit, entries in kit_allow.items():
        spec = tmp_path / f"{kit}.yaml"
        lines = ["caps:", "  network:", "    allow:", *[f"      - {e}" for e in entries]]
        spec.write_text("\n".join(lines) + "\n", encoding="utf-8")
        specs.append(str(spec))
    script = (
        'acq_debug() { :; }; . acq.backends/kit-translate.sh; . acq.backends/msb.sh; '
        '_acq_msb_balanced_rules_into out; printf "%s\\n" "${out[@]}"; '
        'for s in "$@"; do _acq_msb_net_rules_into out "$s"; '
        '[ "${#out[@]}" -gt 0 ] && printf "%s\\n" "${out[@]}"; done'
    )
    home = tmp_path / "home"
    home.mkdir()
    env = {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "HOME": str(home),
        "XDG_CONFIG_HOME": str(home / "config"),
        "XDG_STATE_HOME": str(home / "state"),
        "XDG_CACHE_HOME": str(home / "cache"),
        "XDG_DATA_HOME": str(home / "data"),
        "ACQ_STATE_DIR": str(home / "acq-state"),
        "ACQ_SCRIPT_DIR": str(REPO_ROOT),
        "ACQ_MSB_BALANCED_HOSTS_FILE": str(CANONICAL_HOSTS),
    }
    proc = subprocess.run(
        ["bash", "-c", script, "bash", *specs],
        cwd=REPO_ROOT, env=env, capture_output=True, text=True, timeout=60,
    )
    assert proc.returncode == 0, proc.stderr
    return proc.stdout.splitlines()


@pytest.mark.skipif(sys.platform == "win32" or shutil.which("bash") is None, reason="needs the Bash adapter")
def test_rule_translation_matches_the_bash_adapter(monkeypatch, tmp_path):
    for name in _EGRESS_ENV:
        monkeypatch.delenv(name, raising=False)
    kit_allow = {k: v for k, v in kits.KIT_NETWORK_ALLOW.items() if v}
    expected = _bash_rules(tmp_path, kit_allow)
    python = msb._balanced_rules() + msb._kit_rules(list(kit_allow))
    # Bash prepends `allow@dns` inside its baseline emitter; Python emits it
    # beside the deny-default. Compare everything else in order.
    assert expected[:2] == ["--net-rule", "allow@dns"]
    assert python == expected[2:]


def _spec_network_allow(spec: Path) -> tuple[str, ...]:
    """``caps.network.allow`` from a kit spec, parsed as kit_spec_net_allow does."""
    out: list[str] = []
    in_caps = in_net = in_allow = False
    for line in spec.read_text(encoding="utf-8").splitlines():
        if line.startswith("caps:"):
            in_caps, in_net, in_allow = True, False, False
            continue
        if re.match(r"[A-Za-z]", line):
            in_caps = in_net = in_allow = False
        if in_caps and re.match(r"\s+network:", line):
            in_net = True
            continue
        if in_net and re.match(r"\s+allow:", line):
            in_allow = True
            continue
        if in_allow:
            if re.match(r"\s+-\s*", line):
                value = re.sub(r"^\s*-\s*", "", line)
                value = re.sub(r"\s*#.*", "", value).rstrip().strip('"')
                if value:
                    out.append(value)
            elif not re.match(r"\s*#", line):
                in_allow = False
    return tuple(out)


def test_kit_network_allow_matches_the_pinned_kit_specs():
    """KIT_NETWORK_ALLOW is a copy of each built-in kit's pinned spec.

    Runs where a checkout of the pinned Patterns repository is provided via
    ACQ_TEST_PATTERNS_REPO (as the pre-commit and bash32 CI workflows do);
    skipped otherwise, since ordinary tests never fetch.
    """
    root = os.environ.get("ACQ_TEST_PATTERNS_REPO")
    if not root:
        pytest.skip("pinned Patterns checkout is provided by CI via ACQ_TEST_PATTERNS_REPO")
    repo = Path(root)
    head = subprocess.run(["git", "-C", str(repo), "rev-parse", "HEAD"], capture_output=True, text=True)
    if head.returncode == 0:
        assert head.stdout.strip() == kits.KIT_NETWORK_ALLOW_REF
    for kit in kits.BUILTIN_KIT_NAMES:
        spec = repo / kits.CONTROL_PLANE_DIR / kit / "spec.yaml"
        assert spec.is_file(), f"missing pinned spec for built-in kit {kit!r}: {spec}"
        assert _spec_network_allow(spec) == kits.KIT_NETWORK_ALLOW[kit], kit
