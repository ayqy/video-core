#!/usr/bin/env python3
"""Offline, full-utterance adult voice designs; never changes the default voice.

The optional batch loads one pinned CPU model once and generates each complete
utterance sequentially. A technical result is always pending human listening.
"""
from __future__ import annotations

import argparse
import array
from contextlib import ExitStack
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
import time
import wave

ENGINE = "Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign"
MODEL_REVISION = "5ecdb67327fd37bb2e042aab12ff7391903235d3"
SOURCE_WHEEL_SHA256 = "11a290d8dabc7ef91a90c54478c8ab19b3edb1d85c0882313721892bdc4af15d"
SOURCE_MANIFEST = Path(__file__).with_name("voice-design-source.txt")
SOURCE_MANIFEST_SHA256 = "a0ef0caeb1990166cfd90ddde6ae17bd32a7fa36e5a2eac50c4865b6d4b584b2"
RATE = 24000
DIRECT_DEPENDENCIES = {"qwen-tts": "0.1.1", "torch": "2.2.2", "torchaudio": "2.2.2",
                       "numpy": "1.26.4", "transformers": "4.57.3", "accelerate": "1.12.0",
                       "numba": "0.60.0", "llvmlite": "0.43.0"}
MODEL_FILES = {
    "model.safetensors": (3833402552, "391e8db219f292c515297cdceeb43e4eae67cdde35fa57e79a6a8a532fca0522"),
    "speech_tokenizer/model.safetensors": (682293092, "836b7b357f5ea43e889936a3709af68dfe3751881acefe4ecf0dbd30ba571258"),
    "README.md": (3214, "acfaf6c0d433866cb5e2bb73e7915ea3767f5a2e3abca413b485635a2c72b5e6"),
    "config.json": (4421, "aecd2cc4c1fe9edef1cb7ca7c401685a43879ad43f3f9e883f1c6760b61731e0"),
    "generation_config.json": (245, "f1b90b4513f3b34c62851049e2492d7b4c5940daf1276f89c82b8ef04127f3aa"),
    "merges.txt": (1671839, "599bab54075088774b1733fde865d5bd747cbcc7a547c5bc12610e874e26f5e3"),
    "preprocessor_config.json": (127, "efdde1022ea9d76928bf7a9cd53139138f5ba2e466e837f08f6105ab1af1c119"),
    "speech_tokenizer/config.json": (2336, "ee65bb901c876664ab8707c487157aa1a6ee57c65969b28fb5ec9dc211e68167"),
    "speech_tokenizer/configuration.json": (76, "6bc26d64eb5024b4d1dab5a52371958b429256d6c9d59787f1f5294a54e0cebd"),
    "speech_tokenizer/preprocessor_config.json": (234, "fcb3805e597e786d4067706e602f6688524640f8d3396790e2e09b5942fcbdfb"),
    "tokenizer_config.json": (7344, "dc3c31c3bdaedd5016382bb3cbe07323026775ad51f5a4fb564505992ae4a670"),
    "vocab.json": (2776833, "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
}
DESIGNS = {
    "adult-warm-low": {
        "label": "A · 低柔自信",
        "instruction": "一位二十五到三十五岁的成年女性，标准普通话，偏低的中音，音色柔润，带一点自然沙哑和轻微气声，成熟、有吸引力，语气亲近而自信。像面对面分享一个有趣的小故事，开头带好奇，提问时微微上扬，揭示答案时清楚坚定，句尾自然收住。连贯自然地讲述，停顿短而有变化，不播音腔，不逐字重读。",
    },
    "adult-bright-confident": {
        "label": "B · 明亮俏皮",
        "instruction": "一位二十五到三十五岁的成年女性，标准普通话，明亮清晰的中高音，声音轻盈有弹性，带一点俏皮的笑意和自信，活泼但不尖细。像和朋友讲一件有趣的事，问题带着好奇，转折时有鲜明语气，解释清楚利落，结尾温柔有把握。全段连贯，自然聊天，不播音腔，不夸张卖萌。",
    },
    "adult-soft-playful": {
        "label": "C · 温润成熟",
        "instruction": "一位三十五到四十五岁的成年女性，标准普通话，圆润温厚的中音，声线舒展细腻，成熟从容，带自然的温度和吸引力。像坐在身旁娓娓讲一个有悬念的小故事，问题轻轻抛出，转折有清楚的情绪变化，答案说得笃定，句尾柔和收住。语流连贯，停顿自然，不压低耳语，不播音腔，不拖长每个字。",
    },
    "adult-taiwan-warm-narrative-v1": {
        "label": "台湾华语 · 温柔细腻候选",
        "instruction": "一位二十八到三十八岁的成年台湾女性，用清楚自然的台湾华语讲一个有悬念的小故事。音色温柔甜美、圆润有质感，中音稍偏低，带轻微自然气声和亲近的笑意，声音有吸引力但不耳语、不幼态、不模仿任何具体人物。先理解整段故事的因果，再连贯地说给一位朋友听。语速从容，给听众跟上意思的时间；一句话按主语、动作、数量和结果分成自然的信息组，在信息变化处略停，关键动作和对比对象轻轻突出，避免每个字都重读。提出问题时略带好奇，犹豫时声音放轻，出现转折时有清楚但细小的高低起伏，作出决定时清晰笃定，揭示结果时温柔有把握。短停顿前的字要干净收住，不拉长尾音，不逐句固定上扬，不喊话、不争吵、不用播音腔；全文自然衔接，不拆句重录。",
    },
}
GENERATION = dict(non_streaming_mode=True, do_sample=True, top_k=50, top_p=1.0,
                  temperature=0.9, repetition_penalty=1.05, subtalker_dosample=True,
                  subtalker_top_k=50, subtalker_top_p=1.0, subtalker_temperature=0.9,
                  max_new_tokens=2048)


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def validate_request(text: str, voice: str, instruction: str, seed: int,
                     engine: str = ENGINE, language: str = "Chinese") -> None:
    if engine != ENGINE or language != "Chinese":
        raise ValueError("只接受固定VoiceDesign引擎与Chinese语言，不回退其它模型")
    if not isinstance(text, str) or not text.strip() or len(text) > 240 or any(c in text for c in "\x00\r\n\t|<>"):
        raise ValueError("请输入一段1–240字完整正文，不接受多段或控制标记")
    if voice not in DESIGNS:
        raise ValueError("未知成年女声设计编号")
    if not isinstance(instruction, str) or instruction != DESIGNS[voice]["instruction"]:
        raise ValueError("音色指令须与所选成年女声设计完整一致，不忽略未知或空白指令")
    if type(seed) is not int or not 0 <= seed <= 2**31 - 1:
        raise ValueError("seed须为非负32位整数")


def offline_environment(runtime: Path) -> dict:
    for relative in ("temp", "hf", "xdg", "torch", "numba"):
        (runtime / relative).mkdir(exist_ok=True)
    return {"PATH": "/usr/local/bin:/usr/bin:/bin", "LANG": "en_US.UTF-8",
            "HF_HOME": str(runtime / "hf"), "TMPDIR": str(runtime / "temp"),
            "XDG_CACHE_HOME": str(runtime / "xdg"), "TORCH_HOME": str(runtime / "torch"),
            "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1", "HF_HUB_DISABLE_IMPLICIT_TOKEN": "1",
            "HF_HUB_DISABLE_TELEMETRY": "1", "PYTHONDONTWRITEBYTECODE": "1",
            "TOKENIZERS_PARALLELISM": "false", "OMP_NUM_THREADS": "4", "MKL_NUM_THREADS": "4",
            "OPENBLAS_NUM_THREADS": "4", "NUMEXPR_NUM_THREADS": "4",
            "NUMBA_CACHE_DIR": str(runtime / "numba")}


def runtime_inventory(runtime: Path) -> str:
    """Hash all installed dependency files, without importing or loading a model.

    A first explicit seal records the prepared environment. Subsequent requests
    must match that seal byte for byte; neither drift nor cache hits reseal it.
    """
    runtime = runtime.resolve()
    if (runtime / "model").is_symlink() or any(p.is_symlink() for p in (runtime / "model").rglob("*")):
        raise ValueError("模型原件不接受符号链接")
    actual = {p.relative_to(runtime / "model").as_posix() for p in (runtime / "model").rglob("*") if p.is_file()}
    if actual != set(MODEL_FILES):
        raise ValueError("模型原件清单不完整或含额外文件")
    for name, (size, expected) in MODEL_FILES.items():
        path = runtime / "model" / name
        if path.is_symlink() or path.stat().st_size != size or digest(path) != expected:
            raise ValueError("模型原件身份不符：" + name)
    # Isolated mode prevents a caller's cwd/PYTHONPATH from supplying qwen_tts.
    probe = """import importlib.metadata as m, json, sys, sysconfig, platform
root=sysconfig.get_path('purelib')
freeze=sorted((d.metadata['Name'].lower().replace('_','-'),d.version) for d in m.distributions())
print(json.dumps(dict(root=root,freeze=freeze,python=sys.version,platform=platform.machine())))
"""
    result = subprocess.run([str(runtime / "venv/bin/python"), "-I", "-B", "-c", probe],
                            capture_output=True, text=True, check=True, timeout=30,
                            env=offline_environment(runtime))
    environment = json.loads(result.stdout)
    freeze = dict(environment["freeze"])
    if len(freeze) != len(environment["freeze"]) or any(freeze.get(k) != v for k, v in DIRECT_DEPENDENCIES.items()):
        raise ValueError("实际固定依赖版本不符，不回退或采用旧缓存")
    site = Path(environment["root"])
    if site.is_symlink():
        raise ValueError("引擎不在所选隔离环境内")
    site = site.resolve()
    if not site.is_relative_to(runtime / "venv"):
        raise ValueError("引擎不在所选隔离环境内")
    # Complete installed qwen source/data must equal the published wheel payload.
    source_manifest = SOURCE_MANIFEST
    if source_manifest.is_symlink() or digest(source_manifest) != SOURCE_MANIFEST_SHA256:
        raise ValueError("发布引擎源码清单身份不符")
    expected_source = {}
    for line in source_manifest.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        expected, name = line.split("  ", 1)
        if len(expected) != 64 or not name.startswith("qwen_tts/") or ".." in Path(name).parts:
            raise ValueError("发布引擎源码清单无效")
        expected_source[name] = expected
    live_payload = {p.relative_to(site).as_posix(): digest(p) for p in (site / "qwen_tts").rglob("*")
                    if p.is_file() and "__pycache__" not in p.parts and p.suffix != ".pyc"}
    if not expected_source or live_payload != expected_source:
        raise ValueError("实际引擎源码与固定官方wheel不符")
    rows = ["engine=" + ENGINE, "model=" + MODEL_REVISION, "source-wheel=" + SOURCE_WHEEL_SHA256,
            "python=" + environment["python"].replace("\n", " "), "platform=" + environment["platform"]]
    rows += ["dependency=" + name + "==" + version for name, version in environment["freeze"]]
    rows.append("interpreter-sha256=" + digest(runtime / "venv/bin/python"))
    rows.append("source-list-sha256=" + digest(source_manifest))
    for path in sorted(site.rglob("*")):
        if "__pycache__" in path.parts or path.suffix == ".pyc":
            continue
        if path.is_symlink():
            raise ValueError("依赖不接受符号链接或特殊文件")
        if path.is_dir():
            continue
        if not path.is_file():
            raise ValueError("依赖不接受符号链接或特殊文件")
        rows.append(digest(path) + "  " + path.relative_to(runtime).as_posix())
    return "\n".join(rows) + "\n"


def seal_runtime(runtime: Path) -> None:
    """Explicitly seal an already prepared runtime; never overwrite an old seal."""
    identity = runtime / "identity.txt"
    if identity.exists() or identity.is_symlink():
        raise ValueError("环境身份已存在，不能重封以掩盖依赖变化；请用新运行目录")
    atomic_copy_text(runtime_inventory(runtime), identity)


def identity(runtime: Path) -> dict:
    manifest = runtime / "identity.txt"
    if manifest.is_symlink() or not manifest.is_file() or manifest.read_text() != runtime_inventory(runtime):
        raise ValueError("引擎/模型/实际依赖身份变化，明确拒绝，不自动重封或重生成")
    return {"engine": ENGINE, "model": MODEL_REVISION, "source_wheel": SOURCE_WHEEL_SHA256,
            "runtime_sha256": digest(manifest), "adapter_sha256": digest(Path(__file__)),
            "source_list_sha256": digest(SOURCE_MANIFEST)}


def request_identity(engine: dict, text: str, voice: str, instruction: str, seed: int,
                     language: str = "Chinese") -> tuple[dict, str]:
    validate_request(text, voice, instruction, seed, engine.get("engine"), language)
    if engine.get("model") != MODEL_REVISION or engine.get("source_wheel") != SOURCE_WHEEL_SHA256:
        raise ValueError("请求不能覆盖固定模型或官方引擎身份")
    request = {**engine, "text": text, "voice": voice, "instruction": instruction, "seed": seed,
               "language": language, "sample_rate": RATE, "format": "mono-pcm16",
               "device": "cpu", "dtype": "float32", "attention": "eager", "threads": 4,
               "speed": 1.0, "segmentation": "one-complete-utterance", "generation": GENERATION}
    key = hashlib.sha256(json.dumps(request, ensure_ascii=False, sort_keys=True,
                                    separators=(",", ":")).encode()).hexdigest()
    return request, key


def inspect_wave(path: Path) -> tuple[int, int]:
    if path.is_symlink():
        raise ValueError("音频原件不接受符号链接")
    with wave.open(str(path)) as stream:
        if (stream.getnchannels(), stream.getsampwidth(), stream.getframerate(), stream.getcomptype()) != (1, 2, RATE, "NONE"):
            raise ValueError("配音须为24000Hz单声道PCM16")
        samples = stream.getnframes()
        if not 0.2 <= samples / RATE <= 90:
            raise ValueError("实际声音时长越界，不截句尾、不加速")
        pcm = stream.readframes(samples)
        if len(pcm) != samples * 2:
            raise ValueError("声音原件不完整")
    values = array.array("h", pcm)
    if sys.byteorder != "little":
        values.byteswap()
    peak = max(abs(x) for x in values)
    rms = math.sqrt(sum(x * x for x in values) / samples)
    if rms <= 1 or peak >= 32767:
        raise ValueError("声音静音或削波，不冒生成成功")
    return samples, RATE


def receipt(request: dict, key: str, wav: Path, samples: int) -> str:
    rows = ["# 成年女声设计候选", "", "技术生成记录；完整听审、文字核对、音色选择均待确认。",
            "未更换默认音色；不克隆人物，不裁句拼接，不调速变调。", "", "|字段|值|", "|---|---|"]
    rows += [f"|{name}|{value}|" for name, value in request.items()]
    rows += [f"|cache_key|{key}|", f"|audio_sha256|{digest(wav)}|", f"|samples|{samples}|", ""]
    return "\n".join(rows)


def atomic_copy(source: Path, output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=".voice-", dir=output.parent)
    temporary = Path(name)
    try:
        with source.open("rb") as stream, os.fdopen(fd, "wb") as target:
            shutil.copyfileobj(stream, target)
            target.flush()
            os.fsync(target.fileno())
        os.link(temporary, output)  # Atomic, refuses concurrent overwrite.
    finally:
        temporary.unlink(missing_ok=True)


def atomic_copy_text(text: str, output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".identity-", dir=output.parent) as directory:
        source = Path(directory) / "source.txt"
        source.write_text(text, encoding="utf-8")
        atomic_copy(source, output)


def run_worker(runtime: Path, text: str, jobs: list[dict], deadline: int, log: Path) -> None:
    args = [str(runtime / "venv/bin/python"), "-I", "-B", str(Path(__file__).resolve()),
            "--worker", "--runtime", str(runtime), "--text", text]
    for job in jobs:
        args += ["--voice", job["voice"], "--instruction", job["instruction"],
                 "--seed", str(job["seed"]), "--output", str(job["output"])]
    with log.open("xb") as output:
        process = subprocess.Popen(args, env=offline_environment(runtime), stdout=output,
                                   stderr=output, start_new_session=True)
        try:
            code = process.wait(timeout=deadline)
        except BaseException as error:
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
                raise ValueError("本地音色设计超时，原日志保留；无成功交付、未回退声音") from None
            raise
    if code:
        raise ValueError("本地音色设计失败，原日志保留：" + str(log))


def generate_batch(runtime: Path, cache: Path, text: str, jobs: list[dict], deadline: int = 10800) -> list[dict]:
    """Generate 1–3 complete utterances using one model load, never a GPU batch."""
    if not 1 <= len(jobs) <= 3 or not 5 <= deadline <= 14400:
        raise ValueError("每批1–3个独立音色，生成期限须为5–14400秒")
    outputs, voices = set(), set()
    for job in jobs:
        if set(job) != {"voice", "instruction", "seed", "output"}:
            raise ValueError("未知或缺失音色作业字段")
        validate_request(text, job["voice"], job["instruction"], job["seed"])
        output = Path(job["output"]).absolute()
        if output in outputs or job["voice"] in voices:
            raise ValueError("一批不能重复音色或输出路径")
        if output.exists() or output.is_symlink():
            raise ValueError("输出已存在，不覆盖原音")
        outputs.add(output)
        voices.add(job["voice"])
    if runtime.is_symlink() or cache.is_symlink():
        raise ValueError("运行和缓存目录不接受符号链接")
    runtime, cache = runtime.resolve(), cache.resolve()
    engine = identity(runtime)
    cache.mkdir(parents=True, exist_ok=True)
    state = []
    with ExitStack() as stack:
        runtime_lock = runtime / "inference.lock"
        try:
            runtime_lock.mkdir()
        except FileExistsError:
            raise ValueError("所选本地引擎正在生成，等待原作业，不并发加载模型") from None
        stack.callback(runtime_lock.rmdir)
        directory = Path(stack.enter_context(tempfile.TemporaryDirectory(prefix="design-", dir=cache)))
        pending = []
        for index, job in enumerate(jobs):
            request, key = request_identity(engine, text, job["voice"], job["instruction"], job["seed"])
            lock = cache / (key + ".lock")
            try:
                lock.mkdir()
            except FileExistsError:
                raise ValueError("相同音色正在生成，不能重复提交") from None
            stack.callback(lock.rmdir)
            entry = cache / key
            reused = entry.exists() or entry.is_symlink()
            if reused:
                wav = entry / "voice.wav"
                source = entry / "source.md"
                if entry.is_symlink() or source.is_symlink():
                    raise ValueError("缓存不接受符号链接")
                samples, _ = inspect_wave(wav)
                if source.read_text() != receipt(request, key, wav, samples):
                    raise ValueError("缓存原音或生成身份不符，不静默重生成")
            else:
                entry_staging = directory / str(index)
                entry_staging.mkdir()
                wav = entry_staging / "voice.wav"
                pending.append({**job, "output": wav})
            state.append(dict(job=job, request=request, key=key, entry=entry, wav=wav, reused=reused))
        if pending:
            logs = runtime / "logs"
            logs.mkdir(exist_ok=True)
            log = logs / ("voice-design-" + str(time.time_ns()) + ".log")
            try:
                run_worker(runtime, text, pending, deadline, log)
                if identity(runtime) != engine:
                    raise ValueError("生成期间环境或适配器身份改变，拒绝缓存与交付")
                # Validate the whole returned batch before promoting any new entry.
                for item in state:
                    if not item["reused"]:
                        samples, _ = inspect_wave(item["wav"])
                        (item["wav"].parent / "source.md").write_text(receipt(item["request"], item["key"], item["wav"], samples), encoding="utf-8")
            except BaseException:
                # Preserve any returned original/partial audio as failure evidence;
                # it is outside the addressable success cache and is never reused.
                failed = cache / ("failed-batch-" + str(time.time_ns()))
                directory.rename(failed)
                raise
            for item in state:
                if not item["reused"]:
                    item["wav"].parent.rename(item["entry"])
                    item["wav"] = item["entry"] / "voice.wav"
        results = []
        for item in state:
            samples, rate = inspect_wave(item["wav"])
            output = Path(item["job"]["output"])
            atomic_copy(item["wav"], output)
            results.append(dict(voice=item["job"]["voice"], reused=item["reused"], key=item["key"],
                                sha256=digest(output), samples=samples, sample_rate=rate,
                                receipt=str(item["entry"] / "source.md"), listening_confirmed=False))
        return results


def worker(runtime: Path, text: str, jobs: list[dict]) -> None:
    # The private worker entry also verifies its own interpreter/environment;
    # invoking it directly is not an escape from the normal parent preflight.
    identity(runtime)
    import socket
    def no_network(*a, **kw):
        raise RuntimeError("本地音色设计禁止网络访问")
    socket.create_connection = no_network
    socket.socket.connect = no_network
    socket.socket.connect_ex = no_network
    import random
    import numpy as np
    import torch
    import soundfile as sf
    torch.set_num_threads(4)
    torch.set_num_interop_threads(1)
    from qwen_tts import Qwen3TTSModel
    model = Qwen3TTSModel.from_pretrained(str(runtime / "model"), device_map="cpu",
                                         dtype=torch.float32, attn_implementation="eager",
                                         local_files_only=True)
    if model.model.tts_model_type != "voice_design" or "chinese" not in (model.get_supported_languages() or []):
        raise ValueError("真实模型类型或语言不匹配，拒绝改用预设或克隆")
    for job in jobs:
        validate_request(text, job["voice"], job["instruction"], job["seed"])
        random.seed(job["seed"])
        np.random.seed(job["seed"])
        torch.manual_seed(job["seed"])
        # One complete original text per design; never six scene calls joined.
        wavs, rate = model.generate_voice_design(text=text, language="Chinese",
                                                instruct=job["instruction"], **GENERATION)
        if rate != RATE or len(wavs) != 1 or getattr(wavs[0], "ndim", None) != 1:
            raise ValueError("引擎没有返回一个完整原速单声道音源")
        audio = wavs[0]
        if not len(audio) or not np.isfinite(audio).all() or float(np.max(np.abs(audio))) >= 1:
            raise ValueError("引擎返回空音源、无效值或削波，不裁剪求通过")
        sf.write(str(job["output"]), audio, rate, subtype="PCM_16")
        inspect_wave(Path(job["output"]))
        print("generated=" + job["voice"], flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", required=True, type=Path)
    parser.add_argument("--seal-runtime", action="store_true", help="显式封存已准备的固定环境，不生成声音、不覆盖已有身份")
    parser.add_argument("--cache", type=Path)
    parser.add_argument("--text")
    parser.add_argument("--voice", action="append", choices=tuple(DESIGNS))
    parser.add_argument("--instruction", action="append", help="可省略；显式值必须逐项等于已编号设计")
    parser.add_argument("--seed", action="append", type=int)
    parser.add_argument("--output", action="append", type=Path)
    parser.add_argument("--engine", default=ENGINE)
    parser.add_argument("--language", default="Chinese")
    parser.add_argument("--deadline", type=int, default=10800)
    parser.add_argument("--worker", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    try:
        if args.seal_runtime:
            if any((args.cache, args.text, args.voice, args.instruction, args.seed, args.output, args.worker)):
                parser.error("封存环境不能同时提交生成")
            seal_runtime(args.runtime)
            print("固定本地环境已封存，尚未生成或批准任何声音")
            return 0
        if not args.voice or not args.text or not args.output or len(args.voice) != len(args.output):
            parser.error("正文、音色与对应输出必填，最多3个且数量相等")
        instructions = args.instruction if args.instruction is not None else [DESIGNS[v]["instruction"] for v in args.voice]
        seeds = args.seed if args.seed is not None else [1986] * len(args.voice)
        if len(instructions) != len(args.voice) or len(seeds) != len(args.voice):
            parser.error("显式instruction/seed须与音色逐项数量相等")
        jobs = [dict(voice=v, instruction=i, seed=s, output=o) for v, i, s, o in zip(args.voice, instructions, seeds, args.output)]
        for job in jobs:
            validate_request(args.text, job["voice"], job["instruction"], job["seed"], args.engine, args.language)
        if args.worker:
            worker(args.runtime, args.text, jobs)
        else:
            if not args.cache:
                parser.error("生成须指定--cache")
            for result in generate_batch(args.runtime, args.cache, args.text, jobs, args.deadline):
                print(result["voice"], "reused" if result["reused"] else "generated",
                      result["samples"], result["sample_rate"], result["sha256"], "listening=pending")
        return 0
    except (ValueError, OSError, EOFError, wave.Error, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
