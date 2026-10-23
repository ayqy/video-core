#!/usr/bin/env python3
"""Read the installed native CLI schema without a workspace, model or credential.

Hosts can invoke this bounded helper to avoid injecting the entire nested schema
into their model context. It never installs/configures a provider or writes data.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import selectors
import signal
import stat
import subprocess
import sys
import time


_TIMEOUT_SECONDS = 20.0
_MAX_STDOUT_BYTES = 10 * 1024 * 1024
_ENVIRONMENT = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"}


def _identity(value):
    return (value.st_dev, value.st_ino, value.st_mode, value.st_nlink, value.st_size,
            value.st_mtime_ns, value.st_ctime_ns)


def _pin(binary: Path):
    """Hash a stable regular file without following a replacement symlink."""
    before = binary.lstat()
    if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
        raise ValueError("原生CLI必须是普通单链接文件")
    descriptor = os.open(binary, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as source:
        opened = os.fstat(source.fileno())
        if _identity(opened) != _identity(before):
            raise ValueError("原生CLI在校验时发生变化")
        digest = hashlib.sha256()
        remaining = opened.st_size
        while remaining:
            chunk = source.read(min(1024 * 1024, remaining))
            if not chunk:
                raise ValueError("原生CLI在校验时发生变化")
            digest.update(chunk)
            remaining -= len(chunk)
        if source.read(1) or _identity(os.fstat(source.fileno())) != _identity(opened):
            raise ValueError("原生CLI在校验时发生变化")
    if _identity(binary.lstat()) != _identity(before):
        raise ValueError("原生CLI在校验时发生变化")
    return _identity(before), digest.digest()


def _stop(process) -> bool:
    # Only this helper's start_new_session group is signalled. Its leader may
    # already have exited while descendants still retain the output pipes.
    signals_ok = True
    for value in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(process.pid, value)
            if value == signal.SIGTERM:
                time.sleep(.2)
        except ProcessLookupError:
            pass
        except OSError:
            signals_ok = False
    try:
        process.wait(timeout=1)
    except (subprocess.TimeoutExpired, OSError):
        return False
    return signals_ok


def _schema(binary: Path, *, deadline: float) -> bytes:
    process = subprocess.Popen([str(binary), "schema"], cwd="/", shell=False,
                               stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, start_new_session=True,
                               env=dict(_ENVIRONMENT))
    selector = selectors.DefaultSelector()
    output = bytearray()
    failure = None
    try:
        selector.register(process.stdout, selectors.EVENT_READ, "out")
        selector.register(process.stderr, selectors.EVENT_READ, "err")
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise ValueError("原生schema请求超过期限")
            for key, _ in selector.select(min(.1, remaining)):
                chunk = os.read(key.fileobj.fileno(), 65536)
                if not chunk:
                    selector.unregister(key.fileobj)
                elif key.data == "err":
                    # Any stderr already invalidates discovery; never retain or
                    # echo provider diagnostics, paths or inherited data.
                    raise ValueError("原生schema请求含外部诊断")
                elif len(output) + len(chunk) > _MAX_STDOUT_BYTES:
                    raise ValueError("原生schema输出超过上限")
                else:
                    output.extend(chunk)
        process.wait(timeout=max(.001, deadline - time.monotonic()))
        if process.returncode:
            raise ValueError("原生schema请求未成功")
    except BaseException as error:
        failure = error
        raise
    finally:
        try:
            cleaned = _stop(process)
        finally:
            selector.close()
            process.stdout.close()
            process.stderr.close()
        if not cleaned and failure is None:
            raise ValueError("原生schema进程清理未完成")
    return bytes(output)


def discover(binary: Path) -> str:
    deadline = time.monotonic() + _TIMEOUT_SECONDS
    binary = binary.resolve(strict=True)
    if not binary.is_file():
        raise ValueError("请指定已验证安装的原生video可执行文件")
    pinned = _pin(binary)
    if time.monotonic() >= deadline:
        raise ValueError("原生schema请求超过期限")
    output = _schema(binary, deadline=deadline)
    if _pin(binary) != pinned:
        raise ValueError("原生CLI在执行期间发生变化")
    value = json.loads(output)
    if not isinstance(value, dict) or value.get("schema_version") != "1.0" or value.get("ok") is not True:
        raise ValueError("原生CLI协议版本或状态不符")
    catalog = value.get("result")
    commands = catalog.get("commands") if isinstance(catalog, dict) else None
    if not isinstance(commands, list) or not commands or any(not isinstance(c, dict) or not c.get("name") or not isinstance(c.get("input_schema"), dict) for c in commands):
        raise ValueError("原生能力目录缺少真实命令或输入schema")
    digest = hashlib.sha256(json.dumps(catalog, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()).hexdigest()
    return f"video schema_version=1.0 commands={len(commands)} schema_sha256={digest}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    args = parser.parse_args()
    try:
        print(discover(args.binary))
        return 0
    except (OSError, ValueError, subprocess.SubprocessError):
        print("只读能力发现未完成；请核对原生CLI安装和Apple运行时，未改配置或工程。", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
