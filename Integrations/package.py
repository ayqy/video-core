#!/usr/bin/env python3
"""Build a source-only native host wrapper around the exact same free Skill."""
from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile

HOSTS = ("codex", "claude", "gemini", "grok", "deepseek-codex", "deepseek-qwen")


def package(source: Path, destination: Path, host: str, version: str, *, dry_run=False) -> str:
    spec = importlib.util.spec_from_file_location("video_skill_install", Path(__file__).with_name("install.py"))
    installer = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(installer)
    installer.reject_links(source)
    installer.reject_links(destination)
    source, destination = source.resolve(), destination.resolve()
    if source == destination or source in destination.parents or destination in source.parents:
        raise ValueError("源Skill和宿主包目标不能相同、互为祖先或互相包含")
    relative = installer.skill_relative(host)
    manifests = installer.host_manifests(host, version)
    expected = installer.fingerprints(source)
    reference_spec = importlib.util.spec_from_file_location("video_narration_reference", Path(__file__).with_name("narration_reference.py"))
    reference = importlib.util.module_from_spec(reference_spec)
    reference_spec.loader.exec_module(reference)
    reference.verify_reference(source)
    if not {"LICENSE", "NOTICE"}.issubset(expected):
        raise ValueError("共用Skill缺少完整许可与第三方声明")
    if destination.exists():
        raise ValueError("宿主包目标已存在，不覆盖用户文件")
    if dry_run:
        return "已校验同源Skill和宿主布局；没有写文件或配置宿主"
    destination.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=".video-host-", dir=destination.parent))
    try:
        payload = stage / "payload"
        payload.mkdir()
        target = payload / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(source, target)
        if installer.fingerprints(target) != expected:
            raise ValueError("宿主Skill与共用源不一致，未交付")
        for name, manifest in manifests.items():
            path = payload / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
        shutil.copyfile(source / "LICENSE", payload / "LICENSE")
        shutil.copyfile(source / "NOTICE", payload / "NOTICE")
        if destination.exists() or destination.is_symlink():
            raise ValueError("目标在打包期间出现，保留用户文件")
        installer.install_package(payload, destination, host)
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
