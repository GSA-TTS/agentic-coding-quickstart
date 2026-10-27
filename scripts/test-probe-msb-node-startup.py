#!/usr/bin/env python3
"""Offline checks: python3 scripts/test-probe-msb-node-startup.py."""

import importlib.machinery
import importlib.util
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).with_name("probe-msb-node-startup")
loader = importlib.machinery.SourceFileLoader("node_probe", str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
probe = importlib.util.module_from_spec(spec)
loader.exec_module(probe)


class NodeProbeTests(unittest.TestCase):
    def setUp(self):
        base = SCRIPT.parent.parent / "tmp"
        base.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="node-test-", dir=base)
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)

    def test_comparison_runs_both_forms_as_agent_and_reverses_order(self):
        with mock.patch.object(probe, "execute", return_value=(0, probe.EXPECTED, 0.1)) as execute, \
                mock.patch("builtins.print"):
            probe.compare("/real/msb", "box", self.directory)
        commands = [call.args[0] for call in execute.call_args_list]
        self.assertEqual(len(commands), 7)
        self.assertEqual(commands[0][-4:-1], ["mkdir", "-m", "755"])
        runs = commands[3:]
        self.assertEqual([command[8] for command in runs], ["node", "sh", "sh", "node"])
        for command in runs:
            self.assertEqual(command[:8], ["/real/msb", "exec", "box", "-u", "agent",
                                           "-e", "HOME=/home/agent", "--"])
        records = json.loads((self.directory / "results.json").read_text())
        self.assertEqual([row["label"] for row in records], ["direct", "fixed-shell", "fixed-shell", "direct"])

    def test_collision_stops_before_copy(self):
        with mock.patch.object(probe, "execute", return_value=(1, b"private diagnostic", 0.1)) as execute, \
                mock.patch("builtins.print"), self.assertRaises(RuntimeError):
            probe.compare("/real/msb", "box", self.directory)
        self.assertEqual(execute.call_count, 1)
        self.assertNotIn("private", (self.directory / "timings.jsonl").read_text())
        self.assertFalse((self.directory / "results.json").exists())

    def test_unexpected_output_is_failure_and_not_saved(self):
        with mock.patch.object(probe, "execute", return_value=(0, b"private output", 0.1)), \
                mock.patch("builtins.print"), self.assertRaises(RuntimeError):
            probe.measure(["unused"], self.directory, "direct", expected=probe.EXPECTED)
        record = json.loads((self.directory / "timings.jsonl").read_text())
        self.assertEqual(record["status"], "failed")
        self.assertNotIn("private", str(record))

    def test_timeout_kills_and_reaps_child(self):
        children = []
        real_popen = subprocess.Popen
        def remember(*args, **kwargs):
            child = real_popen(*args, **kwargs)
            children.append(child)
            return child
        with mock.patch.object(probe.subprocess, "Popen", side_effect=remember), \
                self.assertRaises(subprocess.TimeoutExpired):
            probe.execute([sys.executable, "-c", "import time; time.sleep(60)"], 0.1)
        self.assertIsNotNone(children[0].poll())
        with self.assertRaises(ChildProcessError):
            os.waitpid(children[0].pid, os.WNOHANG)

    def test_fixed_shell_preserves_arguments_and_status(self):
        command = ["sh", "-c", '"$@"', "sh", sys.executable, "-c",
                   "import sys; print(sys.argv[1]); sys.exit(17)", "two words;$(false)"]
        rc, output, _ = probe.execute(command, 5)
        self.assertEqual(rc, 17)
        self.assertEqual(output, b"two words;$(false)\n")

    def test_signals_kill_and_reap_isolated_cli_child(self):
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            with self.subTest(signal=sig):
                ready = self.directory / f"child-{sig}"
                guest = ("import os,sys,time; from pathlib import Path; "
                         "Path(sys.argv[1]).write_text(str(os.getpid())); time.sleep(60)")
                parent_code = ("import runpy,sys; p=runpy.run_path(sys.argv[1]); "
                               "p['execute']([sys.executable,'-c',sys.argv[2],sys.argv[3]],60)")
                parent = subprocess.Popen([sys.executable, "-B", "-c", parent_code,
                                           str(SCRIPT), guest, str(ready)],
                                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                child_pid = None
                try:
                    deadline = time.monotonic() + 5
                    while time.monotonic() < deadline:
                        if ready.exists() and ready.read_text():
                            child_pid = int(ready.read_text())
                            break
                        if parent.poll() is not None:
                            self.fail("probe exited before child readiness")
                        time.sleep(0.01)
                    self.assertIsNotNone(child_pid, "child did not become ready")
                    parent.send_signal(sig)
                    self.assertEqual(parent.wait(timeout=5), 128 + sig)
                    with self.assertRaises(ProcessLookupError):
                        os.kill(child_pid, 0)
                finally:
                    if parent.poll() is None:
                        parent.kill()
                    parent.wait()
                    if child_pid is not None:
                        try:
                            os.kill(child_pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass

    def test_signal_handlers_restored_after_success_and_spawn_failure(self):
        signals = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
        previous = [signal.getsignal(sig) for sig in signals]
        probe.execute([sys.executable, "-c", "pass"], 5)
        self.assertEqual([signal.getsignal(sig) for sig in signals], previous)
        with mock.patch.object(probe.subprocess, "Popen", side_effect=OSError), \
                self.assertRaises(OSError):
            probe.execute(["unused"], 5)
        self.assertEqual([signal.getsignal(sig) for sig in signals], previous)


if __name__ == "__main__":
    unittest.main()
