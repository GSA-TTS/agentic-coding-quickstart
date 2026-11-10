"""``acq configure``: show the configuration, or change it at a terminal (ADR-0031).

A port of the Bash ``acq_configure`` / ``_acq_configure_show_current`` and the
prompt widgets in ``acq.backends/prompt.sh``. The verb always opens by printing
the current settings, each with the layer it comes from. On an interactive
terminal it then asks the Bash questions in the Bash order, with the Bash
defaults, and writes the same three ``config.yaml`` keys Bash writes:

* ``extra_kits`` — the chosen opt-in kit NAMES (space-separated; none removes
  the key), from a checkbox list that shows the built-in kits as frozen rows;
* ``scope_github_token`` — ``yes``/``no``, the default answer for the
  per-sandbox GitHub-token prompt;
* ``provider_kit`` — the first checked provider-kit candidate.

The Python acq reads all three. ``extra_kits`` and ``provider_kit`` feed the kit
selection at create and run, with Bash's precedence (a non-empty
``ACQ_EXTRA_KITS`` over ``extra_kits``; ``--no-provider-kits``, then a set
``ACQ_PROVIDER_KITS``, over ``provider_kit``), but it applies only kits from its
pinned built-in bundle: a kit that would have to be fetched (every catalog extra
kit today) is refused at create, and needs the Bash acq (``ACQ_IMPL=bash``).
``--json`` says so with ``"python_applies": "bundled-only"`` on those two
settings. ``scope_github_token`` is the default answer to the per-sandbox
GitHub-token prompt at create and run. Every write goes through :func:`acq_py.config.write_field`, so other
keys (including ones acq does not know) are kept, a symlinked config is written
through, and each write is atomic. A newer ``config.yaml`` schema is refused
before the first prompt; the forward-migration pre-step (the one every mutating
verb takes) runs only just before the first write, so cancelling leaves a legacy
file untouched.

Without a terminal (stdin is not a TTY, ``ACQ_NO_PROMPT`` or ``ACQ_NO_PROGRESS``
is set, or ``--json`` was given) nothing is written. ``--json`` reports each
setting as ``{key, value, source, honoured_by_python}``, where ``source`` is the
layer the value came from: ``flag``, ``env``, ``config`` or ``default``. The
provider-credential setting also lists each binding with its own layer (its
``source`` is ``mixed`` when both layers contribute). Values are settings, never
credentials: bindings are an env var name and its hosts, userinfo in a kit ref is
redacted, and no secret store or keychain is consulted.

The first-run offer and the create-time kit picker that Bash also builds on these
widgets are not ported (accepted gaps, ADR-0048m; the deliberate differences are
listed in py-acq/README.md under "configure").
"""

from __future__ import annotations

import contextlib
import json
import os
import re
import shutil
import signal
import sys
from collections.abc import Callable, Iterator, Sequence
from typing import NamedTuple

from .. import backends, config, envelope, errors, hostexec, kits, provider_creds
from . import common

COMMAND = "configure"

# The opt-in kit catalog, in Bash's order (``ACQ_OPTIN_KIT_NAMES`` / ``_DESCS``).
OPTIN_KITS: tuple[tuple[str, str], ...] = (
    ("openchamber", "Browser UI for OpenCode alongside the terminal TUI (publishes ports 3000/4096)"),
    ("paseo", "Self-hosted Paseo browser web UI for coding agents (one port, loopback only)"),
    ("oci-engine", "Rootless podman for docker run / docker compose inside the sandbox (installs packages)"),
)

# Descriptions of the built-in kits, shown as the frozen rows (``ACQ_KIT_DESCS``).
BUILTIN_KIT_DESCS = {
    "zscaler-ca-certificate": "Zscaler/corporate CA trust so TLS-intercepting proxies don't break fetches",
    "usai-provider": "USAi provider + model config for OpenCode (endpoints, key wiring)",
    "agentic-coding-playbook": "Federal agent rules and skills from the agentic-coding playbook",
    "git-ssh-sign": "SSH-based git commit signing for the agent's commits",
}

# The shipped provider kit, as data (Bash ``ACQ_PROVIDER_KIT_DEFAULT``).
PROVIDER_KIT_DEFAULT = "agentic-coding-patterns/" + kits.PROVIDER_KIT_NAMES[0]

SCOPE_PROMPT = "Scope a per-sandbox GitHub token by default (on create)?"
_HEADER = "? Select kits (dimmed rows are always applied · ↑/↓ move · SPACE toggle · ENTER confirm · q cancel)"

FLAG, ENV, CONFIG, DEFAULT, MIXED = "flag", "env", "config", "default", "mixed"

# The keys the Python acq reads but serves only from its pinned built-in bundle.
BUNDLED_ONLY_KEYS = frozenset({"extra_kits", "provider_kit"})
BUNDLED_ONLY_NOTE = (
    "      note: the Python acq applies extra and provider kits only from its built-in bundle "
    "(others need ACQ_IMPL=bash)."
)

# Raw terminal control bytes (C0, DEL, C1) are dropped from displayed labels.
_CONTROL_RE = re.compile("[\x00-\x1f\x7f-\x9f]")


class Setting(NamedTuple):
    key: str
    value: str | None
    source: str
    origin: str | None = None  # the flag or env var behind a flag/env value
    entries: tuple[tuple[str, str], ...] = ()  # (value, source) per binding

    def as_json(self) -> dict:
        doc: dict = {
            "key": self.key,
            "value": _redacted(self.value),
            "source": self.source,
            # Every reported setting is read by the Python acq; the field stays
            # in the contract, and python_applies qualifies a partial reading.
            "honoured_by_python": True,
        }
        if self.key in BUNDLED_ONLY_KEYS:
            doc["python_applies"] = "bundled-only"
        if self.entries:
            doc["entries"] = [{"value": value, "source": source} for value, source in self.entries]
        return doc


def _redacted(value: str | None) -> str | None:
    return None if value is None else kits.redact_userinfo(value)


class Signalled(BaseException):
    """SIGTERM or SIGHUP arrived while the terminal was in key mode."""

    def __init__(self, signum: int):
        super().__init__(signum)
        self.signum = signum


# ---------------------------------------------------------------------------
# The settings in effect.
# ---------------------------------------------------------------------------

def _backend_setting(backend_override: str | None) -> Setting:
    # The same precedence as backend resolution, without the auto-detect probe:
    # an invalid ACQ_BACKEND is ignored there, so it is ignored here.
    if backend_override is not None:
        return Setting("backend", backend_override, FLAG, "--backend")
    env_backend = os.environ.get("ACQ_BACKEND")
    if env_backend in backends.BACKENDS:
        return Setting("backend", env_backend, ENV, "ACQ_BACKEND")
    persisted = config.read_field("backend")
    if persisted is not None:
        return Setting("backend", persisted, CONFIG)
    return Setting("backend", None, DEFAULT)


def _config_or_default(key: str, default: str | None, env: str | None = None, *, empty_env_counts: bool = False) -> Setting:
    """``env`` (when set, and non-empty unless ``empty_env_counts``), then the
    config key, then ``default``."""
    if env is not None and env in os.environ and (os.environ[env] or empty_env_counts):
        return Setting(key, os.environ[env], ENV, env)
    value = config.read_field(key)
    if value is not None:
        return Setting(key, value, CONFIG)
    return Setting(key, default, DEFAULT)


def _bindings_setting() -> Setting:
    """Provider-credential bindings in Bash's ``id=KEY_ENV@host,host`` form.

    Raises ``ValueError`` for a malformed ``ACQ_PROVIDER_CREDENTIAL_BINDINGS``.
    """
    bindings = provider_creds.list_bindings()
    if not bindings:
        return Setting("provider_credential_bindings", None, DEFAULT)
    entries = []
    for entry in bindings:
        pair = f"{entry['provider']}={entry['key_env']}"
        if entry["hosts"]:
            pair += "@" + ",".join(entry["hosts"])
        entries.append((pair, ENV if entry["source_layer"] == provider_creds.ENV_LAYER else CONFIG))
    layers = {source for _, source in entries}
    source = layers.pop() if len(layers) == 1 else MIXED
    return Setting("provider_credential_bindings", " ".join(p for p, _ in entries), source, entries=tuple(entries))


def _kit_sources_setting() -> Setting:
    """Registered kit sources in Bash's ``repo@ref[|dir]`` form (the pinned
    control plane is always trusted and is the default)."""
    entries = []
    for src in kits.all_sources()[1:]:
        entry = f"{src['repository']}@{src['ref']}"
        if src["directory"] != kits.CONTROL_PLANE_DIR:
            entry += f"|{src['directory']}"
        entries.append(entry)
    if not entries:
        return Setting("kit_sources", None, DEFAULT)
    return Setting("kit_sources", " ".join(entries), CONFIG)


def current_settings(backend_override: str | None) -> list[Setting]:
    """Every setting ``configure`` reports, in Bash's display order."""
    return [
        _backend_setting(backend_override),
        _config_or_default("extra_kits", None, env="ACQ_EXTRA_KITS"),
        _config_or_default("scope_github_token", "no"),
        _bindings_setting(),
        # An explicitly empty ACQ_PROVIDER_KITS is authoritative: no provider kit.
        _config_or_default("provider_kit", PROVIDER_KIT_DEFAULT, env="ACQ_PROVIDER_KITS", empty_env_counts=True),
        _kit_sources_setting(),
    ]


def _show_current(settings: list[Setting]) -> None:
    """Print the settings to stderr in Bash ``_acq_configure_show_current``'s layout."""
    by_key = {s.key: s for s in settings}

    def shown(key: str, placeholder: str, hint: str = "") -> str:
        setting = by_key[key]
        if setting.entries:  # each binding names its own layer when one is env
            value = " ".join(f"{v} [{src}]" if src == ENV else v for v, src in setting.entries)
        else:
            value = _redacted(setting.value) or ""
        text = (value or placeholder) + hint
        if setting.origin is not None:
            text += f"   [from {setting.origin}]"
        return text

    _err(f"acq: current configuration ({config.config_path()}):")
    _err(f"      default backend:    {shown('backend', '<auto-detect>')}")
    _err(f"      extra kits:         {shown('extra_kits', '<none>')}")
    _err(f"      scope GitHub token: {shown('scope_github_token', 'no')}")
    _err(f"      provider creds:     {shown('provider_credential_bindings', '<none>', '   (acq provider-credential ls)')}")
    _err(f"      provider kit:       {shown('provider_kit', '<none>', '   (acq kit-source ls)')}")
    _err(f"      kit sources:        {shown('kit_sources', '<shipped default>')}")
    _err(BUNDLED_ONLY_NOTE)
    _err("")


def _err(line: str) -> None:
    print(line, file=sys.stderr, flush=True)


# ---------------------------------------------------------------------------
# The verb.
# ---------------------------------------------------------------------------

def interactive(emit_json: bool) -> bool:
    """True when the prompts may run (Bash ``_acq_prompt_interactive``, plus
    ``--json``, which always reports instead)."""
    if emit_json or os.environ.get("ACQ_NO_PROMPT") or os.environ.get("ACQ_NO_PROGRESS"):
        return False
    return common._stdin_is_terminal()


def run_configure(emit_json: bool, backend_override: str | None, before_write: Callable[[], int | None]) -> int:
    """Report the settings; at a terminal, ask and write. ``before_write`` is the
    migration pre-step: called once just before the first write, it returns an
    exit code (already reported) to stop, or ``None`` to go on."""
    try:
        settings = current_settings(backend_override)
    except ValueError as exc:
        return common._operational_failure(
            COMMAND, errors.VALIDATION_FAILED, str(exc),
            f"fix the malformed {provider_creds.BINDINGS_ENV} entry and retry", emit_json,
        )
    if emit_json:
        data = {
            "config_path": str(config.config_path()),
            "interactive": False,
            "changed": False,
            "settings": [s.as_json() for s in settings],
        }
        print(json.dumps(envelope.success(COMMAND, data)))
        return errors.EXIT_SUCCESS
    _show_current(settings)
    if not interactive(emit_json):
        _err("acq: non-interactive; configuration unchanged.")
        _err("      Run 'acq configure' from a terminal to change kits/token scoping.")
        return errors.EXIT_SUCCESS
    try:
        config.config_schema()
    except config.ConfigSchemaError as exc:
        # Refused before any prompt; the same code and advice as the pre-step.
        return common._operational_failure(
            COMMAND, errors.STATE_SCHEMA_UNSUPPORTED, str(exc),
            "repair or remove config.yaml so its schema marker is readable", False,
        )
    term = Terminal()
    try:
        return _configure_interactively(term, before_write)
    except KeyboardInterrupt:
        term.write("\033[?25h\n")
        return 130
    except Signalled as exc:
        term.write("\033[?25h\n")
        return 128 + exc.signum
    except OSError as exc:
        where = f" ({exc.filename})" if exc.filename else ""
        return common._operational_failure(
            COMMAND, errors.FAILURE,
            f"could not write {config.config_path()}: {exc.strerror or exc}{where}",
            "check the permissions of the acq config directory and file, then retry", False,
        )


def _configure_interactively(term: Terminal, before_write: Callable[[], int | None]) -> int:
    current_extras = (config.read_field("extra_kits") or "").split()
    rows = [(name, BUILTIN_KIT_DESCS[name]) for name in kits.BUILTIN_KIT_NAMES]
    rows += list(OPTIN_KITS)
    defaults = [i for i, (name, _) in enumerate(OPTIN_KITS, 1) if name in current_extras]
    chosen = multiselect(term, len(kits.BUILTIN_KIT_NAMES), defaults, rows)
    if chosen is None:
        return errors.EXIT_SUCCESS
    refused = before_write()
    if refused is not None:
        return refused
    selected = " ".join(OPTIN_KITS[i - 1][0] for i in chosen)
    config.write_field("extra_kits", selected)

    scope_default = config.read_field("scope_github_token") in ("yes", "y", "Y")
    scope = confirm(term, SCOPE_PROMPT, scope_default)
    config.write_field("scope_github_token", "yes" if scope else "no")

    candidates = provider_kit_candidates()
    current_provider = config.read_field("provider_kit") or PROVIDER_KIT_DEFAULT
    provider_defaults = [i for i, (value, _) in enumerate(candidates, 1) if value == current_provider]
    picked = multiselect(term, 0, provider_defaults[-1:], candidates)
    provider_sel = ""
    if picked:
        provider_sel = candidates[picked[0] - 1][0]
        config.write_field("provider_kit", provider_sel)

    _err("")
    _err(f"acq: configuration saved to {config.config_path()}.")
    _err(f"      extra kits:         {selected or '<none>'}")
    _err(f"      provider kit:       {_redacted(provider_sel or current_provider)}")
    return errors.EXIT_SUCCESS


def provider_kit_candidates() -> list[tuple[str, str]]:
    """``(value, label)`` per selectable provider kit: the shipped default first,
    then each provider kit a trusted source publishes (Bash
    ``acq_provider_kit_candidates``). Discovery is the offline one ``kit-source
    ls`` uses, so it never fetches."""
    out = [(PROVIDER_KIT_DEFAULT, f"{PROVIDER_KIT_DEFAULT} (shipped)")]
    seen = {PROVIDER_KIT_DEFAULT}
    for src in kits.all_sources():
        if not src["ref"]:
            continue
        _status, provider_kits = kits.discover_provider_kits(src["repository"])
        for kit in provider_kits:
            value = f"{src['repository']}/{kit}"
            if value not in seen:
                seen.add(value)
                out.append((value, f"{value} (@{src['ref']})"))
    return out


# ---------------------------------------------------------------------------
# Terminal widgets (prompt.sh). All chrome goes to stderr.
# ---------------------------------------------------------------------------

class Terminal:
    """Key and line input on stdin, chrome on stderr."""

    def __init__(self) -> None:
        self.color = hostexec.stream_is_terminal(sys.stderr)

    def write(self, text: str) -> None:
        sys.stderr.write(text)
        sys.stderr.flush()

    def sgr(self, code: str) -> str:
        return f"\033[{code}m" if self.color else ""

    def columns(self) -> int:
        """Terminal width, as Bash's ``_acq_prompt_term_cols`` finds it."""
        raw = os.environ.get("COLUMNS", "")
        if raw.isascii() and raw.isdigit():
            cols = int(raw)
        else:
            cols = shutil.get_terminal_size((80, 24)).columns
        return cols if cols >= 20 else 80

    @contextlib.contextmanager
    def keys(self) -> Iterator[None]:
        """Unbuffered, unechoed key input for the duration (Bash ``read -rsn1``)."""
        try:
            import termios
        except ImportError:  # Windows: msvcrt reads keys unbuffered already
            yield
            return
        try:
            fd = _stdin_fd()
            saved = termios.tcgetattr(fd)
        except (termios.error, OSError):  # not a terminal: nothing to switch
            yield
            return
        mode = termios.tcgetattr(fd)
        mode[3] &= ~(termios.ECHO | termios.ICANON)
        mode[6][termios.VMIN] = 1
        mode[6][termios.VTIME] = 0
        termios.tcsetattr(fd, termios.TCSANOW, mode)
        try:
            yield
        finally:
            termios.tcsetattr(fd, termios.TCSANOW, saved)

    def read_key(self) -> str:
        """One logical key: UP DOWN LEFT RIGHT SPACE ENTER QUIT, or the character."""
        if sys.platform == "win32":
            return _read_key_windows()
        fd = _stdin_fd()
        byte = os.read(fd, 1)
        if not byte:
            return "QUIT"
        if byte == b"\x1b":
            import select

            rest = b""
            while len(rest) < 2 and select.select([fd], [], [], 1)[0]:
                more = os.read(fd, 1)
                if not more:
                    break
                rest += more
            return {b"[A": "UP", b"[B": "DOWN", b"[C": "RIGHT", b"[D": "LEFT"}.get(rest, "QUIT")
        return _KEY_NAMES.get(byte, byte.decode("utf-8", "replace"))

    def read_line(self) -> str:
        """A line from stdin with the line discipline's echo (Bash ``read -r``)."""
        if sys.platform == "win32":
            return sys.stdin.readline()
        fd = _stdin_fd()
        data = b""
        while not data.endswith(b"\n"):
            byte = os.read(fd, 1)
            if not byte:
                break
            data += byte
        return data.decode("utf-8", "replace")


_KEY_NAMES = {
    b"\n": "ENTER", b"\r": "ENTER", b" ": "SPACE",
    b"q": "QUIT", b"Q": "QUIT", b"j": "DOWN", b"J": "DOWN", b"k": "UP", b"K": "UP",
}


def _stdin_fd() -> int:
    return sys.stdin.fileno()


def _read_key_windows() -> str:  # pragma: no cover - Windows console only
    if sys.platform == "win32":
        import msvcrt

        char = msvcrt.getwch()
        if char == "\x03":
            raise KeyboardInterrupt
        if char in ("\x00", "\xe0"):
            return {"H": "UP", "P": "DOWN", "M": "RIGHT", "K": "LEFT"}.get(msvcrt.getwch(), "")
        if char == "\x1b":
            return "QUIT"
        return _KEY_NAMES.get(char.encode("utf-8", "replace"), char)
    return "QUIT"


def _raise_signalled(signum: int, _frame: object) -> None:
    raise Signalled(signum)


@contextlib.contextmanager
def _signals_raise() -> Iterator[None]:
    """Turn SIGTERM and SIGHUP into :class:`Signalled` for the duration, so the
    ``finally`` blocks restore the terminal mode and the cursor."""
    saved: list[tuple[int, signal.Handlers | int | Callable | None]] = []
    for name in ("SIGTERM", "SIGHUP"):
        signum = getattr(signal, name, None)
        if signum is None:  # no SIGHUP on Windows
            continue
        try:
            saved.append((signum, signal.signal(signum, _raise_signalled)))
        except (ValueError, OSError):  # not the main thread
            continue
    try:
        yield
    finally:
        for signum, handler in saved:
            signal.signal(signum, signal.SIG_DFL if handler is None else handler)


def _sanitize(text: str) -> str:
    return _CONTROL_RE.sub("", text)


def _fit(text: str, cols: int) -> str:
    """Truncate to ``cols`` characters with an ellipsis, so a row never wraps."""
    if len(text) <= cols:
        return text
    return text[: max(cols - 1, 0)] + "…"


def multiselect(term: Terminal, locked: int, defaults: Sequence[int], items: Sequence[tuple[str, str]]) -> list[int] | None:
    """Bash ``acq_prompt_multiselect``: a checkbox list whose first ``locked`` rows
    are frozen. ``defaults`` and the result are 1-based indices relative to the
    toggleable rows; the result is ascending, and ``None`` means cancelled."""
    # Rows can carry kit refs, so userinfo is redacted as everywhere else.
    labels = [(_sanitize(kits.redact_userinfo(label)), _sanitize(kits.redact_userinfo(desc))) for label, desc in items]
    total = len(labels)
    locked = min(locked, total)
    first = locked + 1
    checked = {i + locked for i in defaults if first <= i + locked <= total}
    cursor = first
    cols = term.columns()
    bold, reset = term.sgr("1"), term.sgr("0")
    with _signals_raise(), term.keys():
        term.write("\033[?25l")
        try:
            term.write(f"{bold}{_fit(_HEADER, cols)}{reset}\n")
            rendered = False
            while True:
                if rendered:
                    term.write(f"\033[{total}A")
                term.write("".join(_row(term, i, labels[i - 1], locked, i in checked, i == cursor, cols)
                                   for i in range(1, total + 1)))
                rendered = True
                key = term.read_key()
                if key in ("UP", "DOWN") and first <= total:
                    step = -1 if key == "UP" else 1
                    cursor = (cursor - first + step) % (total - locked) + first
                elif key == "SPACE" and first <= cursor <= total:
                    checked ^= {cursor}
                elif key == "ENTER":
                    return sorted(i - locked for i in checked)
                elif key == "QUIT":
                    term.write(f"{term.sgr('2')}acq: selection cancelled; keeping current configuration.{reset}\n")
                    return None
        finally:
            term.write("\033[?25h")


def _row(term: Terminal, index: int, item: tuple[str, str], locked: int, checked: bool, cursor: bool, cols: int) -> str:
    label, desc = item
    reset = term.sgr("0")
    if index <= locked:
        line = term.sgr("2") + _fit(f"  [x] {label}  {desc} (always applied)", cols) + reset
    else:
        mark = "[x]" if checked else "[ ]"
        if cursor:
            line = term.sgr("36") + term.sgr("1") + _fit(f"❯ {mark} {label}  {desc}", cols) + reset
        elif checked:
            line = term.sgr("32") + _fit(f"  {mark} {label}  {desc}", cols) + reset
        else:
            line = _fit(f"  {mark} {label}  {desc}", cols)
    return f"\033[K{line}\n"


def confirm(term: Terminal, prompt: str, default: bool) -> bool:
    """Bash ``acq_prompt_confirm``: ``[Y/n]``/``[y/N]``; anything but a clear
    yes or no (including a bare ENTER and end of input) takes the default."""
    hint = "[Y/n]" if default else "[y/N]"
    bold, green, dim, reset = term.sgr("1"), term.sgr("32"), term.sgr("2"), term.sgr("0")
    term.write(f"{bold}{green}?{reset} {_sanitize(prompt)} {dim}{hint}{reset} ")
    answer = term.read_line().strip(" \t\r\n")
    if answer in ("y", "Y", "yes", "YES"):
        return True
    if answer in ("n", "N", "no", "NO"):
        return False
    return default
