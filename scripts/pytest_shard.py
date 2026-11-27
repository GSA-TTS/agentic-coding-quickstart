"""CI-only pytest plugin: partition collected tests by whole file (ADR-0054m)."""

from __future__ import annotations

import re
from collections import Counter

import pytest


def partition(files: Counter[str], count: int) -> list[list[str]]:
    """Greedily balance collected item counts, with stable path tie-breaking."""
    if count < 1 or len(files) < count or any(n < 1 for n in files.values()):
        raise ValueError("shards require at least one collected file each")
    shards: list[list[str]] = [[] for _ in range(count)]
    loads = [0] * count
    for path in sorted(files, key=lambda path: (-files[path], path)):
        index = min(range(count), key=lambda index: (loads[index], index))
        shards[index].append(path)
        loads[index] += files[path]
    return shards


def pytest_addoption(parser):
    parser.addoption("--acq-shard", help="whole-file shard I/N (one-based)")


@pytest.hookimpl(trylast=True)
def pytest_collection_modifyitems(session, config, items):
    spec = config.getoption("--acq-shard")
    if spec is None:
        return
    if session.testsfailed:
        return  # Preserve pytest's collection error rather than masking it.
    match = re.fullmatch(r"([1-9][0-9]*)/([1-9][0-9]*)", spec)
    if match is None:
        raise pytest.UsageError("--acq-shard must be I/N, with 1 <= I <= N")
    index, count = map(int, match.groups())
    if index > count:
        raise pytest.UsageError("--acq-shard must be I/N, with 1 <= I <= N")
    try:
        shards = partition(Counter(str(item.path) for item in items), count)
    except ValueError as error:
        raise pytest.UsageError(str(error)) from error
    paths = set(shards[index - 1])
    selected = [item for item in items if str(item.path) in paths]
    deselected = [item for item in items if str(item.path) not in paths]
    config.hook.pytest_deselected(items=deselected)
    items[:] = selected
    reporter = config.pluginmanager.get_plugin("terminalreporter")
    if reporter:
        reporter.write_line(f"acq shard {spec}: {len(paths)} files, {len(items)} items")
