"""How the qualification tooling starts host programs.

The same rules as acq's launchers. Programs (``git``, ``gh``, the backend CLIs)
are resolved to an absolute path from absolute ``PATH`` entries only, so a copy
planted in the current directory never runs: on Windows a bare name is looked
up there first, and on POSIX an empty or relative ``PATH`` entry means the
current directory. Python children run with ``-P`` and a ``PYTHONPATH`` fixed to
the checkout they import from, never the caller's, whose empty or relative
entries would put the current directory back on ``sys.path``.

The resolver is acq's own (``acq_py.hostexec``), loaded by file path from this
checkout's ``py-acq/src``. The package is often imported without that directory
on ``sys.path`` (the CI gate sets ``PYTHONPATH`` to a base-branch worktree only),
and loading by path pins it to the copy that sits beside this package.
"""

from __future__ import annotations

import importlib.util
import os
import sys
from pathlib import Path
from types import ModuleType

# The checkout this package was imported from: the PYTHONPATH its own Python
# children get, and where the resolver is loaded from.
PACKAGE_ROOT = Path(__file__).resolve().parent.parent
_RESOLVER = PACKAGE_ROOT / "py-acq" / "src" / "acq_py" / "hostexec.py"


def _load_resolver() -> ModuleType:
    spec = importlib.util.spec_from_file_location("qualification._acq_hostexec", _RESOLVER)
    if spec is None or spec.loader is None:  # pragma: no cover - a missing file raises below
        raise ImportError(f"cannot load {_RESOLVER}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_resolver = _load_resolver()

# ``which(name)`` returns the absolute path or None; ``command(name)`` returns
# ``[absolute path]`` or raises FileNotFoundError, as starting a missing
# program would.
which = _resolver.which
command = _resolver.command


def python_command(module: str, *args: str) -> list[str]:
    """``python -P -m module args``: the current directory is not put on ``sys.path``."""
    return [sys.executable, "-P", "-m", module, *args]


def python_env(*pythonpath: Path, base: dict[str, str] | None = None) -> dict[str, str]:
    """``base`` (default: this process's environment) with ``PYTHONPATH`` fixed to ``pythonpath``.

    Every directory must be absolute: a relative one would resolve against the
    child's current directory.
    """
    if not pythonpath or not all(p.is_absolute() for p in pythonpath):
        raise ValueError("PYTHONPATH entries must be absolute directories")
    env = dict(os.environ if base is None else base)
    env["PYTHONPATH"] = os.pathsep.join(str(p) for p in pythonpath)
    return env
