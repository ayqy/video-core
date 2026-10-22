#!/usr/bin/env python3
"""Install the shared instructions only; never configure models, credentials or services."""
import argparse
import hashlib
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


def install(source: Path, destination: Path, *, verify=False, dry_run=False) -> str:
    expected = fingerprints(source)
    if destination.exists() or destination.is_symlink():
        if fingerprints(destination) != expected:
            raise ValueError("目标含不同内容，保留原安装；请选新目录或自行审查后更新")
        return "已有安装内容完全一致"
    if verify:
        raise ValueError("目标尚未安装")
    if dry_run:
        return "校验通过；未创建目录或修改宿主配置"
    destination.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=".video-skill-", dir=destination.parent))
    try:
        payload = stage / "video"
        shutil.copytree(source, payload)
        if fingerprints(payload) != expected:
            raise ValueError("暂存文件校验失败，未安装")
        if destination.exists() or destination.is_symlink():
            raise ValueError("目标在安装过程中出现，未覆盖")
        payload.rename(destination)
        if fingerprints(destination) != expected:
            raise ValueError("安装后校验失败，请保留现场检查")
    finally:
        shutil.rmtree(stage, ignore_errors=True)
    return "共用Skill已安装并验证；宿主发现/工具权限仍需会话验收"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True, choices=["codex", "claude", "gemini", "grok", "deepseek-codex", "deepseek-qwen"])
    parser.add_argument("--destination", type=Path, required=True, help="用户选择的完整video技能目录；不隐式改全局环境")
    parser.add_argument("--verify", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    source = Path(__file__).resolve().parent / "skills/video"
    try:
        result = install(source, args.destination.absolute(), verify=args.verify, dry_run=args.dry_run)
        print(f"{args.host}：{result}。未配置模型、凭据、MCP或市场。")
        return 0
    except (OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
