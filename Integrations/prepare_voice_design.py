#!/usr/bin/env python3
"""Prepare the pinned Intel VoiceDesign runtime in an explicitly selected cache.

Environment installation, public model recovery and sealing are separate bounded
stages. This entry never loads a model, synthesizes speech or approves a voice.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unicodedata
import urllib.parse
import urllib.request

import voice_design_tts as tts


LOCK = Path(__file__).with_name("voice-design-cpu-lock.txt")
LOCK_SHA256 = "3d0f9e64ed711773f2c29562ae3fb64f4e9dabf52b5aaf4801b22a543cb04894"
PYTHON_VERSION = "3.10.16"
STAGES = ("environment", "model", "seal", "verify")
OFFLINE_DIRECTORIES = ("temp", "hf", "xdg", "torch", "numba")
MINIMUM_FREE_BYTES = 10 * 1024**3
ENVIRONMENT_PEAK_ALLOWANCE = 3 * 1024**3
SOX_SOURCE = ("https://files.pythonhosted.org/packages/3d/a2/d8e0d8fd7abf509ead4a2cb0fb24e5758b5330166bf9223d5cb9f98a7e8d/sox-1.5.0.tar.gz",
              63905, "12c7be5bb1f548d891fe11e82c08cf5f1a1d74e225298f60082e5aeb2469ada0")
BUILD_CONSTRAINTS = "setuptools==70.0.0\nwheel==0.46.3\nnumpy==1.26.4\npackaging==26.3\n"


class PreparationTimeout(ValueError):
    pass


class Budget:
    def __init__(self, seconds: int):
        if type(seconds) is not int or not 5 <= seconds <= 840:
            raise ValueError("准备阶段期限须为5–840秒")
        self.end = time.monotonic() + seconds

    def remaining(self) -> float:
        seconds = self.end - time.monotonic()
        if seconds <= 0:
            raise PreparationTimeout("准备阶段超时，未完成原件和诊断保留，不计准备成功")
        return seconds


@contextmanager
def deadline(seconds: int):
    """A process-local timer also bounds blocking public reads and hashing."""
    budget = Budget(seconds)
    if signal.getitimer(signal.ITIMER_REAL)[0]:
        raise ValueError("调用进程已有定时器，请在独立有限准备进程中运行")
    previous = signal.getsignal(signal.SIGALRM)

    def expired(*_):
        raise PreparationTimeout("准备阶段超时，未完成原件和诊断保留，不计准备成功")

    signal.signal(signal.SIGALRM, expired)
    signal.setitimer(signal.ITIMER_REAL, seconds)
    try:
        yield budget
        budget.remaining()
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)


def ordinary_path(path: Path, *, directory: bool = False) -> None:
    """Reject links in a caller-selected cache path and its existing parents."""
    if not path.is_absolute() or ".." in path.parts:
        raise ValueError("缓存路径须规范且不含上级跳转")
    for component in (path, *path.parents):
        if component.is_symlink():
            raise ValueError("缓存和模型路径不接受符号链接")
    if path.exists():
        mode = path.stat().st_mode
        if not (stat.S_ISDIR(mode) if directory else stat.S_ISREG(mode)):
            raise ValueError("缓存路径类型不符")
        if not directory and path.stat().st_nlink != 1:
            raise ValueError("模型原件和部分下载不接受硬链接")


def fixed_lock() -> dict[str, str]:
    ordinary_path(LOCK.absolute())
    if tts.digest(LOCK) != LOCK_SHA256:
        raise ValueError("固定91项依赖原件身份不符")
    rows = LOCK.read_text(encoding="utf-8").splitlines()
    if len(rows) != 91 or any(not re.fullmatch(r"[a-z0-9.-]+==[A-Za-z0-9.+!-]+", row) for row in rows):
        raise ValueError("固定依赖须为91行精确name==version，不接受额外源或选项")
    result = dict(row.split("==", 1) for row in rows)
    if len(result) != len(rows) or any(result.get(k) != v for k, v in tts.DIRECT_DEPENDENCIES.items()):
        raise ValueError("固定依赖重复或与当前VoiceDesign目标不符")
    return result


def preparation_environment(root: Path) -> dict[str, str]:
    for relative in (*OFFLINE_DIRECTORIES, "uv-cache"):
        selected = root / relative
        ordinary_path(selected, directory=True)
        selected.mkdir(exist_ok=True)
    return {**tts.offline_environment(root), "UV_CACHE_DIR": str(root / "uv-cache"),
            "UV_PYTHON_DOWNLOADS": "never", "UV_KEYRING_PROVIDER": "disabled",
            "UV_NO_CONFIG": "1", "UV_NO_PROGRESS": "1", "UV_CONCURRENT_DOWNLOADS": "1",
            "UV_CONCURRENT_BUILDS": "1", "GRADIO_ANALYTICS_ENABLED": "false"}


def run_owned(args: list[str], root: Path, budget: Budget, label: str,
              *, capture: bool = False, readonly: bool = False) -> bytes:
    """Wait for and, on failure/timeout, clean up only this child process group."""
    if readonly:
        for relative in OFFLINE_DIRECTORIES:
            selected = root / relative
            ordinary_path(selected, directory=True)
            if not selected.is_dir():
                raise ValueError("封存环境缺少既有缓存目录，不在校验时重建")
        # Sealed runtime verification does not create a permanent preparation log.
        output = tempfile.TemporaryFile(dir=root / "temp")
    else:
        logs = root / "preparation-logs"
        ordinary_path(logs, directory=True)
        logs.mkdir(exist_ok=True)
        output = (logs / (label + "-" + str(time.time_ns()) + ".log")).open("xb+")
    with output:
        if readonly:
            env = {**tts.offline_environment(root), "GRADIO_ANALYTICS_ENABLED": "false"}
        else:
            env = preparation_environment(root)
        process = subprocess.Popen(args, env=env, stdout=output, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        try:
            code = process.wait(timeout=budget.remaining())
            budget.remaining()
            if code:
                raise ValueError("准备子阶段失败：" + label + "；原诊断留在所选缓存，未自动回退")
        except BaseException:
            signal.setitimer(signal.ITIMER_REAL, 0)
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
            raise
        if capture:
            output.flush()
            if output.tell() > 65536:
                raise ValueError("环境身份回执超限")
            output.seek(0)
            return output.read()
    return b""


PROBE = """import importlib.metadata as m,json,platform,sys
print(json.dumps(dict(python=platform.python_version(),platform=sys.platform,machine=platform.machine(),
                     packages=sorted((d.metadata['Name'].lower().replace('_','-'),d.version) for d in m.distributions()))))
"""


def environment_state(executable: Path, root: Path, budget: Budget, *, complete: bool,
                      readonly: bool = False, empty: bool = False) -> dict:
    data = run_owned([str(executable), "-I", "-B", "-c", PROBE], root, budget, "environment-state",
                     capture=True, readonly=readonly)
    try:
        state = json.loads(data)
        pairs = state["packages"]
        if not isinstance(state, dict) or not isinstance(pairs, list) or any(
                not isinstance(pair, list) or len(pair) != 2 or not all(isinstance(value, str) for value in pair)
                or not re.fullmatch(r"[a-z0-9.-]+", pair[0]) for pair in pairs):
            raise ValueError("环境依赖回执结构不符")
        actual = dict(pairs)
    except (ValueError, TypeError, KeyError):
        raise ValueError("环境身份回执不完整") from None
    if (set(state) != {"python", "platform", "machine", "packages"}
            or state["python"] != PYTHON_VERSION or state["platform"] != "darwin" or state["machine"] != "x86_64"):
        raise ValueError("仅支持已验证的CPython3.10.16、Darwin x86_64，不自动换解释器或平台")
    expected = fixed_lock()
    if len(actual) != len(pairs) or any(expected.get(k) != v for k, v in actual.items()):
        raise ValueError("已有环境含冲突版本、重复或未固定依赖，不自动改动")
    if complete and actual != expected or empty and actual:
        raise ValueError("实际环境尚未严格匹配完整91项固定依赖")
    return state


def executable_path(path: Path | None) -> Path:
    if path is None or not path.is_absolute():
        raise ValueError("环境准备须显式指定绝对解释器和uv路径")
    selected = path.resolve(strict=True)
    if not selected.is_file() or not os.access(selected, os.X_OK):
        raise ValueError("指定的准备工具不可执行")
    return selected


def fixed_preparation_text(path: Path, value: str) -> None:
    ordinary_path(path)
    if path.exists():
        if path.read_text(encoding="utf-8") != value:
            raise ValueError("既有准备清单与固定原件冲突，不覆盖")
    else:
        tts.atomic_copy_text(value, path)


def prepare_environment(root: Path, budget: Budget, python: Path, uv: Path) -> None:
    python, uv = executable_path(python), executable_path(uv)
    # The caller's interpreter may contain unrelated packages; only its native
    # Python/platform identity is used to create a separate, initially empty venv.
    base = run_owned([str(python), "-I", "-B", "-c",
                      "import json,platform,sys;print(json.dumps([platform.python_version(),sys.platform,platform.machine()]))"],
                     root, budget, "base-python", capture=True)
    if json.loads(base) != [PYTHON_VERSION, "darwin", "x86_64"]:
        raise ValueError("指定基础解释器不是已验证的CPython3.10.16 Darwin x86_64")
    venv = root / "venv"
    ordinary_path(venv, directory=True)
    if not venv.exists():
        run_owned([str(uv), "venv", "--python", str(python), "--no-config", str(venv)],
                  root, budget, "create-environment")
        environment_state(venv / "bin/python", root, budget, complete=False, empty=True)
    else:
        environment_state(venv / "bin/python", root, budget, complete=False)
    # PyPI sox==1.5.0 has only the fixed 63,905-byte sdist. All other runtime
    # packages remain binary-only. This one reviewed source build does not change
    # the complete 91 installed dependency versions or permit arbitrary sdists.
    binary_lock = root / "runtime-binary-lock.txt"
    fixed_preparation_text(binary_lock, "".join(row + "\n" for row in LOCK.read_text().splitlines()
                                                if row != "sox==1.5.0"))
    run_owned([str(uv), "pip", "install", "--python", str(venv / "bin/python"), "--no-config",
               "--index-url", "https://pypi.org/simple", "--no-deps", "--only-binary", ":all:",
               "--requirement", str(binary_lock)], root, budget, "install-fixed-environment")
    source = root / "sources/sox-1.5.0.tar.gz"
    source.parent.mkdir(exist_ok=True)
    url, size, expected = SOX_SOURCE
    recover_original(root, source, url, size, expected, budget)
    constraints = root / "build-constraints.txt"
    fixed_preparation_text(constraints, BUILD_CONSTRAINTS)
    run_owned([str(uv), "pip", "install", "--python", str(venv / "bin/python"), "--no-config",
               "--index-url", "https://pypi.org/simple", "--no-deps", "--build-constraints", str(constraints),
               str(source)], root, budget, "install-fixed-sox")
    environment_state(venv / "bin/python", root, budget, complete=True)
    imports = """import socket
def deny(*a,**kw): raise RuntimeError('VoiceDesign preparation import is offline')
socket.create_connection=deny;socket.socket.connect=deny;socket.socket.connect_ex=deny
import torch,torchaudio,numpy,transformers,accelerate,numba,llvmlite
from qwen_tts import Qwen3TTSModel
print('fixed imports passed; no model loaded')
"""
    run_owned([str(venv / "bin/python"), "-I", "-B", "-c", imports], root, budget, "import-fixed-environment")


class HTTPSRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, url):
        if not url.startswith("https://"):
            raise ValueError("固定公共模型不接受非HTTPS重定向")
        return super().redirect_request(request, fp, code, message, headers, url)


def validate_public_route(value: str) -> str:
    if (not isinstance(value, str) or not value or len(value.encode("utf-8")) > 2048
            or any(character.isspace() or unicodedata.category(character).startswith("C") for character in value)):
        raise ValueError("公共路由须为不含空白或控制字符的有界无账号URL")
    try:
        route = urllib.parse.urlsplit(value)
        port = route.port
        if (route.scheme not in ("http", "https") or not route.hostname or not route.netloc
                or route.username is not None or route.password is not None
                or route.path not in ("", "/") or route.query or route.fragment
                or route.netloc.endswith(":") or "%" in route.netloc or (port is not None and not 1 <= port <= 65535)):
            raise ValueError("公共路由URL不符合无账号HTTP(S)主机及端口格式")
    except ValueError:
        # Never echo a rejected value, even when it contains credentials.
        raise ValueError("公共路由URL不符合无账号HTTP(S)主机及端口格式") from None
    return value


def read_public_route(path: Path) -> str:
    selected = path.absolute()
    ordinary_path(selected)
    if not selected.is_file() or not 0 < selected.stat().st_size <= 2048:
        raise ValueError("公共路由文件须为1–2048字节普通原件")
    with selected.open("rb") as source:
        data = source.read(2049)
    if not 0 < len(data) <= 2048:
        raise ValueError("公共路由文件大小变化或超限")
    try:
        value = data.decode("utf-8")
    except UnicodeError:
        raise ValueError("公共路由文件须为有效UTF-8") from None
    return validate_public_route(value)


def public_open(request: urllib.request.Request, timeout: float, *, public_route: str | None = None):
    # Default is direct. A route is explicit, account-free and never obtained
    # from proxy environment variables, netrc or a service credential.
    proxies = {} if public_route is None else {"https": validate_public_route(public_route)}
    opener = urllib.request.build_opener(urllib.request.ProxyHandler(proxies), HTTPSRedirect())
    return opener.open(request, timeout=timeout)


def model_layout(root: Path, *, complete: bool = False) -> None:
    model = root / "model"
    ordinary_path(model, directory=True)
    if not model.exists():
        if complete:
            raise ValueError("固定模型目录缺失")
        return
    directories = {parent.as_posix() for name in tts.MODEL_FILES for parent in Path(name).parents if parent.parts}
    found = set()
    for path in model.rglob("*"):
        relative = path.relative_to(model).as_posix()
        ordinary_path(path, directory=path.is_dir())
        if path.is_dir():
            if relative not in directories:
                raise ValueError("固定模型含额外目录")
        elif relative in tts.MODEL_FILES:
            found.add(relative)
        elif not complete and relative.endswith(".part") and relative[:-5] in tts.MODEL_FILES:
            continue
        else:
            raise ValueError("固定模型含额外原件或未完成下载")
    if complete and found != set(tts.MODEL_FILES):
        raise ValueError("固定12件模型原件不完整")


def recover_file(root: Path, name: str, budget: Budget, *, public_route: str | None = None) -> None:
    if name not in tts.MODEL_FILES:
        raise ValueError("未知固定模型原件")
    size, expected = tts.MODEL_FILES[name]
    target = root / "model" / name
    url = f"https://huggingface.co/{tts.ENGINE}/resolve/{tts.MODEL_REVISION}/{name}"
    recover_original(root, target, url, size, expected, budget, public_route=public_route)


def recover_original(root: Path, target: Path, url: str, size: int, expected: str, budget: Budget,
                     *, public_route: str | None = None) -> None:
    """Recover only an internally selected fixed model or reviewed sox original."""
    part = target.with_name(target.name + ".part")
    ordinary_path(target)
    ordinary_path(part)
    if target.exists():
        if part.exists() or target.stat().st_size != size or tts.digest(target) != expected:
            raise ValueError("已有模型原件身份冲突，不覆盖或重新下载")
        budget.remaining()
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    offset = part.stat().st_size if part.exists() else 0
    if offset > size:
        raise ValueError("未完成下载大小超过固定原件，不截断或覆盖")
    if offset < size:
        if shutil.disk_usage(root).free < size - offset + MINIMUM_FREE_BYTES:
            raise ValueError("固定原件恢复空间不足，请先释放闲置缓存")
        headers = {"User-Agent": "Video-fixed-VoiceDesign-preparation"}
        if offset:
            headers["Range"] = f"bytes={offset}-"
        request = urllib.request.Request(url, headers=headers)
        with public_open(request, timeout=min(30, budget.remaining()), public_route=public_route) as response:
            status = response.status
            expected_status = 206 if offset else 200
            content_range = response.headers.get("Content-Range")
            length = response.headers.get("Content-Length")
            if status != expected_status or (offset and content_range != f"bytes {offset}-{size - 1}/{size}"):
                raise ValueError("公共下载没有严格续接当前部分原件，不追加响应")
            if not offset and content_range is not None:
                raise ValueError("完整公共原件响应错误地带有分段范围")
            if length is not None and (not length.isdecimal() or int(length) != size - offset):
                raise ValueError("公共响应长度与固定原件不符，不追加响应")
            with part.open("ab" if part.exists() else "xb") as stream:
                while True:
                    budget.remaining()
                    block = response.read(min(1024 * 1024, size - offset + 1))
                    budget.remaining()
                    if not block:
                        break
                    if offset + len(block) > size:
                        raise ValueError("公共响应超出固定原件大小")
                    stream.write(block)
                    offset += len(block)
                stream.flush()
                os.fsync(stream.fileno())
    if offset != size or tts.digest(part) != expected:
        raise ValueError("完整模型大小或SHA256不符，部分原件保留且不提升")
    budget.remaining()
    os.link(part, target)  # Refuse even a concurrent destination overwrite.
    part.unlink()


def verify_or_seal(root: Path, budget: Budget, *, seal: bool) -> None:
    model_layout(root, complete=True)
    environment_state(root / "venv/bin/python", root, budget, complete=True, readonly=not seal)
    adapter = Path(tts.__file__).resolve()
    if seal:
        args = [sys.executable, "-I", "-B", str(adapter), "--runtime", str(root), "--seal-runtime"]
    else:
        code = "import runpy,sys;runpy.run_path(sys.argv[1])['identity'](__import__('pathlib').Path(sys.argv[2]));print('fixed runtime verified; no model loaded')"
        args = [sys.executable, "-I", "-B", "-c", code, str(adapter), str(root)]
    run_owned(args, root, budget, "seal-runtime" if seal else "verify-runtime", readonly=not seal)


def space_preflight(root: Path, stage: str, files: list[str] | None) -> None:
    if stage not in ("environment", "model"):
        return
    model_layout(root)
    selected = list(tts.MODEL_FILES) if stage == "environment" or files is None else files
    remaining = 0
    for name in selected:
        size, _ = tts.MODEL_FILES[name]
        target = root / "model" / name
        part = target.with_name(target.name + ".part")
        ordinary_path(target)
        ordinary_path(part)
        if not target.exists():
            existing = part.stat().st_size if part.exists() else 0
            if existing > size:
                raise ValueError("未完成下载大小超过固定原件")
            remaining += size - existing
    # The planning allowance covers the isolated environment, its downloaded
    # wheels/build cache and temporary extraction together; it is not a measured
    # installed size. Model downloads append in place, without a second weight copy.
    required = MINIMUM_FREE_BYTES + remaining + (ENVIRONMENT_PEAK_ALLOWANCE if stage == "environment" else 0)
    existing_root = root
    while not existing_root.exists():
        existing_root = existing_root.parent
    if shutil.disk_usage(existing_root).free < required:
        raise ValueError("准备空间不足：须保留10GiB，并预留固定原件余量和环境/下载临时空间；未开始安装或下载")


def prepare(runtime: Path, stage: str, seconds: int = 840, *, python: Path | None = None,
            uv: Path | None = None, files: list[str] | None = None,
            public_route_file: Path | None = None) -> str:
    if stage not in STAGES or (stage != "environment" and (python is not None or uv is not None)):
        raise ValueError("准备工具参数与阶段不符")
    if stage == "environment" and (python is None or uv is None):
        raise ValueError("环境阶段须显式指定解释器和uv")
    if public_route_file is not None and stage != "model":
        raise ValueError("公共路由文件仅用于model阶段，不影响环境安装、封存或校验")
    if files is not None and (stage != "model" or not files or len(files) != len(set(files))
                              or any(name not in tts.MODEL_FILES for name in files)):
        raise ValueError("模型阶段仅接受不重复的固定原件名称")
    if sys.platform != "darwin" or platform.machine() != "x86_64":
        raise ValueError("仅支持已验证的Darwin x86_64准备宿主")
    root = runtime.absolute()
    ordinary_path(root, directory=True)
    fixed_lock()
    if stage == "verify" and not root.is_dir():
        raise ValueError("校验目录不存在，不创建运行环境")
    identity = root / "identity.txt"
    if stage != "verify" and (identity.exists() or identity.is_symlink()):
        raise ValueError("运行环境已封存，不修改依赖、模型或身份；只能verify或选择新缓存")
    if (root / "inference.lock").exists() or (root / "inference.lock").is_symlink():
        raise ValueError("所选运行环境正在生成，等待原作业，不并发准备")
    with deadline(seconds) as budget:
        public_route = read_public_route(public_route_file) if public_route_file is not None else None
        if stage == "verify":
            if (root / "preparation.lock").exists() or (root / "preparation.lock").is_symlink():
                raise ValueError("所选运行环境正在准备，不并发校验")
            verify_or_seal(root, budget, seal=False)
            return "固定运行环境身份校验通过；未加载模型、未生成或批准声音"
        space_preflight(root, stage, files)
        root.mkdir(parents=True, exist_ok=True)
        lock = root / "preparation.lock"
        try:
            lock.mkdir()
        except FileExistsError:
            raise ValueError("所选运行环境正在准备，等待原阶段，不重复提交") from None
        try:
            # Recheck after acquiring the exclusive preparation lease.
            if identity.exists() or identity.is_symlink():
                raise ValueError("运行环境已封存，不修改原件")
            if stage == "environment":
                prepare_environment(root, budget, python, uv)
                return "固定91项环境及离线导入检查通过；尚未封存、未加载模型"
            if stage == "model":
                model_layout(root)
                selected = files if files is not None else list(tts.MODEL_FILES)
                for name in selected:
                    recover_file(root, name, budget, public_route=public_route)
                model_layout(root)
                return f"本阶段{len(selected)}件固定原件校验通过；须完整12件及环境通过后另行seal"
            verify_or_seal(root, budget, seal=True)
            return "固定运行环境已显式封存；未加载模型、未生成或批准声音"
        finally:
            lock.rmdir()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--stage", choices=STAGES, required=True)
    parser.add_argument("--deadline", type=int, default=840)
    parser.add_argument("--python", type=Path)
    parser.add_argument("--uv", type=Path)
    parser.add_argument("--public-route-file", type=Path, help="仅model可选的普通无账号路由文件；默认直连，不读取隐式环境代理")
    parser.add_argument("--file", action="append", choices=tuple(tts.MODEL_FILES), dest="files")
    args = parser.parse_args()
    try:
        print(prepare(args.runtime, args.stage, args.deadline, python=args.python, uv=args.uv,
                      files=args.files, public_route_file=args.public_route_file))
        return 0
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        # No redirect URL, environment value or package-manager stream is echoed.
        message = str(error) if isinstance(error, ValueError) else type(error).__name__
        print(message, file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
