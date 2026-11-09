"""kitspec: parity with the Bash kit_spec_* parsers, the pinned bundle, and kit selection.

The parity tests run Bash's own awk parsers (acq.backends/kit-translate.sh, and
kit_spec_agent_field from common.sh) on the same spec bytes as kitspec and
compare the complete output, stdout and warnings, byte for byte. They cover the
bundled built-in kits, hand-written hostile and edge-case specs, and a seeded
random corpus built from the line shapes the parsers react to. They need bash,
awk and base64, so they are skipped where those are missing (a Windows host
without Git Bash).
"""

from __future__ import annotations

import glob
import json
import os
import random
import re
import shutil
import subprocess
from pathlib import Path

import pytest

from acq_py import kits, kitspec

REPO_ROOT = Path(__file__).resolve().parents[2]
KIT_TRANSLATE = REPO_ROOT / "acq.backends" / "kit-translate.sh"
COMMON_SH = REPO_ROOT / "acq.backends" / "common.sh"
BASH = shutil.which("bash")

needs_bash = pytest.mark.skipif(
    BASH is None or shutil.which("awk") is None or shutil.which("base64") is None or os.name == "nt",
    reason="the Bash parity check needs bash, awk and base64",
)

FIELDS = ("schemaVersion", "kind", "name", "displayName", "description")
AGENT_FIELDS = ("name", "entrypoint")
SECTIONS = (
    ("files", "files"),
    ("commands", "commands"),
    ("env", "environment"),
    ("net_allow", None),
    ("published_ports", "publishedPorts"),
    ("volumes", "volumes"),
    ("agent_context", None),
)

# Runs every kit_spec_* accessor on each spec named on the command line and
# prints one delimited report per spec. kit_spec_agent_field lives in common.sh,
# which needs the whole acq environment to source, so its definition is lifted
# out and evaluated on its own.
BASH_DRIVER = r"""
set -u
. "$KIT_TRANSLATE"
eval "$(awk '/^kit_spec_agent_field\(\) \{/{on=1} on{print} on&&/^\}/{exit}' "$COMMON_SH")"
err=$(mktemp)
for spec in "$@"; do
  printf '##### %s\n' "$spec"
  for fn in files commands env net_allow published_ports volumes agent_context; do
    printf '=== %s\n' "$fn"
    "kit_spec_$fn" "$spec" 2>"$err"
    printf -- '--- err\n'
    cat "$err"
  done
  for k in schemaVersion kind name displayName description; do
    printf '=== field:%s\n' "$k"; kit_spec_field "$spec" "$k"
  done
  for k in name entrypoint; do
    printf '=== agent:%s\n' "$k"; kit_spec_agent_field "$spec" "$k"
  done
  for b in msb sbx; do
    printf '=== has:%s\n' "$b"
    if kit_spec_has_shortcut "$spec" "$b"; then echo yes; else echo no; fi
    printf '=== val:%s\n' "$b"; kit_spec_shortcut_val "$spec" "$b" trust_host_cas
  done
done
rm -f "$err"
"""


def bash_reports(specs: list[Path], locale: str = "C") -> dict[str, str]:
    env = {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "LC_ALL": locale,
        "KIT_TRANSLATE": str(KIT_TRANSLATE),
        "COMMON_SH": str(COMMON_SH),
        "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
    }
    assert BASH is not None
    proc = subprocess.run(
        [BASH, "-c", BASH_DRIVER, "driver", *map(str, specs)],
        env=env, capture_output=True, check=True,
    )
    out = proc.stdout.decode("utf-8", "surrogateescape")
    reports: dict[str, str] = {}
    for chunk in out.split("##### ")[1:]:
        name, _, body = chunk.partition("\n")
        reports[name] = body
    return reports


def python_report(spec: kitspec.KitSpec) -> str:
    out: list[str] = []
    rows = {
        "files": [f.record() for f in spec.files],
        "commands": [line for c in spec.commands for line in c.record_lines()],
        "env": [e.record() for e in spec.env],
        "net_allow": list(spec.net_allow),
        "published_ports": [p.record() for p in spec.published_ports],
        "volumes": [v.record() for v in spec.volumes],
        "agent_context": list(spec.agent_context),
    }
    for name, section in SECTIONS:
        out.append(f"=== {name}\n")
        out.extend(f"{line}\n" for line in rows[name])
        out.append("--- err\n")
        out.extend(f"{w}\n" for w in (spec.warnings[section] if section else ()))
    for key in FIELDS:
        value = spec.field(key)
        out.append(f"=== field:{key}\n" + ("" if value is None else f"{value}\n"))
    for key in AGENT_FIELDS:
        value = spec.agent_field(key)
        out.append(f"=== agent:{key}\n" + ("" if value is None else f"{value}\n"))
    for backend in ("msb", "sbx"):
        out.append(f"=== has:{backend}\n" + ("yes\n" if spec.has_shortcut(backend) else "no\n"))
        value = spec.shortcut_val(backend, "trust_host_cas")
        out.append(f"=== val:{backend}\n" + ("" if value is None else f"{value}\n"))
    return "".join(out)


def assert_parity(paths: list[Path], locale: str = "C") -> int:
    """Compare every spec; return how many Python refused as a whole."""
    reports = bash_reports(paths, locale)
    refused = 0
    for path in paths:
        try:
            spec = kitspec.load_spec(path)
        except kitspec.KitSpecError as exc:
            # The only refusal a fuzzed spec can reach: a dedent that splits a
            # multi-byte character, where Bash would print a broken byte.
            assert "multi-byte" in str(exc), (path, exc)
            refused += 1
            continue
        assert python_report(spec) == reports[str(path)], f"parity mismatch for {path}:\n{path.read_bytes()!r}"
    return refused


# ---------------------------------------------------------------------------
# Hand-written hostile and edge-case specs.
# ---------------------------------------------------------------------------

EDGE_SPECS: dict[str, str] = {
    "files-validation": """\
schemaVersion: "hybrid/v1"
files:
  - path: /home/agent/ok
    mode: "0755"
    source: files/ok
    readonly: true
  - path: /home/agent/three
    mode: 644
    phase: initFiles
  - path: /home/agent/badmode
    mode: "07555"
  - path: /home/agent/hex
    mode: 0x1ed
  - path: "/home/agent/with space"
  - path: /home/agent/$(id)
  - path: /home/agent/up
    source: ../escape
  - path: /home/agent/abs
    source: /etc/passwd
  - path: /home/agent/mid
    source: files/../../x
  - path: /home/agent/dotdot-prefix
    source: files/..hidden
  - path: /home/agent/ro-caps
    readonly: True   # only the exact word true counts
  - path: /home/agent/quoted
    readonly: "true"
    description: >
      folded text that mentions
      path: /home/agent/hijack
  - mode: "0644"
    source: files/no-path
files:
  - path: /home/agent/second-block
""",
    "commands-validation": """\
commands:
  - phase: startup
    user: "0"
    background: yes
    description: d
    command:
      - sh
      - -c
      - |
        set -eu

        echo "two blank-separated lines"
          indented more


  - phase: boot
    command: [echo, hi]
  - phase: install
    user: root;rm -rf /
    command:
      - echo
  - user: 1000
    command:
      - "quoted arg"
      - 'single'
      - trailing spaces
      # a comment line inside argv
      - a # not a comment
  - phase: initFiles
    background: false
    command:
      - |
      - after-empty-block
    user: late
  - |
    stray block
  - phase: "startup"
    user: "0" # root
    command:
      - x
name: after
""",
    "commands-crlf-tabs": (
        "commands:\r\n"
        "  - phase: startup\r\n"
        "    command:\r\n"
        "      - sh\r\n"
        "      - |\r\n"
        "        line one\r\n"
        "        line two\r\n"
        "\t- tabbed\r\n"
        "  - phase:\tinstall\r\n"
        "    command:\r\n"
        "\t  - tab-led\r\n"
    ),
    "env-validation": """\
environment:
  OPENCODE_CONFIG: /home/agent/usai-config/opencode.jsonc
  "QUOTED_NAME": quoted
  'SINGLE': 'single value'
  BAD-NAME: x
  9LEADING: x
  PIPE: "|"
  BLOCK: |
    body: not an entry
	tabbed: still body
    more: body
  AFTER: yes # trailing comment
  FOLDED: >-
    x: y
  EMPTY:
  URL: https://example.gov:8443/path
  # comment
  HASH: a#b
environment:
  SECOND: block
""",
    "network": """\
caps:
  network:
    allow:
      - api.gsa.usai.gov
      # comment kept inside the list
      - "quoted.example.gov:443"   # trailing
      -nospace.example.gov
      - 'single.example.gov'

      - after-blank.example.gov
    deny:
      - denied.example.gov
    allow:
      - reopened.example.gov
  network: {}
other:
  allow:
    - not-caps.example.gov
""",
    "ports-neutral": """\
publishedPorts:
  - guest: 3000
    host: 3000
    protocol: tcp
    name: openchamber
  - guest: "4096"
    protocol: udp
  - guest: 0
  - guest: 65536
  - guest: 00080
    host: 99999
  - guest: 22
    protocol: sctp
  - guest: 23
    name: bad name
  - host: 8080
  - name: only-name
  # comment
  - guest: 8443 # trailing comment
backend_extras:
  sbx:
    publishedPorts:
      - container: 1234
""",
    "ports-legacy": """\
publishedPorts:
  - name: no-guest
backend_extras:
  sbx:
    publishedPorts:
      - container: 3000
        protocol: tcp
        name: openchamber
      - container: 70000
      - container: 81
        other: stop
      - container: 82
  msb:
    publishedPorts:
      - container: 9999
""",
    "volumes": """\
volumes:
  - path: /var/lib/docker
    size: 20G
  - path: /scratch
    type: tmpfs
    size: 2G
  - path: relative
    size: 1G
  - path: /data/../etc
    size: 1G
  - path: /data/
    size: 1G
  - path: //data
    size: 1G
  - path: /.
    size: 1G
  - path: /data/..hidden
    size: 1.5G
  - path: /bad type
    size: 1G
  - path: /t
    type: overlay
    size: 1G
  - path: /nosize
  - path: /zero
    size: 0.0G
  - path: /bytes
    size: 256MB
  - size: 5G
  - path: /ok
    size: "512m"
""",
    "agent-context": """\
agentContext: |
    ## Title

    Indented four.
  Less indented: cut.
	tab-led line
      deeper
# column-0 comment ends it
  not part
agentContext: >-
  ## Second block
  text
name: x
""",
    "fields": """\
name: ""
name: second # comment kept
kind: 'mixin'
displayName: "Quoted Display"
description: >
  First line
    indented continuation

  after blank
# comment ends the block
schemaVersion: hybrid/v1
agent:
  name: "opencode"   # comment
  entrypoint:
agent2: x
""",
    "fields-block-at-eof": """\
description: |
  only line
""",
    "agent-ends": """\
agent:
  name: first
other: x
agent: # comment
  entrypoint: opencode
""",
    "shortcuts": """\
backend_shortcuts:
  msb:
    trust_host_cas: "true"   # comment
  sbx: {}
""",
    "shortcuts-inline": """\
backend_shortcuts:
  sbx: { trust_host_cas: true }
  msb:
  # comment
    trust_host_cas: no
""",
    "shortcuts-empty-then-key": """\
backend_shortcuts:
  msb:
  sbx:
    trust_host_cas: false
""",
    "empty": "",
    "only-newline": "\n",
    "no-trailing-newline": "files:\n  - path: /x",
    "unicode": """\
name: naïve
description: >
  Ünïcode — dashes
environment:
  GREETING: héllo wörld
agentContext: |
  ## Ünïcode
  ✓ check
files:
  - path: /home/agent/é
""",
}


@needs_bash
def test_parity_hand_written_specs(tmp_path):
    paths = []
    for name, text in EDGE_SPECS.items():
        path = tmp_path / f"{name}.yaml"
        path.write_bytes(text.encode("utf-8"))
        paths.append(path)
    assert assert_parity(paths) == 0


@needs_bash
@pytest.mark.parametrize("locale", ["C", "C.UTF-8"])
def test_parity_bundled_kits(locale):
    paths = [kitspec.bundle_kit_dir(name) / "spec.yaml" for name in kitspec.bundle_kit_names()]
    assert assert_parity(paths, locale) == 0


@needs_bash
def test_parity_legacy_fixtures():
    paths = [REPO_ROOT / "test" / "fixtures" / d / "spec.yaml" for d in ("kit-valid", "kit-invalid")]
    assert assert_parity(paths) == 0


# ---------------------------------------------------------------------------
# Seeded random corpus.
# ---------------------------------------------------------------------------

_TOP = [
    "files:", "commands:", "environment:", "caps:", "publishedPorts:", "publishedPorts: []",
    "volumes:", "agentContext: |", "agentContext: >-", "backend_shortcuts:", "backend_extras:",
    "agent:", "agent: # c", "name: x", "kind: mixin", 'schemaVersion: "hybrid/v1"', "description: >",
    "description: |", "displayName: 'D'", "# comment", "foo: bar", "commands: # again", "x",
]
_KEYS = [
    "path", "mode", "phase", "source", "readonly", "description", "user", "background", "command",
    "guest", "host", "protocol", "name", "container", "size", "type", "network", "allow", "sbx", "msb",
    "trust_host_cas", "entrypoint", "publishedPorts", "FOO", "_x", "9BAD", '"Q"', "'S'", "a-b",
]
_VALUES = [
    "", "/home/agent/x", "files/a", "../etc", "/abs", "0755", "755", "0x", "true", "false", "yes",
    "install", "startup", "initFiles", "boot", "0", "1000", "root user", '"0"', "'q'", '"a#b"',
    "v # c", "|", ">", "|-", ">2", "3000", "65536", "00080", "tcp", "udp", "sctp", "ok.name",
    "bad name", "20G", "512m", "0G", "1.5G", "2gib", "tmpfs", "//x", "/a/../b", "/a/", "{}", "x:y",
    "é", "naïve/é", "a\tb", "val\r", '"', "api.gsa.usai.gov", "host:443", "[a, b]", "'it''s'",
]
_INDENTS = ["", " ", "  ", "    ", "      ", "        ", "\t", "  \t", "   "]


def _random_line(rng: random.Random) -> str:
    kind = rng.randrange(10)
    ind = rng.choice(_INDENTS)
    key, value = rng.choice(_KEYS), rng.choice(_VALUES)
    if kind == 0:
        return rng.choice(_TOP)
    if kind in (1, 2):
        return f"{ind}{key}: {value}"
    if kind == 3:
        return f"{ind}- {key}: {value}"
    if kind == 4:
        return f"{ind}- {value}"
    if kind == 5:
        return f"{ind}- |"
    if kind == 6:
        return f"{ind}{value} {rng.choice(_VALUES)}"
    if kind == 7:
        return f"{ind}# {value}"
    return rng.choice(["", "   ", "\t"])


def _random_spec(rng: random.Random) -> bytes:
    lines = [_random_line(rng) for _ in range(rng.randrange(3, 40))]
    if rng.random() < 0.2:
        lines = [line + "\r" for line in lines]
    text = "\n".join(lines) + ("\n" if rng.random() < 0.9 else "")
    return text.encode("utf-8")


@needs_bash
def test_parity_random_corpus(tmp_path):
    rng = random.Random(20261109)
    paths = []
    for i in range(240):
        path = tmp_path / f"fuzz-{i:04d}.yaml"
        path.write_bytes(_random_spec(rng))
        paths.append(path)
    refused = assert_parity(paths)
    assert refused < len(paths) // 10


# Section-shaped lines reach deeper parser states than the flat corpus above:
# argv blocks, legacy sbx port blocks, nested shortcut keys.
_SECTION_LINES = {
    "commands:": ["  - phase: {v}", "    user: {v}", "    background: {v}", "    command:", "      - {v}",
                  "      - |", "        {v}", "          {v}", "", "    description: {v}", "  - {k}: {v}",
                  "    command: {v}", "\t- {v}", "  # {v}"],
    "files:": ["  - path: {v}", "    mode: {v}", "    source: {v}", "    phase: {v}", "    readonly: {v}",
               "    description: >", "      {k}: {v}", "  - {k}: {v}"],
    "environment:": ["  {n}: {v}", "  {n}: |", "    {k}: {v}", "\t{k}: {v}", "  # c", "", "      {n}: {v}"],
    "caps:": ["  network:", "    allow:", "      - {v}", "    {k}:", "      # c", "", "  {k}:"],
    "publishedPorts:": ["  - guest: {v}", "    host: {v}", "    protocol: {v}", "    name: {v}", "  - {k}: {v}"],
    "backend_extras:": ["  sbx:", "    publishedPorts:", "      - container: {v}", "        protocol: {v}",
                        "        name: {v}", "        {k}: {v}", "    {k}: {v}", "  msb:", "  {k}:"],
    "volumes:": ["  - path: {v}", "    size: {v}", "    type: {v}", "  - {k}: {v}"],
    "backend_shortcuts:": ["  msb:", "  sbx:", "  msb: {v}", "  sbx: {v}", "    trust_host_cas: {v}", "  # c", "",
                           "    {k}: {v}"],
    "agentContext: |": ["  {v}", "    {v}", "", "{v}", "# c", "      {v}"],
    "agent:": ["  name: {v}", "  entrypoint: {v}", "  # c", "   name: {v}"],
}
_SECTION_VALUES = [*_VALUES, "3000", "/home/agent/a", "files/x", "0644", '"0"', "api.example.gov:443", "1G"]


def _section_spec(rng: random.Random) -> bytes:
    out = []
    for _ in range(rng.randrange(1, 5)):
        head = rng.choice([*_SECTION_LINES, "name: x", "description: >", "x"])
        out.append(head)
        for _ in range(rng.randrange(0, 14)):
            template = rng.choice(_SECTION_LINES.get(head, ["  {k}: {v}"]))
            out.append(template.format(v=rng.choice(_SECTION_VALUES), k=rng.choice(_KEYS),
                                       n=rng.choice(["FOO", "BAR_1", "bad-n", '"Q"', "9X"])))
    if rng.random() < 0.1:
        out = [line + "\r" for line in out]
    return ("\n".join(out) + "\n").encode("utf-8")


@needs_bash
def test_parity_section_corpus(tmp_path):
    rng = random.Random(1109)
    paths = []
    for i in range(160):
        path = tmp_path / f"section-{i:04d}.yaml"
        path.write_bytes(_section_spec(rng))
        paths.append(path)
    assert assert_parity(paths) < len(paths) // 10


# ---------------------------------------------------------------------------
# Whole-spec refusals (the odd-input envelope).
# ---------------------------------------------------------------------------


def test_refuses_oversized_nul_and_non_utf8(tmp_path):
    with pytest.raises(kitspec.KitSpecError, match="larger than"):
        kitspec.parse_spec(b"#" * (kitspec.MAX_SPEC_BYTES + 1))
    with pytest.raises(kitspec.KitSpecError, match="NUL"):
        kitspec.parse_spec(b"name: a\0b\n")
    with pytest.raises(kitspec.KitSpecError, match="UTF-8"):
        kitspec.parse_spec(b"name: \xff\n")
    big = tmp_path / "big.yaml"
    big.write_bytes(b"#" * (kitspec.MAX_SPEC_BYTES + 1))
    with pytest.raises(kitspec.KitSpecError, match="larger than"):
        kitspec.load_spec(big)


def test_refuses_non_regular_files(tmp_path):
    with pytest.raises(kitspec.KitSpecError, match="regular file"):
        kitspec.load_spec(tmp_path)
    if hasattr(os, "mkfifo"):
        fifo = tmp_path / "fifo.yaml"
        os.mkfifo(fifo)
        with pytest.raises(kitspec.KitSpecError, match="regular file"):
            kitspec.load_spec(fifo)
    with pytest.raises(kitspec.KitSpecError, match="does not exist"):
        kitspec.load_kit(tmp_path / "missing")
    with pytest.raises(kitspec.KitSpecError, match="regular file"):
        kitspec.load_kit(tmp_path)


def test_refuses_spec_symlink_outside_kit(tmp_path):
    outside = tmp_path / "outside.yaml"
    outside.write_text("name: x\n")
    kit = tmp_path / "kit"
    kit.mkdir()
    (kit / "spec.yaml").symlink_to(outside)
    with pytest.raises(kitspec.KitSpecError, match="outside the kit"):
        kitspec.load_kit(kit)
    (kit / "real.yaml").write_text("name: inside\n")
    (kit / "spec.yaml").unlink()
    (kit / "spec.yaml").symlink_to("real.yaml")
    assert kitspec.load_kit(kit).field("name") == "inside"


def test_refuses_oversized_command_argument():
    big = "x" * (kitspec.MAX_COMMAND_TOKEN_BYTES + 1)
    text = f"commands:\n  - phase: startup\n    command:\n      - {big}\n"
    with pytest.raises(kitspec.KitSpecError, match="command argument"):
        kitspec.parse_spec(text.encode())
    # A dropped command is never emitted, so its size does not matter.
    dropped = text.replace("phase: startup", "phase: boot")
    assert kitspec.parse_spec(dropped.encode()).commands == ()


def test_refuses_agent_context_cut_inside_a_character():
    # The first line sets a four-byte dedent; the next has three spaces and a
    # two-byte character, so cutting four bytes would split the character.
    text = "agentContext: |\n    four\n   \u00e9\n"
    with pytest.raises(kitspec.KitSpecError, match="multi-byte"):
        kitspec.parse_spec(text.encode())


def test_rejects_unsafe_accessor_arguments():
    spec = kitspec.parse_spec(b"name: x\n")
    for bad in ("na.me", "", "a b"):
        with pytest.raises(ValueError):
            spec.field(bad)
        with pytest.raises(ValueError):
            spec.agent_field(bad)
    with pytest.raises(ValueError):
        spec.has_shortcut("m.sb")
    with pytest.raises(ValueError):
        spec.shortcut_val("msb", "a.b")


def test_typed_records():
    spec = kitspec.load_bundled_kit("opencode")
    assert [c.phase for c in spec.commands_for("startup")] == ["startup", "startup"]
    assert spec.commands_for("initFiles") == ()
    install = spec.commands_for("install")[0]
    assert install.user == "0" and install.background is False
    assert install.argv[:2] == ("sh", "-c") and install.argv[2].startswith('OPENCODE_VERSION="2.0.30"')
    assert not install.argv[2].endswith("\n")
    assert spec.all_warnings() == []
    usai = kitspec.load_bundled_kit("usai-provider")
    assert usai.files[0].path == "/home/agent/usai-config/model-catalog-snapshot.json"
    assert usai.files[0].readonly is False and usai.files[0].phase == ""
    zscaler = kitspec.load_bundled_kit("zscaler-ca-certificate")
    assert zscaler.has_shortcut("msb") and not zscaler.has_shortcut("sbx")
    assert zscaler.shortcut_val("msb", "trust_host_cas") == "true"
    assert zscaler.agent_context[0] == "## Zscaler Root CA"


# ---------------------------------------------------------------------------
# File-source confinement parity (kit_source_resolve, kit_tree_symlinks_within).
# ---------------------------------------------------------------------------


def _confinement_kit(tmp_path: Path) -> Path:
    kit = tmp_path / "kit"
    files = kit / "files"
    (files / "dir").mkdir(parents=True)
    (files / "a").write_text("a\n")
    (files / "..hidden").write_text("h\n")
    outside = tmp_path / "outside.txt"
    outside.write_text("secret\n")
    (files / "link_in").symlink_to("a")
    (files / "link_out").symlink_to(outside)
    (files / "dangling").symlink_to("nonexistent")
    (files / "loop1").symlink_to("loop2")
    (files / "loop2").symlink_to("loop1")
    (files / "linkdir").symlink_to("dir")
    (files / "updir").symlink_to("..")
    (files / "rootlink").symlink_to(tmp_path)
    (kit / "spec.yaml").write_text("name: k\n")
    return kit


_SOURCES = [
    "files/a", "files/dir", "files/link_in", "files/link_out", "files/dangling", "files/loop1",
    "files/linkdir", "files/updir/files/a", "files/rootlink/outside.txt", "files/..hidden", "/abs",
    "../kit/files/a", "files/../files/a", "", "files/nonexistent", "files//a", "./files/a", "files/a/",
    "spec.yaml", ".", "files", "files/a/x", "files/nonexistent/", "files/dir/../a",
]
# GNU realpath refuses a file followed by "/." and uutils (the Rust coreutils)
# accepts it, so Bash's answer depends on the host. Python refuses it.
_HOST_DEPENDENT_SOURCES = ["files/a/."]


@needs_bash
@pytest.mark.parametrize("via_link", [False, True])
def test_source_confinement_parity(tmp_path, via_link):
    kit = _confinement_kit(tmp_path)
    kit_arg = kit
    if via_link:
        kit_arg = tmp_path / "kit-link"
        kit_arg.symlink_to(kit)
    script = '. "$1"; shift; k="$1"; shift; for s in "$@"; do printf "[%s] " "$s"; kit_source_resolve "$k" "$s" || printf "FAIL\\n"; done'
    assert BASH is not None
    out = subprocess.run(
        [BASH, "-c", script, "x", str(KIT_TRANSLATE), str(kit_arg), *_SOURCES],
        capture_output=True, text=True, check=True, env={"PATH": os.environ.get("PATH", ""), "LC_ALL": "C"},
    ).stdout
    expected = []
    for source in _SOURCES:
        got = kitspec.resolve_source(kit_arg, source)
        expected.append(f"[{source}] " + ("FAIL" if got is None else str(got)))
    assert out.splitlines() == expected
    assert kitspec.resolve_source(kit_arg, "files/a") == (kit / "files" / "a").resolve()
    for source in _HOST_DEPENDENT_SOURCES:
        assert kitspec.resolve_source(kit_arg, source) is None
    assert kitspec.resolve_source(kit_arg, "files/link_out") is None


def _tree_cases(tmp_path: Path) -> dict[str, tuple[Path, Path]]:
    cases = {}
    for name in ("clean", "outside", "dangling-in", "dangling-out", "loop", "newline", "toplink"):
        kit = tmp_path / name
        tree = kit / "files"
        (tree / "sub").mkdir(parents=True)
        (tree / "sub" / "f").write_text("f\n")
        (tree / "in").symlink_to("sub/f")
        (tree / "kitroot").symlink_to("..")
        cases[name] = (kit, tree)
    (tmp_path / "outside" / "files" / "sub" / "out").symlink_to(tmp_path)
    (tmp_path / "dangling-in" / "files" / "dl").symlink_to("missing")
    (tmp_path / "dangling-in" / "files" / "dl-slash").symlink_to("missing/")
    (tmp_path / "dangling-in" / "files" / "through-file").symlink_to("sub/f/x")
    (tmp_path / "dangling-out" / "files" / "dl").symlink_to(tmp_path / "missing")
    (tmp_path / "loop" / "files" / "l1").symlink_to("l2")
    (tmp_path / "loop" / "files" / "l2").symlink_to("l1")
    (tmp_path / "newline" / "files" / "bad\nname").write_text("x\n")
    top = tmp_path / "toplink"
    shutil.rmtree(top / "files")
    (top / "elsewhere").mkdir()
    (top / "elsewhere" / "x").symlink_to(tmp_path)
    (top / "files").symlink_to("elsewhere")
    return cases


@needs_bash
def test_tree_symlink_parity(tmp_path):
    script = '. "$1"; kit_tree_symlinks_within "$2" "$3"; echo "rc=$?" >&2'
    assert BASH is not None
    for name, (kit, tree) in _tree_cases(tmp_path).items():
        proc = subprocess.run(
            [BASH, "-c", script, "x", str(KIT_TRANSLATE), str(kit), str(tree)],
            capture_output=True, text=True, env={"PATH": os.environ.get("PATH", ""), "LC_ALL": "C"},
        )
        lines = proc.stderr.splitlines()
        rc = lines.pop()
        problems = kitspec.tree_symlinks_within(kit, tree)
        assert sorted(lines) == sorted(problems), name
        assert rc == ("rc=0" if not problems else "rc=1"), name
    assert kitspec.tree_symlinks_within(tmp_path, tmp_path / "absent") == []


# ---------------------------------------------------------------------------
# Pin parity: the control-plane ref, the bundle, and the Bash pin agree.
# ---------------------------------------------------------------------------


def _bash_assignment(name: str) -> str:
    match = re.search(rf'^{name}="([^"]*)"', COMMON_SH.read_text(encoding="utf-8"), re.MULTILINE)
    assert match, name
    return match.group(1)


def _bash_array(name: str) -> list[str]:
    match = re.search(rf"^{name}=\(([^)]*)\)", COMMON_SH.read_text(encoding="utf-8"), re.MULTILINE)
    assert match, name
    return [t.replace('"$USAI_PROVIDER_KIT_NAME"', "usai-provider") for t in match.group(1).split()]


def test_pin_parity_with_bash():
    ref = _bash_assignment("PATTERNS_KIT_REF")
    assert kits.CONTROL_PLANE_REF == ref
    assert kits.KIT_NETWORK_ALLOW_REF == ref
    assert f"git+https://{kits.CONTROL_PLANE_REPO}.git" == _bash_assignment("PATTERNS_KIT_REPO")
    assert kits.CONTROL_PLANE_DIR == _bash_assignment("PATTERNS_KIT_DIR")
    manifest = kitspec.bundle_manifest()
    assert manifest["ref"] == ref
    assert list(kits.BUILTIN_KIT_NAMES) == _bash_array("ACQ_KIT_NAMES")
    assert list(kitspec.OPTIN_KIT_NAMES) == _bash_array("ACQ_OPTIN_KIT_NAMES")
    assert set(kits.BUILTIN_KIT_NAMES) | {"opencode"} == set(kitspec.bundle_kit_names())


def test_bundle_matches_its_manifest():
    assert kitspec.verify_bundle() == []
    for entry in kitspec.bundle_manifest()["kits"].values():
        for meta in entry["files"].values():
            assert set(meta) == {"git_blob", "size", "upstream_mode"}
    for name in kitspec.bundle_kit_names():
        spec = kitspec.load_bundled_kit(name)
        assert spec.field("schemaVersion") == "hybrid/v1"
        assert spec.field("name") == name
        for entry in spec.files:
            assert kitspec.resolve_source(spec.kit_dir or Path(), entry.source) is not None, (name, entry)
        assert kitspec.tree_symlinks_within(kitspec.bundle_kit_dir(name), kitspec.bundle_kit_dir(name) / "files") == []


def test_kit_network_allow_is_the_bundle_allowlist():
    bundle = kitspec.bundle_network_allow()
    for name in kits.BUILTIN_KIT_NAMES:
        assert kits.KIT_NETWORK_ALLOW[name] == bundle[name], name
    # kits.KIT_NETWORK_ALLOW["opencode"] describes the Python nix agent kit,
    # not the bundled Patterns opencode kit, which also allows npm's registry.
    assert bundle["opencode"] == ("registry.npmjs.org",)


def test_bundle_refuses_a_stale_or_tampered_copy(tmp_path, monkeypatch):
    copy = tmp_path / "kitbundle"
    shutil.copytree(kitspec.BUNDLE_DIR, copy)
    monkeypatch.setattr(kitspec, "BUNDLE_DIR", copy)
    monkeypatch.setattr(kitspec, "BUNDLE_MANIFEST", copy / "MANIFEST.json")
    (copy / "usai-provider" / "files" / "home" / "usai-config" / "model-catalog-snapshot.json").write_text("{}")
    (copy / "git-ssh-sign" / "extra").write_text("x")
    (copy / "opencode" / "spec.yaml").unlink()
    problems = kitspec.verify_bundle()
    assert any("model-catalog-snapshot.json does not match" in p for p in problems)
    assert any("git-ssh-sign: extra is not in the manifest" in p for p in problems)
    assert any("opencode: spec.yaml is missing" in p for p in problems)
    assert not kitspec.agent_kit_ready("opencode")
    doc = json.loads((copy / "MANIFEST.json").read_text())
    doc["kits"]["zscaler-ca-certificate"]["files"]["../escape"] = {}
    (copy / "MANIFEST.json").write_text(json.dumps(doc))
    assert any("bad manifest entry" in p for p in kitspec.verify_bundle())
    doc["ref"] = "0" * 40
    (copy / "MANIFEST.json").write_text(json.dumps(doc))
    with pytest.raises(kitspec.KitSpecError, match="pinned to"):
        kitspec.bundle_manifest()
    assert kitspec.bundled_name_for_ref(kitspec.builtin_kit_ref("usai-provider")) is None
    (copy / "MANIFEST.json").write_text("not json")
    with pytest.raises(kitspec.KitSpecError, match="not valid JSON"):
        kitspec.bundle_manifest()
    (copy / "MANIFEST.json").write_text(json.dumps({"schema": 2}))
    with pytest.raises(kitspec.KitSpecError, match="unknown schema"):
        kitspec.bundle_manifest()
    good = {k: doc[k] for k in ("schema", "repository", "directory")} | {"ref": kits.CONTROL_PLANE_REF}
    (copy / "MANIFEST.json").write_text(json.dumps(good | {"kits": []}))
    with pytest.raises(kitspec.KitSpecError, match="does not list"):
        kitspec.bundle_manifest()
    with pytest.raises(kitspec.KitSpecError):
        kitspec.bundle_kit_dir("usai-provider")


def test_bundle_is_packaged_and_pinned_lf():
    pyproject = (REPO_ROOT / "py-acq" / "pyproject.toml").read_text(encoding="utf-8")
    patterns = re.findall(r'"(kitbundle/[^"]+)"', pyproject)
    root = kitspec.BUNDLE_DIR.parent
    # setuptools expands package-data with glob.glob, which skips hidden paths.
    packaged = {
        Path(match).as_posix()
        for pat in patterns
        for match in glob.glob(pat, root_dir=root, recursive=True)
        if (root / match).is_file()
    }
    on_disk = {p.relative_to(root).as_posix() for p in kitspec.BUNDLE_DIR.rglob("*") if p.is_file()}
    assert packaged == on_disk
    assert "py-acq/src/acq_py/kitbundle/** text eol=lf" in (REPO_ROOT / ".gitattributes").read_text()


# ---------------------------------------------------------------------------
# Kit selection.
# ---------------------------------------------------------------------------

REF = kitspec.builtin_kit_ref
SUPPORT = [REF("zscaler-ca-certificate"), REF("usai-provider"), REF("agentic-coding-playbook"), REF("git-ssh-sign")]


def _write_config(text: str) -> None:
    path = Path(os.environ["XDG_CONFIG_HOME"]) / "acq" / "config.yaml"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def test_selection_defaults():
    sel = kitspec.select_kits("shell", env={})
    assert sel.refs == SUPPORT
    assert [k.role for k in sel.kits] == ["support", "provider", "support", "support"]
    assert [k.bundled for k in sel.kits] == list(kits.BUILTIN_KIT_NAMES)
    assert (sel.builtin_support_count, sel.builtin_count, sel.provider_error) == (4, 4, None)
    sel = kitspec.select_kits("opencode", env={})
    assert sel.refs == [*SUPPORT, REF("opencode")]
    assert sel.kits[-1].role == "agent" and sel.kits[-1].bundled == "opencode"
    assert (sel.builtin_support_count, sel.builtin_count) == (4, 5)
    assert kitspec.select_kits(None, env={}).refs == SUPPORT
    assert kitspec.select_kits("claude", env={}).refs == SUPPORT
    assert kitspec.select_kits("not-an-agent", env={}).refs == SUPPORT


def test_selection_provider_sources():
    assert kitspec.select_kits(None, env={"ACQ_PROVIDER_KITS": ""}).refs == [SUPPORT[0], *SUPPORT[2:]]
    sel = kitspec.select_kits(None, env={"ACQ_PROVIDER_KITS": " /p/one\tgit+https://x/y.git#ref=a&dir=b \n"})
    assert sel.refs == [SUPPORT[0], "/p/one", "git+https://x/y.git#ref=a&dir=b", *SUPPORT[2:]]
    assert [k.bundled for k in sel.kits][1:3] == [None, None]
    # --no-provider-kits beats the environment.
    assert kitspec.select_kits(None, env={"ACQ_PROVIDER_KITS": "/p"}, no_provider_kits=True).refs == [
        SUPPORT[0], *SUPPORT[2:]]
    for value in ("usai-provider", "usai-provider@agentic-coding-patterns", "agentic-coding-patterns/usai-provider",
                  "github.com/GSA-TTS/agentic-coding-patterns/usai-provider",
                  "usai-provider@github.com/GSA-TTS/agentic-coding-patterns", f'"{REF("usai-provider")}" # c'):
        _write_config(f"provider_kit: {value}\n")
        assert kitspec.select_kits(None, env={}).refs == SUPPORT, value
    _write_config("provider_kit: openchamber\n")
    assert kitspec.select_kits(None, env={}).refs[1] == REF("openchamber")
    _write_config("provider_kit: ./local-provider\n")
    assert kitspec.select_kits(None, env={}).refs[1] == "./local-provider"
    # The environment beats config.
    assert kitspec.select_kits(None, env={"ACQ_PROVIDER_KITS": "/env"}).refs[1] == "/env"


@pytest.mark.parametrize(
    ("value", "message"),
    [
        ("git+https://github.com/evil/kits.git#ref=abc&dir=k", "untrusted remote ref"),
        ("git+https://user@github.com/GSA-TTS/agentic-coding-patterns.git#ref=a&dir=b", "untrusted"),
        ("usai provider", "unsafe kit name"),
        ("agentic-coding-patterns/", "does not name a kit"),
        ("kit@github.com/acme/untrusted", "is not trusted"),
        ("kit@unknown-source", "is not registered"),
    ],
)
def test_selection_provider_errors_are_latched(value, message):
    _write_config(f"provider_kit: {value}\n")
    sel = kitspec.select_kits("shell", env={})
    assert sel.refs == [SUPPORT[0], *SUPPORT[2:]]
    assert sel.provider_error is not None and message in sel.provider_error
    with pytest.raises(kitspec.KitSelectionError, match="provider kit could not be resolved"):
        sel.require_provider()
    kitspec.select_kits("shell", env={"ACQ_PROVIDER_KITS": ""}).require_provider()


def test_selection_provider_from_registered_sources():
    sha = "a" * 40
    kits.set_source("github.com/acme/kits", sha, "k")
    kits.set_source("github.com/other/kits", "b" * 40, ".")
    _write_config("provider_kit: github.com/acme/kits/p\n")
    assert kitspec.select_kits(None, env={}).refs[1] == f"git+https://github.com/acme/kits.git#ref={sha}&dir=k/p"
    _write_config("provider_kit: p@github.com/other/kits\n")
    assert kitspec.select_kits(None, env={}).refs[1] == f"git+https://github.com/other/kits.git#ref={'b' * 40}&dir=p"
    _write_config("provider_kit: kits/p\n")
    assert "ambiguous" in (kitspec.select_kits(None, env={}).provider_error or "")
    _write_config("provider_kit: git+https://github.com/acme/kits.git#ref=x&dir=y\n")
    assert kitspec.select_kits(None, env={}).refs[1] == "git+https://github.com/acme/kits.git#ref=x&dir=y"
    _write_config("provider_kit: git+https://github.com/acme/other.git#ref=x&dir=y\n")
    assert kitspec.select_kits(None, env={}).provider_error
    env = {kits.EXTRA_KIT_SOURCES_ENV: "github.com/acme/"}
    assert kitspec.select_kits(None, env=env).refs[1] == "git+https://github.com/acme/other.git#ref=x&dir=y"


def test_selection_registered_source_without_ref(monkeypatch):
    monkeypatch.setenv(kits.SEED_ENV, json.dumps([{"repository": "github.com/acme/unpinned"}]))
    _write_config("provider_kit: p@unpinned\n")
    assert "no pinned ref" in (kitspec.select_kits(None, env={}).provider_error or "")


def test_selection_extra_and_cli_kits(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    (tmp_path / "localkit").mkdir()
    env = {"ACQ_EXTRA_KITS": "localkit git+https://e/x.git#ref=1&dir=d missing-dir"}
    sel = kitspec.select_kits("opencode", env=env, cli_kits=["localkit", "/abs/kit"])
    local = str((tmp_path / "localkit").resolve())
    assert sel.refs[4:] == [local, "git+https://e/x.git#ref=1&dir=d", "missing-dir", local, "/abs/kit"]
    assert [k.role for k in sel.kits[4:]] == ["extra", "extra", "extra", "cli", "cli"]
    # Any --kit drops the implicit agent kit, unless that agent kit is required.
    assert sel.builtin_count == 4 and REF("opencode") not in sel.refs
    sel = kitspec.select_kits("opencode", env={}, cli_kits=["/k"], required_agent_kit="opencode")
    assert sel.refs == [*SUPPORT, REF("opencode"), "/k"]
    assert kitspec.kit_ref_absolute("C:/kits/x") == "C:/kits/x"
    assert kitspec.kit_ref_absolute("") == ""


def test_selection_configured_extra_kits():
    _write_config("extra_kits: openchamber paseo # picked\n")
    # Only create and run fold config extras in; _build_kit_list alone does not.
    assert kitspec.select_kits(None, env={}).refs == SUPPORT
    sel = kitspec.select_kits(None, env={}, configured_extras=True)
    assert sel.refs[4:] == [REF("openchamber"), REF("paseo")]
    assert [k.bundled for k in sel.kits[4:]] == [None, None]
    sel.require()
    # A non-empty ACQ_EXTRA_KITS wins, even when it is only whitespace.
    for value, expected in (("/e", ["/e"]), ("  ", []), ("", [REF("openchamber"), REF("paseo")])):
        sel = kitspec.select_kits(None, env={"ACQ_EXTRA_KITS": value}, configured_extras=True)
        assert sel.refs[4:] == expected, value


def test_selection_unknown_configured_extra_is_latched():
    _write_config("extra_kits: openchamber git+https://evil/x.git\n")
    # Verbs other than create and run never read config extras, so they cannot be locked out.
    plain = kitspec.select_kits(None, env={})
    assert plain.extras_error is None
    plain.require()
    sel = kitspec.select_kits(None, env={}, configured_extras=True)
    assert sel.refs == SUPPORT
    assert sel.extras_error is not None and "unknown kit 'git+https://evil/x.git'" in sel.extras_error
    sel.require_provider()
    with pytest.raises(kitspec.KitSelectionError, match="unknown kit"):
        sel.require()
    with pytest.raises(kitspec.KitSelectionError, match="unknown kit"):
        sel.require_extras()
    # ACQ_EXTRA_KITS from the environment means config is not consulted at all.
    assert kitspec.select_kits(None, env={"ACQ_EXTRA_KITS": "/e"}, configured_extras=True).extras_error is None


def test_selection_required_agent_kit():
    with pytest.raises(kitspec.KitSelectionError, match="required built-in opencode kit"):
        kitspec.select_kits("opencode", env={}, required_agent_kit="opencode", ready=lambda agent: False)
    assert kitspec.select_kits("opencode", env={}, ready=lambda agent: False).refs == SUPPORT
    assert kitspec.select_kits("shell", env={}, required_agent_kit="opencode", ready=lambda a: False).refs == SUPPORT
    assert not kitspec.agent_kit_ready("claude")


@pytest.mark.parametrize(
    ("line", "value"),
    [
        ("extra_kits: a b", "a b"),
        ('extra_kits: "a # b" # c', "a # b"),
        ("extra_kits: 'a b'", "a b"),
        ("extra_kits: a#b", "a#b"),
        ("extra_kits: # only a comment", ""),
        ("extra_kits :  spaced  ", "spaced"),
        ("extra_kits: '", ""),
        ('extra_kits: "unterminated', '"unterminated'),
        ("  extra_kits: indented", ""),
    ],
)
def test_config_read_field(line, value):
    _write_config(f"backend: msb\n{line}\n")
    assert kitspec.config_read_field("extra_kits") == value
    assert kitspec.config_read_field("bad key") == ""


def test_config_read_field_last_wins_and_absent():
    assert kitspec.config_read_field("extra_kits") == ""
    _write_config("extra_kits: a\nextra_kits: b\n")
    assert kitspec.config_read_field("extra_kits") == "b"
    _write_config("extra_kits: a\nextra_kits:\n")
    assert kitspec.config_read_field("extra_kits") == ""


# Bash selection parity: source acq the way the bats suite does and compare
# KITS for the same environment, config and arguments.
BASH_SELECT = r"""
ACQ_SOURCE_ONLY=1 . "$REPO/acq"
agent="$1"; shift
ACQ_CLI_KITS=("$@")
if [ -n "${NO_PROVIDER:-}" ]; then ACQ_PROVIDER_KITS=""; ACQ_PROVIDER_KITS_FROM_CLI=1; fi
if [ -n "${REQUIRED:-}" ]; then ACQ_REQUIRED_AGENT_KIT="$REQUIRED"; fi
_acq_kit_refs_make_absolute
if [ -n "${APPLY:-}" ]; then
  _acq_apply_configured_extra_kits 2>/dev/null || { echo ERROR; exit 0; }
fi
_build_kit_list "$agent" 2>/dev/null || { echo ERROR; exit 0; }
printf 'K %s\n' "${KITS[@]}"
printf 'S %s\nB %s\n' "$ACQ_BUILTIN_SUPPORT_KIT_COUNT" "$ACQ_BUILTIN_KIT_COUNT"
[ -z "$ACQ_PROVIDER_SELECTION_ERROR" ] || echo PROVIDER-ERROR
"""

_SELECTION_CASES = [
    ("defaults", "shell", [], {}, None),
    ("agent", "opencode", [], {}, None),
    ("agent-with-cli", "opencode", ["localkit", "/abs"], {}, None),
    ("required-with-cli", "opencode", ["/abs"], {"REQUIRED": "opencode"}, None),
    ("required-broken", "opencode", [], {"REQUIRED": "opencode", "BROKEN_AGENT": "1"}, None),
    ("provider-empty", "shell", [], {"ACQ_PROVIDER_KITS": ""}, None),
    ("provider-env", "shell", [], {"ACQ_PROVIDER_KITS": "/p1 git+https://x/y.git#ref=a&dir=b"}, None),
    ("no-provider", "shell", [], {"NO_PROVIDER": "1", "ACQ_PROVIDER_KITS": "/p"}, None),
    ("extra-env", "shell", ["c1"], {"ACQ_EXTRA_KITS": "localkit missing git+https://e/x.git#ref=1&dir=d"}, None),
    ("extra-config", "shell", [], {"APPLY": "1"}, "extra_kits: openchamber paseo # c\n"),
    ("extra-env-wins", "shell", [], {"APPLY": "1", "ACQ_EXTRA_KITS": "/e"}, "extra_kits: paseo\n"),
    ("extra-config-unknown", "shell", [], {"APPLY": "1"}, "extra_kits: openchamber nope\n"),
    # _build_kit_list without _acq_apply_configured_extra_kits ignores config extras.
    ("extra-config-no-apply", "opencode", [], {}, "extra_kits: openchamber paseo\n"),
    ("extra-config-unknown-no-apply", "shell", [], {}, "extra_kits: openchamber nope\n"),
    ("provider-short", "shell", [], {}, "provider_kit: usai-provider@agentic-coding-patterns\n"),
    ("provider-full", "shell", [], {}, "provider_kit: github.com/GSA-TTS/agentic-coding-patterns/openchamber\n"),
    ("provider-local", "shell", [], {}, "provider_kit: ./local\n"),
    ("provider-trusted-ref", "shell", [], {}, f"provider_kit: {REF('usai-provider')}\n"),
    ("provider-untrusted", "shell", [], {}, "provider_kit: git+https://github.com/evil/k.git#ref=a&dir=b\n"),
    ("provider-unsafe", "shell", [], {}, "provider_kit: usai provider\n"),
    ("provider-unregistered", "shell", [], {}, "provider_kit: kit@nowhere\n"),
]


@needs_bash
@pytest.mark.parametrize(("case", "agent", "cli", "extra_env", "config"), _SELECTION_CASES)
def test_selection_parity_with_bash(tmp_path, monkeypatch, case, agent, cli, extra_env, config):
    monkeypatch.chdir(tmp_path)
    (tmp_path / "localkit").mkdir()
    if config is not None:
        _write_config(config)
    agent_kit = kitspec.bundle_kit_dir("opencode")
    if extra_env.get("BROKEN_AGENT"):
        agent_kit = tmp_path / "broken-agent"
        agent_kit.mkdir()
        (agent_kit / "spec.yaml").write_text('schemaVersion: "hybrid/v1"\nkind: mixin\nname: opencode\n')
    env = {k: v for k, v in os.environ.items() if not k.startswith("ACQ_")}
    env |= {k: v for k, v in extra_env.items() if k != "BROKEN_AGENT"}
    # Bash validates the agent kit by fetching it; the bats seam points it at a
    # local copy instead, which is the bundled kit unless the case breaks it.
    env |= {"REPO": str(REPO_ROOT), "BATS_TEST_NAME": "kitspec-parity", "ACQ_TEST_AGENT_KIT": str(agent_kit),
            "ACQ_STATE_DIR": str(tmp_path / "state"), "LC_ALL": "C"}
    assert BASH is not None
    out = subprocess.run([BASH, "-c", BASH_SELECT, "x", agent, *cli], env=env, capture_output=True, text=True,
                         check=True, cwd=tmp_path).stdout
    py_env = {k: v for k, v in extra_env.items() if k.startswith("ACQ_")}
    try:
        sel = kitspec.select_kits(
            agent, cli_kits=cli, env=py_env, no_provider_kits=bool(extra_env.get("NO_PROVIDER")),
            required_agent_kit=extra_env.get("REQUIRED"), configured_extras=bool(extra_env.get("APPLY")),
            ready=(lambda a: False) if extra_env.get("BROKEN_AGENT") else kitspec.agent_kit_ready,
        )
    except kitspec.KitSelectionError:
        assert out == "ERROR\n", case
        return
    if sel.extras_error is not None:
        assert out == "ERROR\n", case
        return
    lines = [f"K {str(agent_kit) if r == REF('opencode') else r}" for r in sel.refs]
    lines += [f"S {sel.builtin_support_count}", f"B {sel.builtin_count}"]
    if sel.provider_error:
        lines.append("PROVIDER-ERROR")
    assert out.splitlines() == lines, case
