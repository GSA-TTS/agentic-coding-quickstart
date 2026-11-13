"""Offline bootstrap checks using only synthetic inputs and Git metadata."""

import os
import json
from datetime import datetime, timezone
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from qualification import gate
from qualification.ledger import parse_ledger


class BootstrapTests(unittest.TestCase):
    def invoke(self, cwd):
        env = {key: value for key, value in os.environ.items()
               if not key.startswith(("GIT_", "PYTHON"))}
        env.update(PYTHONPATH=str(ROOT), PYTHONDONTWRITEBYTECODE="1",
                   GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_SYSTEM=os.devnull,
                   GIT_NO_REPLACE_OBJECTS="1")
        return subprocess.run(
            [sys.executable, "-B", "-s", "-P", "-m", "qualification.gate", "check"],
            cwd=cwd, env=env, capture_output=True, text=True, timeout=30,
        )

    def test_missing_ledger_is_not_success(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = self.invoke(tmp)
            self.assertNotEqual(result.returncode, 0)

    def test_candidate_module_cannot_replace_evaluator(self):
        with tempfile.TemporaryDirectory() as tmp:
            candidate = Path(tmp)
            package = candidate / "qualification"
            package.mkdir()
            sentinel = candidate / "candidate-executed"
            (package / "__init__.py").write_text(
                "from pathlib import Path\n"
                "Path('candidate-executed').write_text('bad')\n",
                encoding="utf-8",
            )
            (package / "gate.py").write_text("raise SystemExit(0)\n", encoding="utf-8")
            result = self.invoke(tmp)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(sentinel.exists())

    def test_empty_ledger_blocks_all_claimed_cells(self):
        with tempfile.TemporaryDirectory() as tmp:
            docs = Path(tmp) / "docs"
            docs.mkdir()
            (docs / "qualification-ledger.json").write_text(
                '{"schema_version":1,"accepted_backend_versions":'
                '{"msb":"0.7.7","sbx":"0.51.0"},"entries":[],"waivers":[]}',
                encoding="utf-8",
            )
            result = self.invoke(tmp)
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn("7 blocked", result.stdout)
            self.assertNotIn("Gate passes", result.stdout)

    def test_expired_waiver_does_not_pass(self):
        ledger = parse_ledger({
            "schema_version": 1, "entries": [],
            "accepted_backend_versions": {"msb": "0.7.7", "sbx": "0.51.0"},
            "waivers": [{"backend": "msb", "platform": "linux-x86_64",
                         "expires": "2020-01-01", "reason": "synthetic expired waiver"}],
        })
        statuses = gate.evaluate(ledger, now=datetime(2026, 11, 13, tzinfo=timezone.utc))
        cell = next(s for s in statuses if s.backend == "msb" and s.platform == "linux-x86_64")
        self.assertEqual(cell.status, "blocked")
        self.assertIn("expired", cell.reason)

    def test_malformed_ledger_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            docs = Path(tmp) / "docs"
            docs.mkdir()
            (docs / "qualification-ledger.json").write_text(
                json.dumps({"schema_version": 1, "entries": "not a list"}), encoding="utf-8")
            self.assertNotEqual(self.invoke(tmp).returncode, 0)


if __name__ == "__main__":
    unittest.main()
