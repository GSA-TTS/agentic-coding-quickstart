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
