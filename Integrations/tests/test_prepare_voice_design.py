"""Finite preparation rules; no dependency install, network or speech model.

Public responses, process metadata and files below are explicit fixtures. These
tests do not prove that real wheels download, a runtime imports or speech sounds
correct; those stages require their own normal bounded execution.
"""
from __future__ import annotations

from contextlib import ExitStack
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock


INTEGRATIONS = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("prepare_voice_design_under_test", INTEGRATIONS / "prepare_voice_design.py")
prep = importlib.util.module_from_spec(SPEC)
with mock.patch.object(sys, "path", [str(INTEGRATIONS), *sys.path]):
    SPEC.loader.exec_module(prep)


def state(packages=None, **changes):
    selected = packages if packages is not None else prep.fixed_lock()
    result = dict(python=prep.PYTHON_VERSION, platform="darwin", machine="x86_64",
                  packages=sorted(selected.items()) if isinstance(selected, dict) else selected)
    result.update(changes)
    return json.dumps(result).encode()


class TemporaryCase(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve() / "runtime"
        self.root.mkdir()
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        self.stack.enter_context(mock.patch.object(prep.sys, "platform", "darwin"))
        self.stack.enter_context(mock.patch.object(prep.platform, "machine", return_value="x86_64"))
        self.stack.enter_context(mock.patch.object(prep.shutil, "disk_usage", return_value=SimpleNamespace(free=10**12)))

    def model(self, payload=b"synthetic public model bytes; never deserialized"):
        self.payload = payload
        self.name = "weights.bin"
        self.stack.enter_context(mock.patch.object(prep.tts, "MODEL_FILES", {
            self.name: (len(payload), hashlib.sha256(payload).hexdigest())}))
        self.target = self.root / "model" / self.name
        self.target.parent.mkdir(exist_ok=True)
        self.part = self.target.with_name(self.target.name + ".part")


class RequestAndLockTests(TemporaryCase):
    def test_published_lock_is_the_complete_original_91_dependency_record(self):
        self.assertEqual(prep.LOCK.stat().st_size, 1550)
        self.assertEqual(prep.tts.digest(prep.LOCK), prep.LOCK_SHA256)
        self.assertEqual(len(prep.fixed_lock()), 91)
        for name, version in prep.tts.DIRECT_DEPENDENCIES.items():
            self.assertEqual(prep.fixed_lock()[name], version)

    def test_bad_lock_identity_format_duplicate_or_direct_version_is_rejected(self):
        original = prep.LOCK.read_bytes()
        target = self.root / "lock.txt"
        for value in (original + b"\n", original.replace(b"qwen-tts==0.1.1", b"qwen-tts==9.0.0"),
                      original.replace(b"accelerate==1.12.0", b"--extra-index-url=https://invalid"),
                      original.replace(b"annotated-doc==0.0.5", b"accelerate==1.12.0")):
            target.write_bytes(value)
            with mock.patch.object(prep, "LOCK", target), \
                    mock.patch.object(prep, "LOCK_SHA256", hashlib.sha256(value).hexdigest()):
                with self.assertRaises(ValueError):
                    prep.fixed_lock()
        target.write_bytes(original + b"changed")
        with mock.patch.object(prep, "LOCK", target):
            with self.assertRaisesRegex(ValueError, "身份"):
                prep.fixed_lock()

    def test_invalid_stage_arguments_and_deadlines_do_not_create_a_runtime(self):
        absent = self.root / "absent"
        cases = [dict(stage="unknown"), dict(stage="environment"),
                 dict(stage="model", python=Path("/bin/python")),
                 dict(stage="verify", files=["weights.bin"]),
                 dict(stage="model", files=[]), dict(stage="model", files=["unknown"])]
        for options in cases:
            with self.subTest(options=options), self.assertRaises(ValueError):
                prep.prepare(absent, **options)
        for seconds in (True, 4, 841, 5.0):
            with self.assertRaises(ValueError):
                prep.prepare(absent, "model", seconds)
        self.assertFalse(absent.exists())

    def test_unsupported_host_is_not_silently_substituted(self):
        with mock.patch.object(prep.platform, "machine", return_value="arm64"):
            with self.assertRaisesRegex(ValueError, "Darwin x86_64"):
                prep.prepare(self.root, "model")

    def test_sealed_environment_rejects_every_mutating_stage_without_changing_files(self):
        identity = self.root / "identity.txt"
        identity.write_bytes(b"existing fixed environment identity")
        for stage in ("environment", "model", "seal"):
            options = dict(python=Path("/bin/python"), uv=Path("/bin/uv")) if stage == "environment" else {}
            with self.subTest(stage=stage), self.assertRaisesRegex(ValueError, "已封存"):
                prep.prepare(self.root, stage, **options)
        self.assertEqual(identity.read_bytes(), b"existing fixed environment identity")
        self.assertEqual({p.name for p in self.root.iterdir()}, {"identity.txt"})

    def test_runtime_symlink_parent_traversal_and_hardlinked_models_are_rejected(self):
        link = self.root.parent / "linked-runtime"
        link.symlink_to(self.root, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "链接"):
            prep.prepare(link / "child", "model")
        with self.assertRaises(ValueError):
            prep.prepare(self.root / ".." / "another", "model")
        original = self.root / "original"
        original.write_bytes(b"original")
        linked = self.root / "linked"
        prep.os.link(original, linked)
        with self.assertRaisesRegex(ValueError, "硬链接"):
            prep.ordinary_path(linked)

    def test_preparation_and_inference_locks_are_preserved_and_reject_concurrency(self):
        for name in ("preparation.lock", "inference.lock"):
            lock = self.root / name
            lock.mkdir()
            with self.assertRaisesRegex(ValueError, "正在"):
                prep.prepare(self.root, "model")
            self.assertTrue(lock.is_dir())
            lock.rmdir()

    def test_verify_never_creates_missing_directory_or_persistent_files(self):
        absent = self.root / "absent"
        with self.assertRaisesRegex(ValueError, "不存在"):
            prep.prepare(absent, "verify")
        self.assertFalse(absent.exists())
        (self.root / "identity.txt").write_bytes(b"fixed")
        before = sorted(p.name for p in self.root.iterdir())
        with mock.patch.object(prep, "verify_or_seal") as verify:
            result = prep.prepare(self.root, "verify")
        verify.assert_called_once()
        self.assertFalse(verify.call_args.kwargs["seal"])
        self.assertIn("未加载模型", result)
        self.assertEqual(sorted(p.name for p in self.root.iterdir()), before)


class Response(io.BytesIO):
    def __init__(self, payload, status=200, headers=None):
        super().__init__(payload)
        self.status = status
        self.headers = headers or {}


class ModelRecoveryTests(TemporaryCase):
    def setUp(self):
        super().setUp()
        self.model()
        self.stack.enter_context(mock.patch.object(prep.shutil, "disk_usage", return_value=SimpleNamespace(free=10**12)))

    def test_full_public_original_has_fixed_url_no_credentials_and_atomic_promotion(self):
        with mock.patch.object(prep, "public_open", return_value=Response(self.payload, headers={"Content-Length": str(len(self.payload))})) as opening:
            prep.recover_file(self.root, self.name, prep.Budget(5))
        request = opening.call_args.args[0]
        self.assertEqual(request.full_url, f"https://huggingface.co/{prep.tts.ENGINE}/resolve/{prep.tts.MODEL_REVISION}/{self.name}")
        self.assertIsNone(request.get_header("Authorization"))
        self.assertIsNone(request.get_header("Range"))
        self.assertEqual(self.target.read_bytes(), self.payload)
        self.assertFalse(self.part.exists())

    def test_existing_verified_original_is_reused_and_conflicting_bytes_are_not_overwritten(self):
        self.target.write_bytes(self.payload)
        with mock.patch.object(prep, "public_open", side_effect=AssertionError("verified original was downloaded")):
            prep.recover_file(self.root, self.name, prep.Budget(5))
            self.target.write_bytes(b"changed")
            with self.assertRaisesRegex(ValueError, "身份冲突"):
                prep.recover_file(self.root, self.name, prep.Budget(5))
        self.assertEqual(self.target.read_bytes(), b"changed")

    def test_partial_original_resumes_only_exact_range_and_complete_hash(self):
        prefix = self.payload[:11]
        self.part.write_bytes(prefix)
        headers = {"Content-Range": f"bytes 11-{len(self.payload) - 1}/{len(self.payload)}", "Content-Length": str(len(self.payload) - 11)}
        with mock.patch.object(prep, "public_open", return_value=Response(self.payload[11:], 206, headers)) as opening:
            prep.recover_file(self.root, self.name, prep.Budget(5))
        self.assertEqual(opening.call_args.args[0].get_header("Range"), "bytes=11-")
        self.assertEqual(self.target.read_bytes(), self.payload)
        self.assertFalse(self.part.exists())

    def test_empty_partial_can_resume_without_overwrite_or_spurious_range(self):
        self.part.write_bytes(b"")
        with mock.patch.object(prep, "public_open", return_value=Response(self.payload)) as opening:
            prep.recover_file(self.root, self.name, prep.Budget(5))
        self.assertIsNone(opening.call_args.args[0].get_header("Range"))
        self.assertEqual(self.target.read_bytes(), self.payload)

    def test_wrong_status_range_or_length_preserves_previous_partial_bytes(self):
        prefix = self.payload[:5]
        for status, headers in ((200, {}), (206, {}), (206, {"Content-Range": "bytes 0-9/10"}),
                                (206, {"Content-Range": f"bytes 5-{len(self.payload) - 1}/{len(self.payload)}", "Content-Length": "999"})):
            self.part.write_bytes(prefix)
            with self.subTest(status=status, headers=headers), \
                    mock.patch.object(prep, "public_open", return_value=Response(self.payload[5:], status, headers)):
                with self.assertRaises(ValueError):
                    prep.recover_file(self.root, self.name, prep.Budget(5))
            self.assertEqual(self.part.read_bytes(), prefix)
            self.assertFalse(self.target.exists())

    def test_short_oversize_and_wrong_hash_responses_are_never_success_cache(self):
        for payload in (self.payload[:-1], self.payload + b"extra", b"x" * len(self.payload)):
            self.part.unlink(missing_ok=True)
            with self.subTest(length=len(payload)), mock.patch.object(prep, "public_open", return_value=Response(payload)):
                with self.assertRaises(ValueError):
                    prep.recover_file(self.root, self.name, prep.Budget(5))
            self.assertFalse(self.target.exists())
            self.assertTrue(self.part.exists())

    def test_interrupted_download_keeps_exact_returned_prefix_for_a_later_stage(self):
        response = Response(self.payload)
        first = self.payload[:9]
        response.read = mock.Mock(side_effect=[first, OSError("synthetic connection interruption")])
        with mock.patch.object(prep, "public_open", return_value=response):
            with self.assertRaises(OSError):
                prep.recover_file(self.root, self.name, prep.Budget(5))
        self.assertEqual(self.part.read_bytes(), first)
        self.assertFalse(self.target.exists())

    def test_complete_partial_promotes_only_after_hash_without_contacting_network(self):
        self.part.write_bytes(self.payload)
        with mock.patch.object(prep, "public_open", side_effect=AssertionError("full partial was downloaded")):
            prep.recover_file(self.root, self.name, prep.Budget(5))
        self.assertEqual(self.target.read_bytes(), self.payload)

    def test_extra_model_entry_links_and_missing_complete_inventory_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "不完整"):
            prep.model_layout(self.root, complete=True)
        extra = self.target.parent / "extra"
        extra.mkdir()
        with self.assertRaisesRegex(ValueError, "额外"):
            prep.model_layout(self.root)
        extra.rmdir()
        self.target.symlink_to(self.root / "missing")
        with self.assertRaisesRegex(ValueError, "链接"):
            prep.model_layout(self.root)

    def test_insufficient_disk_or_unknown_file_never_opens_a_public_download(self):
        with mock.patch.object(prep, "public_open", side_effect=AssertionError("invalid request downloaded")), \
                mock.patch.object(prep.shutil, "disk_usage", return_value=SimpleNamespace(free=1)):
            with self.assertRaisesRegex(ValueError, "空间不足"):
                prep.recover_file(self.root, self.name, prep.Budget(5))
            with self.assertRaisesRegex(ValueError, "未知"):
                prep.recover_file(self.root, "other.bin", prep.Budget(5))

    def test_model_stage_is_finite_explicit_and_does_not_claim_complete_runtime(self):
        with mock.patch.object(prep, "public_open", return_value=Response(self.payload)):
            result = prep.prepare(self.root, "model", 5, files=[self.name])
        self.assertIn("本阶段1件", result)
        self.assertIn("另行seal", result)
        self.assertFalse((self.root / "identity.txt").exists())
        self.assertFalse((self.root / "preparation.lock").exists())


class EnvironmentTests(TemporaryCase):
    def test_metadata_accepts_only_recorded_partial_or_complete_pinned_environment(self):
        venv_python = self.root / "venv/bin/python"
        with mock.patch.object(prep, "run_owned", return_value=state({"torch": "2.2.2"})):
            prep.environment_state(venv_python, self.root, prep.Budget(5), complete=False)
            with self.assertRaisesRegex(ValueError, "完整91"):
                prep.environment_state(venv_python, self.root, prep.Budget(5), complete=True)
        with mock.patch.object(prep, "run_owned", return_value=state()):
            prep.environment_state(venv_python, self.root, prep.Budget(5), complete=True)

    def test_conflicts_duplicate_packages_wrong_interpreter_or_malformed_probe_are_rejected(self):
        cases = [state({"torch": "9.0"}), state({"unknown": "1"}), state(python="3.10.17"),
                 state(machine="arm64"), state(platform="linux"), state(packages=[["torch", "2.2.2"], ["torch", "2.2.2"]]),
                 b"not json", state(packages=[["torch", 2]]), state(packages=["torch==2.2.2"])]
        for response in cases:
            with self.subTest(response=response), mock.patch.object(prep, "run_owned", return_value=response):
                with self.assertRaises(ValueError):
                    prep.environment_state(self.root / "venv/bin/python", self.root, prep.Budget(5), complete=False)

    def test_environment_uses_explicit_base_separate_venv_full_lock_and_offline_import_only(self):
        python = self.root / "base-python"
        uv = self.root / "uv"
        for executable in (python, uv):
            executable.write_bytes(b"fixture; never executed")
            executable.chmod(0o700)
        calls = []

        def child(args, root, budget, label, **options):
            calls.append((args, label, options))
            if label == "base-python":
                return json.dumps([prep.PYTHON_VERSION, "darwin", "x86_64"]).encode()
            if label == "create-environment":
                (root / "venv").mkdir()
            if label == "environment-state":
                earlier = sum(name == label for _, name, _ in calls)
                return state({} if earlier == 1 else None)
            return b""

        with mock.patch.object(prep, "run_owned", side_effect=child), mock.patch.object(prep, "recover_original") as source:
            prep.prepare(self.root, "environment", 5, python=python, uv=uv)
        install = next(args for args, label, _ in calls if label == "install-fixed-environment")
        self.assertEqual(install[0], str(uv))
        self.assertIn("--no-config", install)
        self.assertIn("--no-deps", install)
        self.assertIn("--only-binary", install)
        self.assertEqual(install[-2:], ["--requirement", str(self.root / "runtime-binary-lock.txt")])
        binary = (self.root / "runtime-binary-lock.txt").read_text().splitlines()
        self.assertEqual(len(binary), 90)
        self.assertEqual(set(binary), set(prep.LOCK.read_text().splitlines()) - {"sox==1.5.0"})
        self.assertEqual(install[install.index("--index-url") + 1], "https://pypi.org/simple")
        source.assert_called_once()
        self.assertEqual(source.call_args.args[2:5], prep.SOX_SOURCE)
        sox_install = next(args for args, label, _ in calls if label == "install-fixed-sox")
        self.assertEqual(sox_install[-1], str(self.root / "sources/sox-1.5.0.tar.gz"))
        self.assertEqual((self.root / "build-constraints.txt").read_text(),
                         "setuptools==70.0.0\nwheel==0.46.3\nnumpy==1.26.4\npackaging==26.3\n")
        imports = next(args[-1] for args, label, _ in calls if label == "import-fixed-environment")
        self.assertIn("from qwen_tts import Qwen3TTSModel", imports)
        self.assertNotIn("from_pretrained", imports)
        self.assertNotIn("generate_voice", imports)
        self.assertFalse((self.root / "identity.txt").exists())

    def test_preparation_environment_omits_credentials_and_uses_only_selected_caches(self):
        with mock.patch.dict(prep.os.environ, {"HF_TOKEN": "synthetic-not-a-token", "HTTP_PROXY": "synthetic-not-a-proxy", "PYTHONPATH": "untrusted"}):
            env = prep.preparation_environment(self.root)
        for key in ("HF_TOKEN", "HTTP_PROXY", "PYTHONPATH", "PIP_INDEX_URL"):
            self.assertNotIn(key, env)
        for key in ("UV_CACHE_DIR", "HF_HOME", "TMPDIR", "TORCH_HOME", "NUMBA_CACHE_DIR"):
            self.assertTrue(Path(env[key]).is_relative_to(self.root))
        self.assertEqual(env["UV_PYTHON_DOWNLOADS"], "never")
        self.assertEqual(env["UV_CONCURRENT_DOWNLOADS"], "1")

    def test_disk_preflight_accounts_for_environment_model_and_minimum_reserve_before_writes(self):
        marker = self.root / "current-latest-artifact"
        marker.write_bytes(b"keep current data")
        with mock.patch.object(prep.shutil, "disk_usage", return_value=SimpleNamespace(free=prep.MINIMUM_FREE_BYTES + 4 * 1024**3)), \
                mock.patch.object(prep, "run_owned", side_effect=AssertionError("low-space preparation installed packages")), \
                mock.patch.object(prep, "public_open", side_effect=AssertionError("low-space preparation downloaded model")):
            with self.assertRaisesRegex(ValueError, "空间不足"):
                prep.prepare(self.root, "environment", 5, python=Path("/explicit/python"), uv=Path("/explicit/uv"))
        self.assertEqual(marker.read_bytes(), b"keep current data")
        self.assertEqual({p.name for p in self.root.iterdir()}, {marker.name})

    def test_existing_fixed_preparation_records_cannot_be_overwritten(self):
        path = self.root / "build-constraints.txt"
        prep.fixed_preparation_text(path, prep.BUILD_CONSTRAINTS)
        prep.fixed_preparation_text(path, prep.BUILD_CONSTRAINTS)
        path.write_bytes(b"user changed build constraints")
        with self.assertRaisesRegex(ValueError, "冲突"):
            prep.fixed_preparation_text(path, prep.BUILD_CONSTRAINTS)
        self.assertEqual(path.read_bytes(), b"user changed build constraints")

    def test_seal_and_verify_delegate_to_normal_adapter_identity_without_model_loading(self):
        self.model()
        self.target.write_bytes(self.payload)
        (self.root / "venv").mkdir()
        with mock.patch.object(prep, "environment_state") as environment, mock.patch.object(prep, "run_owned") as runner:
            prep.verify_or_seal(self.root, prep.Budget(5), seal=True)
        self.assertTrue(environment.call_args.kwargs["complete"])
        self.assertIn("--seal-runtime", runner.call_args.args[0])
        with mock.patch.object(prep, "environment_state"), mock.patch.object(prep, "run_owned") as runner:
            prep.verify_or_seal(self.root, prep.Budget(5), seal=False)
        args = runner.call_args.args[0]
        self.assertIn("['identity']", args[4])
        self.assertNotIn("from_pretrained", " ".join(args))
        self.assertTrue(runner.call_args.kwargs["readonly"])


class ProcessAndDeadlineTests(TemporaryCase):
    def test_readonly_bad_temp_path_is_rejected_before_creating_any_temporary_file(self):
        outside = self.root.parent / "outside"
        outside.mkdir()
        (self.root / "temp").symlink_to(outside, target_is_directory=True)
        for name in prep.OFFLINE_DIRECTORIES[1:]:
            (self.root / name).mkdir()
        with mock.patch.object(prep.tempfile, "TemporaryFile", side_effect=AssertionError("created a file through bad temp")) as temporary, \
                mock.patch.object(prep.subprocess, "Popen", side_effect=AssertionError("started through bad temp")):
            with self.assertRaisesRegex(ValueError, "链接"):
                prep.run_owned(["fixture-not-executed"], self.root, prep.Budget(5), "verify", readonly=True)
        temporary.assert_not_called()
        self.assertEqual(list(outside.iterdir()), [])

    def test_budget_deadline_is_bounded_and_does_not_silently_succeed_after_expiry(self):
        with mock.patch.object(prep.time, "monotonic", side_effect=[10, 16]):
            budget = prep.Budget(5)
            with self.assertRaises(prep.PreparationTimeout):
                budget.remaining()

    def test_process_timeout_terminates_only_its_owned_group_and_keeps_diagnostic(self):
        process = SimpleNamespace(pid=991073, wait=mock.Mock(side_effect=[subprocess.TimeoutExpired("fixture", 5), 0]))
        with mock.patch.object(prep.subprocess, "Popen", return_value=process), mock.patch.object(prep.os, "killpg") as kill:
            with self.assertRaises(subprocess.TimeoutExpired):
                prep.run_owned(["fixture-not-executed"], self.root, prep.Budget(5), "timeout")
        kill.assert_called_once_with(991073, signal.SIGTERM)
        self.assertEqual(len(list((self.root / "preparation-logs").glob("timeout-*.log"))), 1)

    def test_nonzero_process_result_is_failure_and_forced_cleanup_stays_in_owned_group(self):
        process = SimpleNamespace(pid=991074, wait=mock.Mock(side_effect=[2, subprocess.TimeoutExpired("fixture", 5), 0]))
        with mock.patch.object(prep.subprocess, "Popen", return_value=process), mock.patch.object(prep.os, "killpg") as kill:
            with self.assertRaisesRegex(ValueError, "子阶段失败"):
                prep.run_owned(["fixture-not-executed"], self.root, prep.Budget(5), "failure")
        self.assertEqual(kill.call_args_list, [mock.call(991074, signal.SIGTERM), mock.call(991074, signal.SIGKILL)])

    def test_expired_model_stage_preserves_partial_and_releases_only_its_own_lock(self):
        self.model()

        def interrupted(root, name, budget):
            self.part.write_bytes(b"returned prefix")
            raise prep.PreparationTimeout("synthetic finite expiry")

        with mock.patch.object(prep, "recover_file", side_effect=interrupted):
            with self.assertRaises(prep.PreparationTimeout):
                prep.prepare(self.root, "model", 5, files=[self.name])
        self.assertEqual(self.part.read_bytes(), b"returned prefix")
        self.assertFalse(self.target.exists())
        self.assertFalse((self.root / "preparation.lock").exists())

    def test_existing_timer_is_not_overridden_and_previous_handler_is_restored(self):
        with mock.patch.object(prep.signal, "getitimer", return_value=(1, 0)):
            with self.assertRaisesRegex(ValueError, "已有定时器"):
                with prep.deadline(5):
                    self.fail("active timer was replaced")
        original = prep.signal.getsignal(prep.signal.SIGALRM)
        with prep.deadline(5):
            pass
        self.assertEqual(prep.signal.getsignal(prep.signal.SIGALRM), original)
        self.assertEqual(prep.signal.getitimer(prep.signal.ITIMER_REAL), (0, 0))


if __name__ == "__main__":
    unittest.main()
