"""Discriminating transcript schema, identity, reproduction and evidence tests."""

import copy
from dataclasses import replace
import hashlib
import unittest

from fixtures import document, ledger_document
from qualification.ledger import (
    LedgerError, audit_evidence, entry_from_transcript, evidence_blocks,
    parse_ledger, verify_evidence,
)
from qualification.model import BINDING_FIELDS, canonical_transcript_bytes


def record(doc, **kwargs):
    return entry_from_transcript(doc, canonical_transcript_bytes(doc),
                                 oracle_digest=lambda rev, path: "d" * 64, **kwargs)


class TranscriptTests(unittest.TestCase):
    def assert_rejected(self, doc):
        with self.assertRaises(LedgerError):
            record(doc)
        # Also exercise reconstruction against a hand-written entry bearing the
        # malformed block's *matching* hash: rejection must not be a hash miss.
        raw = canonical_transcript_bytes(doc)
        entry = replace(record(document()), transcript_sha256=hashlib.sha256(raw).hexdigest())
        result = verify_evidence(parse_ledger(ledger_document([entry])), [raw])
        self.assertEqual(result[0][0], entry.transcript_sha256)
        self.assertIsNotNone(result[0][1])
        self.assertNotIn("no ledger entry", result[0][1])

    def test_reproduction_outcomes_round_trip(self):
        cases = [(('PASS',), 'PASS'), (('BLOCKED',), 'BLOCKED'),
                 (('FAIL',), 'FLAKY'), (('FAIL', 'FAIL'), 'FAIL'),
                 (('FAIL', 'FAIL', 'FAIL'), 'FAIL'), (('FAIL', 'PASS'), 'FLAKY'),
                 (('FAIL', 'BLOCKED'), 'FLAKY'), (('FAIL', 'FAIL', 'PASS'), 'FLAKY')]
        cases.append((('FAIL',) * 4, 'FAIL'))  # Existing configurable budget, not a new schema limit.
        for verdicts, outcome in cases:
            with self.subTest(verdicts=verdicts):
                doc = document(verdicts, outcome)
                raw = canonical_transcript_bytes(doc)
                entry = record(doc)
                self.assertEqual(entry.verdict, outcome)
                self.assertEqual(verify_evidence(parse_ledger(ledger_document([entry])), [raw]),
                                 [(hashlib.sha256(raw).hexdigest(), None)])

    def test_top_level_outcome_cannot_contradict_attempts(self):
        for verdicts, outcome in [(('FAIL',), 'PASS'), (('BLOCKED',), 'PASS'),
                                  (('PASS',), 'FAIL'), (('FAIL', 'PASS'), 'FAIL'),
                                  (('FAIL',), 'FAIL')]:
            with self.subTest(verdicts=verdicts, outcome=outcome):
                self.assert_rejected(document(verdicts, outcome))

    def test_binding_divergence_is_flaky_not_confirmed_failure(self):
        values = {"rev": "e" * 40, "artifact_sha256": "f" * 64,
                  "backend_version": "0.7.8", "os_build": "other", "hypervisor": "other"}
        self.assertEqual(set(values), set(BINDING_FIELDS))
        for field, value in values.items():
            with self.subTest(field=field):
                doc = document(('FAIL', 'FAIL'), 'FAIL')
                doc['attempts'][1]['environment'][field] = value
                self.assert_rejected(doc)
                doc['outcome'] = 'FLAKY'
                self.assertEqual(record(doc).verdict, 'FLAKY')

    def test_attempts_after_settlement_are_rejected(self):
        for verdicts, outcome in [(('PASS', 'FAIL'), 'PASS'),
                                  (('BLOCKED', 'FAIL'), 'BLOCKED'),
                                  (('FAIL', 'PASS', 'FAIL'), 'FLAKY')]:
            with self.subTest(verdicts=verdicts):
                self.assert_rejected(document(verdicts, outcome))

    def test_later_attempt_must_also_run_the_cell_oracle(self):
        doc = document(('FAIL', 'FAIL'), 'FAIL')
        doc['attempts'][1]['commands'] = ['scripts/other', '--backend', 'msb']
        self.assert_rejected(doc)

    def test_schema_fields_and_types_are_exact(self):
        for location in [(), ('attempts', 0), ('attempts', 0, 'environment')]:
            for operation in ('missing', 'extra', 'not-object'):
                with self.subTest(location=location, operation=operation):
                    doc = document()
                    target = doc
                    for key in location:
                        target = target[key]
                    if operation == 'missing':
                        target.pop(next(iter(target)))
                    elif operation == 'extra':
                        target['unexpected'] = 'not a schema field'
                    elif location:
                        parent = doc
                        for key in location[:-1]:
                            parent = parent[key]
                        parent[location[-1]] = []
                    else:
                        doc = []
                    self.assert_rejected(doc)
        for version in (True, 1.0, '1', 0, 2, None):
            doc = document()
            doc['schema_version'] = version
            self.assert_rejected(doc)

    def test_malformed_attempt_values_are_rejected(self):
        cases = {'verdict': ['FLAKY', 'pass', None, 1, {}],
                 'commands': [[], 'command', [1], ['wrong-oracle']],
                 'output_sha256': ['', 'x' * 64, 'A' * 64, 'a' * 63, None],
                 'detail': [None, []], 'recorded_at': [None, 'yesterday', '2026-11-16']}
        for field, values in cases.items():
            for value in values:
                with self.subTest(field=field, value=value):
                    doc = document()
                    doc['attempts'][0][field] = value
                    self.assert_rejected(doc)
        for attempts in (None, [], {}, [None]):
            doc = document()
            doc['attempts'] = attempts
            self.assert_rejected(doc)

    def test_every_environment_is_validated(self):
        cases = {'rev': ['short', '0' * 40, None],
                 'artifact_sha256': ['bad', 'A' * 64], 'os': ['unknown', None],
                 'arch': [None, ''], 'backend': ['other', None],
                 'backend_version': ['unknown', 7], 'os_build': [None, ''],
                 'hypervisor': ['', None], 'glibc_floor': [1, []],
                 'image': [None], 'transcript_dir': ['/private/local/path']}
        for field, values in cases.items():
            for value in values:
                for index in (0, 1):
                    with self.subTest(field=field, value=value, index=index):
                        doc = document(('FAIL', 'FAIL'), 'FAIL')
                        doc['attempts'][index]['environment'][field] = value
                        self.assert_rejected(doc)

    def test_cross_cell_attempts_are_rejected_even_as_flaky(self):
        for field, value in [('backend', 'sbx'), ('os', 'Darwin'), ('arch', 'arm64')]:
            doc = document(('FAIL', 'FAIL'), 'FLAKY')
            doc['attempts'][1]['environment'][field] = value
            self.assert_rejected(doc)

    def test_blocked_empty_digest_and_legacy_timestamp_override(self):
        doc = document(('BLOCKED',), 'BLOCKED')
        doc['attempts'][0]['output_sha256'] = ''
        self.assertEqual(record(doc).verdict, 'BLOCKED')
        doc['attempts'][0]['recorded_at'] = ''
        with self.assertRaises(LedgerError):
            record(doc)
        entry = record(doc, recorded_at='2026-11-16T00:00:00+00:00')
        self.assertEqual(entry.verdict, 'BLOCKED')

    def test_interpreter_spellings_and_sha256_git_revision_are_supported(self):
        for interpreter in ('python3', '<local>/python3', '<local>/python.exe', 'py.exe'):
            doc = document(rev='a' * 64)
            doc['attempts'][0]['commands'].insert(0, interpreter)
            self.assertEqual(record(doc).rev, 'a' * 64)

    def test_canonical_bytes_oracle_and_platform_still_required(self):
        doc = document()
        raw = canonical_transcript_bytes(doc)
        for altered in (raw.rstrip(), raw.replace(b'\n', b'\r\n')):
            with self.assertRaises(LedgerError):
                entry_from_transcript(doc, altered, oracle_digest=lambda rev, path: 'd' * 64)
        with self.assertRaises(LedgerError):
            record(doc, platform='macos-arm64')
        with self.assertRaises(LedgerError):
            entry_from_transcript(doc, raw, oracle_digest=lambda rev, path: None)
        for argv in [['scripts/qualify-backend-cell', '--backend', 'sbx'],
                     ['/private/python3', 'scripts/qualify-backend-cell', '--backend', 'msb']]:
            bad = copy.deepcopy(doc)
            bad['attempts'][0]['commands'] = argv
            self.assert_rejected(bad)

    def test_visible_evidence_set_and_entry_equality(self):
        doc = document()
        raw = canonical_transcript_bytes(doc)
        entry = record(doc)
        ledger = parse_ledger(ledger_document([entry]))
        body = '```json\n' + raw.decode() + '```\n'
        results, problems = audit_evidence(ledger, evidence_blocks(body), [entry])
        self.assertEqual(problems, [])
        self.assertIsNone(results[0][1])
        for text, code in [('', 'MISSING'), (body * 2, 'DUPLICATE'),
                           ('<!--\n' + body + '-->', 'HIDDEN')]:
            self.assertTrue(any(code in p for p in audit_evidence(ledger, evidence_blocks(text), [entry])[1]))
        self.assertTrue(any('EXTRA' in p for p in audit_evidence(ledger, evidence_blocks(body), [])[1]))
        changed = replace(entry, recorded_at='2026-11-17T00:00:00+00:00')
        result = verify_evidence(parse_ledger(ledger_document([changed])), [raw])
        self.assertIn('entry differs in recorded_at', result[0][1])


if __name__ == '__main__':
    unittest.main()
