"""Real Git-backed recorder and immutable base-relative evidence regressions."""

import copy
import json
from pathlib import Path
import tempfile
import unittest

from fixtures import document, git, invoke, ledger_document
from qualification.model import canonical_transcript_bytes


class RecordingGitTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        git(self.repo, 'init')
        oracle = self.repo / 'scripts' / 'qualify-backend-cell'
        oracle.parent.mkdir()
        # If the evaluator executes rather than hashes this file, it is a bug.
        oracle.write_text("raise RuntimeError('synthetic oracle must never execute')\n", encoding='utf-8')
        git(self.repo, 'add', '.')
        git(self.repo, 'commit', '-m', 'synthetic oracle')
        self.rev = git(self.repo, 'rev-parse', 'HEAD')
        self.ledger = self.repo / 'ledger.json'
        self.ledger.write_text(json.dumps(ledger_document()), encoding='utf-8')
        self.transcript = self.repo / 'transcript.json'
        self.body = self.repo / 'body.md'
        self.doc = document(rev=self.rev)
        self.write_transcript(self.doc)
        self.body.write_text('', encoding='utf-8')

    def write_transcript(self, doc):
        raw = canonical_transcript_bytes(doc)
        self.transcript.write_bytes(raw)
        return '```json\n' + raw.decode('ascii') + '```\n'

    def record(self):
        return invoke(self.repo, '--ledger', str(self.ledger), 'record', str(self.transcript))

    def verify(self, base=None):
        args = ['--ledger', str(self.ledger), 'verify-evidence', str(self.body)]
        if base is not None:
            args += ['--base', base]
        return invoke(self.repo, *args)

    def commit_ledger(self):
        git(self.repo, 'add', 'ledger.json')
        git(self.repo, 'commit', '-m', 'synthetic ledger')
        return git(self.repo, 'rev-parse', 'HEAD')

    def test_record_round_trip_duplicate_and_malformed_do_not_mutate(self):
        result = self.record()
        self.assertEqual(result.returncode, 0, result.stderr)
        before = self.ledger.read_bytes()
        self.body.write_text(self.write_transcript(self.doc), encoding='utf-8')
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(self.record().returncode, 2)
        self.assertEqual(self.ledger.read_bytes(), before)
        bad = document(('FAIL',), 'PASS', rev=self.rev)
        self.write_transcript(bad)
        result = self.record()
        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertIn('outcome', result.stderr)
        self.assertEqual(self.ledger.read_bytes(), before)

    def test_same_hash_mutations_rejected_with_empty_body(self):
        self.assertEqual(self.record().returncode, 0)
        base = self.commit_ledger()
        original = json.loads(self.ledger.read_text(encoding='utf-8'))
        # Positive control: identical base/candidate with no new blocks passes.
        self.assertEqual(self.verify(base).returncode, 0)
        changes = {'rev': base, 'recorded_at': '2026-11-17T00:00:00+00:00',
                   'verdict': 'FAIL', 'backend_version': '0.7.8',
                   'oracle_sha256': 'f' * 64, 'os_build': 'other',
                   'artifact_sha256': 'e' * 64, 'arch': 'arm64',
                   'hypervisor': 'hvf', 'backend': 'sbx',
                   'platform': 'macos-arm64', 'oracle': 'other'}
        for field, value in changes.items():
            with self.subTest(field=field):
                changed = copy.deepcopy(original)
                changed['entries'][0][field] = value
                self.ledger.write_text(json.dumps(changed), encoding='utf-8')
                result = self.verify(base)
                self.assertEqual(result.returncode, 2, result.stdout)
                self.assertIn('entries are immutable', result.stderr)

    def test_removing_entry_is_not_no_entries_added_success(self):
        self.assertEqual(self.record().returncode, 0)
        base = self.commit_ledger()
        self.ledger.write_text(json.dumps(ledger_document()), encoding='utf-8')
        result = self.verify(base)
        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertIn('append-only', result.stderr)

    def test_new_entry_needs_exactly_one_visible_block(self):
        base = self.commit_ledger()
        self.assertEqual(self.record().returncode, 0)
        block = self.write_transcript(self.doc)
        for body, expected, diagnostic in [('', 1, 'MISSING'),
                                            (block, 0, 'OK'),
                                            (block * 2, 1, 'DUPLICATE'),
                                            ('<!--\n' + block + '-->', 1, 'HIDDEN')]:
            with self.subTest(diagnostic=diagnostic):
                self.body.write_text(body, encoding='utf-8')
                result = self.verify(base)
                self.assertEqual(result.returncode, expected, result.stderr + result.stdout)
                self.assertIn(diagnostic, result.stdout)

    def test_appending_new_evidence_preserves_old_entry(self):
        self.assertEqual(self.record().returncode, 0)
        base = self.commit_ledger()
        newer = copy.deepcopy(self.doc)
        newer['attempts'][0]['recorded_at'] = '2026-11-17T00:00:00+00:00'
        self.body.write_text(self.write_transcript(newer), encoding='utf-8')
        self.assertEqual(self.record().returncode, 0)
        result = self.verify(base)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(len(json.loads(self.ledger.read_text())['entries']), 2)

    def test_unknown_base_fails_closed(self):
        result = self.verify('f' * 40)
        self.assertEqual(result.returncode, 2)
        self.assertIn('cannot read', result.stderr)


if __name__ == '__main__':
    unittest.main()
