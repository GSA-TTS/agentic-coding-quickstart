"""Read a duration override from the environment, lazily and safely.

The bounded waits (the migration lock, the exec-ready gate) take their budget
from an ``ACQ_*`` environment variable. Reading it with ``float()`` at import
made a malformed value (``30s``) crash every command, ``acq version`` included,
and accepted ``nan``/``inf``, which turn a bounded wait into an unbounded one
(``time.monotonic() >= nan`` is never true). Each caller therefore reads the
variable when it needs it, through :func:`env_seconds`, which accepts only a
finite number of seconds that is zero or more. Anything else falls back to the
default with a warning on stderr, so the wait stays bounded and the command
keeps acq's output contract (diagnostics on stderr, never stdout).
"""

from __future__ import annotations

import math
import os
import sys


def env_seconds(name: str, default: float) -> float:
    """Return ``$name`` as seconds, or ``default`` when it is unset or invalid.

    Valid means a finite float that is ``>= 0``. An invalid value is reported on
    stderr, naming the variable and quoting the rejected value (a timeout, never
    a secret), and ignored.
    """
    raw = os.environ.get(name)
    if raw is None or raw.strip() == "":
        return default
    try:
        # float() also accepts other scripts' digits ("\u0661\u0662"); only an
        # ASCII spelling is a valid override.
        value = float(raw) if raw.isascii() else math.nan
    except ValueError:
        value = math.nan
    if math.isfinite(value) and value >= 0:
        return value
    print(
        f"acq: ignoring {name}={raw!r}: expected a finite number of seconds "
        f">= 0; using {default:g}",
        file=sys.stderr,
    )
    return default


# Key rotation (``acq usai-rotate-api-key``) holds the usai provider lock while
# it lists and re-sets the backends' secrets, so each of those backend calls is
# bounded: a backend that hangs (an sbx waiting on an interactive login, say)
# must not keep the lock, and every other usai credential command, forever. The
# 120 s default is the Bash adapter's ROTATE_VALIDATE_TIMEOUT, which bounds the
# sbx call its rotation makes.
ROTATE_TIMEOUT_ENV = "ACQ_ROTATE_TIMEOUT"
DEFAULT_ROTATE_TIMEOUT_S = 120.0


def positive_seconds(name: str, default: float) -> float:
    """Return ``$name`` as seconds for a subprocess timeout, or ``default``.

    Unlike :func:`env_seconds`, zero is invalid here: a subprocess timeout of 0
    fails every call at once (it does not mean "no limit", as it does for GNU
    ``timeout``). Zero, like any other invalid value, falls back to the default
    with a warning on stderr.
    """
    value = env_seconds(name, default)
    if value > 0:
        return value
    print(
        f"acq: ignoring {name}={os.environ.get(name)!r}: expected a number of seconds > 0; using {default:g}",
        file=sys.stderr,
    )
    return default


def rotate_timeout_s() -> float:
    """The per-call budget, in seconds, for a rotation's backend calls."""
    return positive_seconds(ROTATE_TIMEOUT_ENV, DEFAULT_ROTATE_TIMEOUT_S)


# Listing the backend's sandboxes (``acq ls``, and every existence or running
# check behind create, start, rm and the secret re-feeds) is bounded too: a
# backend that hangs (one waiting on a lock or an interactive login) must make
# the command fail with a clear message, not wait forever.
LIST_TIMEOUT_ENV = "ACQ_LIST_TIMEOUT"
DEFAULT_LIST_TIMEOUT_S = 60.0


def list_timeout_s() -> float:
    """The budget, in seconds, for one backend sandbox-listing call."""
    return positive_seconds(LIST_TIMEOUT_ENV, DEFAULT_LIST_TIMEOUT_S)


# ``sbx kit add`` (the heal before an attach, ``kit apply`` and ``kit update``)
# runs with the sandbox's lifecycle lock held, so it is bounded as well: an sbx
# that hangs must not keep the lock, and every other command on the sandbox,
# waiting forever. Adding a kit to a live sandbox copies files and sets
# variables, so ten minutes is generous.
KIT_ADD_TIMEOUT_ENV = "ACQ_SBX_KIT_ADD_TIMEOUT"
DEFAULT_KIT_ADD_TIMEOUT_S = 600.0


def kit_add_timeout_s() -> float:
    """The budget, in seconds, for one ``sbx kit add`` call."""
    return positive_seconds(KIT_ADD_TIMEOUT_ENV, DEFAULT_KIT_ADD_TIMEOUT_S)
