#!/usr/bin/env python3
"""Explicit-network, original MP3 candidates from two Taiwanese ReadAloud voices.

This third-party consumer client is not the Azure Speech API. Results remain
pending listening and are not a commercial licence or a default-voice change.
"""
from __future__ import annotations

import argparse
import array
from contextlib import ExitStack
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unicodedata
import zipfile
from zoneinfo import ZoneInfo

ENGINE = "Microsoft Edge consumer ReadAloud via third-party edge-tts"
CLIENT_VERSION = "7.3.1"
WHEEL_NAME = "edge_tts-7.3.1-py3-none-any.whl"
WHEEL_BYTES = 38908
WHEEL_SHA256 = "2a3c79d6235a7a736d681233823ce5492e829b43eb47beae49aa181237a8f9a4"
LOCK = Path(__file__).with_name("readaloud-cpu-lock.txt")
VOICES = {"zh-TW-HsiaoChenNeural": "D · 台湾女声晓臻",
          "zh-TW-HsiaoYuNeural": "E · 台湾女声晓雨"}
CONFIG = dict(locale="zh-TW", gender="Female", rate="+0%", volume="+0%", pitch="+0Hz",
              codec="audio-24khz-48kbitrate-mono-mp3", segmentation="one-complete-request",
              remote_model_revision="unknown_not_exposed_by_service",
              seed="unknown_not_exposed_by_service", usage="private_noncommercial_audition_only")


class ReadAloudError(ValueError):
    """A bounded diagnostic code; never contains a URL, token or response body."""


def validate_rate(rate: str) -> str:
    """Accept canonical native speech-rate percentages, not audio processing."""
    if type(rate) is not str or not re.fullmatch(r"[+-](?:0|[1-9][0-9]{0,2})%", rate):
        raise ReadAloudError("语速须为带符号的规范整数百分比，范围-50%至+100%，默认+0%")
    value = int(rate[:-1])
    if not -50 <= value <= 100 or f"{value:+d}%" != rate:
        raise ReadAloudError("语速须为带符号的规范整数百分比，范围-50%至+100%，默认+0%")
    return rate


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def validate_request(text: str, voice: str) -> None:
    if (not isinstance(text, str) or not text.strip() or len(text) > 240
            or any(ord(c) < 32 or c in "<>|\u2028\u2029" for c in text)):
        raise ReadAloudError("正文须为1–240字的单段完整文字，不接受控制字符或SSML")
    if voice not in VOICES:
        raise ReadAloudError("只接受已核实的两个zh-TW女声，不接受人物、克隆或自定义声线")
    # edge-tts escapes text before its byte splitter. Even worst-case escaping
    # of 240 characters must remain one request, not an unnoticed sentence join.
    from xml.sax.saxutils import escape
    if len(escape(text).encode("utf-8")) > 4096:
        raise ReadAloudError("正文超过单请求上限，不拆句、不截尾")


def environment(network: bool) -> dict:
    result = {"PATH": "/usr/local/bin:/usr/bin:/bin", "LANG": "en_US.UTF-8",
              "PYTHONDONTWRITEBYTECODE": "1", "NETRC": os.devnull}
    if network:
        # Retain only existing transport routing; never log it, inspect secret
        # stores, or allow aiohttp's trust_env mode to read a user's .netrc.
        for name in ("HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "NO_PROXY",
                     "https_proxy", "http_proxy", "all_proxy", "no_proxy"):
            if name in os.environ:
                result[name] = os.environ[name]
    return result


def fixed_dependencies() -> dict:
    if LOCK.is_symlink() or not LOCK.is_file():
        raise ReadAloudError("固定依赖文件缺失或不是原件")
    versions = dict(re.findall(r"^([a-z0-9-]+)==([^\s\\]+)", LOCK.read_text(), re.M))
    if versions.get("edge-tts") != CLIENT_VERSION or len(versions) < 5:
        raise ReadAloudError("固定依赖清单无效")
    return versions


def tool_identity(path: Path) -> dict:
    if not path.is_file():
        raise ReadAloudError("音频检查工具不存在")
    r = subprocess.run([str(path), "-version"], capture_output=True, timeout=10,
                       env=environment(False))
    if r.returncode or not r.stdout or len(r.stdout) > 128 * 1024:
        raise ReadAloudError("音频检查工具版本查询失败")
    return dict(sha256=digest(path), version=r.stdout.decode("utf-8", "replace").splitlines()[0])


def runtime_identity(runtime: Path, ffmpeg: Path, ffprobe: Path) -> dict:
    """Verify the pinned wheel and involved dependencies, not an entire venv."""
    if runtime.is_symlink():
        raise ReadAloudError("运行目录不能是符号链接")
    runtime = runtime.resolve()
    wheel = runtime / "wheels" / WHEEL_NAME
    if (wheel.is_symlink() or not wheel.is_file() or wheel.stat().st_size != WHEEL_BYTES
            or digest(wheel) != WHEEL_SHA256):
        raise ReadAloudError("固定第三方客户端wheel原件身份不符")
    versions = fixed_dependencies()
    probe = r'''import hashlib, importlib.metadata as m, json, pathlib, platform, sys, sysconfig
def sha(p):
    h=hashlib.sha256()
    with p.open('rb') as f:
        for b in iter(lambda:f.read(1048576),b''): h.update(b)
    return h.hexdigest()
site=pathlib.Path(sysconfig.get_path('purelib')).resolve()
base=pathlib.Path(sys.prefix).resolve(); dependencies={}
for name, version in json.loads(sys.argv[1]).items():
    d=m.distribution(name)
    if d.version!=version or not d.files: raise ValueError('dependency_version_or_inventory')
    rows=[]
    for item in sorted(d.files,key=str):
        if '__pycache__' in item.parts or item.suffix=='.pyc' or item.name=='RECORD': continue
        p=d.locate_file(item)
        if p.is_symlink() or not p.is_file() or not p.resolve().is_relative_to(base):
            raise ValueError('dependency_payload')
        rows.append(str(item)+' '+str(p.stat().st_size)+' '+sha(p))
    dependencies[name]={'version':d.version,'payload_sha256':hashlib.sha256(('\n'.join(rows)+'\n').encode()).hexdigest(),'file_count':len(rows)}
print(json.dumps({'site':str(site),'python':sys.version.replace('\n',' '),'machine':platform.machine(),'dependencies':dependencies}))
'''
    result = subprocess.run([str(runtime / "venv/bin/python"), "-I", "-B", "-c", probe,
                             json.dumps(versions)], capture_output=True, timeout=30,
                            env=environment(False))
    if result.returncode or len(result.stdout) > 256 * 1024:
        raise ReadAloudError("隔离依赖版本或实际载荷核验失败")
    try:
        actual = json.loads(result.stdout)
        site = Path(actual.pop("site"))
        if not site.is_relative_to(runtime / "venv"):
            raise ValueError()
        with zipfile.ZipFile(wheel) as archive:
            names = [n for n in archive.namelist() if n.startswith("edge_tts/") and not n.endswith("/")]
            if not names or any(".." in Path(n).parts for n in names):
                raise ValueError()
            expected = {n: hashlib.sha256(archive.read(n)).hexdigest() for n in names}
        live = {p.relative_to(site).as_posix(): digest(p) for p in (site / "edge_tts").rglob("*")
                if p.is_file() and "__pycache__" not in p.parts and p.suffix != ".pyc"}
        if live != expected:
            raise ValueError()
    except (ValueError, KeyError, OSError, zipfile.BadZipFile):
        raise ReadAloudError("实际客户端源码与固定wheel不一致") from None
    return dict(client="edge-tts", client_version=CLIENT_VERSION, wheel_sha256=WHEEL_SHA256,
                wheel_bytes=WHEEL_BYTES, lock_sha256=digest(LOCK),
                adapter_sha256=digest(Path(__file__)), interpreter_sha256=digest(runtime / "venv/bin/python"),
                **actual, ffmpeg=tool_identity(ffmpeg), ffprobe=tool_identity(ffprobe))


def request_identity(identity: dict, text: str, voice: str, *, rate: str = "+0%",
                     word_boundaries: bool = False) -> tuple[dict, str]:
    validate_request(text, voice)
    rate = validate_rate(rate)
    if type(word_boundaries) is not bool:
        raise ReadAloudError("逐词边界选项须为布尔值")
    if identity.get("client_version") != CLIENT_VERSION or identity.get("wheel_sha256") != WHEEL_SHA256:
        raise ReadAloudError("请求客户端身份不符合固定原件")
    configuration = dict(CONFIG, rate=rate)
    if word_boundaries:
        configuration["boundary"] = "WordBoundary"
    request = dict(schema=1, engine=ENGINE, text=text, voice=voice, configuration=configuration,
                   runtime=identity)
    key = hashlib.sha256(json.dumps(request, sort_keys=True, ensure_ascii=False,
                                   separators=(",", ":")).encode()).hexdigest()
    return request, key


def inspect_mp3(path: Path, ffmpeg: Path, ffprobe: Path) -> dict:
    """Decode the entire original; never transcode, normalize or alter it."""
    if path.is_symlink() or not path.is_file() or not 64 <= path.stat().st_size <= 2 * 1024 * 1024:
        raise ReadAloudError("MP3原件为空、过大或不是普通原件")
    p = subprocess.run([str(ffprobe), "-v", "error", "-select_streams", "a",
                        "-show_entries", "stream=codec_name,sample_rate,channels,bit_rate:format=duration",
                        "-of", "json", str(path)], capture_output=True, timeout=15,
                       env=environment(False))
    try:
        if p.returncode or len(p.stdout) > 64 * 1024:
            raise ValueError()
        probe = json.loads(p.stdout)
        streams = probe["streams"]
        if (len(streams) != 1 or streams[0]["codec_name"] != "mp3"
                or int(streams[0]["sample_rate"]) != 24000 or streams[0]["channels"] != 1
                or int(streams[0]["bit_rate"]) != 48000):
            raise ValueError()
        duration = float(probe["format"]["duration"])
        if not math.isfinite(duration) or not 0.2 <= duration <= 90:
            raise ValueError()
    except (ValueError, KeyError, TypeError):
        raise ReadAloudError("原MP3格式、采样率、声道或实长不符") from None
    decoded = subprocess.run([str(ffmpeg), "-v", "error", "-xerror", "-i", str(path),
                              "-map", "0:a:0", "-vn", "-sn", "-dn", "-c:a", "pcm_f32le",
                              "-f", "f32le", "pipe:1"], capture_output=True, timeout=20,
                             env=environment(False))
    if decoded.returncode or not decoded.stdout or len(decoded.stdout) % 4 or len(decoded.stdout) > 90 * 24000 * 4:
        raise ReadAloudError("完整MP3解码失败、超长或返回残缺采样")
    values = array.array("f", decoded.stdout)
    if sys.byteorder != "little":
        values.byteswap()
    if not 0.2 <= len(values) / 24000 <= 90 or not all(math.isfinite(v) for v in values):
        raise ReadAloudError("解码采样无效或实长越界")
    peak = max(abs(v) for v in values)
    rms = math.sqrt(sum(v * v for v in values) / len(values))
    if rms <= 1 / 32768:
        raise ReadAloudError("MP3接近静音，不冒生成成功")
    # Lossy decode overshoot is reported, not silently clamped or called a
    # reliable measurement of clipping in an unavailable service-side master.
    return dict(samples=len(values), sample_rate=24000, channels=1, bitrate=48000,
                decoded_duration=len(values) / 24000, container_duration=duration,
                peak_float=peak, rms_float=rms, decoded_samples_at_or_above_one=sum(abs(v) >= 1 for v in values))


def flatten(value: dict, prefix: str = "") -> list[tuple[str, str]]:
    rows = []
    for name, item in sorted(value.items()):
        key = prefix + name
        rows += flatten(item, key + ".") if isinstance(item, dict) else [(key, str(item))]
    return rows


def spoken_text(text: str) -> str:
    """Only punctuation/space may be absent from SDK's spoken word text."""
    return "".join(c for c in text if not c.isspace() and unicodedata.category(c)[0] != "P")


def read_word_boundaries(path: Path, text: str, inspection: dict) -> list[dict]:
    """Read actual normal SDK JSONL; never estimate word timing from text."""
    if (path.is_symlink() or not path.is_file() or not 1 <= path.stat().st_size <= 512 * 1024):
        raise ReadAloudError("SDK逐词边界原件缺失、超大或不是普通文件")
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
        if not 1 <= len(lines) <= 2048 or any(not line for line in lines):
            raise ValueError()
        rows = [json.loads(line) for line in lines]
        previous_end = 0
        for row in rows:
            if (not isinstance(row, dict) or set(row) != {"type", "offset", "duration", "text"}
                    or row["type"] != "WordBoundary" or type(row["offset"]) is not int
                    or type(row["duration"]) is not int or row["offset"] < previous_end
                    or row["duration"] <= 0 or not isinstance(row["text"], str) or not row["text"]):
                raise ValueError()
            previous_end = row["offset"] + row["duration"]
        actual_duration = max(inspection["decoded_duration"], inspection["container_duration"])
        if (not math.isfinite(actual_duration) or previous_end / 10_000_000 > actual_duration + 1 / 24000
                or not spoken_text(text) or "".join(spoken_text(row["text"]) for row in rows) != spoken_text(text)):
            raise ValueError()
        return rows
    except (ValueError, KeyError, TypeError, UnicodeError):
        raise ReadAloudError("SDK逐词边界类型、原文覆盖、单调时间或实长校验失败；原件保留，不估算或重请求") from None


def boundary_summary(path: Path, text: str, inspection: dict) -> dict:
    rows = read_word_boundaries(path, text, inspection)
    return dict(format="edge_tts_sdk_jsonl_v1", sha256=digest(path), count=len(rows),
                ticks_per_second=10_000_000, text_coverage="exact_except_punctuation_and_space",
                first_offset=rows[0]["offset"], last_end=rows[-1]["offset"] + rows[-1]["duration"])


def receipt(request: dict, key: str, audio: Path, inspection: dict, generated_at: str,
            word_metadata: dict | None = None) -> str:
    instant = datetime.fromisoformat(generated_at)  # Original time, not cache-hit time.
    if instant.tzinfo is None:
        raise ReadAloudError("原始生成时间缺少时区")
    rows = ["# 台湾女声朗读试听原件", "", "技术检查通过；完整听审、文字核对、音色选择均待确认。",
            "第三方edge-tts调用Microsoft Edge消费者ReadAloud；不是Azure Speech正式API。",
            "仅供本地非商教学与管理员试听；服务可调用与客户端LGPLv3均不授予音频商用或平台发布权。",
            "未改默认；无名人模仿、克隆、后期变调、后期调速、拼句或转码。",
            "语速由服务按本次request.configuration.rate原生合成；原MP3保持服务返回字节。", "",
            "生成时间（北京时间）：" + instant.astimezone(ZoneInfo("Asia/Shanghai")).isoformat(timespec="seconds"),
            "生成时间（UTC）：" + generated_at, "", "|字段|值|", "|---|---|"]
    fields = dict(request=request, cache_key=key, audio_sha256=digest(audio), inspection=inspection,
                  listening_confirmed=False, commercial_allowed=False, upload_consent=False)
    if word_metadata is not None:
        fields["word_boundaries"] = word_metadata
    rows += [f"|{name}|{value}|" for name, value in flatten(fields)]
    rows += ["", "来源：[edge-tts](https://github.com/rany2/edge-tts)；",
             "[官方ReadAloud说明](https://support.microsoft.com/en-us/accessibility/edge/accessibility-features-in-microsoft-edge)。", ""]
    return "\n".join(rows)


def atomic_copy(source: Path, output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=".readaloud-", dir=output.parent)
    temporary = Path(name)
    try:
        with source.open("rb") as f, os.fdopen(fd, "wb") as target:
            shutil.copyfileobj(f, target)
            target.flush()
            os.fsync(target.fileno())
        os.link(temporary, output)  # Atomic publication, including concurrent no-overwrite.
    finally:
        temporary.unlink(missing_ok=True)


def stop_process(process: subprocess.Popen) -> None:
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=3)


def run_worker(runtime: Path, text: str, voice: str, output: Path, deadline: int, log: Path,
               *, rate: str = "+0%", word_boundaries: bool = False) -> None:
    rate = validate_rate(rate)
    command = [str(runtime / "venv/bin/python"), "-I", "-B", str(Path(__file__).resolve()),
               "--worker", "--allow-network", "--runtime", str(runtime), "--text", text,
               "--voice", voice, "--output", str(output), "--deadline", str(deadline), "--rate=" + rate]
    if word_boundaries:
        command.append("--word-boundaries")
    with log.open("xb") as f:
        process = subprocess.Popen(command, env=environment(True), stdout=f, stderr=f, start_new_session=True)
        try:
            code = process.wait(timeout=deadline)
        except BaseException as error:
            stop_process(process)
            if isinstance(error, subprocess.TimeoutExpired):
                raise ReadAloudError("网络合成超时，失败原件保留；未回退或批准声音") from None
            raise
    if code:
        raise ReadAloudError("网络合成失败；已保留脱敏过程记录与实际返回原件")


def generate_batch(runtime: Path, cache: Path, text: str, jobs: list[dict], ffmpeg: Path,
                   ffprobe: Path, *, allow_network: bool = False, deadline: int = 120,
                   rate: str = "+0%", word_boundaries: bool = False) -> list[dict]:
    rate = validate_rate(rate)
    if type(word_boundaries) is not bool:
        raise ReadAloudError("逐词边界选项须为布尔值")
    if not 1 <= len(jobs) <= 2 or type(deadline) is not int or not 10 <= deadline <= 300:
        raise ReadAloudError("每批1–2个不同女声，每声网络期限须为10–300秒")
    outputs, voices = set(), set()
    for job in jobs:
        if set(job) != {"voice", "output"}:
            raise ReadAloudError("未知或缺失作业字段")
        validate_request(text, job["voice"])
        output = Path(os.path.abspath(job["output"]))
        if output.suffix.lower() != ".mp3" or output in outputs or job["voice"] in voices:
            raise ReadAloudError("每声使用不同的原MP3输出，不重复音色或伪装文件格式")
        if any(p.exists() or p.is_symlink() for p in (output, output.with_suffix(".source.md"))):
            raise ReadAloudError("原音或来源输出已存在，不覆盖")
        outputs.add(output)
        voices.add(job["voice"])
    if runtime.is_symlink() or cache.is_symlink():
        raise ReadAloudError("运行和缓存目录不接受符号链接")
    runtime, cache = runtime.resolve(), cache.resolve()
    identity = runtime_identity(runtime, ffmpeg, ffprobe)
    cache.mkdir(parents=True, exist_ok=True)
    with ExitStack() as stack:
        staging = Path(stack.enter_context(tempfile.TemporaryDirectory(prefix="readaloud-", dir=cache)))
        states = []
        for index, job in enumerate(jobs):
            request, key = request_identity(identity, text, job["voice"], rate=rate,
                                            word_boundaries=word_boundaries)
            lock = cache / (key + ".lock")
            try:
                lock.mkdir()
            except FileExistsError:
                raise ReadAloudError("相同请求正在处理，不重复提交") from None
            stack.callback(lock.rmdir)
            entry = cache / key
            reused = entry.exists() or entry.is_symlink()
            if reused:
                audio, source = entry / "voice.mp3", entry / "source.md"
                if entry.is_symlink() or source.is_symlink() or not source.is_file():
                    raise ReadAloudError("缓存来源缺失或不是原件")
                inspection = inspect_mp3(audio, ffmpeg, ffprobe)
                original = source.read_text()
                stamps = [s.removeprefix("生成时间（UTC）：") for s in original.splitlines() if s.startswith("生成时间（UTC）：")]
                if len(stamps) != 1 or (not word_boundaries
                        and original != receipt(request, key, audio, inspection, stamps[0])):
                    raise ReadAloudError("缓存原音、来源或请求身份不符，不静默重生")
            else:
                if word_boundaries and any(cache.glob("failed-batch-*/" + key + ".request")):
                    raise ReadAloudError("相同逐词请求已有失败或部分原件；先检查原批次，不自动重复提交")
                directory = staging / str(index)
                directory.mkdir()
                audio, source = directory / "voice.mp3", directory / "source.md"
            metadata = audio.with_name("word-boundaries.jsonl") if word_boundaries else None
            word_metadata = boundary_summary(metadata, text, inspection) if reused and word_boundaries else None
            if reused and word_boundaries:
                if original != receipt(request, key, audio, inspection, stamps[0], word_metadata):
                    raise ReadAloudError("缓存逐词边界或来源身份不符，不静默重生")
            states.append(dict(job=job, request=request, key=key, entry=entry, audio=audio,
                               source=source, metadata=metadata, word_metadata=word_metadata, reused=reused))
        if any(not s["reused"] for s in states):
            if not allow_network:
                raise ReadAloudError("缺少显式--allow-network；未上传正文或提交网络合成")
            lock = runtime / "generation.lock"
            try:
                lock.mkdir()
            except FileExistsError:
                raise ReadAloudError("此运行目录已有网络批次，等待原作业") from None
            stack.callback(lock.rmdir)
            logs = runtime / "logs"
            logs.mkdir(exist_ok=True)
            try:
                for state in states:
                    if state["reused"]:
                        continue
                    stamp = datetime.now(timezone.utc).isoformat()
                    if word_boundaries:
                        (staging / (state["key"] + ".request")).write_text(state["key"] + "\n")
                    options = dict(rate=rate)
                    if word_boundaries:
                        options["word_boundaries"] = True
                    run_worker(runtime, text, state["job"]["voice"], state["audio"], deadline,
                               logs / ("readaloud-" + str(time.time_ns()) + ".log"), **options)
                    inspection = inspect_mp3(state["audio"], ffmpeg, ffprobe)
                    if word_boundaries:
                        state["word_metadata"] = boundary_summary(state["metadata"], text, inspection)
                    state["source"].write_text(receipt(state["request"], state["key"], state["audio"],
                                                       inspection, stamp, state["word_metadata"]))
                if runtime_identity(runtime, ffmpeg, ffprobe) != identity:
                    raise ReadAloudError("生成期间客户端或依赖身份改变，不缓存或交付")
            except BaseException as error:
                (staging / "failure.md").write_text("# 失败批次\n\n错误类别：" + type(error).__name__ +
                                                   "\n返回的原始/部分MP3仅保全，不作为成功缓存或交付。\n")
                staging.rename(cache / ("failed-batch-" + str(time.time_ns())))
                raise
            # Promote only after every new original has passed full decoding.
            for state in states:
                if not state["reused"]:
                    state["audio"].parent.rename(state["entry"])
                    state["audio"] = state["entry"] / "voice.mp3"
                    state["source"] = state["entry"] / "source.md"
                    if word_boundaries:
                        state["metadata"] = state["entry"] / "word-boundaries.jsonl"
        results = []
        for state in states:
            output = Path(state["job"]["output"])
            atomic_copy(state["audio"], output)
            atomic_copy(state["source"], output.with_suffix(".source.md"))
            results.append(dict(voice=state["job"]["voice"], rate=rate, reused=state["reused"], key=state["key"],
                                sha256=digest(output), bytes=output.stat().st_size,
                                receipt=str(output.with_suffix(".source.md")), listening_confirmed=False,
                                commercial_allowed=False, upload_consent=False))
            if word_boundaries:
                results[-1].update(word_boundaries_path=str(state["metadata"]),
                    word_boundaries_sha256=state["word_metadata"]["sha256"],
                    word_boundaries_count=state["word_metadata"]["count"])
        return results


def worker(text: str, voice: str, output: Path, deadline: int, *, rate: str = "+0%",
           word_boundaries: bool = False) -> None:
    validate_request(text, voice)
    rate = validate_rate(rate)
    metadata = output.with_name("word-boundaries.jsonl") if word_boundaries else None
    if output.exists() or output.is_symlink() or (metadata is not None and (metadata.exists() or metadata.is_symlink())):
        raise ReadAloudError("worker原音输出已存在")
    import asyncio
    import edge_tts
    import importlib.metadata
    if importlib.metadata.version("edge-tts") != CLIENT_VERSION:
        raise ReadAloudError("worker客户端版本不符")
    async def synthesize():
        options = {"boundary": "WordBoundary"} if word_boundaries else {}
        client = edge_tts.Communicate(text=text, voice=voice, rate=rate,
                                     volume=CONFIG["volume"], pitch=CONFIG["pitch"],
                                     connect_timeout=10, receive_timeout=min(60, deadline - 2), **options)
        saving = client.save(str(output), str(metadata)) if word_boundaries else client.save(str(output))
        await asyncio.wait_for(saving, timeout=deadline - 1)
    asyncio.run(synthesize())


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", required=True, type=Path)
    parser.add_argument("--cache", type=Path)
    parser.add_argument("--text", required=True)
    parser.add_argument("--voice", required=True, action="append", choices=tuple(VOICES))
    parser.add_argument("--output", required=True, action="append", type=Path)
    parser.add_argument("--ffmpeg", type=Path, default=shutil.which("ffmpeg"))
    parser.add_argument("--ffprobe", type=Path, default=shutil.which("ffprobe"))
    parser.add_argument("--allow-network", action="store_true", help="允许把本次完整正文传给在线消费者朗读服务")
    parser.add_argument("--deadline", type=int, default=120)
    parser.add_argument("--rate", default="+0%",
                        help="服务原生语速，规范整数百分比-50%%至+100%%，默认+0%%；不是后期变速")
    parser.add_argument("--worker", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--word-boundaries", action="store_true", help="同一次SDK流保留真实逐词边界于缓存，供字幕读取")
    args = parser.parse_args()
    try:
        if len(args.voice) != len(args.output) or not 1 <= len(args.voice) <= 2:
            raise ReadAloudError("音色和原MP3输出须逐项对应，每批1–2项")
        if args.worker:
            if not args.allow_network or len(args.voice) != 1 or not 10 <= args.deadline <= 300:
                raise ReadAloudError("worker须是明确授权的单声有界网络调用")
            options = {"word_boundaries": True} if args.word_boundaries else {}
            worker(args.text, args.voice[0], args.output[0], args.deadline, rate=args.rate, **options)
        else:
            if not args.cache or not args.ffmpeg or not args.ffprobe:
                raise ReadAloudError("须指定缓存与可用ffmpeg/ffprobe检查工具")
            results = generate_batch(args.runtime, args.cache, args.text,
                                     [dict(voice=v, output=o) for v, o in zip(args.voice, args.output)],
                                     Path(args.ffmpeg).resolve(), Path(args.ffprobe).resolve(),
                                     allow_network=args.allow_network, deadline=args.deadline, rate=args.rate,
                                     word_boundaries=args.word_boundaries)
            for result in results:
                print(result["voice"], "rate=" + result["rate"], "reused" if result["reused"] else "generated",
                      result["bytes"], result["sha256"], "listening=pending commercial=false upload=false")
        return 0
    except ReadAloudError as error:
        print(str(error), file=sys.stderr)
        return 2
    except Exception as error:
        # SDK exceptions may embed its full service URL and public client token.
        # Neither stdout, logs, source receipts nor callers receive that text.
        status = getattr(error, "status", None)
        suffix = "; HTTP=" + str(status) if type(status) is int and 100 <= status <= 599 else ""
        print("朗读操作失败：" + type(error).__name__ + suffix, file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
