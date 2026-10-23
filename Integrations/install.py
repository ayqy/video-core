#!/usr/bin/env python3
"""Install the shared instructions only; never configure models, credentials or services."""
from __future__ import annotations
import argparse
import hashlib
import json
import re
import shutil
import sys
import tempfile
from pathlib import Path


def fingerprints(root: Path) -> dict[str, str]:
    if not root.is_dir() or root.is_symlink():
        raise ValueError("Skill目录不存在或为符号链接")
    values = {}
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise ValueError("Skill安装不接受符号链接")
        if path.is_file():
            if path.stat().st_size > 2 * 1024 * 1024:
                raise ValueError("Skill文件超出2MiB限制")
            values[path.relative_to(root).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
    if "SKILL.md" not in values:
        raise ValueError("缺少SKILL.md")
    return values


def fingerprint_digest(values: dict[str, str]) -> str:
    return hashlib.sha256(json.dumps(values, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def install(source: Path, destination: Path, *, verify=False, dry_run=False,
            update_from: str | None = None) -> str:
    expected = fingerprints(source)
    current = None
    backup = None
    if any(p.is_symlink() for p in (destination, *destination.parents)):
        raise ValueError("目标及父目录不能为符号链接")
    if update_from is not None and not re.fullmatch(r"[a-f0-9]{64}", update_from):
        raise ValueError("更新须绑定已审查原安装的64位SHA-256指纹")
    if verify and update_from is not None:
        raise ValueError("--verify不能同时更新；请先核对再执行更新")
    if source.resolve() == destination.resolve():
        raise ValueError("源技能与目标安装不能是同一目录")
    if destination.exists() or destination.is_symlink():
        current = fingerprints(destination)
        if update_from is not None and fingerprint_digest(current) != update_from:
            raise ValueError("原安装在核对后已变化；不覆盖用户修改，请重新审查")
        if current == expected:
            return "已有安装内容完全一致"
        if update_from is None:
            raise ValueError("目标含不同内容，保留原安装；请审查后用--update-from绑定原指纹")
        backup = destination.parent / ("." + destination.name + ".previous-" + update_from)
        if backup.exists() or backup.is_symlink():
            if fingerprints(backup) != current:
                raise ValueError("上一版保留目录与当前原安装不符，未覆盖任何版本")
    elif update_from is not None:
        raise ValueError("原安装不存在，不能按旧指纹更新")
    if verify:
        raise ValueError("目标尚未安装")
    if dry_run:
        return "校验通过；未创建目录、替换技能或修改宿主配置"
    destination.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=".video-skill-", dir=destination.parent))
    try:
        payload = stage / "video"
        shutil.copytree(source, payload)
        if fingerprints(payload) != expected:
            raise ValueError("暂存文件校验失败，未安装")
        displaced = stage / "original"
        if current is not None:
            if fingerprints(destination) != current:
                raise ValueError("原安装在更新过程中变化，未覆盖")
            destination.rename(displaced)
        elif destination.exists() or destination.is_symlink():
            raise ValueError("目标在安装过程中出现，未覆盖")
        try:
            payload.rename(destination)
            if fingerprints(destination) != expected:
                raise ValueError("安装后校验失败，恢复原安装")
            if backup is not None and not backup.exists():
                displaced.rename(backup)
        except BaseException:
            if displaced.exists():
                if destination.exists():
                    shutil.rmtree(destination)
                displaced.rename(destination)
            raise
    finally:
        shutil.rmtree(stage, ignore_errors=True)
    return ("共用Skill已更新并保留上一版" if backup is not None else "共用Skill已安装并验证") + "；宿主发现/工具权限仍需会话验收"


def rollback(destination: Path, previous_digest: str, expected_current: str, *, dry_run=False) -> str:
    if not re.fullmatch(r"[a-f0-9]{64}", previous_digest):
        raise ValueError("回滚须指定已保留上一版的64位指纹")
    previous = destination.parent / ("." + destination.name + ".previous-" + previous_digest)
    if fingerprint_digest(fingerprints(previous)) != previous_digest:
        raise ValueError("上一版内容与保留指纹不符，不能回滚")
    result = install(previous, destination, dry_run=dry_run, update_from=expected_current)
    return "回滚：" + result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True, choices=["codex", "claude", "gemini", "grok", "deepseek-codex", "deepseek-qwen"])
    parser.add_argument("--destination", type=Path, required=True, help="用户选择的完整video技能目录；不隐式改全局环境")
    parser.add_argument("--verify", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--fingerprint", action="store_true", help="只回读目标指纹，不读取认证或修改文件")
    parser.add_argument("--update-from", help="原安装经过审查的SHA-256；不同内容才更新并保留上一版")
    parser.add_argument("--rollback-from", help="已保留上一版的SHA-256；须同时指定--update-from绑定当前安装")
    args = parser.parse_args()
    source = Path(__file__).resolve().parent / "skills/video"
    try:
        destination = args.destination.absolute()
        if args.fingerprint:
            if args.verify or args.dry_run or args.update_from or args.rollback_from:
                raise ValueError("--fingerprint只读，不能与更新/回滚/验证组合")
            print(fingerprint_digest(fingerprints(destination)))
            return 0
        if args.rollback_from:
            if not args.update_from or args.verify:
                raise ValueError("回滚需--update-from绑定当前安装，不能与--verify组合")
            result = rollback(destination, args.rollback_from, args.update_from, dry_run=args.dry_run)
        else:
            result = install(source, destination, verify=args.verify, dry_run=args.dry_run, update_from=args.update_from)
        print(f"{args.host}：{result}。未配置模型、凭据、MCP或市场。")
        return 0
    except (OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
