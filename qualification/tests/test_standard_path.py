"""Pin the offline suite's standard pre-commit/hosted path without YAML dependencies."""

import re
import unittest

from fixtures import ROOT


class StandardPathTests(unittest.TestCase):
    def test_hook_executes_suite_and_covers_dependency_closure(self):
        config = (ROOT / '.pre-commit-config.yaml').read_text(encoding='utf-8')
        match = re.search(r'(?m)^      - id: test-qualification\n(.*?)(?=^      - id:|\Z)',
                          config, re.S)
        self.assertIsNotNone(match, 'offline tests must be wired into the standard hook suite')
        hook = match.group(1)
        self.assertRegex(hook, r'(?m)^        entry: python3 -B -s -m unittest discover -s qualification/tests -v$')
        self.assertRegex(hook, r'(?m)^        language: system$')
        self.assertRegex(hook, r'(?m)^        pass_filenames: false$')
        self.assertNotIn('stages:', hook, 'a manual-only hook is not standard verification')
        pattern = re.search(r"(?m)^        files: '([^']+)'$", hook).group(1)
        for path in ['qualification/ledger.py', 'qualification/transcript_validation.py',
                     'qualification/tests/test_recording_git.py', 'qualification/new_module.py',
                     'py-acq/src/acq_py/hostexec.py', '.pre-commit-config.yaml',
                     '.github/workflows/pre-commit.yml']:
            self.assertRegex(path, pattern)

    def test_existing_hosted_standard_path_runs_all_hooks(self):
        workflow = (ROOT / '.github/workflows/pre-commit.yml').read_text(encoding='utf-8')
        for event in ('pull_request', 'push', 'merge_group'):
            self.assertRegex(workflow, rf'(?m)^  {event}:$')
        self.assertRegex(workflow, r'(?m)^        run: pre-commit run --all-files .*--verbose$')
        self.assertIn('persist-credentials: false', workflow)
        self.assertNotIn('qualification.gate check', workflow)


if __name__ == '__main__':
    unittest.main()
