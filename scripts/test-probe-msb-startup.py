#!/usr/bin/env python3
"""Offline tests: python3 scripts/test-probe-msb-startup.py (no MSB required)."""

import importlib.machinery
import importlib.util
import os
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).with_name("probe-msb-startup")
loader = importlib.machinery.SourceFileLoader("probe", str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
probe = importlib.util.module_from_spec(spec)
loader.exec_module(probe)


class ProbeTests(unittest.TestCase):
    def setUp(self):
        base = SCRIPT.parent.parent / "tmp"
        base.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="test-msb-startup-", dir=base)
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)

    def event(self, at, event, label, **fields):
        pid = fields.pop("pid", os.getpid())
        with mock.patch.object(probe.time, "monotonic", return_value=at), \
                mock.patch.object(probe.os, "getpid", return_value=pid):
            probe.emit(self.directory, event, label, **fields)

    def test_summary_excludes_session_and_unions_overlapping_calls(self):
        self.event(0, "run-start", "acq-run")
        self.event(1, "cli-start", "create", pid=10)
        self.event(2, "cli-start", "exec", pid=11)
        self.event(3, "cli-end", "create", pid=10, rc=0)
        self.event(4, "cli-end", "exec", pid=11, rc=7)
        self.event(6, "attach", "interactive-handoff")
        self.event(100, "run-end", "acq-run", rc=0)
        text = probe.summary(self.directory)
        self.assertIn("handoff: 6.000s", text)
        self.assertIn("outside measured MSB calls: 3.000s", text)
        self.assertIn("exec [7]", text)
        self.assertNotIn("+  100.000", text)

    def test_fixed_markers_never_persist_payloads(self):
        markers = probe.Markers(self.directory)
        payload = "PRIVATE_SENTINEL_DO_NOT_RECORD"
        lines = [f"acq[debug 12:34:56]: msb provision: applying kit dir /{payload}",
                 f"acq[debug 12:34:56]: msb cmd[install] START (user=0): {payload}",
                 f"acq[debug 12:34:57]: msb cmd[install] DONE: {payload}",
                 f"acq[debug 12:34:57]: msb provision: applied kit dir /{payload}",
                 f"acq[debug 12:34:57]: unknown: {payload}", payload]
        data = ("\r\n".join(lines) + "\r\n").encode()
        for byte in data:
            markers.feed(bytes([byte]))
        raw = (self.directory / "events.jsonl").read_text()
        self.assertNotIn(payload, raw)
        records, partial = probe.read_events(self.directory)
        self.assertFalse(partial)
        self.assertEqual(len(records), 4)
        self.assertEqual([e["label"] for e in records], ["kit", "install", "install", "kit"])
        self.assertTrue(all(e["kit"] == 1 for e in records))

    def test_shim_preserves_io_arguments_and_failure_without_logging_them(self):
        stub = self.directory / "real-msb"
        stub.write_text("#!/bin/sh\n[ \"$2\" = 'private arg' ] || exit 99\n"
                        "[ \"$PROBE_TEST_PRIVATE\" = 'private env' ] || exit 98\n"
                        "IFS= read -r input\nprintf '%s' \"$input\"\nexit 23\n")
        stub.chmod(0o700)
        env = dict(os.environ, ACQ_PROBE_DIR=str(self.directory), ACQ_PROBE_MSB=str(stub),
                   PROBE_TEST_PRIVATE="private env")
        result = subprocess.run([sys.executable, str(SCRIPT), "--msb-shim", "exec", "private arg"],
                                env=env, input="private input\n", text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertEqual(result.stdout, "private input")
        raw = (self.directory / "events.jsonl").read_text()
        self.assertNotIn("private", raw)
        events, _ = probe.read_events(self.directory)
        self.assertEqual(events[-1]["rc"], 23)
        self.assertEqual(events[0]["event"], "cli-start")

    def test_guest_t_flag_is_not_attach(self):
        self.assertEqual(probe.cli_label(["exec", "box", "--", "tool", "-t"]), "exec")
        self.assertEqual(probe.cli_label(["exec", "-t", "box", "--", "opencode"]), "interactive-exec")
        self.assertEqual(probe.cli_label(["unknown-private-value"]), "other")
        self.assertEqual(probe.cli_label(["exec", "box", "--", "chmod", "755", "private"]), "exec-chmod")
        self.assertEqual(probe.cli_label(["exec", "box", "--", "chown", "agent", "private"]), "exec-chown")

    def test_validation_shape_and_builtin_kit_label(self):
        guest = "curl -sS -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer PLACEHOLDER'"
        self.assertEqual(probe.cli_label(["exec", "box", "--", "sh", "-c", guest]),
                         "key-validation-exec")
        markers = probe.Markers(self.directory)
        markers.line("acq[debug 12:00:00]: msb provision: applying kit dir /cache/opencode (box)")
        events, _ = probe.read_events(self.directory)
        self.assertEqual(events[0]["kit_name"], "opencode")

    def test_failed_run_partial_record_and_unfinished_phase_are_explicit(self):
        self.event(0, "run-start", "acq-run")
        self.event(1, "phase-start", "boot-wait")
        self.event(4, "run-end", "acq-run", rc=1)
        with (self.directory / "events.jsonl").open("a") as stream:
            stream.write('{"incomplete":')
        text = probe.summary(self.directory)
        self.assertIn("No interactive handoff observed", text)
        self.assertIn("Run exit: 1", text)
        self.assertIn("boot-wait [incomplete]", text)
        self.assertIn("WARNING: malformed/partial event record", text)

    def test_pty_keeps_all_streams_interactive_and_propagates_exit(self):
        self.event(0, "run-start", "acq-run")
        code = "import os,sys; sys.exit(17 if all(os.isatty(n) for n in (0,1,2)) else 99)"
        rc = probe.run([sys.executable, "-c", code], dict(os.environ), self.directory)
        self.assertEqual(rc, 17)

    def test_missing_workspace_fails_before_launch(self):
        result = subprocess.run([sys.executable, str(SCRIPT), str(self.directory / "absent")],
                                text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn("existing workspace directory", result.stderr)

    def test_host_entrypoint_writes_summary_before_session_exit(self):
        scripts = self.directory / "scripts"
        scripts.mkdir()
        shutil.copyfile(SCRIPT, scripts / SCRIPT.name)
        stub = self.directory / "msb"
        stub.write_text("#!/bin/sh\nexit 0\n")
        stub.chmod(0o700)
        acq = self.directory / "acq"
        acq.write_text("#!/bin/bash\n"
                       "msb create ignored || exit $?\n"
                       "msb exec -t ignored -- opencode || exit $?\n"
                       "for n in 1 2 3 4 5; do\n"
                       "  [ -s \"$ACQ_PROBE_DIR/summary.txt\" ] && exit 0\n"
                       "  sleep 0.2\n"
                       "done\nexit 91\n")
        env = dict(os.environ, PATH=str(self.directory) + os.pathsep + os.environ["PATH"])
        self.event(0, "run-start", "test")
        # Nest the entrypoint in a real PTY so its terminal preflight is exercised.
        rc = probe.run([sys.executable, str(scripts / SCRIPT.name), str(self.directory)],
                       env, self.directory)
        self.assertEqual(rc, 0)
        runs = list((self.directory / "tmp").glob("msb-startup-*"))
        self.assertEqual(len(runs), 1)
        text = (runs[0] / "summary.txt").read_text()
        self.assertIn("Time to interactive handoff:", text)
        self.assertIn("Create calls: 1", text)
        self.assertIn("Run exit: 0", text)
        self.assertIn("shell-to-Python launches", text)
        self.assertTrue((runs[0] / "launcher.tsv").read_text().strip())

    def test_launcher_delay_and_spawn_are_measured_separately(self):
        stub = self.directory / "msb"
        stub.write_text("#!/bin/sh\nexit 0\n")
        stub.chmod(0o700)
        env = dict(os.environ, ACQ_PROBE_DIR=str(self.directory), ACQ_PROBE_MSB=str(stub),
                   ACQ_PROBE_LAUNCH_EPOCH=str(int(time.time()) - 18))
        result = subprocess.run([sys.executable, str(SCRIPT), "--msb-shim", "exec",
                                 "box", "--", "chmod", "755", "private"],
                                env=env, capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        events, _ = probe.read_events(self.directory)
        self.assertGreaterEqual(events[0]["launcher_seconds"], 18)
        self.assertEqual(events[0]["label"], "exec-chmod")
        self.assertEqual(events[1]["event"], "spawned")
        self.assertGreaterEqual(events[1]["spawn_seconds"], 0)
        self.assertNotIn("private", (self.directory / "events.jsonl").read_text())

    def test_shim_preserves_signal_exit(self):
        stub = self.directory / "msb"
        stub.write_text("#!/bin/sh\nkill -INT $$\n")
        stub.chmod(0o700)
        env = dict(os.environ, ACQ_PROBE_DIR=str(self.directory), ACQ_PROBE_MSB=str(stub))
        result = subprocess.run([sys.executable, str(SCRIPT), "--msb-shim", "exec"],
                                env=env, capture_output=True, check=False)
        self.assertEqual(result.returncode, 130, result.stderr)
        events, _ = probe.read_events(self.directory)
        self.assertEqual(events[-1]["rc"], -2)

    def test_calibration_is_read_only_and_alternates_order(self):
        with mock.patch.object(probe.subprocess, "call", return_value=0) as call, \
                mock.patch("builtins.print"):
            rc = probe.calibrate("box", "/real/msb", Path("/shim/msb"), {}, self.directory)
        self.assertEqual(rc, 0)
        self.assertEqual(call.call_count, 16)
        commands = [invocation.args[0] for invocation in call.call_args_list]
        self.assertEqual(commands[0][0], "/real/msb")
        self.assertEqual(commands[8][0], "/shim/msb")
        for command in commands:
            self.assertIn(command[6:], (["true"], ["chmod", "--version"],
                                        ["chown", "--version"], ["node", "--version"]))

    def test_calibration_stops_on_failure(self):
        with mock.patch.object(probe.subprocess, "call", return_value=7) as call, \
                mock.patch("builtins.print"):
            rc = probe.calibrate("box", "/real/msb", Path("/shim/msb"), {}, self.directory)
        self.assertEqual(rc, 1)
        self.assertEqual(call.call_count, 1)

    def test_phase_only_summary_does_not_claim_zero_calls_or_excluded_session(self):
        (self.directory / "metadata.json").write_text('{"phase_only": true}')
        self.event(0, "run-start", "acq-run")
        self.event(1, "phase-start", "create")
        self.event(3, "phase-end", "create")
        self.event(9, "run-end", "acq-run", rc=0)
        text = probe.summary(self.directory)
        self.assertIn("MSB calls not instrumented", text)
        self.assertNotIn("Create calls: 0", text)
        self.assertNotIn("Interactive session time is excluded", text)
        self.assertNotIn("Time outside measured MSB calls", text)
        self.assertIn("create [done]", text)

    def test_phase_only_executes_with_original_path(self):
        with mock.patch.object(probe, "run", return_value=0) as run, \
                mock.patch("builtins.print"), \
                mock.patch.object(probe.tempfile, "mkdtemp", return_value=str(self.directory)):
            args = mock.Mock(calibrate=None, calibrate_files=None, calibrate_batch=None, phase_only=True,
                             directory=self.directory)
            self.assertEqual(probe.execute(args, "/real/msb"), 0)
        command, env, _ = run.call_args.args
        self.assertEqual(env["PATH"], os.environ["PATH"])
        self.assertIn("opencode", command)
        self.assertEqual(env.get("ACQ_NO_PROGRESS"), os.environ.get("ACQ_NO_PROGRESS"))

    def test_relay_error_terminates_and_reaps_owned_child(self):
        self.event(0, "run-start", "test")
        children = []
        real_fork = probe.pty.fork
        def remember_child():
            pid, fd = real_fork()
            if pid:
                children.append(pid)
            return pid, fd
        with mock.patch.object(probe.pty, "fork", side_effect=remember_child), \
                mock.patch.object(probe, "relay", side_effect=OSError("injected")), \
                self.assertRaises(OSError):
            probe.run([sys.executable, "-c", "import time; time.sleep(60)"],
                      dict(os.environ), self.directory)
        with self.assertRaises(ChildProcessError):
            os.waitpid(children[0], os.WNOHANG)

    def test_terminating_shim_reaps_real_child(self):
        stub = self.directory / "msb"
        stub.write_text("#!/bin/sh\nprintf '%s' \"$$\" > \"$ACQ_PROBE_DIR/child.pid\"\n"
                        "exec sleep 60\n")
        stub.chmod(0o700)
        env = dict(os.environ, ACQ_PROBE_DIR=str(self.directory), ACQ_PROBE_MSB=str(stub))
        process = subprocess.Popen([sys.executable, str(SCRIPT), "--msb-shim", "exec"], env=env)
        child = None
        try:
            deadline = time.monotonic() + 5
            while not (self.directory / "child.pid").exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            child = int((self.directory / "child.pid").read_text())
            process.terminate()
            self.assertEqual(process.wait(timeout=5), 143)
            with self.assertRaises(ProcessLookupError):
                os.kill(child, 0)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
            if child:
                try:
                    os.kill(child, signal.SIGKILL)
                except ProcessLookupError:
                    pass

    def test_relay_error_kills_resistant_descendant_after_leader_exits(self):
        reader, writer = os.pipe()
        os.set_inheritable(writer, True)
        code = ("import os,signal,time\n"
                "if os.fork() == 0:\n"
                " signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
                " signal.signal(signal.SIGHUP, signal.SIG_IGN)\n"
                f" os.write({writer}, b'ready')\n"
                " time.sleep(60)\n"
                "else:\n"
                f" os.close({writer})\n"
                " time.sleep(60)\n")
        children = []
        real_fork = probe.pty.fork
        def remember_child():
            pid, fd = real_fork()
            if pid:
                children.append(pid)
                os.close(writer)
            return pid, fd
        def fail_after_descendant_ready(*_):
            self.assertTrue(select.select([reader], [], [], 5)[0], "descendant not ready")
            self.assertEqual(os.read(reader, 5), b"ready")
            raise OSError("injected relay failure")
        try:
            with mock.patch.object(probe.pty, "fork", side_effect=remember_child), \
                    mock.patch.object(probe, "relay", side_effect=fail_after_descendant_ready), \
                    self.assertRaises(OSError):
                probe.run([sys.executable, "-c", code], dict(os.environ), self.directory)
            # EOF proves the descendant closed its inherited writer, even on hosts
            # where an orphan remains visible as a zombie until init reaps it.
            self.assertTrue(select.select([reader], [], [], 5)[0], "descendant survived cleanup")
            self.assertEqual(os.read(reader, 1), b"")
            with self.assertRaises(ChildProcessError):
                os.waitpid(children[0], os.WNOHANG)
        finally:
            if children:
                try:
                    os.killpg(children[0], signal.SIGKILL)
                except ProcessLookupError:
                    pass
            else:
                os.close(writer)
            os.close(reader)

    def test_ssh_serve_preserves_managed_pid(self):
        with mock.patch.dict(os.environ, ACQ_PROBE_DIR=str(self.directory), ACQ_PROBE_MSB="/real/msb"), \
                mock.patch.object(probe.os, "execvpe", side_effect=SystemExit(0)) as execute, \
                self.assertRaises(SystemExit):
            probe.shim(["ssh", "serve", "box"])
        self.assertEqual(execute.call_args.args[:2], ("/real/msb", ["/real/msb", "ssh", "serve", "box"]))

    def test_post_spawn_event_failure_reaps_child(self):
        child = subprocess.Popen(["sleep", "60"])
        try:
            with mock.patch.dict(os.environ, ACQ_PROBE_DIR=str(self.directory), ACQ_PROBE_MSB="/real/msb"), \
                    mock.patch.object(probe.subprocess, "Popen", return_value=child), \
                    mock.patch.object(probe, "emit", side_effect=[None, OSError("injected")]), \
                    self.assertRaises(OSError):
                probe.shim(["exec"])
            self.assertIsNotNone(child.poll())
        finally:
            if child.poll() is None:
                child.kill()
                child.wait(timeout=5)

    def test_file_calibration_changes_only_new_scratch(self):
        with mock.patch.object(probe.subprocess, "call", return_value=0) as call, \
                mock.patch("builtins.print"):
            rc = probe.calibrate("box", "/real/msb", Path("/shim/msb"), {}, self.directory, files=True)
        self.assertEqual(rc, 0)
        commands = [item.args[0] for item in call.call_args_list]
        scratch = "/home/agent/" + self.directory.name
        self.assertEqual(commands[0][6:], ["mkdir", "-m", "755", scratch])
        self.assertEqual(len(commands), 25)
        for command in commands[1:]:
            self.assertIn(scratch + "/fixture.mjs", " ".join(command))
        self.assertTrue((self.directory / "fixture.mjs").is_file())

    def test_file_calibration_collision_stops_before_copy_or_permissions(self):
        with mock.patch.object(probe.subprocess, "call", return_value=1) as call, \
                mock.patch("builtins.print"):
            rc = probe.calibrate("box", "/real/msb", Path("/shim/msb"), {}, self.directory, files=True)
        self.assertEqual(rc, 1)
        self.assertEqual(call.call_count, 1)
        self.assertFalse((self.directory / "fixture.mjs").exists())

    def test_batch_comparison_uses_real_msb_fresh_files_and_verification(self):
        with mock.patch.object(probe.subprocess, "call", return_value=0) as call, \
                mock.patch("builtins.print"):
            rc = probe.calibrate_batch("box", "/real/msb", {"PATH": "/shim"}, self.directory)
        self.assertEqual(rc, 0)
        commands = [item.args[0] for item in call.call_args_list]
        self.assertEqual(len(commands), 27)  # setup + 6 copies + 14 permission calls + 6 checks
        self.assertTrue(all(command[0] == "/real/msb" for command in commands))
        self.assertTrue(all(item.kwargs["env"]["PATH"] == os.environ["PATH"]
                            for item in call.call_args_list))
        copies = [command for command in commands if command[1] == "copy"]
        self.assertEqual(len({command[-1] for command in copies}), 6)
        checks = [command for command in commands if "stat -c %a" in command[-1]]
        self.assertEqual(len(checks), 6)
        self.assertTrue(all("stat -c %U" in command[-1] for command in checks))

    def test_batched_shell_stops_if_first_operation_fails(self):
        # On the real local shell, a failed chmod must prevent later commands.
        commands = probe.permission_commands(str(self.directory / "absent"), "batched-shell")
        result = subprocess.run(commands[0], capture_output=True, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(b"chown:", result.stderr)

    def test_batch_failed_verification_is_not_reported_as_completed(self):
        # Setup, copy, three operations succeed; verification fails.
        with mock.patch.object(probe.subprocess, "call", side_effect=[0, 0, 0, 0, 0, 1]) as call, \
                mock.patch("builtins.print"):
            rc = probe.calibrate_batch("box", "/real/msb", {}, self.directory)
        self.assertEqual(rc, 1)
        self.assertEqual(call.call_count, 6)
        self.assertFalse((self.directory / "batch-totals.json").exists())


if __name__ == "__main__":
    unittest.main()
