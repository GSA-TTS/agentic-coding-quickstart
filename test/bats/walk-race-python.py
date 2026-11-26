#!/usr/bin/env python3
# Stand-in for `python3 -I - ARGS...` (how acq runs its provider-input path
# walks) that opens a race window deterministically: the first lookup of the
# component named by ACQ_TEST_WALK_RACE misses, and a rival process creates that
# component before the walk's own mkdir runs. The rival makes a directory, or,
# when ACQ_TEST_WALK_RACE_LINK names a target, a symlink to it. The marker file
# ACQ_TEST_WALK_RACE_MARK records that the window was really exercised.
#
# Invoked by a `python3` shim on PATH as:
#   REAL_PYTHON -I walk-race-python.py -I - ARGS...   (the script on stdin)

import os
import sys

args = sys.argv[1:]
while args and args[0] == "-I":
    args = args[1:]
if not args or args[0] != "-":
    raise SystemExit("walk-race-python: expected the script on stdin")
source = sys.stdin.read()

target = os.environ.get("ACQ_TEST_WALK_RACE", "")
link = os.environ.get("ACQ_TEST_WALK_RACE_LINK", "")
mark = os.environ.get("ACQ_TEST_WALK_RACE_MARK", "")
real_open = os.open
raced = []


def racing_open(path, flags, mode=0o777, *, dir_fd=None):
    if path != target or raced:
        return real_open(path, flags, mode, dir_fd=dir_fd)
    raced.append(path)
    try:
        return real_open(path, flags, mode, dir_fd=dir_fd)
    except FileNotFoundError:
        if link:
            os.symlink(link, path, dir_fd=dir_fd)
        else:
            os.mkdir(path, 0o755, dir_fd=dir_fd)
        if mark:
            with open(mark, "a") as marker:
                marker.write(path + "\n")
        raise


if target:
    os.open = racing_open
sys.argv = args
exec(compile(source, "<stdin>", "exec"), {"__name__": "__main__"})
