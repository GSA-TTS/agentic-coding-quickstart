"""Run a contract vector that needs acq state set up by earlier acq calls.

Usage (from a vector's ``invoke.argv``)::

    {python} -I test/vectors/drivers/seeded-run.py STEPS {acq}

ADR-0043m vectors are one CLI invocation with no fixtures, and the runners do
not implement ``invoke.fixtures`` yet. A vector whose oracle needs a seeded acq
secret store runs this driver instead (the deviation is recorded in the
coverage manifest). ``STEPS`` is a JSON array of ``[ARGS, FEED_STDIN, EXPECTED_EXIT]``;
each step runs ``{acq} ARGS`` in the vector's isolated environment. The vector's
stdin (a sentinel secret value) is fed only to steps with ``FEED_STDIN`` true.

Exactly one step has ``EXPECTED_EXIT`` null: it is the observed invocation, and
its stdout, stderr and exit status become the vector's result. Every other step,
before or after it, must exit with its expected status. The driver exits 1 with
a message (and no stdout) if a step exits otherwise or if the sentinel appears
in any step's stdout or stderr, so a leak fails the vector.
"""

from __future__ import annotations

import json
import subprocess
import sys


def main(argv: list[str]) -> int:
    steps = json.loads(argv[1])
    acq = argv[2:]
    if not acq or [want for _args, _feed, want in steps].count(None) != 1:
        print("seeded-run: need STEPS with exactly one observed step, then the acq command", file=sys.stderr)
        return 2
    value = sys.stdin.buffer.read()
    observed = None
    for args, feed, want in steps:
        proc = subprocess.run([*acq, *args], input=value if feed else b"", capture_output=True)
        if value and (value in proc.stdout or value in proc.stderr):
            print("seeded-run: the secret value appeared in acq output", file=sys.stderr)
            return 1
        if want is None:
            observed = proc
        elif proc.returncode != want:
            print(f"seeded-run: {' '.join(args)} exited {proc.returncode}, expected {want}", file=sys.stderr)
            return 1
    assert observed is not None
    sys.stdout.buffer.write(observed.stdout)
    sys.stderr.buffer.write(observed.stderr)
    return observed.returncode


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
