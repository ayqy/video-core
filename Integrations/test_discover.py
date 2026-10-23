"""Offline discovery boundaries use local executables, never a host or model."""
import hashlib
import json
import os
from pathlib import Path
import selectors
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

import discover


CATALOG = {"commands": [{"name": "schema", "input_schema": {"type": "object"}}]}
SCHEMA = {"schema_version": "1.0", "ok": True, "result": CATALOG}


class DiscoverTests(unittest.TestCase):
    def setUp(self):
        base = Path.cwd() / ".cache" / "discover-tests"
        base.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=base)
        self.root = Path(self.temporary.name).resolve()
        self.binary = self.root / "video"

    def tearDown(self):
        self.temporary.cleanup()

    def executable(self, body):
        self.binary.write_text("#!" + sys.executable + "\n" + body)
        self.binary.chmod(0o700)
        return self.binary

    def valid(self, before="", after=""):
        return self.executable(before + "\nprint(" + repr(json.dumps(SCHEMA)) + ", flush=True)\n" + after)

    def capture(self):
        captured = []
        original = subprocess.Popen

        def launch(*args, **kwargs):
            process = original(*args, **kwargs)
            captured.append(process)
            return process

        return captured, patch("discover.subprocess.Popen", side_effect=launch)

    def test_real_child_schema_summary_retains_existing_canonical_contract(self):
        self.valid()
        digest = hashlib.sha256(json.dumps(CATALOG, sort_keys=True, separators=(",", ":"),
                                           ensure_ascii=False).encode()).hexdigest()
        self.assertEqual(discover.discover(self.binary),
                         f"video schema_version=1.0 commands=1 schema_sha256={digest}")

    def test_real_child_does_not_receive_home_provider_secrets_or_workspace(self):
        self.valid("import os\n"
                   "assert 'DISCOVERY_TEST_SECRET' not in os.environ\n"
                   "assert 'HOME' not in os.environ\n"
                   "assert os.environ['PATH'] == '/usr/bin:/bin:/usr/sbin:/sbin'\n"
                   # macOS adds its own text-encoding marker during exec.
                   "assert set(os.environ) <= {'PATH', 'LANG', 'LC_CTYPE', '__CF_USER_TEXT_ENCODING'}\n"
                   "assert os.getcwd() == '/'\n")
        with patch.dict(os.environ, {"DISCOVERY_TEST_SECRET": "test-only-sentinel"}):
            self.assertIn("commands=1", discover.discover(self.binary))

    def test_stdout_bound_is_enforced_before_producer_finishes(self):
        self.executable("import os,time\n"
                        "for _ in range(10000): os.write(1, b'x' * 8192)\n"
                        "time.sleep(30)\n")
        processes, launch = self.capture()
        started = time.monotonic()
        with launch, patch("discover._MAX_STDOUT_BYTES", 4096):
            with self.assertRaisesRegex(ValueError, "输出超过上限"):
                discover.discover(self.binary)
        self.assertLess(time.monotonic() - started, 2)
        self.assertIsNotNone(processes[0].poll())

    def test_stderr_is_rejected_without_waiting_for_or_returning_diagnostics(self):
        self.executable("import os,time\n"
                        "os.write(2, b'test-only-private-diagnostic')\n"
                        "time.sleep(30)\n")
        processes, launch = self.capture()
        started = time.monotonic()
        with launch:
            with self.assertRaises(ValueError) as failure:
                discover.discover(self.binary)
        self.assertNotIn("test-only-private", str(failure.exception))
        self.assertLess(time.monotonic() - started, 2)
        self.assertIsNotNone(processes[0].poll())

    def test_deadline_reaps_owned_child_even_after_both_streams_close(self):
        self.executable("import os,time\nos.close(1)\nos.close(2)\ntime.sleep(30)\n")
        processes, launch = self.capture()
        started = time.monotonic()
        with launch, patch("discover._TIMEOUT_SECONDS", .2):
            with self.assertRaises((ValueError, subprocess.TimeoutExpired)):
                discover.discover(self.binary)
        self.assertLess(time.monotonic() - started, 2)
        self.assertIsNotNone(processes[0].poll())

    def test_exited_leader_term_ignoring_descendant_cannot_hold_pipe(self):
        # The leader exits before the reader begins. EOF on a separately owned
        # descriptor proves that cleanup reached the pipe-holding descendant.
        pid_file = self.root / "ready.pid"
        child = ("import os,signal,time\n"
                 "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
                 "with open(" + repr(str(pid_file)) + ", 'w') as f: f.write(str(os.getpid()))\n"
                 "time.sleep(30)\n")
        self.executable("import pathlib,subprocess,time\n"
                        "subprocess.Popen([" + repr(sys.executable) + ", '-c', " + repr(child) + "])\n"
                        "deadline=time.monotonic()+2\n"
                        "while not pathlib.Path(" + repr(str(pid_file)) + ").exists() and time.monotonic()<deadline: time.sleep(.01)\n")
        captured = []
        original = subprocess.Popen

        def launch(*args, **kwargs):
            process = original(*args, **kwargs)
            captured.append((process, os.dup(process.stdout.fileno())))
            process.wait(timeout=3)
            self.assertTrue(pid_file.exists())
            return process

        try:
            with patch("discover.subprocess.Popen", side_effect=launch), patch("discover._TIMEOUT_SECONDS", 1):
                with self.assertRaisesRegex(ValueError, "超过期限"):
                    discover.discover(self.binary)
            process, descriptor = captured[0]
            self.assertEqual(process.returncode, 0)
            watcher = selectors.DefaultSelector()
            try:
                watcher.register(descriptor, selectors.EVENT_READ)
                self.assertTrue(watcher.select(1), "descendant still retains stdout")
                self.assertEqual(os.read(descriptor, 1), b"")
            finally:
                watcher.close()
        finally:
            for _, descriptor in captured:
                os.close(descriptor)

    def test_changed_cli_bytes_and_identical_replacement_both_refuse_summary(self):
        for replace in (False, True):
            with self.subTest(replace=replace):
                self.valid(after=("from pathlib import Path\n"
                                  "p=Path(__file__)\n"
                                  + ("q=p.with_suffix('.new'); q.write_bytes(p.read_bytes()); q.chmod(0o700); q.replace(p)\n"
                                     if replace else "p.write_bytes(p.read_bytes()+b'\\n# changed\\n')\n")))
                with self.assertRaisesRegex(ValueError, "执行期间发生变化"):
                    discover.discover(self.binary)

    def test_hardlink_is_refused_before_starting_child(self):
        self.valid()
        os.link(self.binary, self.root / "alias")
        with patch("discover.subprocess.Popen") as launch:
            with self.assertRaisesRegex(ValueError, "普通单链接文件"):
                discover.discover(self.binary)
        launch.assert_not_called()

    def test_cleanup_signal_failure_cannot_report_success(self):
        self.valid()
        with patch("discover.os.killpg", side_effect=PermissionError):
            with self.assertRaisesRegex(ValueError, "清理未完成"):
                discover.discover(self.binary)

    def test_nonzero_invalid_root_and_missing_input_schema_are_refused(self):
        self.executable("raise SystemExit(3)\n")
        with self.assertRaisesRegex(ValueError, "未成功"):
            discover.discover(self.binary)
        for value in ([], {"schema_version": "1.0", "ok": True, "result": {"commands": []}},
                      {"schema_version": "1.0", "ok": True, "result": {"commands": [{"name": "schema"}]}}):
            with self.subTest(value=value):
                self.executable("print(" + repr(json.dumps(value)) + ")\n")
                with self.assertRaises(ValueError):
                    discover.discover(self.binary)

    def test_command_line_failure_is_generic_and_does_not_echo_child_output(self):
        self.executable("import os\nos.write(2, b'test-only-private-diagnostic')\n")
        result = subprocess.run([sys.executable, str(Path(discover.__file__).resolve()),
                                 "--binary", str(self.binary)], capture_output=True, timeout=3)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, b"")
        self.assertNotIn(b"test-only-private", result.stderr)
        self.assertIn("只读能力发现未完成", result.stderr.decode())


if __name__ == "__main__":
    unittest.main()
