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


def test_every_vector_the_retirement_inventory_cites_exists():
    # The inventory (docs/test-retirement-inventory.md) says its vector
    # cross-references are validated against the corpus; this is that check. A
    # cited id is exact (`cli/version-json`) or a glob over ids (`cli/secret-ls-*`)
    # that must match at least one vector.
    import fnmatch
    import re

    from conftest import REPO_ROOT

    text = (REPO_ROOT / "docs" / "test-retirement-inventory.md").read_text(encoding="utf-8")
    sections = "|".join(sorted(p.name for p in VECTORS_DIR.iterdir() if p.is_dir()))
    cited = set(re.findall(rf"`((?:{sections})/[^`\s]+)`", text))
    assert cited, "the inventory cites no vectors"
    corpus_ids = sorted(vid for vid, _ in engine.discover_vectors(VECTORS_DIR))
    missing = sorted(c for c in cited if not fnmatch.filter(corpus_ids, c))
    assert not missing, f"the inventory cites vectors that do not exist: {missing}"
