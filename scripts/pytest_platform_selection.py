#!/usr/bin/env python3
"""Print one fail-closed pytest marker expression for a CI platform lane.

The expression is deliberately small: collection and the tests in
``test_platform_selection.py`` prove that all collected node IDs are disjointly
classified by these explicit markers.  A test needing both native platforms
must use ``platform_shared`` rather than silently acquiring two markers.
"""

from __future__ import annotations

import argparse


EXPRESSIONS = {
    "linux-neutral": "not platform_windows and not platform_macos and not platform_shared",
    "windows-native": "platform_windows or platform_shared",
    "macos-native": "platform_macos or platform_shared",
}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("lane", choices=sorted(EXPRESSIONS))
    args = parser.parse_args()
    print(EXPRESSIONS[args.lane])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
