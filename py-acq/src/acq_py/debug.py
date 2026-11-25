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
              if v and re.search(r"TOKEN|PASSWORD|SECRET|API_?KEY|CREDENTIAL|_KEY$", k, re.I)}
    shown: list[str] = []
    hide_next = False
    for index, arg in enumerate(argv):
        if arg == "--":
            shown += ["--", "<command>"]
            break
        rendered = redact(arg)
        for value in sorted(values, key=len, reverse=True):
            rendered = rendered.replace(value, "***")
        if hide_next:
            rendered = rendered.split("=", 1)[0] + "=***" if "=" in rendered and argv[index - 1] in ("-e", "--env") else "***"
        elif "=" in rendered and "://" not in rendered:
            rendered = rendered.split("=", 1)[0] + "=***"
        shown.append(shlex.quote(rendered))
        shell_command = (arg == "-c" and index > 0
                         and any(os.path.basename(part) in ("sh", "bash", "dash", "zsh", "ksh")
                                 for part in (argv[0], argv[index - 1])))
        hide_next = arg in ("-e", "--env", "--password", "--token", "--secret-value") or shell_command
    stamp = datetime.now().strftime("%H:%M:%S")
    print(f"acq[debug {stamp}]: {' '.join(shown)}", file=sys.stderr)
