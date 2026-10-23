#!/usr/bin/env python3
"""Build a source-only native host wrapper around the exact same free Skill."""
from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path
import re
import shutil
import tempfile

HOSTS = ("codex", "claude", "gemini", "grok", "deepseek-codex", "deepseek-qwen")


def package(source: Path, destination: Path, host: str, version: str, *, dry_run=False) -> str:
    if host not in HOSTS or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[a-z0-9.-]+)?", version):
        raise ValueError("需要实际支持的宿主和明确的语义版本")
    spec = importlib.util.spec_from_file_location("video_skill_install", Path(__file__).with_name("install.py"))
    installer = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(installer)
    expected = installer.fingerprints(source)
    if any(path.is_symlink() for path in (destination, *destination.parents)):
        raise ValueError("交付目录或父目录不能是符号链接")
    if destination.exists():
        raise ValueError("宿主包目标已存在，不覆盖用户文件")
    if dry_run:
        return "已校验同源Skill和宿主布局；没有写文件或配置宿主"
    destination.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=".video-host-", dir=destination.parent))
    try:
        payload = stage / "payload"
        payload.mkdir()
        if host in ("codex", "deepseek-codex"):
            relative = ".agents/skills/video"
        elif host == "deepseek-qwen":
            relative = ".qwen/skills/video"
        else:
            relative = "skills/video"
        target = payload / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(source, target)
        if installer.fingerprints(target) != expected:
            raise ValueError("宿主Skill与共用源不一致，未交付")
        if host in ("claude", "grok"):
            folder = payload / ".claude-plugin"
            folder.mkdir()
            manifest = {"name": "video", "version": version,
                        "description": "Free native video production Skill using the installed video CLI.",
                        "author": {"name": "Video contributors"},
                        "homepage": "https://ayqy.github.io/video-core/",
                        "repository": "https://github.com/ayqy/video-core",
                        "license": "Apache-2.0"}
            (folder / "plugin.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
        elif host == "gemini":
            manifest = {"name": "video", "version": version,
                        "description": "Free native video production Skill using the installed video CLI."}
            (payload / "gemini-extension.json").write_text(json.dumps(manifest, indent=2) + "\n")
        shutil.copyfile(source / "LICENSE", payload / "LICENSE")
        shutil.copyfile(source / "NOTICE", payload / "NOTICE")
        if destination.exists() or destination.is_symlink():
            raise ValueError("目标在打包期间出现，保留用户文件")
        payload.rename(destination)
    finally:
        shutil.rmtree(stage, ignore_errors=True)
    return "宿主源包已生成并逐文件核对；不含模型配置、凭据、MCP或闭源实现，不声称已安装、可调用或上架"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True, choices=HOSTS)
    parser.add_argument("--version", required=True)
    parser.add_argument("--destination", required=True, type=Path)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    try:
        print(package(Path(__file__).with_name("skills") / "video", args.destination.absolute(),
                      args.host, args.version, dry_run=args.dry_run))
    except (OSError, ValueError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
