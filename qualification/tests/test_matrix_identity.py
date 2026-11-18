"""Public matrix APIs must not relabel evidence from another backend or host."""

from dataclasses import replace
from datetime import datetime, timedelta, timezone
import unittest

from fixtures import ROOT  # Establish the same import path as the other offline tests.
from qualification import cell_state, report_matrix
from qualification.matrix import MatrixState
from qualification.model import Environment, Transcript, Verdict

NOW = datetime(2026, 11, 17, tzinfo=timezone.utc)
# Independent expectations, including supported architecture aliases.
CELLS = [
    ("msb", "linux-x86_64", "Linux", "x86_64", "kvm", "0.7.7"),
    ("msb", "linux-aarch64", "Linux", "aarch64", "kvm", "0.7.7"),
    ("msb", "linux-aarch64", "Linux", "arm64", "kvm", "0.7.7"),
    ("msb", "macos-arm64", "Darwin", "arm64", "hvf", "0.7.7"),
    ("msb", "windows-x64", "Windows", "x86_64", "wsl2", "0.7.7"),
    ("msb", "windows-x64", "Windows", "AMD64", "wsl2", "0.7.7"),
    ("sbx", "linux-x86_64", "Linux", "x86_64", "kvm", "0.51.0"),
    ("sbx", "macos-arm64", "Darwin", "arm64", "hvf", "0.51.0"),
    ("sbx", "windows-x64", "Windows", "x86_64", "wsl2", "0.51.0"),
    ("sbx", "windows-x64", "Windows", "AMD64", "wsl2", "0.51.0"),
]


def evidence(cell):
    backend, _, operating_system, arch, hypervisor, version = cell
    env = Environment(operating_system, "fixture", arch, hypervisor, backend, version,
                      "fixture-image", "a" * 40, "b" * 64, "none")
    return Transcript(Verdict.PASS, env, (), "c" * 64, "synthetic", NOW.isoformat())


class MatrixIdentityTests(unittest.TestCase):
    def assert_state(self, cell, transcript, expected):
        backend, platform, *_, version = cell
        self.assertEqual(cell_state(backend, platform, transcript=transcript, now=NOW,
                                    backend_version=version), expected)
        reports = report_matrix({(backend, platform): transcript}, now=NOW,
                                backend_versions={backend: version})
        selected = [r for r in reports if (r.backend, r.platform) == (backend, platform)]
        self.assertEqual(len(selected), 1)
        self.assertEqual(selected[0].state, expected)

    def test_same_cell_and_supported_aliases_qualify(self):
        for cell in CELLS:
            with self.subTest(cell=cell):
                self.assert_state(cell, evidence(cell), MatrixState.QUALIFIED)

    def test_each_identity_component_is_required(self):
        for cell in CELLS:
            original = evidence(cell)
            changes = {"backend": "sbx" if cell[0] == "msb" else "msb",
                       "os": "Darwin" if cell[2] != "Darwin" else "Linux",
                       "arch": "wrong-architecture", "hypervisor": "wrong-hypervisor"}
            for field, value in changes.items():
                with self.subTest(cell=cell, field=field):
                    changed = replace(original, environment=replace(original.environment, **{field: value}))
                    self.assert_state(cell, changed, MatrixState.BLOCKED)

    def test_reported_cross_cell_examples_are_blocked(self):
        target = CELLS[0]
        mac = evidence(CELLS[3])
        self.assert_state(target, mac, MatrixState.BLOCKED)
        sbx_linux = evidence(CELLS[6])
        # Use a matching accepted version so identity is the discriminating check.
        self.assert_state((*target[:-1], "0.51.0"), sbx_linux, MatrixState.BLOCKED)
        self.assert_state((*target[:-1], "0.51.0"), evidence(CELLS[7]), MatrixState.BLOCKED)

    def test_noncanonical_or_missing_host_identity_is_blocked(self):
        cell = CELLS[0]
        original = evidence(cell)
        for field, value in [("os", "linux"), ("os", None), ("backend", None),
                             ("arch", None), ("arch", []), ("hypervisor", {})]:
            with self.subTest(field=field, value=value):
                changed = replace(original, environment=replace(original.environment, **{field: value}))
                self.assert_state(cell, changed, MatrixState.BLOCKED)
        self.assert_state(cell, replace(original, environment=None), MatrixState.BLOCKED)

    def test_missing_verdict_floors_and_freshness_still_block(self):
        cell = CELLS[0]
        original = evidence(cell)
        for transcript in [None, replace(original, verdict=Verdict.FAIL),
                           replace(original, verdict=Verdict.BLOCKED),
                           replace(original, recorded_at=(NOW - timedelta(days=91)).isoformat()),
                           replace(original, environment=replace(original.environment, backend_version="0.7.2"))]:
            with self.subTest(transcript=transcript):
                self.assert_state(cell, transcript, MatrixState.BLOCKED)
        self.assertEqual(cell_state(cell[0], cell[1], transcript=original, now=NOW,
                                    surface_changed=True), MatrixState.BLOCKED)

    def test_unclaimed_cells_keep_precedence(self):
        for backend, platform in [("msb", "windows-arm64"), ("msb", "linux-musl"),
                                  ("sbx", "linux-aarch64"), ("other", "linux-x86_64")]:
            self.assertEqual(cell_state(backend, platform, transcript=evidence(CELLS[0]), now=NOW),
                             MatrixState.UNQUALIFIED)


if __name__ == "__main__":
    unittest.main()
