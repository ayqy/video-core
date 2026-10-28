"""Cache, PCM and process-boundary rules; these tests do not assess TTS quality.

Every waveform below is synthetic test PCM. The mocked worker never loads or
evaluates a speech model, and its result is not listening-acceptance evidence.
"""
from __future__ import annotations

import concurrent.futures
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import random
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import textwrap
import threading
import time
from types import ModuleType, SimpleNamespace
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
                            instruction="", seed=1986)

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
                   ("text", "小明出了十元，桥还没修好。"), ("voice", "中文男"), ("seed", 1987)]
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
                   ("voice", "外部克隆音色"), ("instruction", "自然讲述"),
                   ("instruction", "语" * 161), ("instruction", "自然\r讲述"),
                   ("instruction", "<|endofprompt|>"),
                   ("seed", -1), ("seed", 2**31)]
        for field, value in changes:
            with self.subTest(field=field, value=repr(value)):
                request = {**self.request, field: value}
                with self.assertRaises(ValueError):
                    tts.request_identity(self.engine, **request)

    def test_cache_identity_declares_sft_mode_and_separates_rejected_instruct_cache(self):
        request, key = tts.request_identity(self.engine, **self.request)
        self.assertEqual(request["mode"], "sft-text-only")
        self.assertEqual(request["text"], self.request["text"])
        self.assertFalse(request.get("instruction"))
        self.assertNotIn("instruction_boundary", request)
        for marker in ("<endofprompt>", "<|endofprompt|>"):
            self.assertNotIn(marker, request["text"])
        for boundary in (None, "CosyVoice-300M-legacy-<endofprompt>",
                         "CosyVoice-300M-current-upstream-v3"):
            historical = {**request, "engine": "FunAudioLLM/CosyVoice-300M-Instruct",
                          "model": "706bee1915e9fd1f1214929e2a0509c874cff433",
                          "instruction": "请用好奇、活泼的语气说话。"}
            historical.pop("mode")
            if boundary is not None:
                historical["instruction_boundary"] = boundary
            old_key = hashlib.sha256(json.dumps(historical, ensure_ascii=False,
                                                sort_keys=True, separators=(",", ":")).encode()).hexdigest()
            self.assertNotEqual(key, old_key)
        overridden, _ = tts.request_identity({**self.engine, "mode": "instruct"}, **self.request)
        self.assertEqual(overridden["mode"], "sft-text-only")


class SFTContractTests(unittest.TestCase):
    def test_nonempty_directions_are_rejected_rather_than_ignored_or_spoken(self):
        tts.validate_request("四个邻居想修路。", "中文女", "", 1986)
        for instruction in ("请用好奇、活泼的语气说话。", "A happy girl with high tone.", " ", "\t"):
            with self.subTest(instruction=repr(instruction)):
                with self.assertRaises(ValueError):
                    tts.validate_request("四个邻居想修路。", "中文女", instruction, 1986)

    def test_caller_cannot_supply_either_generation_of_control_marker(self):
        for instruction in ("自然讲述<endofprompt>", "自然讲述<|endofprompt|>",
                            "<endofprompt>", "<|endofprompt|>", "自然\n讲述", "自然\x00讲述"):
            with self.subTest(instruction=repr(instruction)):
                with self.assertRaises(ValueError):
                    tts.validate_request("四个邻居想修路。", "中文女", instruction, 1986)
                with self.assertRaises(ValueError):
                    tts.validate_request("四个邻居想修路。" + instruction, "中文女", "", 1986)

    def test_worker_calls_sft_with_original_narration_and_never_calls_instruct(self):
        # This isolates the actual adapter-to-engine call without installing or
        # pretending to evaluate a model. It catches accidental concatenation of
        # the direction into the narration, which file/PCM tests cannot detect.
        waveform = mock.MagicMock(name="synthetic-waveform")
        waveform.__len__.return_value = 6615
        waveform.reshape.return_value = waveform
        tensor = mock.MagicMock(name="synthetic-engine-output")
        tensor.detach.return_value.cpu.return_value.numpy.return_value = waveform
        engine = mock.Mock(sample_rate=22050)
        engine.list_available_spks.return_value = ["中文女", "中文男"]
        engine.inference_sft.return_value = [{"tts_speech": tensor}]
        factory = mock.Mock(return_value=engine)
        numpy = SimpleNamespace(random=SimpleNamespace(seed=mock.Mock()),
                                isfinite=mock.Mock(return_value=SimpleNamespace(all=lambda: True)))
        torch = SimpleNamespace(set_num_threads=mock.Mock(), set_num_interop_threads=mock.Mock(),
                                manual_seed=mock.Mock())
        soundfile = SimpleNamespace(write=mock.Mock())
        package, cli, module = ModuleType("cosyvoice"), ModuleType("cosyvoice.cli"), ModuleType("cosyvoice.cli.cosyvoice")
        package.__path__ = []
        cli.__path__ = []
        module.AutoModel = factory
        fake_modules = {"numpy": numpy, "torch": torch, "soundfile": soundfile,
                        "cosyvoice": package, "cosyvoice.cli": cli,
                        "cosyvoice.cli.cosyvoice": module}
        args = SimpleNamespace(runtime=Path(tempfile.gettempdir()) / "synthetic-runtime",
                               output=Path(tempfile.gettempdir()) / "synthetic-output.wav",
                               text="四个邻居想修路。凑够三枚硬币，就能开工。",
                               voice="中文女", instruction="", seed=1986)
        with mock.patch.dict(sys.modules, fake_modules), \
                mock.patch.object(sys, "path", list(sys.path)), \
                mock.patch.object(random, "seed"), \
                mock.patch.object(socket, "create_connection"), \
                mock.patch.object(socket.socket, "connect"), \
                mock.patch.object(socket.socket, "connect_ex"):
            previous_thread_hook = threading.excepthook
            tts.worker(args)
            self.assertIs(threading.excepthook, previous_thread_hook)
        engine.inference_sft.assert_called_once_with(
            args.text, args.voice,
            stream=False, speed=1.0, text_frontend=False)
        engine.inference_instruct.assert_not_called()
        engine.inference_instruct2.assert_not_called()
        soundfile.write.assert_called_once_with(str(args.output), waveform, 22050, subtype="PCM_16")


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
                            instruction="", seed=1986)

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

        def competing_request():
            try:
                self.assertTrue(entered.wait(5), "original worker did not start")
                with self.assertRaisesRegex(ValueError, "正在生成"):
                    self.generate(output=second_output)
                self.assertFalse(second_output.exists())
            finally:
                release.set()

        with mock.patch.object(tts.subprocess, "Popen", side_effect=spawn) as worker:
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                competing = pool.submit(competing_request)
                result = self.generate()
                competing.result(timeout=5)
            self.assertEqual(worker.call_count, 1)
        self.assertFalse(result["reused"])
        self.assertTrue(self.output.is_file())
        self.assertFalse(list(self.cache.glob("*.lock")))

    def test_sigterm_during_worker_creation_defers_until_handle_is_owned_and_restores_handler(self):
        previous = signal.getsignal(signal.SIGTERM)
        process = SimpleNamespace(pid=991238, wait=mock.Mock(return_value=0))

        def spawn(args, **kwargs):
            write_test_pcm(Path(args[args.index("--output") + 1]))
            signal.getsignal(signal.SIGTERM)(signal.SIGTERM, None)
            return process

        with mock.patch.object(tts.subprocess, "Popen", side_effect=spawn), \
                mock.patch.object(tts.os, "killpg") as kill:
            with self.assertRaisesRegex(tts.WorkerCancelled, "取消"):
                self.generate()
        kill.assert_called_once_with(process.pid, signal.SIGTERM)
        process.wait.assert_called_once_with(timeout=5)
        self.assertIs(signal.getsignal(signal.SIGTERM), previous)
        self.assert_no_delivery_cache_or_lock()

    def test_nonmain_cache_miss_never_creates_a_worker_or_changes_signal_handler(self):
        previous = signal.getsignal(signal.SIGTERM)
        with mock.patch.object(tts.subprocess, "Popen", side_effect=AssertionError("nonmain worker spawned")) as spawn:
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                result = pool.submit(self.generate)
                with self.assertRaisesRegex(ValueError, "主线程"):
                    result.result(timeout=5)
        spawn.assert_not_called()
        self.assertIs(signal.getsignal(signal.SIGTERM), previous)
        self.assert_no_delivery_cache_or_lock()

    def test_keyboard_interrupt_reaps_owned_group_even_when_term_repeats_during_cleanup(self):
        previous = signal.getsignal(signal.SIGTERM)
        process = SimpleNamespace(pid=991239, wait=mock.Mock(side_effect=[KeyboardInterrupt(), 0]))

        def repeated_term(pid, number):
            signal.getsignal(signal.SIGTERM)(signal.SIGTERM, None)

        with mock.patch.object(tts.subprocess, "Popen", return_value=process), \
                mock.patch.object(tts.os, "killpg", side_effect=repeated_term) as kill:
            with self.assertRaises(KeyboardInterrupt):
                self.generate()
        kill.assert_called_once_with(process.pid, signal.SIGTERM)
        self.assertEqual(process.wait.call_args_list, [mock.call(timeout=600), mock.call(timeout=5)])
        self.assertIs(signal.getsignal(signal.SIGTERM), previous)
        self.assert_no_delivery_cache_or_lock()

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

    def test_partial_inference_chunk_then_thread_failure_never_writes_or_caches_audio(self):
        # Execute the real worker and parent publication path against a finite
        # engine fixture. Upstream-like background failure happens after a
        # nonempty chunk; a valid WAV must not hide the failed LLM thread.
        waveform = mock.MagicMock(name="partial-synthetic-waveform")
        waveform.__len__.return_value = 6615
        waveform.reshape.return_value = waveform
        tensor = mock.MagicMock(name="partial-engine-output")
        tensor.detach.return_value.cpu.return_value.numpy.return_value = waveform
        engine = mock.Mock(sample_rate=22050)
        engine.list_available_spks.return_value = ["中文女", "中文男"]

        def inference(*args, **kwargs):
            yield {"tts_speech": tensor}

            def fail_after_tokens():
                raise RuntimeError("synthetic LLM failure after partial tokens")

            thread = threading.Thread(target=fail_after_tokens)
            thread.start()
            thread.join(timeout=2)
            self.assertFalse(thread.is_alive())

        engine.inference_sft.side_effect = inference
        numpy = SimpleNamespace(random=SimpleNamespace(seed=mock.Mock()),
                                isfinite=mock.Mock(return_value=SimpleNamespace(all=lambda: True)))
        torch = SimpleNamespace(set_num_threads=mock.Mock(), set_num_interop_threads=mock.Mock(),
                                manual_seed=mock.Mock())
        soundfile = SimpleNamespace(write=mock.Mock(side_effect=lambda path, *a, **kw: write_test_pcm(Path(path))))
        package, cli, module = ModuleType("cosyvoice"), ModuleType("cosyvoice.cli"), ModuleType("cosyvoice.cli.cosyvoice")
        package.__path__ = []
        cli.__path__ = []
        module.AutoModel = mock.Mock(return_value=engine)
        fake_modules = {"numpy": numpy, "torch": torch, "soundfile": soundfile,
                        "cosyvoice": package, "cosyvoice.cli": cli, "cosyvoice.cli.cosyvoice": module}

        def actual_worker(argv, **kwargs):
            get = lambda option: argv[argv.index(option) + 1]
            args = SimpleNamespace(runtime=Path(get("--runtime")), output=Path(get("--output")),
                                   text=get("--text"), voice=get("--voice"),
                                   instruction=get("--instruction"), seed=int(get("--seed")))
            try:
                tts.worker(args)
                code = 0
            except ValueError as error:
                kwargs["stdout"].write(str(error).encode())
                kwargs["stdout"].flush()
                code = 2
            return SimpleNamespace(pid=991237, wait=mock.Mock(return_value=code))

        with mock.patch.dict(sys.modules, fake_modules), \
                mock.patch.object(sys, "path", list(sys.path)), \
                mock.patch.object(random, "seed"), \
                mock.patch.object(socket, "create_connection"), \
                mock.patch.object(socket.socket, "connect"), \
                mock.patch.object(socket.socket, "connect_ex"), \
                mock.patch.object(threading, "excepthook") as original_hook, \
                mock.patch.object(tts.subprocess, "Popen", side_effect=actual_worker):
            with self.assertRaisesRegex(ValueError, "推理线程失败"):
                self.generate()
            self.assertIs(threading.excepthook, original_hook)
        soundfile.write.assert_not_called()
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


class OwnedWorkerSignalTests(unittest.TestCase):
    def test_parent_sigterm_reaps_real_worker_and_leaves_bystander_alive(self):
        self.check_real_cancellation(during_creation=False)

    def test_sigterm_before_popen_returns_reaps_real_worker_and_leaves_bystander_alive(self):
        self.check_real_cancellation(during_creation=True)

    def check_real_cancellation(self, *, during_creation):
        # Real finite processes exercise ownership, reaping and cache cleanup.
        # They never import a speech model, read credentials or create audio.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            runtime = root / "runtime"
            binary = runtime / "venv/bin/python"
            binary.parent.mkdir(parents=True)
            binary.symlink_to(Path(sys.executable).resolve())
            worker = runtime / "worker-fixture.py"
            worker.write_text(textwrap.dedent("""
                import os,signal,sys,time
                from pathlib import Path
                root=Path(sys.argv[sys.argv.index('--runtime')+1])
                def term(signum,frame):
                    (root/'term-seen').write_text('TERM observed by finite worker')
                signal.signal(signal.SIGTERM,term)
                marker=root/'worker-ready.part'
                marker.write_text(str(os.getpid())+'\\n'+str(os.getpgrp()))
                marker.rename(root/'worker-ready')
                end=time.monotonic()+20
                while time.monotonic()<end: time.sleep(0.02)
                """), encoding="utf-8")
            parent_script = root / "parent-fixture.py"
            parent_script.write_text(textwrap.dedent("""
                import importlib.util,os,signal,sys,time
                from pathlib import Path
                source=Path(sys.argv[1]);root=Path(sys.argv[2]);creation=sys.argv[3]=='creation'
                spec=importlib.util.spec_from_file_location('finite_adapter',source)
                tts=importlib.util.module_from_spec(spec);spec.loader.exec_module(tts)
                tts.__file__=str(root/'worker-fixture.py')
                tts.identity=lambda runtime: dict(engine=tts.ENGINE,model=tts.MODEL_REVISION,
                    source=tts.SOURCE_REVISION,runtime_sha256='finite-fixture',adapter_sha256='finite-fixture')
                def previous(signum,frame): pass
                signal.signal(signal.SIGTERM,previous)
                original=tts.subprocess.Popen;children=[]
                def tracked(*args,**options):
                    child=original(*args,**options);children.append(child)
                    if creation:
                        end=time.monotonic()+5
                        while not (root/'worker-ready').is_file():
                            if time.monotonic()>=end or child.poll() is not None:
                                raise AssertionError('finite worker never became ready')
                            time.sleep(0.02)
                        os.kill(os.getpid(),signal.SIGTERM)
                    return child
                tts.subprocess.Popen=tracked
                cache=root/'cache';delivery=root/'delivery.wav'
                try:
                    tts.generate(root,cache,'finite process fixture','中文女','',1986,delivery,10)
                except tts.WorkerCancelled:
                    child=children[0];reaped=False
                    try: os.waitpid(child.pid,os.WNOHANG)
                    except ChildProcessError: reaped=True
                    values=dict(cancelled=1,reaped=int(reaped),
                        handler_restored=int(signal.getsignal(signal.SIGTERM) is previous),
                        returncode=child.returncode,no_delivery=int(not delivery.exists()),
                        no_cache_or_lock=int(not list(cache.iterdir())))
                    (root/'result.txt').write_text('\\n'.join(str(k)+'='+str(v) for k,v in values.items()))
                    raise SystemExit(2)
                raise SystemExit(3)
                """), encoding="utf-8")
            side = subprocess.Popen([sys.executable, "-I", "-B", "-c", "import time;time.sleep(20)"],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
            parent = None
            reaped = False
            worker_id = None
            with (root / "parent.log").open("xb") as parent_log:
                try:
                    parent = subprocess.Popen([sys.executable, "-I", "-B", str(parent_script),
                                               str(ADAPTER_PATH), str(runtime),
                                               "creation" if during_creation else "waiting"],
                                              stdout=parent_log, stderr=parent_log, start_new_session=True)

                    def ready(path, seconds):
                        end = time.monotonic() + seconds
                        while time.monotonic() < end:
                            if path.is_file():
                                return
                            if parent.poll() is not None:
                                self.fail("finite parent exited before its process checkpoint")
                            time.sleep(0.02)
                        self.fail("finite process checkpoint timed out")

                    ready(runtime / "worker-ready", 5)
                    worker_id, group = map(int, (runtime / "worker-ready").read_text().splitlines())
                    self.assertEqual(worker_id, group)
                    self.assertNotIn(group, (os.getpgrp(), parent.pid, side.pid))
                    if not during_creation:
                        parent.send_signal(signal.SIGTERM)
                    ready(runtime / "term-seen", 2)
                    # A repeated parent TERM must not interrupt the bounded
                    # cleanup of a worker deliberately ignoring its first TERM.
                    parent.send_signal(signal.SIGTERM)
                    self.assertEqual(parent.wait(timeout=12), 2)
                    result = dict(row.split("=", 1) for row in (runtime / "result.txt").read_text().splitlines())
                    reaped = result.get("reaped") == "1"
                    self.assertEqual(result, dict(cancelled="1", reaped="1", handler_restored="1",
                        returncode=str(-signal.SIGKILL), no_delivery="1", no_cache_or_lock="1"))
                    self.assertIsNone(side.poll(), "the unrelated finite bystander was terminated")
                    with self.assertRaises(ProcessLookupError):
                        os.killpg(group, 0)
                    self.assertFalse(list(runtime.rglob("*.wav")))
                finally:
                    if worker_id is not None and not reaped:
                        try:
                            os.killpg(worker_id, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                    for owned in (parent, side):
                        if owned is not None:
                            if owned.poll() is None:
                                try:
                                    os.killpg(owned.pid, signal.SIGKILL)
                                except ProcessLookupError:
                                    pass
                            owned.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
