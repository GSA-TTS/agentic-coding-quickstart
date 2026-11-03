"""Coverage-manifest validation (ADR-0043m).

The manifest maps every contract row to at least one vector id. This test
validates the manifest against the actual corpus: a missing or renamed vector
fails the check rather than being assumed absent, and an orphaned vector (in the
corpus but not referenced) is also an error.
"""

from __future__ import annotations

import json

import vector_engine as engine
from conftest import VECTORS_DIR


def test_coverage_manifest_is_valid_against_corpus():
    manifest_path = VECTORS_DIR / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    rows = manifest.get("rows", [])
    assert rows, "coverage manifest has no rows"

    corpus_ids = {vid for vid, _ in engine.discover_vectors(VECTORS_DIR)}
    referenced: set[str] = set()

    for row in rows:
        assert row.get("contract"), f"contract row missing 'contract': {row}"
        assert row.get("vectors"), f"contract row references no vectors: {row['contract']}"
        for vid in row["vectors"]:
            assert (VECTORS_DIR / f"{vid}.json").exists(), (
                f"manifest references missing vector: {vid} (contract: {row['contract']})"
            )
            referenced.add(vid)

    orphans = corpus_ids - referenced
    assert not orphans, f"corpus vectors not referenced by the manifest: {sorted(orphans)}"
