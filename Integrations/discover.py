#!/usr/bin/env python3
"""Read the installed native CLI schema without a workspace, model or credential.

Hosts can invoke this bounded helper to avoid injecting the entire nested schema
into their model context. It never installs/configures a provider or writes data.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys


def discover(binary: Path) -> str:
    binary = binary.resolve(strict=True)
    if not binary.is_file():
        raise ValueError("请指定已验证安装的原生video可执行文件")
    result = subprocess.run([str(binary), "schema"], stdin=subprocess.DEVNULL,
                            capture_output=True, timeout=20, check=False)
    if result.returncode or result.stderr or len(result.stdout) > 10 * 1024 * 1024:
        raise ValueError("原生schema请求未通过；未输出完整结果或外部诊断")
    value = json.loads(result.stdout)
    if value.get("schema_version") != "1.0" or value.get("ok") is not True:
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
