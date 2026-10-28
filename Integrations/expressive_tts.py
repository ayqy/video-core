#!/usr/bin/env python3
"""Offline, full-utterance CosyVoice preset narration with a verified cache.

No account, remote inference, voice cloning, editing workspace or review approval.
Use prepare_cosyvoice.py once to install the explicitly selected local engine.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import wave

ENGINE = "FunAudioLLM/CosyVoice-300M-SFT"
MODEL_REVISION = "fbb71de2afe387ed854eebd80b9f3d078c6b9869"
SOURCE_REVISION = "074ca6dc9e80a2f424f1f74b48bdd7d3fea531cc"
MODEL_FILES = {
    "llm.pt": (1242994835, "d198ce56636e1eb1c9d0cb0d6e3529de8fdfd3fd45075c346296b0d6dcfc54ea"),
    "flow.pt": (419900943, "21eae78c105b5e1c6c337b04f667843377651b4bcfb2d43247ed3ad7fd0a3470"),
    "hift.pt": (81896716, "91e679b6ca1eff71187ffb4f3ab0444935594cdcc20a9bd12afad111ef8d6012"),
    "speech_tokenizer_v1.onnx": (522624269, "23b5a723ed9143aebfd9ffda14ac4c21231f31c35ef837b6a13bb9e5488abb1e"),
    "campplus.onnx": (28303423, "a6ac6a63997761ae2997373e2ee1c47040854b4b759ea41ec48e4e42df0f4d73"),
    "spk2info.pt": (7772, "e3b1d62ca87cdcb25a9003fa0c8f2cba5c94f55b0d5f80f0b63ef8c22d919cfc"),
}


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def validate_request(text: str, voice: str, instruction: str, seed: int) -> None:
    if not text.strip() or len(text) > 240 or any(c in text for c in "\x00\r\n|<>"):
        raise ValueError("请输入一段1–240字完整讲述；不接受控制标记或多段拼接")
    if voice not in ("中文女", "中文男"):
        raise ValueError("本地叙事配音只使用模型发布的中文女/中文男预设，不克隆人物")
    if instruction != "":
        raise ValueError("当前预设音色模型不支持语气指令；请保留空串，导演备注不要送进旁白")
    if not 0 <= seed <= 2**31 - 1:
        raise ValueError("seed须为非负32位整数")


def identity(runtime: Path) -> dict:
    """Verify pinned weights and the complete installed source/dependency identity."""
    manifest = runtime / "identity.txt"
    lines = manifest.read_text(encoding="utf-8").splitlines()
    if lines[:2] != ["source=" + SOURCE_REVISION, "model=" + MODEL_REVISION]:
        raise ValueError("本地模型或引擎版本不符，请重新准备，不回退旧声音")
    for name, (size, expected) in MODEL_FILES.items():
        path = runtime / "model" / name
        if path.is_symlink() or path.stat().st_size != size or digest(path) != expected:
            raise ValueError("模型原件校验失败：" + name)
    for line in lines[2:]:
        expected, relative = line.split("  ", 1)
        path = runtime / relative
        if path.is_symlink() or not path.is_file() or digest(path) != expected:
            raise ValueError("引擎源码/配置/固定依赖身份校验失败：" + relative)
    if len(lines) < 12:
        raise ValueError("不完整的本地引擎身份")
    code = "import importlib.metadata as m; print('\\n'.join(sorted(d.metadata['Name'].lower().replace('_','-')+'=='+d.version for d in m.distributions())))"
    live = subprocess.run([str(runtime / "venv/bin/python"), "-B", "-c", code],
                          capture_output=True, text=True, check=True, timeout=30)
    if live.stdout != (runtime / "environment-freeze.txt").read_text():
        raise ValueError("实际安装的依赖与固定环境不符，不复用旧配音")
    return {"engine": ENGINE, "model": MODEL_REVISION, "source": SOURCE_REVISION,
            "runtime_sha256": digest(manifest), "adapter_sha256": digest(Path(__file__))}


def request_identity(engine: dict, text: str, voice: str, instruction: str, seed: int) -> tuple[dict, str]:
    validate_request(text, voice, instruction, seed)
    request = {**engine, "text": text, "voice": voice, "instruction": instruction,
               "seed": seed, "speed": 1.0, "sample_rate": 22050,
               "segmentation": "one-complete-utterance", "format": "mono-pcm16",
               "mode": "sft-text-only"}
    key = hashlib.sha256(json.dumps(request, ensure_ascii=False, sort_keys=True,
                                    separators=(",", ":")).encode()).hexdigest()
    return request, key


def inspect_wave(path: Path) -> tuple[int, int]:
    with wave.open(str(path)) as stream:
        if (stream.getnchannels(), stream.getsampwidth(), stream.getframerate()) != (1, 2, 22050):
            raise ValueError("配音必须是22050Hz单声道PCM16")
        samples = stream.getnframes()
        if not 0.2 <= samples / 22050 <= 90:
            raise ValueError("配音实际时长越界，不自动截断或加速")
        pcm = stream.readframes(samples)
        if len(pcm) != samples * 2:
            raise ValueError("配音原件不完整")
        import array
        values = array.array("h", pcm)
        if sys.byteorder != "little":
            values.byteswap()
        peak = max(abs(x) for x in values)
        rms = math.sqrt(sum(x * x for x in values) / samples)
        if not 1 < rms or peak >= 32767:
            raise ValueError("配音静音或削波；请调整生成配置，不能冒成功")
    return samples, 22050


def receipt(request: dict, key: str, wav: Path, samples: int) -> str:
    rows = ["# 本地完整句段配音", "", "声音/字幕/整片均待实际试听确认。",
            "不提供字级或句内精确时间戳，不调用远端服务，不克隆人物。", "",
            "|字段|值|", "|---|---|"]
    rows += [f"|{k}|{v}|" for k, v in request.items()]
    rows += [f"|cache_key|{key}|", f"|audio_sha256|{digest(wav)}|", f"|samples|{samples}|", ""]
    return "\n".join(rows)


class WorkerCancelled(ValueError):
    pass


def run_worker(args: list[str], env: dict[str, str], log, deadline: int) -> int:
    """Own one isolated worker until it exits, including parent cancellation."""
    if threading.current_thread() is not threading.main_thread():
        raise ValueError("本地配音worker须由主线程管理信号，不在后台线程创建进程")
    process = None
    cancelled = False
    cleaning = False
    previous = signal.getsignal(signal.SIGTERM)

    def cancel(signum, frame):
        nonlocal cancelled
        cancelled = True
        # Popen may have created its child before returning the owned handle.
        # Defer interruption through that assignment window and through reaping.
        if process is not None and not cleaning:
            raise WorkerCancelled("本地配音已取消；无交付、未回退旧声音")

    signal.signal(signal.SIGTERM, cancel)
    try:
        try:
            if cancelled:
                raise WorkerCancelled("本地配音已取消，未启动配音worker")
            process = subprocess.Popen(args, env=env, stdout=log, stderr=log, start_new_session=True)
            if cancelled:
                raise WorkerCancelled("本地配音已取消；无交付、未回退旧声音")
            code = process.wait(timeout=deadline)
            if cancelled:
                raise WorkerCancelled("本地配音已取消；无交付、未回退旧声音")
        except BaseException as error:
            cleaning = True
            if process is not None:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.wait(timeout=5)
            if isinstance(error, subprocess.TimeoutExpired):
                raise ValueError("本地配音超时；无交付、未回退旧声音") from None
            raise
        return code
    finally:
        signal.signal(signal.SIGTERM, previous)


def generate(runtime: Path, cache: Path, text: str, voice: str, instruction: str,
             seed: int, output: Path, deadline: int = 600) -> dict:
    validate_request(text, voice, instruction, seed)
    if output.exists() or output.is_symlink():
        raise ValueError("输出已存在，不覆盖原音")
    if not 5 <= deadline <= 1800:
        raise ValueError("生成期限须为5–1800秒")
    request, key = request_identity(identity(runtime), text, voice, instruction, seed)
    cache.mkdir(parents=True, exist_ok=True)
    entry = cache / key
    lock = cache / (key + ".lock")
    try:
        lock.mkdir()
    except FileExistsError:
        raise ValueError("相同配音正在生成；等待原作业完成，不重复提交") from None
    try:
        reused = entry.exists()
        if reused:
            wav = entry / "voice.wav"
            if entry.is_symlink() or wav.is_symlink() or (entry / "source.md").is_symlink():
                raise ValueError("缓存不接受符号链接")
            samples, rate = inspect_wave(wav)
            if (entry / "source.md").read_text() != receipt(request, key, wav, samples):
                raise ValueError("缓存原件或身份不符，不采用损坏缓存、不静默重生成")
        else:
            with tempfile.TemporaryDirectory(prefix=key + ".", dir=cache) as temp:
                staging = Path(temp)
                wav = staging / "voice.wav"
                args = [str(runtime / "venv/bin/python"), "-B", str(Path(__file__).resolve()),
                        "--worker", "--runtime", str(runtime.resolve()), "--text", text,
                        "--voice", voice, "--instruction", instruction, "--seed", str(seed),
                        "--output", str(wav.resolve())]
                (runtime / "temp").mkdir(exist_ok=True)
                env = {"PATH": "/usr/local/bin:/usr/bin:/bin", "LANG": "en_US.UTF-8",
                       "HF_HOME": str(runtime / "hf"), "TMPDIR": str(runtime / "temp"),
                       "XDG_CACHE_HOME": str(runtime / "xdg"), "TORCH_HOME": str(runtime / "torch"),
                       "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1",
                       "HF_HUB_DISABLE_IMPLICIT_TOKEN": "1", "HF_HUB_DISABLE_TELEMETRY": "1",
                       "PYTHONDONTWRITEBYTECODE": "1", "TOKENIZERS_PARALLELISM": "false",
                       "OMP_NUM_THREADS": "2", "MKL_NUM_THREADS": "2"}
                with (staging / "worker-output.txt").open("wb") as log:
                    code = run_worker(args, env, log, deadline)
                if code:
                    detail = (staging / "worker-output.txt").read_text(errors="replace")[-1800:]
                    raise ValueError("本地配音未成功：" + detail)
                samples, rate = inspect_wave(wav)
                (staging / "source.md").write_text(receipt(request, key, wav, samples))
                (staging / "worker-output.txt").unlink()
                staging.rename(entry)
        output.parent.mkdir(parents=True, exist_ok=True)
        # A failed copy must not leave an apparent delivery. Atomic hard-link
        # publication refuses an output created concurrently by another caller.
        fd, staging_name = tempfile.mkstemp(prefix=".voice-", dir=output.parent)
        staging_output = Path(staging_name)
        try:
            with (entry / "voice.wav").open("rb") as source, os.fdopen(fd, "wb") as target:
                shutil.copyfileobj(source, target)
            os.link(staging_output, output)
        finally:
            staging_output.unlink(missing_ok=True)
        return {"reused": reused, "key": key, "sha256": digest(output),
                "samples": samples, "sample_rate": rate, "receipt": str(entry / "source.md")}
    finally:
        lock.rmdir()


def worker(args) -> None:
    import socket
    def no_network(*a, **kw):
        raise RuntimeError("离线配音禁止网络访问")
    socket.create_connection = no_network
    socket.socket.connect = no_network
    socket.socket.connect_ex = no_network
    sys.path.insert(0, str(args.runtime / "source"))
    sys.path.insert(0, str(args.runtime / "source/third_party/Matcha-TTS"))
    import random
    import threading
    import numpy as np
    import torch
    import soundfile as sf
    torch.set_num_threads(2)
    torch.set_num_interop_threads(1)
    from cosyvoice.cli.cosyvoice import AutoModel
    model = AutoModel(model_dir=str(args.runtime / "model"), load_jit=False, load_trt=False, fp16=False)
    random.seed(args.seed)
    np.random.seed(args.seed)
    torch.manual_seed(args.seed)
    if args.voice not in model.list_available_spks():
        raise ValueError("发布模型中没有所选预设音色")
    chunks = []
    thread_errors = []
    previous_thread_hook = threading.excepthook

    def inference_thread_failed(error):
        # Upstream runs the LLM in a Python thread. join() does not rethrow its
        # exception, and a partial token sequence can still produce valid PCM.
        # This worker is an isolated process, so fail it before publishing audio.
        thread_errors.append(error.exc_value)

    threading.excepthook = inference_thread_failed
    try:
        # Preserve punctuation and intonation within a whole scene/utterance.
        # Inputs are already authored/TN-checked; do not split at commas or re-normalize.
        for item in model.inference_sft(args.text, args.voice,
                                        stream=False, speed=1.0, text_frontend=False):
            audio = item["tts_speech"].detach().cpu().numpy().reshape(-1)
            if not len(audio) or not np.isfinite(audio).all():
                raise ValueError("引擎未返回完整有效声音")
            chunks.append(audio)
        if thread_errors:
            raise ValueError("模型推理线程失败；拒绝将部分语音发布或缓存") from thread_errors[0]
        if len(chunks) != 1:
            raise ValueError("整段推理返回多个片段，拒绝无条件拼接破坏语流")
    finally:
        threading.excepthook = previous_thread_hook
    sf.write(str(args.output), chunks[0], model.sample_rate, subtype="PCM_16")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--cache", type=Path)
    parser.add_argument("--text", required=True)
    parser.add_argument("--voice", default="中文男")
    parser.add_argument("--instruction", default="", help="兼容参数；当前SFT模式只接受空串，不支持显式语气指令")
    parser.add_argument("--seed", type=int, default=1986)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--deadline", type=int, default=600)
    parser.add_argument("--worker", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    try:
        validate_request(args.text, args.voice, args.instruction, args.seed)
        if args.worker:
            worker(args)
        else:
            if not args.cache:
                parser.error("--cache required")
            result = generate(args.runtime, args.cache, args.text, args.voice, args.instruction,
                              args.seed, args.output, args.deadline)
            print("本地配音已复用" if result["reused"] else "本地配音已生成",
                  result["samples"], result["sample_rate"], result["sha256"])
        return 0
    except (ValueError, OSError, wave.Error, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
