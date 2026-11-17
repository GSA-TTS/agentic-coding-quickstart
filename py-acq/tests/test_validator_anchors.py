"""Whole-string validators must reject trailing and embedded newlines.

In Python, `$` also matches just before a trailing newline, so an anchored
re.match() accepted values such as "BASH_ENV\\n" while the forbidden/reserved
name checks compared them as different strings.
"""

from __future__ import annotations

import pytest

from acq_py import kits, provider_creds

NEWLINE_VARIANTS = ("{}\n", "{}\r\n", "{}\nX")


@pytest.mark.parametrize("suffix", NEWLINE_VARIANTS)
def test_forbidden_key_env_cannot_be_smuggled_with_a_newline(suffix):
    forbidden = sorted(provider_creds.FORBIDDEN_KEY_ENVS)[0]
    assert not provider_creds.key_env_ok(forbidden)
    assert not provider_creds.key_env_ok(suffix.format(forbidden))


@pytest.mark.parametrize("suffix", NEWLINE_VARIANTS)
def test_key_env_rejects_newlines(suffix):
    assert provider_creds.key_env_ok("OPENCODE_GO_API_KEY")
    assert not provider_creds.key_env_ok(suffix.format("OPENCODE_GO_API_KEY"))


@pytest.mark.parametrize("suffix", NEWLINE_VARIANTS)
def test_provider_id_and_host_reject_newlines(suffix):
    assert provider_creds.provider_id_ok("usai")
    assert not provider_creds.provider_id_ok(suffix.format("usai"))
    assert provider_creds.host_ok("api.gsa.usai.gov")
    assert not provider_creds.host_ok(suffix.format("api.gsa.usai.gov"))


@pytest.mark.parametrize("suffix", NEWLINE_VARIANTS)
def test_reserved_key_env_binding_with_newline_is_refused(suffix):
    reserved = sorted(provider_creds._RESERVED_KEY_ENV_OWNERS)[0]
    err = provider_creds.validate_binding("someprovider", suffix.format(reserved), ["example.com"])
    assert err is not None


@pytest.mark.parametrize("suffix", NEWLINE_VARIANTS)
def test_kit_refs_repos_and_dirs_reject_newlines(suffix):
    sha = "a" * 40
    assert kits.is_full_ref(sha)
    assert not kits.is_full_ref(suffix.format(sha))
    assert kits.normalize_dir("integrations/isolation/acq-kits") is not None
    assert kits.normalize_dir(suffix.format("integrations/isolation/acq-kits")) is None
    assert kits.normalize_repo("github.com/GSA-TTS/agentic-coding-patterns") is not None
    # normalize_repo strips surrounding whitespace first, so only embedded
    # newlines can reach the grammar.
    assert kits.normalize_repo("github.com/GSA-TTS/agentic-\ncoding-patterns") is None


@pytest.mark.parametrize("raw", [
    "github.com/o/r\n.git",
    "github.com/o/r\n/",
    "github.com/o/r\n#x",
    "github.com/o/r\n?x",
])
def test_normalize_repo_rejects_newline_left_after_suffix_stripping(raw):
    # strip() runs first; a newline before a .git, '/', '#' or '?' suffix
    # survived it and only the grammar could refuse the result.
    assert kits.normalize_repo(raw) is None
