"""Offline contracts for release publishing and optional signing (ADR-0050m)."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
BUILD = (ROOT / '.github/workflows/build-assets.yml').read_text()
RELEASE = (ROOT / '.github/workflows/release.yml').read_text()


def _steps(text):
    return re.split(r'^      - ', text, flags=re.M)[1:]


def test_signing_is_opt_in_and_never_runs_on_pull_requests():
    for step in _steps(BUILD):
        if 'secrets.' not in step:
            continue
        assert "inputs.sign" in step
        assert "github.event_name != 'pull_request'" in step
        family = 'WINDOWS' if 'AZURE_' in step else 'MACOS'
        assert f"vars.ENABLE_{family}_SIGNING == 'true'" in step
    for step in _steps(RELEASE):
        if 'cosign' in step:
            assert "vars.ENABLE_COSIGN_SIGNING == 'true'" in step
            assert "github.event_name != 'pull_request'" in step
    assert "default: false" in BUILD
    assert "secrets: inherit" not in RELEASE
    assert 'id-token:' not in BUILD
    assert 'contents: write' not in BUILD
    assert 'gh release' not in BUILD
    # Credentials must never be placed in workflow/job env or ordinary build steps.
    before_steps = BUILD[BUILD.index('jobs:'):BUILD.index('    steps:')]
    assert 'secrets.' not in before_steps
    assert 'secrets.' not in BUILD[:BUILD.index('jobs:')]
    for step in _steps(BUILD):
        if 'secrets.' in step:
            assert 'signing' in step.lower() or 'Authenticode' in step
    for family, names in {
        'windows': ['ENDPOINT', 'ACCOUNT', 'CERTIFICATE_PROFILE', 'TENANT_ID', 'CLIENT_ID', 'CLIENT_SECRET'],
        'macos': ['CERTIFICATE_BASE64', 'CERTIFICATE_PASSWORD', 'SIGNING_IDENTITY', 'KEYCHAIN_PASSWORD', 'API_KEY_BASE64', 'API_KEY_ID', 'API_ISSUER'],
    }.items():
        check = next(s for s in _steps(BUILD) if f'id: {family}-signing' in s)
        for name in names:
            assert re.search(r'\[ -n "\$[A-Z_]*' + name + r'" \]', check)
        signing = next(s for s in _steps(BUILD) if f"steps.{family}-signing.outputs.ready == 'true'" in s)
        assert "github.event_name != 'pull_request'" in signing


def test_publish_attests_and_uploads_the_complete_dist():
    assert 'uses: ./.github/workflows/build-assets.yml' in RELEASE
    assert 'ref: ${{ needs.release-tag.outputs.tag_name }}' in RELEASE
    assert 'needs: [release-tag, build-assets]' in RELEASE
    assert 'name: dist' in RELEASE
    assert "subject-path: 'dist/**/*'" in RELEASE
    assert 'dist/* --clobber' in RELEASE
    assert RELEASE.index('cosign sign-blob') < RELEASE.index('actions/attest-build-provenance@')
    assert RELEASE.index('actions/attest-build-provenance@') < RELEASE.index('gh release upload')
    for legacy in ('sha256sum ', 'DEFAULT_RELEASE_SHA', 'zip -qr', 'wheelhouse-artifacts'):
        assert legacy not in RELEASE
    assert 'scripts/gen-install-assets dist' in BUILD
    assert 'a.get("wheelhouses", [])' in (ROOT / 'scripts/gen-install-assets').read_text()


def test_sign_then_pack_then_hash_and_checkout_release_ref():
    # Every checkout builds or checks the release ref, never the triggering commit.
    checkouts = BUILD.count('uses: actions/checkout@')
    assert checkouts == 4
    assert BUILD.count('ref: ${{ inputs.ref || github.ref }}') == checkouts
    assert BUILD.index('--stage release-tree') < BUILD.index('Authenticode PowerShell files')
    assert BUILD.index('Authenticode PowerShell files') < BUILD.index('--pack release-tree')
    assert BUILD.index('codesign --force') < BUILD.index('notarytool submit') < BUILD.index('--pack release-tree')
    assert BUILD.index('--pack release-tree') < BUILD.index('scripts/gen-install-assets dist')
    assert 'cp release-tree/install.ps1 dist/install.ps1' in BUILD
    cleanup = next(s for s in _steps(BUILD) if s.startswith('name: Clean up'))
    assert 'always()' in cleanup


def test_actions_are_pinned_with_versions_and_permissions_are_scoped():
    for text in (BUILD, RELEASE):
        for line in text.splitlines():
            if 'uses:' not in line or 'uses: ./' in line:
                continue
            assert re.search(r'uses: [\w/-]+@[a-f0-9]{40} # v\d', line), line
    asset_caller = RELEASE.split('  build-assets:\n', 1)[1].split('  publish:\n', 1)[0]
    assert 'contents: read' in asset_caller
    assert 'write' not in asset_caller
    publish = RELEASE.split('  publish:\n', 1)[1]
    assert set(re.findall(r'^      ([\w-]+): write$', publish, re.M)) == {
        'contents', 'id-token', 'attestations',
    }
    assert RELEASE.count('id-token: write') == 1
    assert RELEASE.count('attestations: write') == 1
