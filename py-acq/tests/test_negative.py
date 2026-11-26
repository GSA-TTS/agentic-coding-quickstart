"""Negative-oracle conformance (ADR-0043m): a vector that requires something the
foundation runner cannot honour must be refused (fail closed) with a stable
error code, not silently ignored or skipped.

The vectors live in ``test/vectors/negative/``; they are excluded from the
normal corpus run and asserted here as refusals.
"""

from __future__ import annotations

import pytest

import vector_engine as engine
from conftest import VECTORS_DIR

# Map each negative-oracle id to the stable refusal code it must produce.
EXPECTED_REFUSAL = {
    "negative/isolation-offline": "unsupported_isolation",
    "negative/isolation-ssh-stubs": "unsupported_isolation",
    "negative/backend-required": "unsupported_backend",
}

_PATHS = sorted((VECTORS_DIR / "negative").glob("*.json"))


@pytest.mark.parametrize("path", _PATHS, ids=[p.stem for p in _PATHS])
def test_negative_oracle_is_refused(path, tmp_path, acq_cmd, python_exe):
    vector = engine.load_vector(path)  # structurally valid; loads without error
    with pytest.raises(engine.RefusalError) as excinfo:
        engine.run_vector(
            vector,
            acq_cmd=acq_cmd,
            python_exe=python_exe,
            corpus_root=VECTORS_DIR,
            workdir=tmp_path,
        )
    assert excinfo.value.code == EXPECTED_REFUSAL[vector["id"]], (
        f"expected refusal code {EXPECTED_REFUSAL[vector['id']]!r}, got {excinfo.value.code!r}"
    )
