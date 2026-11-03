"""Sentinel conformance (ADR-0043m): the golden set covers every assertion mode
and every normalisation transform, so a diverging runner fails on the feature
rather than passing on representatives.

This module only *checks coverage*; the sentinels themselves are run by
``test_vectors.py`` like every other vector. A missing mode or transform here is
a fail-closed error, not a silent pass.
"""

from __future__ import annotations

import vector_engine as engine
from conftest import VECTORS_DIR


def test_sentinels_cover_every_mode_and_transform():
    sentinel_dir = VECTORS_DIR / "sentinel"
    vectors = [engine.load_vector(p) for p in sorted(sentinel_dir.glob("*.json"))]
    assert vectors, "sentinel corpus is empty"

    modes: set[str] = set()
    transforms: set[str] = set()
    for vector in vectors:
        expect = vector.get("expect", {})
        for stream in ("stdout", "stderr"):
            spec = expect.get(stream)
            if spec:
                modes.add(spec.get("mode", "exact"))
                transforms.update(spec.get("normalize", []))

    missing_modes = set(engine.MODES) - modes
    assert not missing_modes, f"missing assertion-mode sentinel(s): {sorted(missing_modes)}"
    missing_transforms = set(engine.TRANSFORMS) - transforms
    assert not missing_transforms, f"missing normalisation-transform sentinel(s): {sorted(missing_transforms)}"
