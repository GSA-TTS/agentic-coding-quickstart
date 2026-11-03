"""Tier-1 contract vectors: run every vector in the corpus as a subprocess.

Each vector is one pytest case. Platform/backend scoping follows ADR-0043m:
a vector whose declared platform is not the current one, or whose declared
backend is not available in this slice, is skipped rather than run.
"""

from __future__ import annotations

import pytest

import vector_engine as engine
from conftest import VECTORS_DIR

VECTORS = engine.discover_vectors(VECTORS_DIR)


@pytest.mark.parametrize("vec_id,path", VECTORS, ids=[v[0] for v in VECTORS])
def test_vector(vec_id, path, tmp_path, acq_cmd, python_exe):
    vector = engine.load_vector(path)

    platform = vector.get("platform", "any")
    if platform not in ("any", "all", engine.current_platform()):
        pytest.skip(f"platform {platform!r} != {engine.current_platform()!r}")

    if vector.get("backend"):
        pytest.skip(f"backend {vector['backend']!r} not available in the foundation slice")

    engine.run_vector(
        vector,
        acq_cmd=acq_cmd,
        python_exe=python_exe,
        corpus_root=VECTORS_DIR,
        workdir=tmp_path,
    )
