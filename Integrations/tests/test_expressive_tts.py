"""Cache, PCM and process-boundary rules; these tests do not assess TTS quality.

Every waveform below is synthetic test PCM. The mocked worker never loads or
evaluates a speech model, and its result is not listening-acceptance evidence.
"""
from __future__ import annotations

import concurrent.futures
import hashlib
import importlib.util
from pathlib import Path
import signal
import struct
import subprocess
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest import mock
import wave


ADAPTER_PATH = Path(__file__).resolve().parents[1] / "expressive_tts.py"
SPEC = importlib.util.spec_from_file_location("expressive_tts_under_test", ADAPTER_PATH)
tts = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(tts)


def write_test_pcm(path: Path, *, frames=6615, rate=22050, channels=1,
                   width=2, amplitude=1200):
    """Write 0.3 seconds by default, with distinguishable non-silent samples."""
    path.parent.mkdir(parents=True, exist_ok=True)
    if width == 2:
        pcm = b"".join(struct.pack("<h", amplitude if i % 2 else -amplitude)
                       for i in range(frames * channels))
    else:
        pcm = bytes([128 + min(amplitude, 100)]) * frames * channels * width
    with wave.open(str(path), "wb") as output:
        output.setnchannels(channels)
        output.setsampwidth(width)
        output.setframerate(rate)
        output.writeframes(pcm)
    return path


class RequestIdentityTests(unittest.TestCase):
    def setUp(self):
        self.engine = dict(engine=tts.ENGINE, model=tts.MODEL_REVISION,
                           source=tts.SOURCE_REVISION, runtime_sha256="runtime-v1",
                           adapter_sha256="adapter-v1")
        self.request = dict(text="小明出了十元，桥修好了。", voice="中文女",
                            instruction="先好奇地提问，再清楚地讲出结果。", seed=1986)

    def test_same_complete_request_has_stable_identity_and_explicit_audio_contract(self):
        request, key = tts.request_identity(self.engine, **self.request)
        self.assertEqual((request, key), tts.request_identity(dict(reversed(list(self.engine.items()))), **self.request))
        self.assertEqual(request["segmentation"], "one-complete-utterance")
        self.assertEqual((request["speed"], request["format"], request["sample_rate"]),
                         (1.0, "mono-pcm16", 22050))
        self.assertEqual(len(key), 64)

    def test_every_model_runtime_adapter_and_authored_choice_changes_cache_key(self):
        _, initial = tts.request_identity(self.engine, **self.request)
        keys = {initial}
        changes = [("engine", "another-engine"), ("model", "model-v2"),
                   ("source", "source-v2"), ("runtime_sha256", "runtime-v2"),
                   ("adapter_sha256", "adapter-v2"),
                   ("text", "小明出了十元，桥还没修好。"), ("voice", "中文男"),
                   ("instruction", "温和地讲述，让选择处的停顿自然。"), ("seed", 1987)]
        for field, value in changes:
            with self.subTest(field=field):
                engine, request = dict(self.engine), dict(self.request)
                (engine if field in engine else request)[field] = value
                identity, key = tts.request_identity(engine, **request)
                self.assertEqual(identity[field], value)
                self.assertNotIn(key, keys)
                keys.add(key)

    def test_rejects_control_injection_unapproved_voices_and_request_bounds(self):
        changes = [("text", ""), ("text", " "), ("text", "文" * 241),
                   ("text", "第一段\n第二段"), ("text", "你好<laughter>"),
                   ("text", "甲|乙"), ("text", "甲\x00乙"),
                   ("voice", "外部克隆音色"), ("instruction", ""),
                   ("instruction", "语" * 161), ("instruction", "自然\r讲述"),
                   ("instruction", "<|endofprompt|>"),
                   ("seed", -1), ("seed", 2**31)]
        for field, value in changes:
            with self.subTest(field=field, value=repr(value)):
                request = {**self.request, field: value}
                with self.assertRaises(ValueError):
                    tts.request_identity(self.engine, **request)


class WaveValidationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def test_checks_complete_mono_pcm16_data_and_preserves_actual_sample_count(self):
        path = write_test_pcm(self.root / "valid.wav", frames=7777)
        original = path.read_bytes()
        self.assertEqual(tts.inspect_wave(path), (7777, 22050))
        self.assertEqual(path.read_bytes(), original)

    def test_rejects_wrong_rate_channels_width_duration_silence_and_clipping(self):
        cases = dict(wrong_rate=dict(rate=24000), stereo=dict(channels=2),
                     byte_samples=dict(width=1), too_short=dict(frames=4409),
                     too_long=dict(frames=90 * 22050 + 1),
                     silent=dict(amplitude=0), clipped=dict(amplitude=32767))
        for name, options in cases.items():
            with self.subTest(name=name):
                path = write_test_pcm(self.root / (name + ".wav"), **options)
                with self.assertRaises(ValueError):
                    tts.inspect_wave(path)

    def test_rejects_truncated_data_even_when_wave_header_claims_valid_duration(self):
        path = write_test_pcm(self.root / "truncated.wav")
        path.write_bytes(path.read_bytes()[:-2])
        with self.assertRaisesRegex(ValueError, "不完整"):
            tts.inspect_wave(path)

    def test_rejects_non_wave_data(self):
        path = self.root / "not-wave.wav"
        path.write_bytes(b"this is not a RIFF PCM container")
        with self.assertRaises((wave.Error, EOFError, ValueError)):
            tts.inspect_wave(path)


class GenerationBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.runtime = self.root / "runtime"
        self.cache = self.root / "cache"
        self.output = self.root / "delivery" / "voice.wav"
        self.runtime.mkdir()
        weight = self.runtime / "model" / "fixture.pt"
        weight.parent.mkdir()
        weight.write_bytes(b"synthetic model identity fixture; never deserialized")
        self.weight = weight
        self.weights = {"fixture.pt": (weight.stat().st_size, tts.digest(weight))}
        self.patch_weights = mock.patch.object(tts, "MODEL_FILES", self.weights)
        self.patch_weights.start()
        self.addCleanup(self.patch_weights.stop)
        self.source_files = []
        for index in range(10):
            path = self.runtime / "source" / ("identity-fixture-%02d.txt" % index)
            path.parent.mkdir(exist_ok=True)
            path.write_text("source/dependency fixture %d" % index, encoding="utf-8")
            self.source_files.append(path)
        self.live_freeze = "fixture-engine==1.0\nfixture-torch==2.2.2\n"
        environment = self.runtime / "environment-freeze.txt"
        environment.write_text(self.live_freeze, encoding="utf-8")
        self.source_files.append(environment)
        # Keep dependency discovery independent from the mocked synthesis
        # subprocess. No fixture interpreter or fake real-model environment is
        # installed, and no worker Popen can accidentally service this check.
        self.patch_live_dependencies = mock.patch.object(
            tts.subprocess, "run", side_effect=self.discover_dependencies)
        self.patch_live_dependencies.start()
        self.addCleanup(self.patch_live_dependencies.stop)
        self.write_manifest()
        self.request = dict(text="小明出了十元，桥修好了。", voice="中文女",
                            instruction="用自然亲切的语气讲述。", seed=1986)

    def discover_dependencies(self, args, **kwargs):
        self.assertEqual(args[:3], [str(self.runtime / "venv/bin/python"), "-B", "-c"])
        self.assertIn("importlib.metadata", args[3])
        self.assertTrue(kwargs["check"])
        self.assertEqual(kwargs["timeout"], 30)
        return SimpleNamespace(stdout=self.live_freeze, returncode=0)

    def write_manifest(self):
        lines = ["source=" + tts.SOURCE_REVISION, "model=" + tts.MODEL_REVISION]
        lines += [tts.digest(path) + "  " + str(path.relative_to(self.runtime))
                  for path in self.source_files]
        (self.runtime / "identity.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")

    def generate(self, output=None, **overrides):
        return tts.generate(self.runtime, self.cache, **{**self.request, **overrides},
                            output=output or self.output)

    @staticmethod
    def successful_worker(args, **kwargs):
        write_test_pcm(Path(args[args.index("--output") + 1]))
        return SimpleNamespace(pid=991234, wait=mock.Mock(return_value=0))

    def assert_no_delivery_cache_or_lock(self):
        self.assertFalse(self.output.exists())
        self.assertEqual(list(self.cache.iterdir()) if self.cache.exists() else [], [])

    def produce_cached(self):
        with mock.patch.object(tts.subprocess, "Popen", side_effect=self.successful_worker) as spawn:
            result = self.generate()
        self.assertEqual(spawn.call_count, 1)
        self.assertFalse(result["reused"])
        return result

    def test_second_request_reuses_identical_verified_pcm_without_spawning(self):
        first = self.produce_cached()
        second_output = self.root / "again.wav"
        with mock.patch.object(tts.subprocess, "Popen", side_effect=AssertionError("cache hit spawned worker")):
            second = self.generate(output=second_output)
        self.assertTrue(second["reused"])
        self.assertEqual(first["key"], second["key"])
        self.assertEqual(first["sha256"], second["sha256"])
        self.assertEqual(self.output.read_bytes(), second_output.read_bytes())
        self.assertEqual((second["samples"], second["sample_rate"]), (6615, 22050))
        self.assertFalse(list(self.cache.glob("*.lock")))

    def test_source_change_requires_identity_refresh_then_generates_new_cache_entry(self):
        first = self.produce_cached()
        changed = self.source_files[0]
        changed.write_text("changed dependency fixture", encoding="utf-8")
        changed_output = self.root / "changed.wav"
        with mock.patch.object(tts.subprocess, "Popen", side_effect=AssertionError("unverified source spawned worker")):
            with self.assertRaisesRegex(ValueError, "身份校验失败"):
                self.generate(output=changed_output)
        self.assertFalse(changed_output.exists())
        self.write_manifest()
        with mock.patch.object(tts.subprocess, "Popen", side_effect=self.successful_worker):
            second = self.generate(output=changed_output)
        self.assertFalse(second["reused"])
        self.assertNotEqual(first["key"], second["key"])
        self.assertTrue((self.cache / first["key"] / "voice.wav").is_file())

    def test_installed_dependency_drift_rejects_even_an_existing_valid_cache(self):
        first = self.produce_cached()
        original_pcm = (self.cache / first["key"] / "voice.wav").read_bytes()
        self.live_freeze = "fixture-engine==1.1\nfixture-torch==2.2.2\n"
        target = self.root / "drift.wav"
        with mock.patch.object(tts.subprocess, "Popen", side_effect=AssertionError("dependency drift spawned worker")):
            with self.assertRaisesRegex(ValueError, "实际安装的依赖"):
                self.generate(output=target)
        self.assertFalse(target.exists())
        self.assertFalse(list(self.cache.glob("*.lock")))
        self.assertEqual((self.cache / first["key"] / "voice.wav").read_bytes(), original_pcm)

    def test_corrupt_weights_and_wrong_revision_fail_before_worker_or_cache_creation(self):
        for kind in ("weight", "revision"):
            with self.subTest(kind=kind):
                original_weight = self.weight.read_bytes()
                original_manifest = (self.runtime / "identity.txt").read_bytes()
                if kind == "weight":
                    self.weight.write_bytes(b"tampered model")
                else:
                    manifest = self.runtime / "identity.txt"
                    manifest.write_text(manifest.read_text().replace(tts.MODEL_REVISION, "unapproved-model"))
                try:
                    with mock.patch.object(tts.subprocess, "Popen", side_effect=AssertionError("unverified model spawned worker")):
                        with self.assertRaises(ValueError):
                            self.generate()
                    self.assert_no_delivery_cache_or_lock()
                finally:
                    self.weight.write_bytes(original_weight)
                    (self.runtime / "identity.txt").write_bytes(original_manifest)

    def test_valid_pcm_tampering_and_receipt_tampering_are_rejected_without_regeneration(self):
        first = self.produce_cached()
        entry = self.cache / first["key"]
        wav, source = entry / "voice.wav", entry / "source.md"
        original_wav, original_receipt = wav.read_bytes(), source.read_bytes()
        for kind in ("pcm", "receipt"):
            with self.subTest(kind=kind):
                wav.write_bytes(original_wav)
                source.write_bytes(original_receipt)
                if kind == "pcm":
                    write_test_pcm(wav, amplitude=2400)
                else:
                    source.write_text(source.read_text() + "forged confirmation\n")
                target = self.root / (kind + ".wav")
                with mock.patch.object(tts.subprocess, "Popen", side_effect=AssertionError("corrupt cache silently regenerated")):
                    with self.assertRaisesRegex(ValueError, "缓存原件或身份不符"):
                        self.generate(output=target)
                self.assertFalse(target.exists())
                self.assertFalse(list(self.cache.glob("*.lock")))
                self.assertTrue(entry.is_dir())

    def test_existing_delivery_is_not_overwritten(self):
        self.output.parent.mkdir(parents=True)
        self.output.write_bytes(b"original delivery")
        with mock.patch.object(tts.subprocess, "Popen", side_effect=AssertionError("existing output spawned worker")):
            with self.assertRaisesRegex(ValueError, "输出已存在"):
                self.generate()
        self.assertEqual(self.output.read_bytes(), b"original delivery")

    def test_failed_delivery_copy_leaves_no_partial_output_and_cache_can_be_reused(self):
        first = self.produce_cached()
        target = self.root / "copy-failed.wav"

        def partial_copy(source, destination, *args, **kwargs):
            destination.write(source.read(12))
            raise OSError("synthetic destination write failure")

        with mock.patch.object(tts.shutil, "copyfileobj", side_effect=partial_copy), \
                mock.patch.object(tts.subprocess, "Popen", side_effect=AssertionError("cache hit spawned worker")):
            with self.assertRaisesRegex(OSError, "destination write failure"):
                self.generate(output=target)
        self.assertFalse(target.exists())
        self.assertFalse(list(target.parent.glob(".voice-*")))
        self.assertFalse(list(self.cache.glob("*.lock")))
        self.assertEqual(tts.inspect_wave(self.cache / first["key"] / "voice.wav"), (6615, 22050))
        with mock.patch.object(tts.subprocess, "Popen", side_effect=AssertionError("valid cache was lost")):
            retried = self.generate(output=target)
        self.assertTrue(retried["reused"])
        self.assertEqual(retried["sha256"], first["sha256"])

    def test_delivery_created_concurrently_is_preserved_and_publication_staging_is_removed(self):
        self.produce_cached()
        target = self.root / "concurrent-delivery.wav"
        original_link = tts.os.link

        def racing_link(source, destination):
            Path(destination).write_bytes(b"another caller completed this destination")
            original_link(source, destination)

        with mock.patch.object(tts.os, "link", side_effect=racing_link):
            with self.assertRaises(FileExistsError):
                self.generate(output=target)
        self.assertEqual(target.read_bytes(), b"another caller completed this destination")
        self.assertFalse(list(target.parent.glob(".voice-*")))
        self.assertFalse(list(self.cache.glob("*.lock")))

    def test_concurrent_identical_request_is_rejected_and_original_finishes_once(self):
        entered, release = threading.Event(), threading.Event()

        def spawn(args, **kwargs):
            process = self.successful_worker(args, **kwargs)

            def wait(timeout):
                entered.set()
                if not release.wait(5):
                    raise AssertionError("test did not release the original worker")
                return 0

            process.wait = wait
            return process

        second_output = self.root / "concurrent.wav"
        with mock.patch.object(tts.subprocess, "Popen", side_effect=spawn) as worker:
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                original = pool.submit(self.generate)
                try:
                    self.assertTrue(entered.wait(5), "original worker did not start")
                    with self.assertRaisesRegex(ValueError, "正在生成"):
                        self.generate(output=second_output)
                    self.assertFalse(second_output.exists())
                    self.assertEqual(worker.call_count, 1)
                finally:
                    release.set()
                result = original.result(timeout=5)
        self.assertFalse(result["reused"])
        self.assertTrue(self.output.is_file())
        self.assertFalse(list(self.cache.glob("*.lock")))

    def test_timeout_cleans_partial_pcm_staging_and_lock_and_terminates_process_group(self):
        for escalate in (False, True):
            with self.subTest(escalate=escalate):
                process = SimpleNamespace(pid=991235)
                waits = [subprocess.TimeoutExpired("test worker", 600)]
                if escalate:
                    waits.append(subprocess.TimeoutExpired("test worker", 5))
                waits.append(0)
                process.wait = mock.Mock(side_effect=waits)

                def spawn(args, **kwargs):
                    write_test_pcm(Path(args[args.index("--output") + 1]))
                    return process

                with mock.patch.object(tts.subprocess, "Popen", side_effect=spawn), \
                        mock.patch.object(tts.os, "killpg") as kill:
                    with self.assertRaisesRegex(ValueError, "超时"):
                        self.generate()
                expected = [mock.call(process.pid, signal.SIGTERM)]
                if escalate:
                    expected.append(mock.call(process.pid, signal.SIGKILL))
                self.assertEqual(kill.call_args_list, expected)
                self.assert_no_delivery_cache_or_lock()

    def test_failed_or_invalid_worker_never_promotes_partial_artifacts(self):
        for kind in ("nonzero", "missing", "truncated", "silent", "not_wave", "spawn_error"):
            with self.subTest(kind=kind):
                def spawn(args, **kwargs):
                    path = Path(args[args.index("--output") + 1])
                    if kind == "spawn_error":
                        raise OSError("test worker unavailable")
                    if kind != "missing":
                        write_test_pcm(path, amplitude=0 if kind == "silent" else 1200)
                    if kind == "truncated":
                        path.write_bytes(path.read_bytes()[:-2])
                    elif kind == "not_wave":
                        path.write_bytes(b"not RIFF PCM")
                    if kind == "nonzero":
                        kwargs["stdout"].write(b"test worker failed before completion")
                        kwargs["stdout"].flush()
                    return SimpleNamespace(pid=991236,
                                           wait=mock.Mock(return_value=1 if kind == "nonzero" else 0))

                with mock.patch.object(tts.subprocess, "Popen", side_effect=spawn):
                    with self.assertRaises((ValueError, OSError, wave.Error, EOFError)):
                        self.generate()
                self.assert_no_delivery_cache_or_lock()


if __name__ == "__main__":
    unittest.main()
