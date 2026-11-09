"""Neutral ``hybrid/v1`` kit specs, the built-in kit bundle, and kit selection.

Host side only: this module parses and selects kits. It never runs kit code and
never talks to a backend. The msb and sbx adapters apply what it returns.

Parser
    :class:`KitSpec` reads the subset of ``hybrid/v1`` that acq consumes: the
    top-level scalars, ``files``, ``commands`` (by phase), ``environment``,
    ``caps.network.allow``, ``publishedPorts``, ``volumes``, ``agentContext``,
    the ``agent`` block and ``backend_shortcuts``. Each section is a line-by-line
    port of the matching awk program in ``acq.backends/kit-translate.sh``
    (``kit_spec_*``) or ``acq.backends/common.sh`` (``kit_spec_agent_field``).
    It accepts, drops and warns on exactly what Bash does, with the same
    warning text, so both implementations build the same sandbox from the same
    kit. It is deliberately not a YAML parser: like the awk, it reads the shape
    the kits are written in.

    The awk programs work on bytes, with ASCII character classes. The port
    decodes the spec as Latin-1 (one character per byte) so that every offset
    and class test matches, and converts each result back to UTF-8. On top of
    the Bash rules it refuses, as a whole, input Bash would mishandle silently:
    a spec that is not a regular file, larger than 1 MiB, not UTF-8, or contains
    a NUL byte; a command argument over 64 KiB (Bash passes each argument to a
    shell command line, which the kernel caps); and an ``agentContext`` dedent
    that would cut a multi-byte character in half.

Built-in bundle
    The built-in kits ship as package data under ``kitbundle/``, copied from the
    control-plane repository at :data:`kits.CONTROL_PLANE_REF` by
    ``scripts/refresh-kitbundle``. ``MANIFEST.json`` records that ref and the
    git blob id and size of every file, so the copy can be checked offline
    (:func:`verify_bundle`); CI also checks the blob ids against the pinned
    Patterns tree. Each entry's ``upstream_mode`` is informational: acq does not
    verify the bundled files against it (package data carries no file modes, and
    ``files[].mode`` sets the in-guest mode), though ``refresh-kitbundle
    --check`` compares it with the pinned tree. acq never fetches a built-in kit
    during ordinary operation (ADR-0042m).

Selection
    :func:`select_kits` mirrors Bash ``_build_kit_list`` and
    ``_acq_selected_support_kit_refs``: CA trust, the provider kit(s), the
    playbook, git signing, the agent kit, then extra kits (``ACQ_EXTRA_KITS`` or
    the configured ``extra_kits``), then ``--kit`` refs.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import stat
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from dataclasses import field as dc_field
from pathlib import Path

from . import kits, userdirs

# ---------------------------------------------------------------------------
# Limits and awk character classes.
# ---------------------------------------------------------------------------

# The same ceiling kits.validate_kit applies to a spec it reads.
MAX_SPEC_BYTES = 1024 * 1024

# Bash base64-encodes each command argument by passing it inside an `sh -c`
# command line, and Linux refuses a single argument over 128 KiB. Python refuses
# well below that instead of emitting an argument Bash would have mangled.
MAX_COMMAND_TOKEN_BYTES = 64 * 1024

# POSIX [[:space:]] in the C locale.
_WS = " \t\n\v\f\r"
_S = "[ \t\n\v\f\r]"
_NS = "[^ \t\n\v\f\r]"

_BLANK = re.compile(_S + "*")  # use with fullmatch
_COMMENT = re.compile(_S + "*#")
_TOP_LEVEL = re.compile("[A-Za-z]")
_INDENTED_KEY = re.compile(_S + "+[A-Za-z]")
_DASH_ITEM = re.compile(_S + "+-" + _S)
_DASH_PREFIX = re.compile(_S + "*-" + _S + "*")
_KEY_PREFIX = re.compile("[^:]*:" + _S + "*")
_TRAILING_COMMENT = re.compile(_S + "*#.*", re.DOTALL)
_BLOCK_INDICATOR = re.compile("[|>][0-9+-]*")  # use with fullmatch
_DQUOTE_ENDS = re.compile('^"|"$')
_SQUOTE_ENDS = re.compile("^'|'$")

_SAFE_PATH = re.compile(r"[A-Za-z0-9._/-]+")
_DOTDOT_SEGMENT = re.compile(r"(^|/)\.\.(/|$)")
_OCTAL_MODE = re.compile(r"[0-7][0-7][0-7][0-7]?")
_SAFE_USER = re.compile(r"[A-Za-z0-9_-]+")
_PHASES = ("install", "initFiles", "startup")
_ENV_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
_PORT_NAME = re.compile(r"[A-Za-z0-9._-]+")
_VOLUME_PATH = re.compile(r"/[A-Za-z0-9._/-]+")
_VOLUME_NOT_NORMAL = re.compile(r"//|/\.\.?(/|$)|/$")
_VOLUME_SIZE = re.compile(r"[0-9]+(\.[0-9]+)?[kKmMgGtTpP]?")
_VOLUME_ZERO = re.compile(r"0+(\.0+)?[kKmMgGtTpP]?")
_IDENT = re.compile(r"[A-Za-z0-9_]+")


class KitSpecError(kits.KitSpecError):
    """A kit cannot be read, or holds input this parser refuses as a whole."""


def _trim(s: str) -> str:
    return s.lstrip(_WS).rstrip(_WS)


def _strip_dquotes(s: str) -> str:
    return _DQUOTE_ENDS.sub("", s)


def _trim_q(s: str) -> str:
    """The kit-translate ``trim``: whitespace, then one double quote at each end."""
    return _strip_dquotes(_trim(s))


def _indent_of(s: str) -> int:
    """awk ``indent_of``: leading spaces, and 0 for a line that is all spaces."""
    i = len(s) - len(s.lstrip(" "))
    return 0 if i == len(s) else i


def _key_of(line: str) -> str:
    return line.split(":", 1)[0]


def _value_of(line: str) -> str:
    return _KEY_PREFIX.sub("", line, count=1)


def _uncomment(s: str) -> str:
    return _TRAILING_COMMENT.sub("", s, count=1)


def _text(s: str) -> str:
    """Convert a Latin-1 parse result back to the UTF-8 text it came from."""
    try:
        return s.encode("latin-1").decode("utf-8")
    except UnicodeDecodeError as exc:
        raise KitSpecError("kit spec cuts a multi-byte character in half") from exc


def _is_port(p: str) -> bool:
    if not p or not p.isascii() or not p.isdigit():
        return False
    digits = p.lstrip("0")
    return len(digits) <= 5 and 1 <= int(digits or "0") <= 65535


# ---------------------------------------------------------------------------
# Parsed records.
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class FileEntry:
    """One ``files[]`` entry, as Bash ``kit_spec_files`` emits it."""

    path: str
    mode: str
    phase: str
    source: str
    readonly: bool

    def record(self) -> str:
        return "\t".join((self.path, self.mode, self.phase, self.source, "true" if self.readonly else ""))


@dataclass(frozen=True)
class Command:
    """One ``commands[]`` entry. ``phase`` and ``user`` are "" when unset."""

    phase: str
    user: str
    background: bool
    argv: tuple[str, ...]

    def record_lines(self) -> list[str]:
        head = "\t".join(("__CMD__", self.phase, self.user, "true" if self.background else "false"))
        body = [base64.b64encode(tok.encode("utf-8")).decode("ascii") for tok in self.argv]
        return [head, *body, "__END__"]


@dataclass(frozen=True)
class PublishedPort:
    """One published port. ``host`` stays "" when the kit left it to the backend."""

    guest: str
    protocol: str
    name: str
    host: str

    def record(self) -> str:
        return "\t".join((self.guest, self.protocol, self.name, self.host))


@dataclass(frozen=True)
class Volume:
    """One ``volumes[]`` entry. ``type`` is "" for the default block volume."""

    path: str
    type: str
    size: str

    def record(self) -> str:
        return "\t".join((self.path, self.type, self.size))


@dataclass(frozen=True)
class EnvVar:
    """One ``environment`` entry (non-secret configuration only)."""

    name: str
    value: str

    def record(self) -> str:
        return f"{self.name}\t{self.value}"


# ---------------------------------------------------------------------------
# Section parsers. Each mirrors one awk program, rule by rule and in rule order.
# ---------------------------------------------------------------------------


def _parse_field(lines: Sequence[str], key: str) -> str | None:
    """``kit_spec_field``: a top-level scalar, or a folded/literal block joined by spaces."""
    collecting = False
    buf = ""
    for line in lines:
        if collecting:
            if re.match(_S, line) or _BLANK.fullmatch(line):
                if not _BLANK.fullmatch(line):
                    t = _trim(line)
                    buf = t if buf == "" else f"{buf} {t}"
                continue
            return buf
        if re.match("[A-Za-z][A-Za-z0-9_]*:", line) and _key_of(line) == key:
            v = _value_of(line)
            if _BLOCK_INDICATOR.fullmatch(v):
                collecting, buf = True, ""
                continue
            v = _SQUOTE_ENDS.sub("", _strip_dquotes(v))
            if v != "":
                return v
    return buf if collecting else None


def _parse_agent_field(lines: Sequence[str], key: str) -> str | None:
    """``kit_spec_agent_field``: ``agent.<key>`` (the first matching line decides)."""
    in_agent = False
    key_re = re.compile("  " + re.escape(key) + ":" + _S + "*")
    for line in lines:
        if re.match("agent:" + _S + "*($|#)", line):
            in_agent = True
            continue
        if re.match("[^ \t\n\v\f\r#][^:]*:", line):
            in_agent = False
        if in_agent:
            stripped = _uncomment(line)
            if key_re.match(stripped):
                value = _trim(key_re.sub("", stripped, count=1))
                value = _SQUOTE_ENDS.sub("", _strip_dquotes(value))
                return value if value != "" else None
    return None


def _parse_net_allow(lines: Sequence[str]) -> list[str]:
    """``kit_spec_net_allow``: each ``caps.network.allow`` entry."""
    out: list[str] = []
    in_caps = in_net = in_allow = False
    for line in lines:
        if line.startswith("caps:"):
            in_caps = True
            continue
        if _TOP_LEVEL.match(line):
            in_caps = in_net = in_allow = False
        if in_caps and re.match(_S + "+network:", line):
            in_net = True
            continue
        if in_net and re.match(_S + "+allow:", line):
            in_allow = True
            continue
        if in_allow:
            if re.match(_S + "+-", line):
                v = _uncomment(_DASH_PREFIX.sub("", line, count=1)).rstrip(_WS)
                v = _strip_dquotes(v)
                if v != "":
                    out.append(v)
            elif not _COMMENT.match(line):
                in_allow = False
    return out


class _PortParser:
    """``_kit_pp_parse_neutral``: raw ``guest<TAB>proto<TAB>name<TAB>host`` records."""

    def __init__(self) -> None:
        self.out: list[str] = []
        self.cur = {"guest": "", "host": "", "protocol": "", "name": ""}

    def flush(self) -> None:
        c = self.cur
        if c["guest"] != "":
            self.out.append("\t".join((c["guest"], c["protocol"], c["name"], c["host"])))
        self.cur = dict.fromkeys(c, "")

    def kv(self, text: str) -> None:
        k = _trim_q(_key_of(text))
        v = _trim_q(_uncomment(_value_of(text)))
        if k in self.cur:
            self.cur[k] = v

    def run(self, lines: Sequence[str]) -> list[str]:
        in_pp = False
        for line in lines:
            if re.fullmatch("publishedPorts:" + _S + "*", line):
                in_pp = True
                self.flush()
                continue
            if _TOP_LEVEL.match(line) and in_pp:
                self.flush()
                in_pp = False
            if not in_pp or _BLANK.fullmatch(line) or _COMMENT.match(line):
                continue
            if _DASH_ITEM.match(line):
                self.flush()
                self.kv(_DASH_PREFIX.sub("", line, count=1))
            elif _INDENTED_KEY.match(line):
                self.kv(line)
        if in_pp:
            self.flush()
        return self.out


class _LegacyPortParser:
    """``_kit_pp_parse_legacy``: the deprecated ``backend_extras.sbx.publishedPorts``."""

    _KEYS = ("container", "protocol", "name")

    def __init__(self) -> None:
        self.out: list[str] = []
        self.cur = dict.fromkeys(self._KEYS, "")
        self.in_be = self.in_sbx = self.in_pp = False
        self.sbx_ind = 0

    def flush(self) -> None:
        c = self.cur
        if c["container"] != "":
            self.out.append("\t".join((c["container"], c["protocol"], c["name"], "")))
        self.cur = dict.fromkeys(self._KEYS, "")

    def kv(self, text: str) -> str:
        k = _trim_q(_key_of(text))
        if k in self.cur:
            self.cur[k] = _trim_q(_uncomment(_value_of(text)))
        return k

    def feed(self, line: str) -> None:
        if line.startswith("backend_extras:"):
            self.in_be = True
            return
        if _TOP_LEVEL.match(line) and self.in_be:
            self.flush()
            self.in_be = self.in_sbx = self.in_pp = False
        if not self.in_be:
            return
        if re.fullmatch(_S + "+sbx:" + _S + "*", line):
            self.in_sbx, self.in_pp, self.sbx_ind = True, False, _indent_of(line)
            return
        if (self.in_sbx and re.match(_S + "+[A-Za-z_]+:", line) and _indent_of(line) <= self.sbx_ind
                and "publishedPorts:" not in line and _indent_of(line) == self.sbx_ind):
            self.flush()
            self.in_sbx = self.in_pp = False
        if self.in_sbx and re.search("publishedPorts:" + _S + "*$", line):
            self.in_pp = True
            self.flush()
            return
        if self.in_pp:
            self.feed_item(line)

    def feed_item(self, line: str) -> None:
        if _DASH_ITEM.match(line):
            self.flush()
            self.kv(_DASH_PREFIX.sub("", line, count=1))
        elif _INDENTED_KEY.match(line):
            k = self.kv(line)
            if _indent_of(line) <= self.sbx_ind + 2 and k not in self._KEYS:
                self.flush()
                self.in_pp = False

    def run(self, lines: Sequence[str]) -> list[str]:
        for line in lines:
            self.feed(line)
        if self.in_be:
            self.flush()
        return self.out


def _validate_ports(records: Sequence[str], warn: list[str]) -> list[PublishedPort]:
    """``_kit_pp_validate``: drop records with a bad port, protocol or name."""
    out: list[PublishedPort] = []
    for rec in records:
        g, p, n, h = ([*rec.split("\t"), "", "", ""])[:4]
        if g == "":
            continue
        if not _is_port(g):
            warn.append(f"kit-translate: skipping published port with invalid guest port: {g}")
        elif h != "" and not _is_port(h):
            warn.append(f"kit-translate: skipping published port with invalid host port: {h}")
        elif p not in ("", "tcp", "udp"):
            warn.append(f"kit-translate: skipping published port with invalid protocol: {p}")
        elif n != "" and not _PORT_NAME.fullmatch(n):
            warn.append(f"kit-translate: skipping published port with unsafe name: {n}")
        else:
            out.append(PublishedPort(g, p, n, h))
    return out


_PORT_DEPRECATION = (
    "kit-translate: DEPRECATION: backend_extras.sbx.publishedPorts is deprecated;",
    "kit-translate:   move ports to the neutral top-level 'publishedPorts:' list",
    "kit-translate:   ({guest, host?, protocol?, name?}). The sbx-only fallback is",
    "kit-translate:   removed in the next minor release (ADR-0014).",
)


def _parse_ports(lines: Sequence[str], warn: list[str]) -> list[PublishedPort]:
    """``kit_spec_published_ports``: the neutral list, else the deprecated sbx one."""
    neutral = _PortParser().run(lines)
    if neutral:
        return _validate_ports(neutral, warn)
    legacy = _LegacyPortParser().run(lines)
    if not legacy:
        return []
    warn.extend(_PORT_DEPRECATION)
    return _validate_ports(legacy, warn)


def _parse_volume_records(lines: Sequence[str]) -> list[tuple[str, str, str]]:
    """``_kit_vol_parse_neutral``: raw ``(path, type, size)`` records."""
    out: list[tuple[str, str, str]] = []
    cur = {"path": "", "type": "", "size": ""}

    def flush() -> None:
        nonlocal cur
        if any(cur.values()):
            out.append((cur["path"], cur["type"], cur["size"]))
        cur = dict.fromkeys(cur, "")

    def kv(text: str) -> None:
        k = _trim_q(_key_of(text))
        if k in cur:
            cur[k] = _trim_q(_uncomment(_value_of(text)))

    in_v = False
    for line in lines:
        if re.fullmatch("volumes:" + _S + "*", line):
            in_v = True
            flush()
            continue
        if _TOP_LEVEL.match(line) and in_v:
            flush()
            in_v = False
        if not in_v or _BLANK.fullmatch(line) or _COMMENT.match(line):
            continue
        if _DASH_ITEM.match(line):
            flush()
            kv(_DASH_PREFIX.sub("", line, count=1))
        elif _INDENTED_KEY.match(line):
            kv(line)
    if in_v:
        flush()
    return out


def _volume_problem(p: str, t: str, s: str) -> str | None:
    """The ``_kit_vol_validate`` warning for one record, or ``None`` when it is valid."""
    if p == "":
        return f"kit-translate: skipping volume with missing path (size: {s})"
    if not _VOLUME_PATH.fullmatch(p):
        return f"kit-translate: skipping volume with unsafe path: {p}"
    if _VOLUME_NOT_NORMAL.search(p):
        return ("kit-translate: skipping volume with non-normalized path "
                f"(no . or .. segments, no //, no trailing /): {p}")
    if t not in ("", "tmpfs"):
        return f"kit-translate: skipping volume with invalid type: {t}"
    if s == "":
        return f"kit-translate: skipping volume with missing size: {p}"
    if not _VOLUME_SIZE.fullmatch(s):
        return ("kit-translate: skipping volume with invalid size "
                f"(portable grammar: 20G, 512m; no b/ib suffix): {s}")
    if _VOLUME_ZERO.fullmatch(s):
        return f"kit-translate: skipping volume with zero size: {s}"
    return None


def _parse_volumes(lines: Sequence[str], warn: list[str]) -> list[Volume]:
    """``kit_spec_volumes``."""
    out: list[Volume] = []
    for p, t, s in _parse_volume_records(lines):
        # The record crosses a tab-separated pipe in Bash: a tab inside a value
        # shifts the later fields exactly as awk -F'\t' would see them.
        p, t, s = ([*"\t".join((p, t, s)).split("\t"), "", ""])[:3]
        problem = _volume_problem(p, t, s)
        if problem is None:
            out.append(Volume(p, t, s))
        else:
            warn.append(problem)
    return out


class _FileParser:
    """``kit_spec_files``."""

    _KEYS = ("path", "mode", "phase", "source", "readonly", "description")

    def __init__(self, warn: list[str]) -> None:
        self.warn = warn
        self.out: list[FileEntry] = []
        self.cur = dict.fromkeys(self._KEYS, "")

    def kv(self, text: str) -> None:
        k = _trim_q(_key_of(text))
        if k in self.cur:
            self.cur[k] = _trim_q(_uncomment(_value_of(text)))

    def flush(self) -> None:
        c = self.cur
        self.cur = dict.fromkeys(self._KEYS, "")
        path, mode, source = c["path"], c["mode"], c["source"]
        if path == "":
            return
        if mode != "" and not _OCTAL_MODE.fullmatch(mode):
            self.warn.append(f"kit-translate: skipping file with invalid mode: {mode}")
        elif not _SAFE_PATH.fullmatch(path):
            self.warn.append(f"kit-translate: skipping file with unsafe path: {path}")
        elif source != "" and (not _SAFE_PATH.fullmatch(source) or source.startswith("/")
                               or _DOTDOT_SEGMENT.search(source)):
            self.warn.append(f"kit-translate: skipping file with unsafe source: {source}")
        else:
            self.out.append(FileEntry(path, mode, c["phase"], source, c["readonly"] == "true"))

    def run(self, lines: Sequence[str]) -> list[FileEntry]:
        in_files = False
        for line in lines:
            if line.startswith("files:"):
                in_files = True
                continue
            if _TOP_LEVEL.match(line) and in_files:
                self.flush()
                in_files = False
            if not in_files:
                continue
            if _DASH_ITEM.match(line):
                self.flush()
                self.kv(_DASH_PREFIX.sub("", line, count=1))
            elif _INDENTED_KEY.match(line):
                self.kv(line)
        if in_files:
            self.flush()
        return self.out


class _CommandParser:
    """``kit_spec_commands``: argv lists of plain scalars and ``- |`` literal blocks."""

    def __init__(self, warn: list[str]) -> None:
        self.warn = warn
        self.out: list[Command] = []
        self.in_cmds = self.in_block = self.have_block_line = False
        self.in_argv = self.have = False
        self.block = ""
        self.block_min_indent = 0
        self.phase = self.user = self.background = ""
        self.argv: list[str] = []

    def handle_kv(self, text: str) -> None:
        k = _trim_q(_key_of(text))
        v = _value_of(text)
        if k == "phase":
            self.phase = _trim_q(v)
        elif k == "user":
            self.user = _trim_q(v)
        elif k == "background":
            self.background = _trim_q(v)
        elif k == "command":
            self.in_argv = True

    def end_block(self) -> None:
        self.argv.append(self.block)
        self.in_block = False

    def end_cmd(self) -> None:
        if self.have:
            self.emit()
        self.have = self.in_argv = False
        self.phase = self.user = self.background = ""
        self.argv = []

    def emit(self) -> None:
        bg = self.background
        if bg not in ("true", "false"):
            if bg != "":
                self.warn.append(
                    f"kit-translate: command background must be true|false (got: {bg}); treating as false")
            bg = "false"
        if self.user != "" and not _SAFE_USER.fullmatch(self.user):
            self.warn.append(f"kit-translate: skipping command with unsafe user: {self.user}")
        elif self.phase != "" and self.phase not in _PHASES:
            self.warn.append(f"kit-translate: skipping command with unknown phase: {self.phase}")
        else:
            argv = tuple(tok[:-1] if tok.endswith("\n") else tok for tok in self.argv)
            for tok in argv:
                if len(tok) > MAX_COMMAND_TOKEN_BYTES:
                    raise KitSpecError(f"a command argument is larger than {MAX_COMMAND_TOKEN_BYTES} bytes")
            self.out.append(Command(self.phase, self.user, bg == "true", argv))

    def feed_block(self, line: str) -> bool:
        """Consume a line of an open block scalar; ``False`` when the line ends it."""
        if _BLANK.fullmatch(line):
            self.block += "\n"
            return True
        if _indent_of(line) >= self.block_min_indent:
            txt = line[self.block_min_indent:]
            self.block = f"{self.block}\n{txt}" if self.have_block_line else txt
            self.have_block_line = True
            return True
        self.end_block()
        return False

    def start_item(self, line: str) -> None:
        self.end_cmd()
        self.have = True
        self.handle_kv(_DASH_PREFIX.sub("", line, count=1))

    def feed_argv(self, line: str) -> None:
        if re.fullmatch(_S + "*-" + _S + r"*\|" + _S + "*", line):
            self.in_block, self.block, self.have_block_line = True, "", False
            self.block_min_indent = _indent_of(line) + 2
        elif re.match(_S + "*-" + _S, line):
            tok = _DASH_PREFIX.sub("", line, count=1).rstrip(_WS)
            self.argv.append(_strip_dquotes(tok))
        elif _INDENTED_KEY.match(line):
            self.in_argv = False
            self.handle_kv(line)

    def feed(self, line: str) -> None:
        if line.startswith("commands:"):
            self.in_cmds = True
            return
        if _TOP_LEVEL.match(line) and self.in_cmds:
            if self.in_block:
                self.end_block()
            self.end_cmd()
            self.in_cmds = False
        if not self.in_cmds:
            return
        if self.in_block and self.feed_block(line):
            return
        if _BLANK.fullmatch(line) or _COMMENT.match(line):
            return
        if re.match(_S + "*-" + _S + "*phase:", line):
            self.in_argv = False
            self.start_item(line)
        elif re.match(_S + "*-" + _S, line) and not self.in_argv:
            self.start_item(line)
        elif self.in_argv:
            self.feed_argv(line)
        elif _INDENTED_KEY.match(line):
            self.handle_kv(line)

    def run(self, lines: Sequence[str]) -> list[Command]:
        for line in lines:
            self.feed(line)
        if self.in_block:
            self.end_block()
        self.end_cmd()
        return self.out


def _parse_env(lines: Sequence[str], warn: list[str]) -> list[EnvVar]:
    """``kit_spec_env``: a flat ``NAME: value`` map; block scalars are dropped."""
    out: list[EnvVar] = []
    in_env = skip_blk = False
    blk_ind = 0
    for line in lines:
        if line.startswith("environment:"):
            in_env = True
            continue
        if _TOP_LEVEL.match(line) and in_env:
            in_env = False
        if not in_env:
            continue
        if skip_blk:
            if _BLANK.fullmatch(line) or line.startswith("\t") or _indent_of(line) > blk_ind:
                continue
            skip_blk = False
        if _BLANK.fullmatch(line) or _COMMENT.match(line):
            continue
        if not re.match(_S + "+[^: \t\n\v\f\r#]+:", line):
            continue
        k = _SQUOTE_ENDS.sub("", _strip_dquotes(_trim(_key_of(line))))
        v = _trim(_uncomment(_value_of(line)))
        if _BLOCK_INDICATOR.fullmatch(v):
            warn.append(f"kit-translate: skipping env var with unsupported block scalar value: {k}")
            skip_blk, blk_ind = True, _indent_of(line)
            continue
        v = _SQUOTE_ENDS.sub("", _strip_dquotes(v))
        if _ENV_NAME.fullmatch(k):
            out.append(EnvVar(k, v))
        else:
            warn.append(f"kit-translate: skipping env var with unsafe name: {k}")
    return out


def _parse_agent_context(lines: Sequence[str]) -> list[str]:
    """``kit_spec_agent_context``: the ``agentContext`` block, dedented by its first line."""
    out: list[str] = []
    in_ctx = False
    min_ind = -1
    for line in lines:
        if re.match("agentContext:" + _S + "*[|>]", line):
            in_ctx, min_ind = True, -1
            continue
        if _TOP_LEVEL.match(line) or line.startswith("#"):
            in_ctx = False
        if not in_ctx:
            continue
        if _BLANK.fullmatch(line):
            out.append("")
            continue
        ind = len(line) - len(line.lstrip(" "))
        if min_ind < 0:
            min_ind = ind
        out.append(line[min_ind:])
    return out


def _backend_re(backend: str) -> str:
    if not re.fullmatch("[a-z]+", backend):
        raise ValueError(f"not a backend name: {backend!r}")
    return backend


def _parse_has_shortcut(lines: Sequence[str], backend: str) -> bool:
    """``kit_spec_has_shortcut``: ``backend_shortcuts.<backend>`` present and non-empty."""
    head = re.compile(_S + "+" + _backend_re(backend) + ":" + _S + "*")
    in_bs = in_this = False
    for line in lines:
        if line.startswith("backend_shortcuts:"):
            in_bs = True
            continue
        if _TOP_LEVEL.match(line):
            in_bs = False
        if not in_bs:
            continue
        if head.match(line):
            rest = _uncomment(head.sub("", line, count=1)).rstrip(_WS)
            if rest == "{}":
                return False
            if rest != "":
                return True
            in_this = True
        elif in_this:
            if re.match(_S + _S + "+[A-Za-z]", line):
                return True
            in_this = False
    return False


def _parse_shortcut_val(lines: Sequence[str], backend: str, key: str) -> str | None:
    """``kit_spec_shortcut_val``: ``backend_shortcuts.<backend>.<key>``."""
    name = _backend_re(backend)
    if not _IDENT.fullmatch(key):
        raise ValueError(f"not a shortcut key: {key!r}")
    key_re = re.compile(_S + _S + "+" + key + ":")
    in_bs = in_this = False
    for line in lines:
        if line.startswith("backend_shortcuts:"):
            in_bs = True
            continue
        if _TOP_LEVEL.match(line):
            in_bs = False
        if not in_bs:
            continue
        if re.fullmatch(_S + "+" + name + ":" + _S + "*", line):
            in_this = True
            continue
        if re.match(_S + "+" + name + ":", line):
            in_this = True
        elif _INDENTED_KEY.match(line) and not re.match(_S + _S + "+", line):
            in_this = False
        if in_this and key_re.match(line):
            return _strip_dquotes(_trim(_uncomment(_value_of(line))))
    return None


# ---------------------------------------------------------------------------
# KitSpec.
# ---------------------------------------------------------------------------


def _split_lines(text: str) -> tuple[str, ...]:
    """awk records: split on newline only; a final newline ends the last record."""
    if not text:
        return ()
    parts = text.split("\n")
    if parts[-1] == "":
        parts.pop()
    return tuple(parts)


@dataclass(frozen=True)
class KitSpec:
    """A parsed kit spec. Build one with :func:`parse_spec`, :func:`load_spec` or :func:`load_kit`.

    ``warnings`` maps a section (``files``, ``commands``, ``environment``,
    ``publishedPorts``, ``volumes``) to the warnings Bash prints for it, in order.
    """

    kit_dir: Path | None
    files: tuple[FileEntry, ...]
    commands: tuple[Command, ...]
    env: tuple[EnvVar, ...]
    net_allow: tuple[str, ...]
    published_ports: tuple[PublishedPort, ...]
    volumes: tuple[Volume, ...]
    agent_context: tuple[str, ...]
    warnings: Mapping[str, tuple[str, ...]]
    _lines: tuple[str, ...] = dc_field(repr=False)

    def field(self, key: str) -> str | None:
        """A top-level scalar (``name``, ``kind``, ``schemaVersion``, ``description``…)."""
        if not _IDENT.fullmatch(key):
            raise ValueError(f"not a spec key: {key!r}")
        value = _parse_field(self._lines, key)
        return None if value is None else _text(value)

    def agent_field(self, key: str) -> str | None:
        """``agent.<key>`` (``name`` or ``entrypoint``)."""
        if not _IDENT.fullmatch(key):
            raise ValueError(f"not an agent key: {key!r}")
        value = _parse_agent_field(self._lines, key)
        return None if value is None else _text(value)

    def has_shortcut(self, backend: str) -> bool:
        return _parse_has_shortcut(self._lines, backend)

    def shortcut_val(self, backend: str, key: str) -> str | None:
        value = _parse_shortcut_val(self._lines, backend, key)
        return None if value is None else _text(value)

    def commands_for(self, phase: str) -> tuple[Command, ...]:
        """The commands of one phase. A command without a phase is in none of them."""
        return tuple(c for c in self.commands if c.phase == phase)

    def all_warnings(self) -> list[str]:
        return [w for section in self.warnings.values() for w in section]


def _decode(raw: bytes, label: str) -> str:
    if len(raw) > MAX_SPEC_BYTES:
        raise KitSpecError(f"{label} is larger than {MAX_SPEC_BYTES} bytes")
    if b"\0" in raw:
        raise KitSpecError(f"{label} contains a NUL byte")
    try:
        raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise KitSpecError(f"{label} is not valid UTF-8") from exc
    return raw.decode("latin-1")


def _texts(items: Sequence[str]) -> tuple[str, ...]:
    return tuple(_text(s) for s in items)


def parse_spec(raw: bytes, kit_dir: Path | None = None, label: str = "spec.yaml") -> KitSpec:
    """Parse spec bytes. Raises :class:`KitSpecError` for input refused as a whole."""
    lines = _split_lines(_decode(raw, label))
    warn: dict[str, list[str]] = {k: [] for k in ("files", "commands", "environment", "publishedPorts", "volumes")}
    files = _FileParser(warn["files"]).run(lines)
    commands = _CommandParser(warn["commands"]).run(lines)
    env = _parse_env(lines, warn["environment"])
    ports = _parse_ports(lines, warn["publishedPorts"])
    volumes = _parse_volumes(lines, warn["volumes"])
    return KitSpec(
        kit_dir=kit_dir,
        files=tuple(
            FileEntry(_text(f.path), _text(f.mode), _text(f.phase), _text(f.source), f.readonly) for f in files
        ),
        commands=tuple(Command(_text(c.phase), _text(c.user), c.background, _texts(c.argv)) for c in commands),
        env=tuple(EnvVar(_text(e.name), _text(e.value)) for e in env),
        net_allow=_texts(_parse_net_allow(lines)),
        published_ports=tuple(
            PublishedPort(_text(p.guest), _text(p.protocol), _text(p.name), _text(p.host)) for p in ports
        ),
        volumes=tuple(Volume(_text(v.path), _text(v.type), _text(v.size)) for v in volumes),
        agent_context=_texts(_parse_agent_context(lines)),
        warnings={k: _texts(v) for k, v in warn.items()},
        _lines=lines,
    )


_OPEN_FLAGS = os.O_RDONLY | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_BINARY", 0)


def _read_regular(path: Path) -> bytes:
    """Read a regular file of at most :data:`MAX_SPEC_BYTES`.

    The file is opened without blocking (a FIFO with no writer would otherwise
    hang the open) and checked with ``fstat`` on the open descriptor, so what is
    read is the regular file that was checked, even if the path is swapped.
    """
    try:
        fd = os.open(path, _OPEN_FLAGS)
    except OSError as exc:
        if not path.is_file():
            raise KitSpecError(f"{str(path)!r} is not a regular file") from exc
        raise KitSpecError(f"could not read {str(path)!r}") from exc
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise KitSpecError(f"{str(path)!r} is not a regular file")
    except BaseException:
        os.close(fd)
        raise
    with os.fdopen(fd, "rb") as fh:
        try:
            raw = fh.read(MAX_SPEC_BYTES + 1)
        except OSError as exc:
            raise KitSpecError(f"could not read {str(path)!r}") from exc
    if len(raw) > MAX_SPEC_BYTES:
        raise KitSpecError(f"{str(path)!r} is larger than {MAX_SPEC_BYTES} bytes")
    return raw


def load_spec(path: str | os.PathLike[str]) -> KitSpec:
    """Parse a ``spec.yaml`` file; its directory is the kit directory."""
    p = Path(path)
    return parse_spec(_read_regular(p), kit_dir=p.parent, label=str(p))


def load_kit(kit_dir: str | os.PathLike[str]) -> KitSpec:
    """Parse the ``spec.yaml`` of a kit directory.

    The spec may be a symlink only within the kit directory, as in
    :func:`kits.validate_kit`.
    """
    root = Path(kit_dir)
    if not root.is_dir():
        raise KitSpecError(f"kit directory does not exist: {str(root)!r}")
    spec = root / "spec.yaml"
    resolved_root = root.resolve()
    resolved = spec.resolve()
    if resolved != resolved_root and resolved_root not in resolved.parents:
        raise KitSpecError(f"spec.yaml in {str(root)!r} resolves outside the kit directory")
    return parse_spec(_read_regular(spec), kit_dir=root, label=str(spec))


# ---------------------------------------------------------------------------
# File-source confinement (kit_source_resolve / kit_tree_symlinks_within).
# ---------------------------------------------------------------------------


def _resolve_path(p: str, depth: int = 0) -> str | None:
    """Resolve every symlink in ``p`` like GNU ``realpath`` (the last component may be missing)."""
    if depth > 40:
        return None
    try:
        os.stat(p)
    except NotADirectoryError:
        return None  # a file used as a directory ("file/", "file/.", "file/x")
    except OSError:
        pass
    try:
        return os.path.realpath(p, strict=True)
    except FileNotFoundError:
        pass
    except OSError:
        return None  # a symlink loop
    head, tail = os.path.split(p.rstrip(os.sep) or os.sep)
    try:
        parent = os.path.realpath(head or ".", strict=True)
    except OSError:
        return None
    candidate = os.path.join(parent, tail)
    if _is_link(candidate):
        return _resolve_path(os.path.join(parent, os.readlink(candidate)), depth + 1)
    return candidate


def _is_link(path: str) -> bool:
    """A symlink, or a Windows junction (realpath follows both; neither may be walked into)."""
    return os.path.islink(path) or os.path.isjunction(path)


def resolve_source(kit_dir: str | os.PathLike[str], source: str) -> Path | None:
    """``kit_source_resolve``: the resolved path of a ``files[]`` source, or ``None``.

    The source must be relative with no ``..`` segment, and must resolve
    (symlinks included) to a regular file strictly inside the resolved kit
    directory. Callers copy from the returned path, so what was checked is
    what gets copied.
    """
    if source == "" or source.startswith("/") or "/../" in f"/{source}/":
        return None
    root = _resolve_path(os.fspath(kit_dir))
    target = _resolve_path(os.path.join(os.fspath(kit_dir), source))
    if root is None or target is None:
        return None
    # Bash matches "$root"/*, so a kit directory of / contains nothing.
    if not target.startswith(root + os.sep) or not os.path.isfile(target):
        return None
    return Path(target)


def _kit_relative(kit: str, entry: str) -> str:
    """``${link#"$kitdir"/}`` with ``/`` separators: the kit-relative name used in warnings.

    On Windows the walk yields ``\\``-separated paths; the warning names the
    entry the way Bash does, relative to the kit and with forward slashes.
    """
    for sep in dict.fromkeys((os.sep, "/")):
        if entry.startswith(kit + sep):
            entry = entry[len(kit) + 1:]
            break
    return entry.replace(os.sep, "/")


def tree_symlinks_within(kit_dir: str | os.PathLike[str], tree: str | os.PathLike[str]) -> list[str]:
    """``kit_tree_symlinks_within``: the problems found, empty when the tree is safe.

    No name may contain a newline, and every symlink under ``tree`` must resolve
    inside the kit directory. A Windows junction counts as a symlink, and the
    walk never enters one. A missing tree is safe.
    """
    kit, top = os.fspath(kit_dir), os.fspath(tree)
    if not os.path.isdir(top):
        return []
    root = _resolve_path(kit)
    if root is None:
        return ["kit-translate: cannot resolve the kit directory"]
    problems: list[str] = []
    entries = [top]
    if not _is_link(top):  # find -P lists a symlinked top without entering it
        for base, dirs, names in os.walk(top):
            entries.extend(os.path.join(base, n) for n in (*dirs, *names))
            # os.walk does not follow symlinks, but it does enter junctions.
            dirs[:] = [d for d in dirs if not os.path.isjunction(os.path.join(base, d))]
    for entry in entries:
        rel = _kit_relative(kit, entry)
        if "\n" in entry:
            problems.append("kit-translate: kit payload has a file name containing a newline; refusing it")
        elif _is_link(entry):
            target = _resolve_path(entry)
            if target is None:
                problems.append(f"kit-translate: unresolvable symlink in kit payload: {rel}")
            elif target != root and not target.startswith(root + os.sep):
                problems.append(f"kit-translate: kit payload symlink points outside the kit: {rel}")
    return problems


# ---------------------------------------------------------------------------
# Built-in kit bundle (package data pinned at the control-plane ref).
# ---------------------------------------------------------------------------

BUNDLE_DIR = Path(__file__).resolve().with_name("kitbundle")
BUNDLE_MANIFEST = BUNDLE_DIR / "MANIFEST.json"
BUNDLE_SCHEMA = 1

# The bundled agent kit for each agent that has one, with the entrypoint its
# spec must declare (Bash acq_agent_builtin_kit_name / acq_agent_kit_entrypoint).
AGENT_BUNDLE_KITS: dict[str, tuple[str, str]] = {"opencode": ("opencode", "opencode")}

# Catalog kits `acq configure` can add through config.yaml `extra_kits`, pinned
# to the control plane like the built-ins but not bundled (ACQ_OPTIN_KIT_NAMES).
OPTIN_KIT_NAMES = ("openchamber", "paseo", "oci-engine")

_GIT_BLOB = re.compile("[0-9a-f]{40}")
_BUNDLE_REL = re.compile(r"[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*")


def bundle_manifest() -> dict:
    """The validated bundle manifest. Raises :class:`KitSpecError` if it is unusable.

    The manifest must be pinned to :data:`kits.CONTROL_PLANE_REF`: a pin bump
    without a refreshed bundle fails closed instead of applying stale kits.
    """
    try:
        doc = json.loads(_read_regular(BUNDLE_MANIFEST).decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise KitSpecError("the kit bundle manifest is not valid JSON") from exc
    if not isinstance(doc, dict) or doc.get("schema") != BUNDLE_SCHEMA:
        raise KitSpecError("the kit bundle manifest has an unknown schema")
    pin = (doc.get("repository"), doc.get("ref"), doc.get("directory"))
    expected = (kits.CONTROL_PLANE_REPO, kits.CONTROL_PLANE_REF, kits.CONTROL_PLANE_DIR)
    if pin != expected:
        raise KitSpecError(f"the kit bundle is pinned to {pin[1]!r}, not the control plane {kits.CONTROL_PLANE_REF}")
    entries = doc.get("kits")
    if not isinstance(entries, dict) or not all(
        isinstance(v, dict) and isinstance(v.get("files"), dict) for v in entries.values()
    ):
        raise KitSpecError("the kit bundle manifest does not list its kits")
    return doc


def bundle_kit_names() -> tuple[str, ...]:
    """The bundled kits, in manifest order."""
    return tuple(bundle_manifest()["kits"])


def bundle_kit_dir(name: str) -> Path:
    """The packaged directory of a bundled kit."""
    if name not in bundle_kit_names():
        raise KitSpecError(f"{name!r} is not a bundled kit")
    return BUNDLE_DIR / name


def load_bundled_kit(name: str) -> KitSpec:
    """Parse a bundled kit."""
    return load_kit(bundle_kit_dir(name))


def _git_blob_id(data: bytes) -> str:
    return hashlib.sha1(b"blob %d\0" % len(data) + data, usedforsecurity=False).hexdigest()


def verify_bundle() -> list[str]:
    """Check every bundled file against the manifest; the problems found, or ``[]``.

    Each file must exist with the size and git blob id recorded at the pinned
    ref, and nothing unlisted may sit in a kit directory.
    """
    problems: list[str] = []
    for kit, entry in bundle_manifest()["kits"].items():
        listed = entry["files"]
        root = BUNDLE_DIR / kit
        for rel, meta in listed.items():
            if not isinstance(meta, dict) or not _BUNDLE_REL.fullmatch(rel) or ".." in rel.split("/"):
                problems.append(f"{kit}: bad manifest entry {rel!r}")
                continue
            path = root / rel
            if path.is_symlink() or not path.is_file():
                problems.append(f"{kit}: {rel} is missing")
                continue
            data = path.read_bytes()
            if len(data) != meta.get("size") or _git_blob_id(data) != meta.get("git_blob"):
                problems.append(f"{kit}: {rel} does not match the pinned content")
        if root.is_dir():
            for path in sorted(root.rglob("*")):
                rel = path.relative_to(root).as_posix()
                if (path.is_file() or path.is_symlink()) and rel not in listed:
                    problems.append(f"{kit}: {rel} is not in the manifest")
    return problems


def builtin_kit_ref(name: str) -> str:
    """The fetchable control-plane ref of a kit (Bash ``*_KIT`` / ``_acq_optin_kit_ref``)."""
    return (f"git+https://{kits.CONTROL_PLANE_REPO}.git#ref={kits.CONTROL_PLANE_REF}"
            f"&dir={kits.CONTROL_PLANE_DIR}/{name}")


def bundled_name_for_ref(ref: str) -> str | None:
    """The bundled kit a ref names exactly, or ``None`` (the ref must be fetched)."""
    try:
        names = bundle_kit_names()
    except KitSpecError:
        return None
    for name in names:
        if ref == builtin_kit_ref(name):
            return name
    return None


def bundle_network_allow() -> dict[str, tuple[str, ...]]:
    """Each bundled kit's ``caps.network.allow``, read from its pinned spec."""
    return {name: load_bundled_kit(name).net_allow for name in bundle_kit_names()}


def agent_kit_ready(agent: str) -> bool:
    """``acq_agent_builtin_kit_ready``: the bundled agent kit exists and declares this agent."""
    entry = AGENT_BUNDLE_KITS.get(agent)
    if entry is None:
        return False
    kit_name, entrypoint = entry
    try:
        spec = load_bundled_kit(kit_name)
    except KitSpecError:
        return False
    return (spec.field("schemaVersion") == "hybrid/v1" and spec.field("kind") == "mixin"
            and spec.field("name") == kit_name and spec.agent_field("name") == agent
            and spec.agent_field("entrypoint") == entrypoint)


# ---------------------------------------------------------------------------
# Kit selection (_build_kit_list).
# ---------------------------------------------------------------------------


class KitSelectionError(Exception):
    """The kit list cannot be built (a create or run must not continue)."""


@dataclass(frozen=True)
class SelectedKit:
    """One kit to apply. ``bundled`` names the packaged kit when the ref is a built-in."""

    ref: str
    role: str  # support | provider | agent | extra | cli
    bundled: str | None


@dataclass(frozen=True)
class KitSelection:
    """The ordered kit list.

    ``provider_error`` is set when the provider kit could not be resolved, and
    ``extras_error`` when the configured ``extra_kits`` name an unknown kit. The
    list is then built without that kit or those extras, so the verbs that
    repair the configuration still work, and :meth:`require` must stop a create
    or run (Bash ``ACQ_PROVIDER_SELECTION_ERROR`` /
    ``_acq_require_provider_selection``, and the ``exit 1`` after
    ``_acq_apply_configured_extra_kits``).
    """

    kits: tuple[SelectedKit, ...]
    builtin_support_count: int
    builtin_count: int
    provider_error: str | None
    extras_error: str | None = None

    @property
    def refs(self) -> list[str]:
        return [k.ref for k in self.kits]

    def require_provider(self) -> None:
        if self.provider_error is not None:
            raise KitSelectionError(f"the configured provider kit could not be resolved: {self.provider_error}")

    def require_extras(self) -> None:
        if self.extras_error is not None:
            raise KitSelectionError(self.extras_error)

    def require(self) -> None:
        """Raise unless every selected kit resolved (what create and run check)."""
        self.require_extras()
        self.require_provider()


_PROVIDER_KIT_DEFAULT = "agentic-coding-patterns/usai-provider"
_KIT_NAME = re.compile(r"[A-Za-z0-9._-]+")


def _ifs_split(value: str) -> list[str]:
    """Word-split like the shell's default IFS (space, tab, newline), without globbing."""
    return [t for t in re.split("[ \t\n]+", value) if t]


def kit_ref_absolute(ref: str) -> str:
    """``_acq_kit_ref_absolute``: a relative local kit directory made absolute and physical."""
    if ref == "" or ref.startswith(("git+http", "/")) or re.match(r"[A-Za-z]:[/\\]", ref):
        return ref
    if os.path.isdir(ref):
        return os.path.realpath(ref)
    return ref


_CONFIG_QUOTED = re.compile('"[^"]*"')


def _config_line_value(line: str) -> str:
    """One flat config line's value, with quotes and inline comments handled like Bash."""
    if line[:1] in ('"', "'"):
        in_single = in_double = False
        for i, c in enumerate(line):
            if c == "'" and not in_double:
                in_single = not in_single
            elif c == '"' and not in_single:
                in_double = not in_double
            elif c == "#" and not in_single and not in_double and (i == 0 or line[i - 1] in _WS):
                line = line[:i]
                break
    elif line.startswith("#"):
        line = ""
    else:
        line = re.sub(_S + "+#.*$", "", line, count=1, flags=re.DOTALL)
    line = line.rstrip(_WS)
    if _CONFIG_QUOTED.fullmatch(line):
        return line[1:-1]
    if len(line) >= 1 and line[0] == "'" and line[-1] == "'":
        return line[1:-1]
    return line


def config_read_field(key: str) -> str:
    """``_acq_config_read_field``: a flat top-level ``key: value`` from config.yaml ("" if absent).

    The last occurrence wins, as with the Bash writer's replace-all.
    """
    if not _IDENT.fullmatch(key):
        return ""
    path = userdirs.xdg_base("XDG_CONFIG_HOME", ".config") / "acq" / "config.yaml"
    try:
        text = _read_regular(path).decode("latin-1")
    except KitSpecError:
        return ""
    head = re.compile(re.escape(key) + _S + "*:" + _S + "*")
    val = ""
    for line in _split_lines(text):
        if head.match(line):
            val = _config_line_value(head.sub("", line, count=1))
    try:
        return val.encode("latin-1").decode("utf-8")
    except UnicodeDecodeError:
        return ""


def _registry_entry(repo: str) -> dict | None:
    for src in kits.all_sources():
        if src.get("repository") == repo:
            return src
    return None


def _resolve_source_repo(want: str) -> str:
    """``_acq_kit_source_resolve_repo``: a full repo, or a unique registered basename."""
    if want == kits.CONTROL_PLANE_REPO.rsplit("/", 1)[-1]:
        return kits.CONTROL_PLANE_REPO
    if "/" in want:
        if _registry_entry(want) is None:
            raise KitSelectionError(f"kit source '{want}' is not trusted")
        return want
    found = [s["repository"] for s in kits.all_sources() if (s.get("repository") or "").rsplit("/", 1)[-1] == want]
    if not found:
        raise KitSelectionError(f"kit source name '{want}' is not registered")
    if len(found) > 1:
        raise KitSelectionError(f"kit source name '{want}' is ambiguous; use host/owner/repo")
    return found[0]


def _ref_trusted(ref: str, env: Mapping[str, str]) -> bool:
    """``_acq_kit_source_ref_trusted``: a configured remote ref names exactly one trusted repo."""
    body = ref.removeprefix("git+https://") if ref.startswith("git+https://") else ""
    body = body.split("#", 1)[0]
    if (re.search(r"[@%?:]|//", body) or body.endswith("/") or not _SAFE_PATH.fullmatch(body or "x")
            or re.search(r"/\.\.?(/|$)", body)):
        body = ""
    repo = kits.normalize_repo(body) if body else None
    if repo is None or repo != body.removesuffix(".git"):
        return False
    if _registry_entry(repo) is not None:
        return True
    return any(t.endswith("/") and repo.startswith(t) for t in _ifs_split(env.get(kits.EXTRA_KIT_SOURCES_ENV, "")))


def _split_provider_value(value: str) -> tuple[str, str]:
    """Split ``<kit>@<source>``, ``host/owner/repo/<kit>`` or ``<source>/<kit>`` into (kit, repo)."""
    if "@" in value:
        return value.rsplit("@", 1)[0], value.split("@", 1)[1]
    parts = value.split("/")
    if len(parts) >= 4:
        return "/".join(parts[3:]), "/".join(parts[:3])
    if len(parts) >= 2:
        return value.split("/", 1)[1], parts[0]
    return value, ""


def provider_kit_ref(env: Mapping[str, str]) -> str:
    """``acq_provider_kit_ref``: the default provider kit (config ``provider_kit``) as a ref."""
    value = config_read_field("provider_kit") or _PROVIDER_KIT_DEFAULT
    if value.startswith(("git+http", "/", "./", "../")):
        if value.startswith("git+http") and not _ref_trusted(value, env):
            raise KitSelectionError(f"provider_kit names an untrusted remote ref: {value}")
        return value
    kit, repo = _split_provider_value(value)
    if kit == "":
        raise KitSelectionError(f"provider_kit '{value}' does not name a kit")
    if not _KIT_NAME.fullmatch(kit):
        raise KitSelectionError(f"provider_kit '{value}' has an unsafe kit name '{kit}'")
    repo = _resolve_source_repo(repo or _PROVIDER_KIT_DEFAULT.split("/", 1)[0])
    entry = _registry_entry(repo)
    if entry is None:
        raise KitSelectionError(f"kit source '{repo}' is not trusted")
    ref, directory = entry.get("ref") or "", entry.get("directory") or kits.CONTROL_PLANE_DIR
    if ref == "":
        raise KitSelectionError(f"kit source '{repo}' has no pinned ref, so it cannot be fetched")
    path = kit if directory == "." else f"{directory}/{kit}"
    return f"git+https://{repo}.git#ref={ref}&dir={path}"


def provider_kit_refs(env: Mapping[str, str], no_provider_kits: bool = False) -> list[str]:
    """``_acq_selected_provider_kit_refs``: ``--no-provider-kits``, then ``ACQ_PROVIDER_KITS``, then config."""
    if no_provider_kits:
        return []
    if "ACQ_PROVIDER_KITS" in env:
        return _ifs_split(env["ACQ_PROVIDER_KITS"])
    return [provider_kit_ref(env)]


def configured_extra_kits(env: Mapping[str, str]) -> list[str]:
    """``_acq_apply_configured_extra_kits`` then the split: ``ACQ_EXTRA_KITS`` wins over config.

    The configured value lists catalog kit names only; raw refs belong in
    ``ACQ_EXTRA_KITS`` or ``--kit``. Raises :class:`KitSelectionError` for an
    unknown name.
    """
    if env.get("ACQ_EXTRA_KITS"):
        return _ifs_split(env["ACQ_EXTRA_KITS"])
    refs = []
    for tok in _ifs_split(config_read_field("extra_kits")):
        if tok not in OPTIN_KIT_NAMES:
            raise KitSelectionError(
                f"config extra_kits contains unknown kit '{tok}'; run 'acq configure' to choose "
                "catalog kits, or use ACQ_EXTRA_KITS/--kit for custom refs"
            )
        refs.append(builtin_kit_ref(tok))
    return refs


def _kit(ref: str, role: str) -> SelectedKit:
    return SelectedKit(ref=ref, role=role, bundled=bundled_name_for_ref(ref))


def _support_kits(env: Mapping[str, str], no_provider_kits: bool) -> tuple[list[SelectedKit], str | None]:
    error: str | None = None
    try:
        provider = provider_kit_refs(env, no_provider_kits)
    except KitSelectionError as exc:
        provider, error = [], str(exc)
    support = [_kit(builtin_kit_ref("zscaler-ca-certificate"), "support")]
    support += [_kit(ref, "provider") for ref in provider]
    support += [_kit(builtin_kit_ref(n), "support") for n in ("agentic-coding-playbook", "git-ssh-sign")]
    return support, error


def select_kits(
    agent: str | None,
    *,
    cli_kits: Sequence[str] = (),
    env: Mapping[str, str] | None = None,
    no_provider_kits: bool = False,
    required_agent_kit: str | None = None,
    configured_extras: bool = False,
    ready: Callable[[str], bool] = agent_kit_ready,
) -> KitSelection:
    """Build the ordered kit list (Bash ``_build_kit_list``).

    ``cli_kits`` are ``--kit`` refs. ``required_agent_kit`` names the agent whose
    kit must apply (the generic default image has no agent binary); it is an
    error when that kit is not ready. Relative local refs become absolute.

    Extras come from ``ACQ_EXTRA_KITS`` only, as in ``_build_kit_list``. Create
    and run pass ``configured_extras=True`` to fold in config ``extra_kits``
    first, as Bash does with ``_acq_apply_configured_extra_kits``; an unknown
    configured name is latched in ``extras_error`` rather than raised, so a
    caller must call :meth:`KitSelection.require` before building a sandbox.
    """
    env = os.environ if env is None else env
    known = _known_agents()
    support, provider_error = _support_kits(env, no_provider_kits)
    selected = list(support)
    support_count = len(selected)
    if required_agent_kit and required_agent_kit == agent and not ready(agent):
        raise KitSelectionError(
            f"required built-in {agent} kit is unavailable or has invalid agent metadata; "
            f"refusing the generic default image because it has no bundled {agent} binary"
        )
    if (agent and agent in known and (not cli_kits or required_agent_kit == agent)
            and agent in AGENT_BUNDLE_KITS and ready(agent)):
        selected.append(_kit(builtin_kit_ref(AGENT_BUNDLE_KITS[agent][0]), "agent"))
    builtin_count = len(selected)
    extras, extras_error = _ifs_split(env.get("ACQ_EXTRA_KITS", "")), None
    if configured_extras:
        try:
            extras = configured_extra_kits(env)
        except KitSelectionError as exc:
            extras_error = str(exc)
    selected += [_kit(kit_ref_absolute(r), "extra") for r in extras]
    selected += [_kit(kit_ref_absolute(r), "cli") for r in cli_kits]
    return KitSelection(tuple(selected), support_count, builtin_count, provider_error, extras_error)


def _known_agents() -> frozenset[str]:
    from .commands import common  # lazy: commands.common imports the backend adapters

    return common.KNOWN_AGENTS
