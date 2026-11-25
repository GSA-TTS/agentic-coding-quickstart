"""Offline contracts for rewrite CI triggers and the independent macOS lane."""

from pathlib import Path
import re
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / '.github/workflows'
REWRITE = 'migration/python-cross-platform'
NAMES = ('python-quality', 'python-vectors', 'pre-commit', 'windows', 'bash32-compat', 'macos')


def _text(name):
    return (WORKFLOWS / f'{name}.yml').read_text()


def _event(text, name):
    triggers = text.split('\non:\n', 1)[1].split('\nconcurrency:', 1)[0]
    return re.search(r'^  ' + name + r':\n(.*?)(?=^  \w|\Z)', triggers, re.M | re.S).group(1)


@pytest.mark.parametrize('name', NAMES)
def test_exact_branch_triggers_and_pr_isolated_concurrency(name):
    text = _text(name)
    for event in ('pull_request', 'push'):
        block = _event(text, event)
        assert REWRITE in block
        assert '*' not in block
        # Windows and bash32 never ran main pushes: preserve that contract.
        assert ('main' in block) == (event == 'pull_request' or name not in ('windows', 'bash32-compat'))
    assert _event(text, 'merge_group').strip() == 'branches: [main]'
    assert '${{ github.event.pull_request.number || github.ref }}' in text
    assert not re.search(r'^  (pull_request_target|workflow_run):', text, re.M)
    assert 'secrets.' not in text
    assert ': write' not in text
    for line in text.splitlines():
        if 'uses:' in line:
            assert re.search(r'uses: [\w/-]+@[a-f0-9]{40} +# v\d', line), line
    assert text.count('uses: actions/checkout@') == text.count('persist-credentials: false')


@pytest.mark.parametrize('name', ('windows', 'bash32-compat', 'macos'))
def test_relevance_uses_actual_event_base_and_push_runs_everything(name, tmp_path):
    text = _text(name)
    assert 'github.event.merge_group.base_sha || github.event.pull_request.base.sha' in text
    assert 'origin/main' not in text.replace('# Like Windows, diff the actual event base, not origin/main.', '')
    # Execute the real inline script for a push lacking BASE_SHA: no fetch/diff
    # may be attempted, and the expensive work must be selected.
    marker = 'id: filter\n'
    script = text.split(marker, 1)[1].split('        run: |\n', 1)[1].split('\n\n', 1)[0]
    script = '\n'.join(line[10:] for line in script.splitlines())
    output = tmp_path / 'output'
    result = subprocess.run(['bash', '-c', script], env={
        'PATH': '/usr/bin:/bin', 'EVENT_NAME': 'push', 'BASE_SHA': '',
        'GITHUB_OUTPUT': str(output),
    }, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    assert output.read_text() == 'relevant=true\n'


def test_diff_dry_run_is_relative_to_each_actual_base(tmp_path):
    """Real Git diff: a rewrite-only input is not a change against its own base."""
    def git(*args):
        return subprocess.check_output(['git', '-C', str(tmp_path), *args], text=True).strip()

    git('init', '-q')
    path = tmp_path / 'acq'
    path.write_text('main\n')
    git('add', 'acq')
    main = git('write-tree')
    path.write_text('rewrite\n')
    git('add', 'acq')
    rewrite = git('write-tree')
    (tmp_path / 'prose.txt').write_text('irrelevant\n')
    git('add', 'prose.txt')
    head = git('write-tree')
    assert git('diff', '--name-only', main, head, '--', 'acq') == 'acq'
    assert git('diff', '--name-only', rewrite, head, '--', 'acq') == ''


def test_macos_is_independent_native_offline_and_hash_pinned():
    text = _text('macos')
    assert re.findall(r'^  (\w+):$', text.split('jobs:\n', 1)[1], re.M) == ['macos']
    assert 'runs-on: macos-15' in text and 'timeout-minutes: 30' in text
    assert 'needs:' not in text
    assert 'permissions: {}' in text and '      contents: read' in text
    assert '"$(uname -m)" = arm64' in text
    assert 'runner queue' in text
    assert '-m pytest py-acq/tests -q -rs' in text
    assert '--require-hashes --no-deps --only-binary :all:' in text
    assert "text.split('- platform: macos-arm64\\n', 1)" in text
    assert 'sh scripts/assemble-release macos-arm64' in text
    assert 'sh scripts/gen-provenance' in text
    assert '--source "$AREA/dist"' in text
    assert 'version --json' in text and "d['impl'] == 'python'" in text
    assert "d['acq_version']" in text and "d['source_revision']" in text
    assert '"$AREA/bin/acq" --help' in text
    assert '"$AREA/bin/acq" backend list --json' in text
    assert 'if: always() && steps.area.outputs.path' in text
    assert '"$RUNNER_TEMP"/acq-macos.*) rm -rf -- "$AREA"' in text
