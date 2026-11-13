"""``acq acp``: launch an agent's Agent Client Protocol server over clean stdio (ADR-0053m).

An ACP client (an IDE such as Zed) spawns acq and speaks JSON-RPC 2.0 over its
stdin and stdout for the life of the session. Four invariants follow, each the
Python form of ADR-0040:

1. **Stdout purity.** The whole prologue (create or re-attach, kit heal,
   credential check) runs with fd 1 pointed at fd 2, and the real stdout is
   restored only for the final launch, so fd 1 carries JSON-RPC and nothing else.
2. **Non-interactive, fail closed.** ``ACQ_NO_PROMPT=1`` and ``ACQ_UPDATE_CHECK=0``
   are set and stdin is the null device for the prologue, so no picker or
   offer can read the client's pipe. A missing or rejected credential is an
   error with a stable code, not a question.
3. **Pipe-clean streaming, no PTY.** The launch is ``msb exec --stream`` or
   ``sbx exec -i``, never ``-t``.
4. **ACP entrypoint resolution.** ``AGENT`` runs ``AGENT acp``; ``shell`` is not an
   ACP server and is refused with exit 2. Arguments after ``--`` extend the
   command when the first starts with ``-``, and replace it otherwise.

The create-or-re-attach work is :func:`acq_py.commands.lifecycle.run_run`'s;
this module supplies the stdio discipline and the streaming launch.
"""

from __future__ import annotations

import contextlib
import os
import sys
from collections.abc import Iterator

from .. import state
from . import common, lifecycle, session

COMMAND = "acp"

# Set for the prologue only, then put back.
_PROLOGUE_ENV = {"ACQ_NO_PROMPT": "1", "ACQ_UPDATE_CHECK": "0"}

NO_JSON_MESSAGE = "acp speaks JSON-RPC on stdout; --json cannot apply"
USAGE = "usage: acq acp AGENT PATH [create-args] [-- ACP_ARGS...] | acq acp NAME [-- ACP_ARGS...]"


class CleanStdio:
    """fd 1 -> fd 2 and stdin -> the null device, until :meth:`restore`.

    Done at the descriptor level, not by swapping ``sys.stdout``, so output from
    a child process or a C extension cannot slip onto the client's stream either.
    :meth:`restore` is idempotent: the launch calls it, and the context exit
    calls it again on every path.
    """

    def __init__(self) -> None:
        self._saved: tuple[int, int | None] | None = None

    def __enter__(self) -> CleanStdio:
        _flush()
        saved_out = os.dup(1)
        try:
            saved_in: int | None = os.dup(0)
        except OSError:  # stdin already closed: nothing to protect or restore
            saved_in = None
        os.dup2(2, 1)
        null = os.open(os.devnull, os.O_RDONLY)
        try:
            os.dup2(null, 0)
        finally:
            os.close(null)
        self._saved = (saved_out, saved_in)
        return self

    def restore(self) -> None:
        if self._saved is None:
            return
        _flush()
        saved_out, saved_in = self._saved
        self._saved = None
        os.dup2(saved_out, 1)
        os.close(saved_out)
        if saved_in is not None:
            os.dup2(saved_in, 0)
            os.close(saved_in)

    def __exit__(self, *_exc: object) -> None:
        self.restore()


def _flush() -> None:
    for stream in (sys.stdout, sys.stderr):
        with contextlib.suppress(OSError, ValueError):
            stream.flush()


@contextlib.contextmanager
def _prologue_env() -> Iterator[None]:
    previous = {name: os.environ.get(name) for name in _PROLOGUE_ENV}
    os.environ.update(_PROLOGUE_ENV)
    try:
        yield
    finally:
        for name, value in previous.items():
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value


def acp_argv(agent: str, agent_args: list[str]) -> list[str] | None:
    """The guest command for ``agent``'s ACP server, or ``None`` if it has none.

    ``shell`` is an interactive shell, not an ACP server. Arguments after ``--``
    that begin with ``-`` are flags to the agent's ACP command; any other first
    word replaces the command, as in ``acq run NAME -- CMD...``.
    """
    if agent not in common.KNOWN_AGENTS or agent == "shell":
        return None
    if agent_args and not agent_args[0].startswith("-"):
        return list(agent_args)
    return [agent, "acp", *agent_args]


def _recorded_agent(backend: str, name: str) -> str | None:
    try:
        record = state.record_read(backend, name)
    except state.StateSchemaError:
        return None  # the re-attach reports the unreadable record itself
    return (record or {}).get("agent")


def _not_acp(agent: str) -> int:
    return common._usage_failure(
        COMMAND, f"'{agent}' is an interactive shell, not an ACP-capable agent", False, USAGE
    )


def run_acp(parsed, emit_json: bool, backend: str) -> int:
    """``acq acp``: create or re-attach, then stream the agent's ACP server."""
    if emit_json:
        return common._usage_failure(COMMAND, NO_JSON_MESSAGE, True, USAGE)
    target = parsed.target
    if target in common.KNOWN_AGENTS:
        agent = target
    elif common._adapter(backend).exists(target):
        agent = _recorded_agent(backend, target) or "shell"
    else:
        return common._usage_failure(
            COMMAND, f"'{target}' is not a known agent or an existing sandbox", False, USAGE
        )
    if acp_argv(agent, list(getattr(parsed, "agent_args", []))) is None:
        return _not_acp(agent)

    with _prologue_env(), CleanStdio() as stdio:

        def launch(backend: str, name: str, workspace: str | None, _token: str | None,
                   _emit_json: bool, agent_args: list[str] | None = None) -> int:
            argv = acp_argv(agent, list(agent_args or []))
            stdio.restore()
            if argv is None:  # the recorded agent may have changed since the check above
                return _not_acp(agent)
            try:
                env = session.session_env_for(backend, name)
                return common._adapter(backend).stream_command(name, argv, workspace=workspace, env=env)
            except common._ADAPTER_ERRORS as exc:
                return common._operational_failure(COMMAND, exc.code, exc.message, exc.remediation, False)

        return lifecycle.run_run(parsed, False, backend, launch)
