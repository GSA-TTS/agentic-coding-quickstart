"""Read a provider-input root's ``current`` the way acq's reader does (no network, no product state)."""

from __future__ import annotations

import os
import re
from pathlib import Path

_TARGET = re.compile(r"generations/generation\.[A-Za-z0-9_]+")


def current_generation(root: Path) -> Path:
    """The generation ``root/current`` names, as Bash ``_acq_provider_input_current_generation`` reads it.

    ``current`` is a relative symlink on POSIX and a pointer file holding the
    same target (and a newline) on Windows (KNOWN_FAILURE_MODES section 61);
    ``provider_input.publish`` writes whichever the host uses. The target must
    be exactly ``generations/generation.<suffix>`` and name a real directory,
    not a link; anything else fails the test.
    """
    current = root / "current"
    if current.is_symlink():
        target = os.readlink(current)
    else:
        target = current.read_bytes().decode("ascii").removesuffix("\n")
    assert _TARGET.fullmatch(target), f"current names {target!r}"
    generation = root / target
    assert generation.is_dir() and not generation.is_symlink() and not os.path.isjunction(generation)
    return generation
