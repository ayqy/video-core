#!/usr/bin/env python3
"""Prepare explicitly selected local CosyVoice CPU inference in a cache directory.

Downloads only fixed public upstream dependencies. Never clones a task repository,
uses credentials, contacts a synthesis service, or generates a review approval.
"""
from __future__ import annotations
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import tarfile
import urllib.request

from expressive_tts import MODEL_FILES, MODEL_REVISION, SOURCE_REVISION, digest

MATCHA_REVISION = "dd9105b34bf2be2230f4aa1e4769fb586a3c824e"
DEPENDENCIES = (
    "torch==2.2.2", "torchaudio==2.2.2", "numpy==1.26.4", "transformers==4.51.3",
    "soundfile==0.13.1", "onnxruntime==1.18.0", "openai-whisper==20231117",
    "einops==0.8.1", "diffusers==0.29.0", "lightning==2.2.4", "torchmetrics==1.3.2",
    "modelscope==1.20.0", "HyperPyYAML==1.2.3", "omegaconf==2.3.0",
    "hydra-core==1.3.2", "inflect==7.3.1", "librosa==0.10.2", "conformer==0.3.2",
    "matplotlib==3.7.5", "pyarrow==18.1.0", "rich==13.7.1",
    "wget==3.2", "gdown==5.1.0", "pyworld==0.3.4",
    "numba==0.61.2", "llvmlite==0.44.0", "setuptools==70.0.0",
)


def fetch(url: str, target: Path, size: int | None = None, expected: str | None = None) -> None:
    if target.exists():
        if size is not None and target.stat().st_size != size or expected and digest(target) != expected:
            raise ValueError("已有依赖身份不符：" + target.name)
        return
    part = target.with_name(target.name + ".part")
    if part.exists():
        raise ValueError("存在未核完整下载，请检查后再改变取件路径：" + part.name)
    target.parent.mkdir(parents=True, exist_ok=True)
    count = 0
    with urllib.request.urlopen(url, timeout=45) as response, part.open("xb") as stream:
        while True:
            block = response.read(1024 * 1024)
            if not block:
                break
            count += len(block)
            if count > (size if size is not None else 64 * 1024 * 1024):
                raise ValueError("公共依赖响应超限")
            stream.write(block)
    if size is not None and count != size or expected and digest(part) != expected:
        raise ValueError("公共原件未通过完整大小或SHA校验：" + target.name)
    part.rename(target)
    print("已核公共原件", target.name, count, flush=True)


def archive(url: str, target: Path, downloaded: Path) -> None:
    fetch(url, downloaded)
    if target.exists():
        raise ValueError("依赖源码目录已存在，请先检查身份")
    target.mkdir(parents=True)
    total = 0
    with tarfile.open(downloaded) as bundle:
        for item in bundle:
            relative = Path(*Path(item.name).parts[1:])
            if not relative.parts:
                continue
            # Training examples, server runtimes and links are not inference
            # dependencies. Extract only the named upstream runtime package.
            package = "matcha" if "Matcha-TTS" in str(target) else "cosyvoice"
            if len(relative.parts) > 1 and relative.parts[0] != package:
                continue
            if len(relative.parts) == 1 and not (relative.suffix == ".py" or relative.name in ("LICENSE", "README.md", "requirements.txt")):
                continue
            if item.issym() or item.islnk() or relative.is_absolute() or ".." in relative.parts:
                raise ValueError("不安全的上游归档路径")
            if item.isdir():
                continue
            if not item.isfile():
                raise ValueError("非普通的上游依赖文件")
            total += item.size
            if total > 128 * 1024 * 1024:
                raise ValueError("解压依赖超限")
            output = target / relative
            output.parent.mkdir(parents=True, exist_ok=True)
            with bundle.extractfile(item) as source, output.open("xb") as stream:
                import shutil
                shutil.copyfileobj(source, stream)


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--runtime", type=Path, required=True)
    p.add_argument("--python", type=Path, required=True)
    p.add_argument("--uv", type=Path, required=True)
    p.add_argument("--stage", choices=("source", "model", "environment", "identity"), required=True)
    a = p.parse_args()
    root = a.runtime.resolve()
    root.mkdir(parents=True, exist_ok=True)
    if a.stage == "source":
        archive(f"https://codeload.github.com/FunAudioLLM/CosyVoice/tar.gz/{SOURCE_REVISION}",
                root / "source", root / "cosyvoice-upstream.tar.gz")
        archive(f"https://codeload.github.com/shivammehta25/Matcha-TTS/tar.gz/{MATCHA_REVISION}",
                root / "source/third_party/Matcha-TTS", root / "matcha-upstream.tar.gz")
    elif a.stage == "model":
        base = f"https://huggingface.co/FunAudioLLM/CosyVoice-300M-Instruct/resolve/{MODEL_REVISION}/"
        with urllib.request.urlopen("https://huggingface.co/api/models/FunAudioLLM/CosyVoice-300M-Instruct/revision/" + MODEL_REVISION + "?blobs=true", timeout=30) as response:
            meta = json.load(response)
        if meta["sha"] != MODEL_REVISION or meta["cardData"]["license"] != "apache-2.0":
            raise ValueError("官方模型身份/许可不符")
        files = {x["rfilename"]: x for x in meta["siblings"]}
        for name, (size, sha) in MODEL_FILES.items():
            if files[name]["size"] != size or files[name]["lfs"]["sha256"] != sha:
                raise ValueError("官方LFS身份不符")
        def one(name):
            size, sha = MODEL_FILES[name]
            fetch(base + name + "?download=true", root / "model" / name, size, sha)
        with ThreadPoolExecutor(max_workers=3) as pool:
            list(pool.map(one, MODEL_FILES))
        for name in ("cosyvoice.yaml", "README.md", "config.json", "configuration.json"):
            fetch(base + name, root / "model" / name, files[name]["size"])
    elif a.stage == "environment":
        if not (root / "venv").exists():
            subprocess.run([str(a.uv), "venv", "--python", str(a.python), "--no-config", str(root / "venv")], check=True, timeout=45)
        else:
            check = subprocess.run([str(root / "venv/bin/python"), "-B", "-c", "import importlib.metadata as m; assert not list(m.distributions()), '已有部分安装，请先核对，不自动改动'"], check=True, timeout=15)
        # Whisper's fixed upstream sdist still imports pkg_resources while
        # preparing metadata. New setuptools releases removed that API.
        build = root / "build-constraints.txt"
        build.write_text("setuptools==70.0.0\nnumpy==1.26.4\n")
        env = {**os.environ, "UV_CACHE_DIR": str(root / "uv-cache"),
               "UV_PYTHON_DOWNLOADS": "never", "PYTHONDONTWRITEBYTECODE": "1"}
        if sys.platform == "darwin":
            toolchain = Path("/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin")
            sdk = Path("/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk")
            if (toolchain / "clang").is_file() and sdk.is_dir():
                # Native C dependency build only; avoid /usr/bin/cc invoking
                # xcodebuild merely to discover an already-known compiler.
                env.update(CC=str(toolchain / "clang"), CXX=str(toolchain / "clang++"), SDKROOT=str(sdk))
        lock = Path(__file__).with_name("cosyvoice-cpu-lock.txt")
        if lock.is_file():
            rows = lock.read_text().splitlines()
            if not rows or not all(re.fullmatch(r"[a-z0-9.-]+==[A-Za-z0-9.+!-]+", x) for x in rows):
                raise ValueError("固定依赖清单格式不符，不接受额外源或命令选项")
            canonical = lambda x: x.lower().replace("_", "-")
            if not {canonical(x) for x in DEPENDENCIES} <= {canonical(x) for x in rows}:
                raise ValueError("完整固定依赖缺少明确选定的直接目标")
            selected = ["--requirement", str(lock)]
        else:
            raise ValueError("缺少已核完整依赖清单，不进行浮动安装")
        subprocess.run([str(a.uv), "pip", "install", "--python", str(root / "venv/bin/python"),
                        "--no-config", "--build-constraints", str(build),
                        "--index-url", "https://pypi.org/simple", *selected], check=True, timeout=480, env=env)
    else:
        code = "import importlib.metadata as m; print('\\n'.join(sorted(d.metadata['Name'].lower().replace('_','-')+'=='+d.version for d in m.distributions())))"
        result = subprocess.run([str(root / "venv/bin/python"), "-B", "-c", code], check=True, capture_output=True, text=True, timeout=30)
        (root / "environment-freeze.txt").write_text(result.stdout)
        paths = [root / "environment-freeze.txt", *(root / "source").rglob("*.py"),
                 *(root / "source").rglob("*.tiktoken"), root / "source/LICENSE",
                 root / "model/cosyvoice.yaml", root / "model/config.json", root / "model/configuration.json"]
        lines = ["source=" + SOURCE_REVISION, "model=" + MODEL_REVISION]
        lines += [digest(path) + "  " + str(path.relative_to(root)) for path in sorted(paths)]
        target = root / "identity.txt"
        with target.open("x") as stream:
            stream.write("\n".join(lines) + "\n")
        print("本地引擎身份已冻结", len(paths), digest(target))


if __name__ == "__main__":
    main()
