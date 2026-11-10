"""Opt-in stderr tracing without child input, environment values or guest scripts."""

from __future__ import annotations

import os
import re
import shlex
import sys
from collections.abc import Mapping, Sequence
from datetime import datetime


def trace_command(argv: Sequence[str], env: Mapping[str, str] | None = None) -> None:
    """Trace the command shape, redacting credentials before quoting arguments."""
    if not os.environ.get("ACQ_DEBUG"):
        return
    from .legacy_bash import redact

    values = {v for k, v in {**os.environ, **(env or {})}.items()
              if v and re.search(r"TOKEN|PASSWORD|SECRET|API_KEY|CREDENTIAL", k, re.I)}
    shown: list[str] = []
    hide_next = False
    for arg in argv:
        if arg == "--":
            shown += ["--", "<command>"]
            break
        if hide_next:
            rendered = arg.split("=", 1)[0] + "=***" if "=" in arg else "***"
        elif "=" in arg and "://" not in arg:
            rendered = arg.split("=", 1)[0] + "=***"
        else:
            rendered = redact(arg)
            for value in sorted(values, key=len, reverse=True):
                rendered = rendered.replace(value, "***")
        shown.append(shlex.quote(rendered))
        hide_next = arg in ("-e", "--env", "--password", "--token", "--secret-value", "-c")
    stamp = datetime.now().strftime("%H:%M:%S")
    print(f"acq[debug {stamp}]: {' '.join(shown)}", file=sys.stderr)
