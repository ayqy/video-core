"""Parameter, identity, process and cache rules, using synthetic PCM only.

Fake runners here neither load nor evaluate a speech model. Passing these tests
does not prove narration correctness, voice appeal, emotion or listening review.
"""
from __future__ import annotations

from contextlib import ExitStack
import importlib.util
import hashlib
import json
import os
from pathlib import Path
import signal
import struct
import subprocess
import sys
import tempfile
import textwrap
import time
from types import SimpleNamespace
import unittest
from unittest import mock
import wave


SPEC = importlib.util.spec_from_file_location("voice_design_tts_under_test", Path(__file__).resolve().parents[1] / "voice_design_tts.py")
tts = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(tts)
TEXT = "四个邻居想修路。凑够三枚硬币，就能开工。"
ORIGINAL_DESIGNS = ("adult-warm-low", "adult-bright-confident", "adult-soft-playful")
TAIWAN_DESIGN = "adult-taiwan-warm-narrative-v1"
FULL_TEXT = ("四个邻居想修路。凑够三枚硬币，就能开工。别人已经出了三枚，小陈把自己那枚收了回去。"
             "路修好了，他照样走，钱也省下了。把时间倒回去。小周也收回硬币，只剩两枚，路修不成。"
             "这时，小陈补上一枚，路就能修好。路修好了，没出钱的人也能走。有人就想等别人掏钱，这就是搭便车。")
ENGINE_ID = dict(engine=tts.ENGINE, model=tts.MODEL_REVISION,
                 source_wheel=tts.SOURCE_WHEEL_SHA256, runtime_sha256="runtime",
                 adapter_sha256="adapter", source_list_sha256="source-list")


def pcm(path: Path, *, amplitude=1200, frames=7200, rate=24000):
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(rate)
        output.writeframes(b"".join(struct.pack("<h", amplitude if i % 2 else -amplitude) for i in range(frames)))


def job(root: Path, voice=None):
    voice = voice or next(iter(tts.DESIGNS))
    return dict(voice=voice, instruction=tts.DESIGNS[voice]["instruction"], seed=1986, output=root / (voice + ".wav"))


class RequestTests(unittest.TestCase):
    def test_fixed_adult_designs_have_different_full_request_keys(self):
        keys = set()
        for voice in tts.DESIGNS:
            request, key = tts.request_identity(ENGINE_ID, TEXT, voice, tts.DESIGNS[voice]["instruction"], 1986)
            self.assertEqual(request["text"], TEXT)
            self.assertEqual(request["segmentation"], "one-complete-utterance")
            self.assertEqual((request["device"], request["dtype"], request["attention"], request["threads"]), ("cpu", "float32", "eager", 4))
            self.assertEqual(request["speed"], 1.0)
            keys.add(key)
        self.assertEqual(len(keys), 4)

    def test_taiwan_candidate_is_independent_and_preserves_the_three_original_directions(self):
        original_hashes = {
            "adult-warm-low": "9a775d28b8b9be0967542dab4c19a758f9610f5cf50d0a834b1d0d4ee915cb8b",
            "adult-bright-confident": "8a7ac3699e05b48a0fb589665ee3d74247d36662a825a50a21c320fcd8d05e40",
            "adult-soft-playful": "164b69fe9ea0ffd017c5f6129b3cee1a1161bd286bb1c31765e01b35151bf12a",
        }
        self.assertEqual(tuple(tts.DESIGNS), (*ORIGINAL_DESIGNS, TAIWAN_DESIGN))
        for voice, expected in original_hashes.items():
            self.assertEqual(hashlib.sha256(tts.DESIGNS[voice]["instruction"].encode()).hexdigest(), expected)
        direction = tts.DESIGNS[TAIWAN_DESIGN]["instruction"]
        request, key = tts.request_identity(ENGINE_ID, FULL_TEXT, TAIWAN_DESIGN, direction, 1986)
        self.assertEqual(request["voice"], TAIWAN_DESIGN)
        self.assertEqual(request["instruction"], direction)
        self.assertEqual(request["text"], FULL_TEXT)
        self.assertEqual(len(FULL_TEXT), 129)
        self.assertEqual(hashlib.sha256(FULL_TEXT.encode()).hexdigest(), "738a979bcc7f8e1d6630dec646d5b1f2187e59961e6f77af01041a6d52ccc494")
        for voice in ORIGINAL_DESIGNS:
            _, old_key = tts.request_identity(ENGINE_ID, FULL_TEXT, voice, tts.DESIGNS[voice]["instruction"], 1986)
            self.assertNotEqual(key, old_key)
            with self.assertRaises(ValueError):
                tts.validate_request(FULL_TEXT, TAIWAN_DESIGN, tts.DESIGNS[voice]["instruction"], 1986)
        for alias in ("d", "D", "zh-TW-HsiaoChenNeural"):
            with self.assertRaises(ValueError):
                tts.validate_request(FULL_TEXT, alias, direction, 1986)

    def test_unknown_blank_or_mismatched_directions_are_not_ignored(self):
        voice = next(iter(tts.DESIGNS))
        for instruction in ("", " ", "\t", "自定义未知指令", tts.DESIGNS["adult-soft-playful"]["instruction"]):
            with self.subTest(instruction=repr(instruction)):
                with self.assertRaises(ValueError):
                    tts.validate_request(TEXT, voice, instruction, 1986)

    def test_invalid_engine_language_voice_seed_and_text_are_rejected(self):
        base = dict(text=TEXT, voice=next(iter(tts.DESIGNS)), instruction=next(iter(tts.DESIGNS.values()))["instruction"], seed=1986)
        invalid = [("engine", "CosyVoice"), ("language", "Auto"), ("language", "English"),
                   ("voice", "unknown"), ("text", ""), ("text", " "), ("text", "文" * 241),
                   ("text", "甲\n乙"), ("text", "甲<|tag|>乙"), ("seed", True), ("seed", -1), ("seed", 2**31)]
        for field, value in invalid:
            with self.subTest(field=field, value=repr(value)):
                with self.assertRaises(ValueError):
                    tts.validate_request(**{**base, field: value})
        for field, value in (("model", "wrong"), ("source_wheel", "wrong"), ("engine", "wrong")):
            with self.assertRaises(ValueError):
                tts.request_identity({**ENGINE_ID, field: value}, **base)

    def test_authored_text_seed_and_complete_runtime_source_identity_separate_caches(self):
        voice = next(iter(tts.DESIGNS))
        direction = tts.DESIGNS[voice]["instruction"]
        _, original = tts.request_identity(ENGINE_ID, TEXT, voice, direction, 1986)
        keys = {original}
        for field in ("runtime_sha256", "adapter_sha256", "source_list_sha256"):
            _, changed = tts.request_identity({**ENGINE_ID, field: "changed"}, TEXT, voice, direction, 1986)
            self.assertNotIn(changed, keys)
            keys.add(changed)
        for text, seed in ((TEXT + "路修好了。", 1986), (TEXT, 1987)):
            _, changed = tts.request_identity(ENGINE_ID, text, voice, direction, seed)
            self.assertNotIn(changed, keys)
            keys.add(changed)


class RuntimeIdentityTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.runtime = self.root / "runtime"
        self.site = self.runtime / "venv/lib/python3.10/site-packages"
        self.site.mkdir(parents=True)
        self.interpreter = self.runtime / "venv/bin/python"
        self.interpreter.parent.mkdir()
        self.interpreter.write_bytes(b"synthetic interpreter; never executed")
        self.model = self.runtime / "model/config.txt"
        self.model.parent.mkdir()
        self.model.write_bytes(b"synthetic model; never deserialized")
        self.source = self.site / "qwen_tts/__init__.py"
        self.source.parent.mkdir()
        self.source.write_text("# synthetic source identity fixture, not an engine\n")
        self.package_data = self.site / "qwen_tts/assets/model-data.npz"
        self.package_data.parent.mkdir()
        self.package_data.write_bytes(b"synthetic official-wheel data identity fixture")
        self.dependency = self.site / "fixture_dependency.py"
        self.dependency.write_text("# synthetic dependency\n")
        self.source_list = self.root / "source-list.txt"
        self.source_list.write_text(tts.digest(self.source) + "  qwen_tts/__init__.py\n" +
                                    tts.digest(self.package_data) + "  qwen_tts/assets/model-data.npz\n")
        self.environment = dict(root=str(self.site), freeze=sorted(tts.DIRECT_DEPENDENCIES.items()), python="fixture-python", platform="fixture-cpu")
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        self.stack.enter_context(mock.patch.object(tts, "MODEL_FILES", {"config.txt": (self.model.stat().st_size, tts.digest(self.model))}))
        self.stack.enter_context(mock.patch.object(tts, "SOURCE_MANIFEST", self.source_list))
        self.stack.enter_context(mock.patch.object(tts, "SOURCE_MANIFEST_SHA256", tts.digest(self.source_list)))
        self.stack.enter_context(mock.patch.object(tts.subprocess, "run", side_effect=lambda *a, **kw: SimpleNamespace(stdout=json.dumps(self.environment))))

    def test_explicit_seal_binds_complete_source_dependencies_and_interpreter(self):
        tts.seal_runtime(self.runtime)
        original = tts.identity(self.runtime)
        self.assertEqual(original["engine"], tts.ENGINE)
        with self.assertRaisesRegex(ValueError, "已存在"):
            tts.seal_runtime(self.runtime)
        original_dependency = self.dependency.read_bytes()
        for kind in ("dependency", "interpreter", "installed_version"):
            with self.subTest(kind=kind):
                if kind == "dependency":
                    self.dependency.write_text("# changed after seal")
                elif kind == "interpreter":
                    self.interpreter.write_bytes(b"changed interpreter")
                else:
                    self.environment["freeze"] = [(k, "999" if k == "torch" else v) for k, v in self.environment["freeze"]]
                with self.assertRaises(ValueError):
                    tts.identity(self.runtime)
                self.dependency.write_bytes(original_dependency)
                self.interpreter.write_bytes(b"synthetic interpreter; never executed")
                self.environment["freeze"] = sorted(tts.DIRECT_DEPENDENCIES.items())
        self.assertEqual(tts.identity(self.runtime), original)

    def test_wrong_official_source_model_or_source_list_is_rejected_before_sealing(self):
        for target in (self.source, self.package_data, self.model, self.source_list):
            with self.subTest(target=target.name):
                original = target.read_bytes()
                target.write_bytes(original + b"changed")
                with self.assertRaises(ValueError):
                    tts.seal_runtime(self.runtime)
                self.assertFalse((self.runtime / "identity.txt").exists())
                target.write_bytes(original)

    def test_extra_model_source_or_dependency_symlink_is_not_accepted(self):
        extras = [(self.runtime / "model/extra.txt", "model"), (self.site / "qwen_tts/unlisted.py", "source"),
                  (self.site / "qwen_tts/__init__.so", "source-shadow")]
        for extra, kind in extras:
            with self.subTest(kind=kind):
                extra.write_bytes(b"unlisted")
                with self.assertRaises(ValueError):
                    tts.seal_runtime(self.runtime)
                extra.unlink()
        link = self.site / "linked-dependency.py"
        link.symlink_to(self.dependency)
        with self.assertRaisesRegex(ValueError, "符号链接"):
            tts.seal_runtime(self.runtime)


class GenerationRulesTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.runtime = self.root / "runtime"
        self.runtime.mkdir()
        self.cache = self.root / "cache"
        self.jobs = [job(self.root / "delivery", voice) for voice in ORIGINAL_DESIGNS]
        patch = mock.patch.object(tts, "identity", return_value=ENGINE_ID)
        patch.start()
        self.addCleanup(patch.stop)

    @staticmethod
    def fake_runner(runtime, text, jobs, deadline, log):
        log.write_text("synthetic runner; no real speech model\n")
        for item in jobs:
            pcm(item["output"])

    def generate(self, jobs=None):
        return tts.generate_batch(self.runtime, self.cache, TEXT, jobs or self.jobs, deadline=600)

    def test_three_designs_use_one_worker_and_verified_second_batch_reuses_exact_audio(self):
        with mock.patch.object(tts, "run_worker", side_effect=self.fake_runner) as runner:
            first = self.generate()
        self.assertEqual(runner.call_count, 1)
        self.assertEqual(runner.call_args.args[1], TEXT)
        self.assertEqual(len(runner.call_args.args[2]), 3)
        self.assertTrue(all(not item["reused"] and not item["listening_confirmed"] for item in first))
        repeated = [{**item, "output": self.root / "again" / item["output"].name} for item in self.jobs]
        with mock.patch.object(tts, "run_worker", side_effect=AssertionError("cache hit started a model")):
            second = self.generate(repeated)
        self.assertTrue(all(item["reused"] for item in second))
        self.assertEqual([x["sha256"] for x in first], [x["sha256"] for x in second])
        self.assertFalse((self.runtime / "inference.lock").exists())
        self.assertFalse(list(self.cache.glob("*.lock")))

    def test_taiwan_full_utterance_uses_one_worker_and_reuses_only_its_exact_pending_audio(self):
        selected = [job(self.root / "taiwan", TAIWAN_DESIGN)]
        with mock.patch.object(tts, "run_worker", side_effect=self.fake_runner) as runner:
            first = tts.generate_batch(self.runtime, self.cache, FULL_TEXT, selected, deadline=750)
        runner.assert_called_once()
        self.assertEqual(runner.call_args.args[1], FULL_TEXT)
        self.assertEqual(runner.call_args.args[3], 750)
        submitted = runner.call_args.args[2]
        self.assertEqual(len(submitted), 1)
        self.assertEqual(submitted[0]["voice"], TAIWAN_DESIGN)
        self.assertEqual(submitted[0]["instruction"], tts.DESIGNS[TAIWAN_DESIGN]["instruction"])
        self.assertFalse(first[0]["reused"] or first[0]["listening_confirmed"])
        source = (self.cache / first[0]["key"] / "source.md").read_text()
        self.assertIn("|text|" + FULL_TEXT + "|", source)
        self.assertIn("|voice|" + TAIWAN_DESIGN + "|", source)
        repeated = [{**selected[0], "output": self.root / "again/taiwan.wav"}]
        with mock.patch.object(tts, "run_worker", side_effect=AssertionError("cache hit started a model")):
            second = tts.generate_batch(self.runtime, self.cache, FULL_TEXT, repeated, deadline=750)
        self.assertEqual(first[0]["key"], second[0]["key"])
        self.assertEqual(first[0]["sha256"], second[0]["sha256"])
        self.assertTrue(second[0]["reused"])
        self.assertFalse(second[0]["listening_confirmed"])

    def test_cache_tampering_is_rejected_without_new_generation_or_overwriting(self):
        with mock.patch.object(tts, "run_worker", side_effect=self.fake_runner):
            first = self.generate()
        entry = self.cache / first[0]["key"]
        original = (entry / "voice.wav").read_bytes()
        pcm(entry / "voice.wav", amplitude=2400)
        targets = [{**item, "output": self.root / "tampered" / item["output"].name} for item in self.jobs]
        with mock.patch.object(tts, "run_worker", side_effect=AssertionError("bad cache regenerated")):
            with self.assertRaisesRegex(ValueError, "缓存原音或生成身份不符"):
                self.generate(targets)
        self.assertFalse(targets[0]["output"].exists())
        (entry / "voice.wav").write_bytes(original)
        (entry / "source.md").write_text("forged listening approval")
        with self.assertRaisesRegex(ValueError, "缓存原音或生成身份不符"):
            self.generate(targets)

    def test_invalid_batch_and_existing_outputs_never_start_worker(self):
        invalid = [[self.jobs[0], self.jobs[0]], [{**self.jobs[0], "unknown": 1}],
                   [{**self.jobs[0], "instruction": " "}]]
        self.jobs[0]["output"].parent.mkdir()
        self.jobs[0]["output"].write_bytes(b"existing user audio")
        invalid.append(self.jobs)
        with mock.patch.object(tts, "run_worker", side_effect=AssertionError("invalid request started a model")):
            for jobs in invalid:
                with self.subTest(jobs=repr(jobs)):
                    with self.assertRaises(ValueError):
                        self.generate(jobs)
        self.assertEqual(self.jobs[0]["output"].read_bytes(), b"existing user audio")

    def test_engine_lock_rejects_different_voice_concurrent_model_load(self):
        (self.runtime / "inference.lock").mkdir()
        with mock.patch.object(tts, "run_worker", side_effect=AssertionError("second model loaded")):
            with self.assertRaisesRegex(ValueError, "正在生成"):
                self.generate()
        self.assertTrue((self.runtime / "inference.lock").is_dir())

    def test_failed_batch_preserves_returned_originals_without_success_cache_or_delivery(self):
        def fails(runtime, text, jobs, deadline, log):
            pcm(jobs[0]["output"])
            log.write_text("synthetic second voice failure")
            raise ValueError("synthetic second voice failure")
        with mock.patch.object(tts, "run_worker", side_effect=fails):
            with self.assertRaisesRegex(ValueError, "second voice failure"):
                self.generate()
        self.assertTrue(all(not item["output"].exists() for item in self.jobs))
        failures = list(self.cache.glob("failed-batch-*"))
        self.assertEqual(len(failures), 1)
        self.assertEqual(tts.inspect_wave(failures[0] / "0/voice.wav"), (7200, 24000))
        self.assertFalse(any(len(p.name) == 64 for p in self.cache.iterdir()))
        self.assertFalse((self.runtime / "inference.lock").exists())
        self.assertFalse(list(self.cache.glob("*.lock")))

    def test_invalid_audio_and_environment_change_cannot_promote_success(self):
        def silent(runtime, text, jobs, deadline, log):
            for item in jobs:
                pcm(item["output"], amplitude=0)
            log.write_text("synthetic silence")
        with mock.patch.object(tts, "run_worker", side_effect=silent):
            with self.assertRaisesRegex(ValueError, "静音"):
                self.generate()
        with mock.patch.object(tts, "identity", side_effect=[ENGINE_ID, {**ENGINE_ID, "runtime_sha256": "changed"}]), \
                mock.patch.object(tts, "run_worker", side_effect=self.fake_runner):
            with self.assertRaisesRegex(ValueError, "生成期间"):
                self.generate()
        self.assertFalse(any(len(p.name) == 64 for p in self.cache.iterdir()))

    def test_timeout_terminates_only_owned_group_and_preserves_log(self):
        jobs = [{**self.jobs[0], "output": self.root / "partial.wav"}]
        process = SimpleNamespace(pid=991001, wait=mock.Mock(side_effect=[subprocess.TimeoutExpired("fixture", 5), 0]))
        log = self.root / "timeout.log"
        with mock.patch.object(tts.subprocess, "Popen", return_value=process), mock.patch.object(tts.os, "killpg") as kill:
            with self.assertRaisesRegex(ValueError, "超时"):
                tts.run_worker(self.runtime, TEXT, jobs, 5, log)
        kill.assert_called_once_with(991001, signal.SIGTERM)
        self.assertTrue(log.is_file())

    def test_sigterm_during_worker_creation_is_deferred_and_nonmain_calls_never_spawn(self):
        selected = [self.jobs[0]]
        previous = signal.getsignal(signal.SIGTERM)
        process = SimpleNamespace(pid=991075, wait=mock.Mock(return_value=0))

        def create(*args, **options):
            # Simulate TERM after a child exists but before Popen returns it.
            signal.getsignal(signal.SIGTERM)(signal.SIGTERM, None)
            return process

        with mock.patch.object(tts.subprocess, "Popen", side_effect=create), mock.patch.object(tts.os, "killpg") as kill:
            with self.assertRaises(tts.WorkerCancelled):
                tts.run_worker(self.runtime, TEXT, selected, 5, self.root / "creation-cancel.log")
        kill.assert_called_once_with(991075, signal.SIGTERM)
        process.wait.assert_called_once_with(timeout=5)
        self.assertIs(signal.getsignal(signal.SIGTERM), previous)
        with mock.patch.object(tts.threading, "current_thread", return_value=object()), \
                mock.patch.object(tts.subprocess, "Popen", side_effect=AssertionError("nonmain call spawned a worker")) as spawning:
            with self.assertRaisesRegex(ValueError, "主线程"):
                tts.run_worker(self.runtime, TEXT, selected, 5, self.root / "thread.log")
        spawning.assert_not_called()
        self.assertFalse((self.root / "thread.log").exists())

    def test_atomic_copy_failure_and_concurrent_destination_do_not_destroy_other_audio(self):
        source = self.root / "source.wav"
        pcm(source)
        target = self.root / "target.wav"
        def fail(source_stream, output):
            output.write(source_stream.read(8))
            raise OSError("synthetic copy failure")
        with mock.patch.object(tts.shutil, "copyfileobj", side_effect=fail):
            with self.assertRaises(OSError):
                tts.atomic_copy(source, target)
        self.assertFalse(target.exists())
        target.write_bytes(b"other caller audio")
        with self.assertRaises(FileExistsError):
            tts.atomic_copy(source, target)
        self.assertEqual(target.read_bytes(), b"other caller audio")
        self.assertFalse(list(self.root.glob(".voice-*")))


class WorkerCallContractTests(unittest.TestCase):
    def test_one_model_load_then_whole_original_text_per_design_with_distinct_instructions(self):
        self.check_worker_contract(ORIGINAL_DESIGNS, TEXT)

    def test_taiwan_candidate_sends_one_complete_original_and_native_design_instruction(self):
        self.check_worker_contract((TAIWAN_DESIGN,), FULL_TEXT)

    def check_worker_contract(self, voices, text):
        # Finite API fixture only; asserts calls, not genuine voice or quality.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            jobs = [job(root, voice) for voice in voices]
            audio = type("SyntheticAudio", (), {"ndim": 1, "__len__": lambda self: 7200})()
            engine = SimpleNamespace(model=SimpleNamespace(tts_model_type="voice_design"),
                                     get_supported_languages=mock.Mock(return_value=["chinese"]),
                                     generate_voice_design=mock.Mock(return_value=([audio], 24000)))
            factory = mock.Mock(return_value=engine)
            numpy = SimpleNamespace(random=SimpleNamespace(seed=mock.Mock()),
                                    isfinite=mock.Mock(return_value=SimpleNamespace(all=lambda: True)),
                                    abs=mock.Mock(return_value="fixture-abs"), max=mock.Mock(return_value=0.1))
            torch = SimpleNamespace(set_num_threads=mock.Mock(), set_num_interop_threads=mock.Mock(),
                                    manual_seed=mock.Mock(), float32="float32")
            soundfile = SimpleNamespace(write=mock.Mock(side_effect=lambda path, *a, **kw: pcm(Path(path))))
            with mock.patch.object(tts, "identity", return_value=ENGINE_ID), \
                    mock.patch.dict(sys.modules, {"numpy": numpy, "torch": torch, "soundfile": soundfile,
                                               "qwen_tts": SimpleNamespace(Qwen3TTSModel=SimpleNamespace(from_pretrained=factory))}), \
                    mock.patch("socket.create_connection"), mock.patch("socket.socket.connect"), mock.patch("socket.socket.connect_ex"):
                tts.worker(root, text, jobs)
            factory.assert_called_once_with(str(root / "model"), device_map="cpu", dtype="float32", attn_implementation="eager", local_files_only=True)
            self.assertEqual(engine.generate_voice_design.call_count, len(jobs))
            for call, item in zip(engine.generate_voice_design.call_args_list, jobs):
                self.assertEqual(call.kwargs, dict(text=text, language="Chinese", instruct=item["instruction"], **tts.GENERATION))
            torch.set_num_threads.assert_called_once_with(4)
            self.assertEqual(torch.manual_seed.call_args_list, [mock.call(1986)] * len(jobs))
            self.assertEqual(soundfile.write.call_count, len(jobs))

    def test_pcm_validation_rejects_truncation_wrong_rate_duration_silence_and_clipping(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "voice.wav"
            for options in (dict(rate=22050), dict(frames=4799), dict(frames=90 * 24000 + 1), dict(amplitude=0), dict(amplitude=32767)):
                pcm(target, **options)
                with self.assertRaises(ValueError):
                    tts.inspect_wave(target)
            pcm(target)
            target.write_bytes(target.read_bytes()[:-2])
            with self.assertRaisesRegex(ValueError, "不完整"):
                tts.inspect_wave(target)


class OwnedWorkerSignalTests(unittest.TestCase):
    def test_parent_sigterm_reaps_real_owned_worker_while_bystander_survives(self):
        # Finite process integration only. The fake worker never imports a model,
        # reads credentials, contacts a network or writes a speech waveform.
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
                print('finite owned-worker fixture; no speech',flush=True)
                end=time.monotonic()+20
                while time.monotonic()<end: time.sleep(0.02)
                """), encoding="utf-8")
            parent_script = root / "parent-fixture.py"
            parent_script.write_text(textwrap.dedent("""
                import importlib.util,os,signal,sys
                from pathlib import Path
                source=Path(sys.argv[1]);root=Path(sys.argv[2])
                spec=importlib.util.spec_from_file_location('finite_adapter',source)
                tts=importlib.util.module_from_spec(spec);spec.loader.exec_module(tts)
                tts.__file__=str(root/'worker-fixture.py')
                def previous(signum,frame): pass
                signal.signal(signal.SIGTERM,previous)
                original=tts.subprocess.Popen;children=[]
                def tracked(*args,**options):
                    child=original(*args,**options);children.append(child);return child
                tts.subprocess.Popen=tracked
                try:
                    tts.run_worker(root,'finite process fixture',[],10,root/'worker.log')
                except tts.WorkerCancelled:
                    child=children[0];reaped=False
                    try: os.waitpid(child.pid,os.WNOHANG)
                    except ChildProcessError: reaped=True
                    (root/'result.txt').write_text('cancelled=1\\nreaped='+str(int(reaped))+
                        '\\nhandler_restored='+str(int(signal.getsignal(signal.SIGTERM) is previous))+
                        '\\nreturncode='+str(child.returncode)+'\\n')
                    raise SystemExit(2)
                raise SystemExit(3)
                """), encoding="utf-8")
            adapter = Path(tts.__file__).resolve()
            side = subprocess.Popen([sys.executable, "-I", "-B", "-c", "import time;time.sleep(20)"],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
            parent = None
            reaped = False
            worker_id = None
            with (root / "parent.log").open("xb") as parent_log:
                try:
                    parent = subprocess.Popen([sys.executable, "-I", "-B", str(parent_script), str(adapter), str(runtime)],
                                              stdout=parent_log, stderr=parent_log, start_new_session=True)

                    def ready(path, seconds):
                        end = time.monotonic() + seconds
                        while time.monotonic() < end:
                            if path.is_file():
                                return
                            if parent.poll() is not None:
                                self.fail("finite parent exited before its expected process checkpoint")
                            time.sleep(0.02)
                        self.fail("finite process checkpoint timed out")

                    ready(runtime / "worker-ready", 5)
                    worker_id, group = map(int, (runtime / "worker-ready").read_text().splitlines())
                    self.assertEqual(worker_id, group)
                    self.assertNotIn(group, (os.getpgrp(), parent.pid, side.pid))
                    parent.send_signal(signal.SIGTERM)
                    ready(runtime / "term-seen", 2)
                    # The worker deliberately ignores TERM, so this second parent
                    # TERM arrives during the adapter's bounded reaping phase.
                    parent.send_signal(signal.SIGTERM)
                    self.assertEqual(parent.wait(timeout=12), 2)
                    result = dict(row.split("=", 1) for row in (runtime / "result.txt").read_text().splitlines())
                    reaped = result.get("reaped") == "1"
                    self.assertEqual(result, {"cancelled": "1", "reaped": "1", "handler_restored": "1", "returncode": str(-signal.SIGKILL)})
                    self.assertIsNone(side.poll(), "the unrelated owned fixture was terminated")
                    with self.assertRaises(ProcessLookupError):
                        os.killpg(group, 0)
                    self.assertIn("finite owned-worker fixture; no speech", (runtime / "worker.log").read_text())
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
