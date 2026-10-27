"""Offline request/cache/failure rules; no cloud call or voice-quality approval.

Batch fixtures isolate transport. The optional local codec test uses a generated
tone solely to exercise full MP3 decoding, never as a narration candidate.
"""
import contextlib
import copy
import importlib.util
import io
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

PATH = Path(__file__).resolve().parents[1] / "readaloud_tts.py"
SPEC = importlib.util.spec_from_file_location("readaloud_under_test", PATH)
tts = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(tts)
TEXT = "四个邻居想修路。凑够三枚硬币，就能开工。"
VOICES = tuple(tts.VOICES)
IDENTITY = dict(client_version=tts.CLIENT_VERSION, wheel_sha256=tts.WHEEL_SHA256,
                adapter_sha256="adapter", dependencies={"edge-tts": {"version": "7.3.1", "payload_sha256": "payload"}},
                ffmpeg={"sha256": "decoder"})
INSPECTION = dict(samples=24000, sample_rate=24000, channels=1, bitrate=48000,
                  decoded_duration=1.0, container_duration=1.008, peak_float=0.5,
                  rms_float=0.2, decoded_samples_at_or_above_one=0)


class RequestRules(unittest.TestCase):
    def test_only_two_exact_taiwanese_female_ids(self):
        for voice in VOICES:
            tts.validate_request(TEXT, voice)
        for voice in ("zh-TW-YunJheNeural", "zh-CN-XiaoxiaoNeural", "林志玲", "clone", ""):
            with self.subTest(voice=voice), self.assertRaises(tts.ReadAloudError):
                tts.validate_request(TEXT, voice)

    def test_complete_single_paragraph_and_size_bound(self):
        tts.validate_request("字" * 240, VOICES[0])
        for text in ("", " ", "字" * 241, TEXT + "\n", TEXT + "\t", TEXT + "\x00", "<speak>正文</speak>"):
            with self.subTest(text=repr(text)), self.assertRaises(tts.ReadAloudError):
                tts.validate_request(text, VOICES[0])

    def test_identity_binds_text_real_voice_dependencies_tools_and_adapter(self):
        request, original = tts.request_identity(IDENTITY, TEXT, VOICES[0])
        self.assertEqual(request["configuration"]["rate"], "+0%")
        self.assertEqual(request["configuration"]["pitch"], "+0Hz")
        self.assertEqual(request["configuration"]["remote_model_revision"], "unknown_not_exposed_by_service")
        self.assertNotEqual(original, tts.request_identity(IDENTITY, TEXT + "路修好了。", VOICES[0])[1])
        self.assertNotEqual(original, tts.request_identity(IDENTITY, TEXT, VOICES[1])[1])
        for field in ("adapter_sha256", "dependencies", "ffmpeg"):
            current = copy.deepcopy(IDENTITY)
            current[field] = "changed"
            self.assertNotEqual(original, tts.request_identity(current, TEXT, VOICES[0])[1])
        with self.assertRaises(tts.ReadAloudError):
            tts.request_identity({**IDENTITY, "client_version": "unapproved"}, TEXT, VOICES[0])

    def test_transport_environment_excludes_credentials_and_netrc(self):
        with patch.dict(os.environ, {"NETRC": "/private/credentials", "AZURE_SPEECH_KEY": "sensitive",
                                     "HF_TOKEN": "sensitive", "PYTHONPATH": "/foreign", "HTTPS_PROXY": "http://routing"}, clear=True):
            online, offline = tts.environment(True), tts.environment(False)
        self.assertEqual(online["NETRC"], os.devnull)
        self.assertEqual(online["HTTPS_PROXY"], "http://routing")
        self.assertNotIn("HTTPS_PROXY", offline)
        for name in ("AZURE_SPEECH_KEY", "HF_TOKEN", "PYTHONPATH"):
            self.assertNotIn(name, online)

    def test_invalid_fixed_wheel_fails_before_dependency_probe(self):
        with tempfile.TemporaryDirectory() as directory:
            runtime = Path(directory)
            (runtime / "wheels").mkdir()
            (runtime / "wheels" / tts.WHEEL_NAME).write_bytes(b"wrong-wheel")
            with patch.object(tts.subprocess, "run") as command, self.assertRaises(tts.ReadAloudError):
                tts.runtime_identity(runtime, Path("ffmpeg"), Path("ffprobe"))
            command.assert_not_called()

    def test_cli_redacts_sdk_exception_url_and_public_token(self):
        secret = "https://service.invalid/?trustedclienttoken=never-print-this"
        args = ["readaloud_tts.py", "--runtime", "/temporary", "--worker", "--allow-network",
                "--text", TEXT, "--voice", VOICES[0], "--output", "/temporary/original.mp3"]
        stderr = io.StringIO()
        with patch.object(sys, "argv", args), patch.object(tts, "worker", side_effect=RuntimeError(secret)), contextlib.redirect_stderr(stderr):
            self.assertEqual(tts.main(), 2)
        self.assertIn("RuntimeError", stderr.getvalue())
        self.assertNotIn("never-print-this", stderr.getvalue())
        self.assertNotIn("https://", stderr.getvalue())


class BatchRules(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.runtime, self.cache = self.root / "runtime", self.root / "cache"
        self.runtime.mkdir()
        self.ffmpeg, self.ffprobe = self.root / "ffmpeg", self.root / "ffprobe"
        self.identity = patch.object(tts, "runtime_identity", return_value=copy.deepcopy(IDENTITY)).start()
        self.inspect = patch.object(tts, "inspect_mp3", return_value=copy.deepcopy(INSPECTION)).start()
        self.addCleanup(patch.stopall)

    def jobs(self, suffix="original"):
        return [dict(voice=v, output=self.root / f"{i}-{suffix}.mp3") for i, v in enumerate(VOICES)]

    def generate(self, jobs=None, **kwargs):
        return tts.generate_batch(self.runtime, self.cache, TEXT, jobs or self.jobs(),
                                  self.ffmpeg, self.ffprobe, **kwargs)

    def produce(self, runtime, text, voice, output, deadline, log):
        self.assertEqual(text, TEXT)
        output.write_bytes(("original:" + voice).encode())
        log.write_text("generated; no URL or credentials\n")

    def test_missing_network_consent_never_submits_or_promotes(self):
        with patch.object(tts, "run_worker") as transport, self.assertRaises(tts.ReadAloudError):
            self.generate()
        transport.assert_not_called()
        self.assertEqual(list(self.cache.iterdir()), [])
        self.assertFalse((self.runtime / "generation.lock").exists())

    def test_preflight_rejects_existing_original_or_source_before_network(self):
        for source_only in (False, True):
            jobs = self.jobs(str(source_only))
            p = jobs[0]["output"].with_suffix(".source.md") if source_only else jobs[0]["output"]
            p.write_bytes(b"existing")
            with patch.object(tts, "run_worker") as transport, self.assertRaises(tts.ReadAloudError):
                self.generate(jobs, allow_network=True)
            transport.assert_not_called()
            self.assertEqual(p.read_bytes(), b"existing")
        self.identity.assert_not_called()

    def test_duplicate_voice_output_and_disguised_format_are_rejected(self):
        jobs = self.jobs()
        variants = [[jobs[0], jobs[0]], [jobs[0], {**jobs[1], "voice": jobs[0]["voice"]}],
                    [jobs[0], {**jobs[1], "output": jobs[0]["output"]}],
                    [{**jobs[0], "output": self.root / "disguised.wav"}]]
        for value in variants:
            with self.subTest(value=value), self.assertRaises(tts.ReadAloudError):
                self.generate(value, allow_network=True)
        self.identity.assert_not_called()

    def test_request_lock_does_not_duplicate_remote_submission(self):
        self.cache.mkdir()
        _, key = tts.request_identity(IDENTITY, TEXT, VOICES[0])
        lock = self.cache / (key + ".lock")
        lock.mkdir()
        with patch.object(tts, "run_worker") as transport, self.assertRaises(tts.ReadAloudError):
            self.generate(allow_network=True)
        transport.assert_not_called()
        self.assertTrue(lock.is_dir())

    def test_sequential_two_originals_and_truthful_receipts(self):
        with patch.object(tts, "run_worker", side_effect=self.produce) as transport:
            result = self.generate(allow_network=True)
        self.assertEqual([x.args[2] for x in transport.call_args_list], list(VOICES))
        self.assertEqual([r["reused"] for r in result], [False, False])
        for row in result:
            self.assertFalse(row["listening_confirmed"])
            self.assertFalse(row["commercial_allowed"])
            self.assertFalse(row["upload_consent"])
            source = Path(row["receipt"]).read_text()
            self.assertIn(TEXT, source)
            self.assertIn(row["sha256"], source)
            self.assertIn("unknown_not_exposed_by_service", source)
            self.assertIn("不是Azure Speech正式API", source)

    def test_cache_hit_is_byte_identical_without_network_permission_or_worker(self):
        with patch.object(tts, "run_worker", side_effect=self.produce):
            first = self.generate(allow_network=True)
        with patch.object(tts, "run_worker") as transport:
            second = self.generate(self.jobs("cache-hit"))
        transport.assert_not_called()
        self.assertEqual([r["sha256"] for r in first], [r["sha256"] for r in second])
        self.assertTrue(all(r["reused"] for r in second))
        for old, new in zip(first, second):
            self.assertEqual(Path(old["receipt"]).read_bytes(), Path(new["receipt"]).read_bytes())

    def test_corrupt_cache_original_is_not_silently_regenerated(self):
        with patch.object(tts, "run_worker", side_effect=self.produce):
            first = self.generate(allow_network=True)
        (self.cache / first[0]["key"] / "voice.mp3").write_bytes(b"tampered")
        with patch.object(tts, "run_worker") as transport, self.assertRaises(tts.ReadAloudError):
            self.generate(self.jobs("after-corruption"), allow_network=True)
        transport.assert_not_called()

    def test_second_failure_preserves_first_and_partial_original_without_success(self):
        calls = []
        def failed(*args):
            self.produce(*args)
            calls.append(args[2])
            if len(calls) == 2:
                raise tts.ReadAloudError("finite fixture transport failure")
        with patch.object(tts, "run_worker", side_effect=failed), self.assertRaises(tts.ReadAloudError):
            self.generate(allow_network=True)
        entries = list(self.cache.iterdir())
        self.assertEqual(len(entries), 1)
        self.assertTrue(entries[0].name.startswith("failed-batch-"))
        self.assertEqual(len(list(entries[0].rglob("voice.mp3"))), 2)
        self.assertFalse(any(j["output"].exists() for j in self.jobs()))
        self.assertFalse((self.runtime / "generation.lock").exists())
        self.assertFalse(list(self.cache.glob("*.lock")))

    def test_runtime_drift_prevents_cache_and_delivery(self):
        self.identity.side_effect = [copy.deepcopy(IDENTITY), {**IDENTITY, "adapter_sha256": "changed"}]
        with patch.object(tts, "run_worker", side_effect=self.produce), self.assertRaises(tts.ReadAloudError):
            self.generate(allow_network=True)
        self.assertTrue(list(self.cache.glob("failed-batch-*")))
        self.assertFalse(any(j["output"].exists() for j in self.jobs()))

    def test_source_or_original_symlink_cannot_replace_an_existing_file(self):
        outside = self.root / "outside"
        outside.write_bytes(b"untouched")
        jobs = self.jobs()
        jobs[0]["output"].symlink_to(outside)
        with self.assertRaises(tts.ReadAloudError):
            self.generate(jobs, allow_network=True)
        self.assertEqual(outside.read_bytes(), b"untouched")


class FileAndProcessRules(unittest.TestCase):
    def test_atomic_publication_never_overwrites_concurrent_file(self):
        with tempfile.TemporaryDirectory() as directory:
            source, output = Path(directory) / "source", Path(directory) / "output"
            source.write_bytes(b"original")
            output.write_bytes(b"existing")
            with self.assertRaises(FileExistsError):
                tts.atomic_copy(source, output)
            self.assertEqual(output.read_bytes(), b"existing")
            self.assertEqual(sorted(p.name for p in Path(directory).iterdir()), ["output", "source"])

    def test_timeout_terminates_only_the_owned_process_group(self):
        from unittest.mock import Mock
        child = Mock(pid=123456)
        child.wait.side_effect = [subprocess.TimeoutExpired("finite fixture", 10), 0]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(tts.subprocess, "Popen", return_value=child), patch.object(tts.os, "killpg") as kill:
                with self.assertRaises(tts.ReadAloudError):
                    tts.run_worker(root, TEXT, VOICES[0], root / "original.mp3", 10, root / "process.log")
            kill.assert_called_once_with(123456, signal.SIGTERM)

    @unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "local codec tools not installed")
    def test_complete_original_mp3_decode_and_wrong_channels_rejection(self):
        ffmpeg, ffprobe = Path(shutil.which("ffmpeg")), Path(shutil.which("ffprobe"))
        with tempfile.TemporaryDirectory() as directory:
            for channels in (1, 2):
                audio = Path(directory) / f"tone-{channels}.mp3"
                result = subprocess.run([str(ffmpeg), "-v", "error", "-f", "lavfi", "-i",
                                         "sine=frequency=440:sample_rate=24000:duration=0.48", "-ac", str(channels),
                                         "-c:a", "libmp3lame", "-b:a", "48k", str(audio)], capture_output=True, timeout=15)
                self.assertEqual(result.returncode, 0)
                original = tts.digest(audio)
                if channels == 1:
                    info = tts.inspect_mp3(audio, ffmpeg, ffprobe)
                    self.assertGreaterEqual(info["samples"], 10000)
                    self.assertGreater(info["rms_float"], 0.01)
                else:
                    with self.assertRaises(tts.ReadAloudError):
                        tts.inspect_mp3(audio, ffmpeg, ffprobe)
                self.assertEqual(tts.digest(audio), original)


if __name__ == "__main__":
    unittest.main()
