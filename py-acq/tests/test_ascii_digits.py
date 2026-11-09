"""Tier-2 tests: version and number parsers accept ASCII digits only.

Python's ``\\d`` and ``int()``/``float()`` accept every Unicode decimal digit, so
``"\u0661.\u0662.\u0663"`` (Arabic-Indic 1.2.3) would otherwise parse as 1.2.3.
No backend prints such a version and no operator types such a timeout, so each
parser must treat them as unparseable rather than silently converting them. Each
test also checks the ASCII spelling still parses, so the guard cannot pass by
rejecting everything.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT))

from acq_py import backends, timeouts  # noqa: E402
from qualification import host, ledger, matrix  # noqa: E402

# Each spells a version that would otherwise pass every floor: wholly in another
# script, one component mixed in, or another script's digit next to ASCII ones.
NON_ASCII_VERSIONS = [
    "\u0660.\u0667.\u0667",  # Arabic-Indic 0.7.7
    "\u06f0.\u06f7.\u06f7",  # Extended Arabic-Indic (Persian) 0.7.7
    "\u0966.\u096d.\u096d",  # Devanagari 0.7.7
    "\uff10.\uff17.\uff17",  # fullwidth 0.7.7
    "0.7.\u0667",  # Arabic-Indic patch only
    "0.\u0667.7",  # Arabic-Indic minor only
    "\u0661\u0660.0.0",  # Arabic-Indic 10.0.0
    "0.7.7\u0661",  # trailing Arabic-Indic digit
    "\u06610.7.7",  # leading Arabic-Indic digit
]


@pytest.mark.parametrize("raw", NON_ASCII_VERSIONS)
def test_backend_version_parser_rejects_non_ascii_digits(raw):
    assert backends.parse_version("msb 0.7.11") is not None  # ASCII control
    assert backends.parse_version(raw) is None
    assert backends.parse_version(f"msb {raw}") is None


@pytest.mark.parametrize("raw", NON_ASCII_VERSIONS)
def test_forced_stub_version_with_non_ascii_digits_is_unknown(monkeypatch, raw):
    monkeypatch.setenv("ACQ_MSB_BIN", "__stub__")
    monkeypatch.setenv("ACQ_MSB_VERSION", "0.7.7")
    assert backends.check_version(backends.BACKENDS["msb"]) is None  # ASCII control
    monkeypatch.setenv("ACQ_MSB_VERSION", raw)
    problem = backends.check_version(backends.BACKENDS["msb"])
    assert problem is not None and problem.code == "backend_version_unknown"


@pytest.mark.parametrize("raw", NON_ASCII_VERSIONS)
def test_qualification_host_rejects_non_ascii_digits(raw):
    def version(output):
        class Proc:
            returncode, stdout, stderr = 0, output, ""

        return host.backend_version("msb", which=lambda n: "/x/msb", run=lambda *a, **k: Proc())

    assert version("msb 0.7.11") == "0.7.11"  # ASCII control
    assert version(f"msb {raw}") is None


@pytest.mark.parametrize("raw", NON_ASCII_VERSIONS)
def test_qualification_matrix_rejects_non_ascii_digits(raw):
    assert matrix.version_problem("msb", "0.7.11") is None  # ASCII control
    assert matrix.same_minor("0.7.7", "0.7.11") is True
    assert matrix.version_problem("msb", raw) is not None
    assert matrix.same_minor(raw, raw) is False


@pytest.mark.parametrize("raw", NON_ASCII_VERSIONS)
def test_qualification_ledger_rejects_non_ascii_digits(tmp_path, raw):
    ledger.parse_ledger({"schema_version": ledger.SCHEMA_VERSION, "accepted_backend_versions": {"msb": "0.7.11"}})
    with pytest.raises(ledger.LedgerError):
        ledger.parse_ledger({"schema_version": ledger.SCHEMA_VERSION, "accepted_backend_versions": {"msb": raw}})
    with pytest.raises(ledger.LedgerError):
        ledger.set_accepted_version(tmp_path / "ledger.json", "msb", raw)


@pytest.mark.parametrize("raw", ["\u0663\u0660", "\u0661.\u0665", "\uff13\uff10", "3\u0660"])
def test_timeout_override_rejects_non_ascii_digits(monkeypatch, capsys, raw):
    monkeypatch.setenv("ACQ_TEST_TIMEOUT", "30")
    assert timeouts.env_seconds("ACQ_TEST_TIMEOUT", 7.0) == 30.0  # ASCII control
    monkeypatch.setenv("ACQ_TEST_TIMEOUT", raw)
    assert timeouts.env_seconds("ACQ_TEST_TIMEOUT", 7.0) == 7.0
    assert "ignoring ACQ_TEST_TIMEOUT" in capsys.readouterr().err
