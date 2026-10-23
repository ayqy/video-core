#!/usr/bin/env python3
"""Install shared instructions or an explicit complete host package; never configure services."""
from __future__ import annotations
import argparse
import hashlib
import json
import re
import shutil
import stat
import sys
import tempfile
from pathlib import Path

HOSTS = ("codex", "claude", "gemini", "grok", "deepseek-codex", "deepseek-qwen")
VERSION = r"[0-9]+\.[0-9]+\.[0-9]+(?:-[a-z0-9.-]+)?"
DESCRIPTION = "Free native video production Skill using the installed video CLI."
MAX_FILES = 256
MAX_ENTRIES = 512
MAX_TOTAL_BYTES = 16 * 1024 * 1024


def reject_links(path: Path) -> None:
    if any(part.is_symlink() for part in (path, *path.parents)):
        raise ValueError("安装路径及父目录不能是符号链接")


def tree_fingerprints(root: Path) -> dict[str, str]:
    reject_links(root)
    if not root.is_dir():
        raise ValueError("安装源目录不存在")
    values = {}
    total = 0
    for count, path in enumerate(root.rglob("*"), 1):
        if count > MAX_ENTRIES:
            raise ValueError("安装目录项数量超出有限上限")
        info = path.lstat()
        mode = info.st_mode
        if stat.S_ISDIR(mode):
            continue
        if not stat.S_ISREG(mode) or info.st_nlink != 1:
            raise ValueError("安装不接受链接或特殊文件")
        if len(values) >= MAX_FILES:
            raise ValueError("安装文件数超出有限上限")
        total += info.st_size
        if info.st_size > 2 * 1024 * 1024 or total > MAX_TOTAL_BYTES:
            raise ValueError("安装文件超出2MiB或总量超出16MiB限制")
        values[path.relative_to(root).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
    return values


def fingerprints(root: Path) -> dict[str, str]:
    values = tree_fingerprints(root)
    if "SKILL.md" not in values:
        raise ValueError("缺少SKILL.md")
    return values


def fingerprint_digest(values: dict[str, str]) -> str:
    return hashlib.sha256(json.dumps(values, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def skill_relative(host: str) -> str:
    if host not in HOSTS:
        raise ValueError("未知宿主，不推断安装布局")
    if host in ("codex", "deepseek-codex"):
        return ".agents/skills/video"
    if host == "deepseek-qwen":
        return ".qwen/skills/video"
    return "skills/video"


def host_manifests(host: str, version: str) -> dict[str, dict]:
    skill_relative(host)
    if not re.fullmatch(VERSION, version):
        raise ValueError("宿主包需要明确的语义版本")
    if host in ("claude", "grok"):
        return {".claude-plugin/plugin.json": {
            "name": "video", "version": version, "description": DESCRIPTION,
            "author": {"name": "Video contributors"},
            "homepage": "https://ayqy.github.io/video-core/",
            "repository": "https://github.com/ayqy/video-core", "license": "Apache-2.0"}}
    if host == "gemini":
        return {"gemini-extension.json": {"name": "video", "version": version, "description": DESCRIPTION}}
    return {}


def _json_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("宿主manifest含重复字段")
        result[key] = value
    return result


def host_package_fingerprints(root: Path, host: str) -> dict[str, str]:
    relative = skill_relative(host)
    values = tree_fingerprints(root)
    skill = fingerprints(root / relative)
    for name in ("LICENSE", "NOTICE"):
        if name not in skill or values.get(name) != skill[name]:
            raise ValueError("宿主包根许可/声明须与共用Skill原件相同")
    manifest_paths = (".claude-plugin/plugin.json",) if host in ("claude", "grok") else ("gemini-extension.json",) if host == "gemini" else ()
    for name in manifest_paths:
        if name not in values:
            raise ValueError("缺少当前宿主的原生manifest")
        try:
            manifest = json.loads((root / name).read_text(), object_pairs_hook=_json_object)
        except (UnicodeError, json.JSONDecodeError) as error:
            raise ValueError("宿主manifest不是有效UTF-8 JSON") from error
        version = manifest.get("version") if isinstance(manifest, dict) else None
        if not isinstance(version, str) or manifest != host_manifests(host, version)[name]:
            raise ValueError("宿主manifest身份、版本或安全字段不符；不安装未知工具/权限配置")
    allowed = {relative + "/" + name for name in skill} | {"LICENSE", "NOTICE"} | set(manifest_paths)
    if set(values) != allowed:
        raise ValueError("宿主包含未知文件，保留用户文件；只接受完整受支持布局")
    # Empty foreign directories are user state too, even though file hashes omit them.
    allowed_directories = {parent.as_posix() for name in allowed for parent in Path(name).parents if parent != Path(".")}
    for count, path in enumerate(root.rglob("*"), 1):
        if count > MAX_ENTRIES:
            raise ValueError("安装目录项数量在校验期间超出有限上限")
        if path.is_dir() and path.relative_to(root).as_posix() not in allowed_directories:
            raise ValueError("宿主包含未知目录，未替换用户文件")
    return values


def _install(source: Path, destination: Path, validator, *, verify=False, dry_run=False,
             update_from: str | None = None, label: str) -> str:
    reject_links(source)
    reject_links(destination)
    source_path, destination_path = source.resolve(), destination.resolve()
    if source_path == destination_path or source_path in destination_path.parents or destination_path in source_path.parents:
        raise ValueError("源和安装目标不能相同、互为祖先或互相包含")
    expected = validator(source)
    current = None
    backup = None
    if update_from is not None and not re.fullmatch(r"[a-f0-9]{64}", update_from):
        raise ValueError("更新须绑定已审查原安装的64位SHA-256指纹")
    if verify and update_from is not None:
        raise ValueError("--verify不能同时更新；请先核对再执行更新")
    if destination.exists():
        current = validator(destination)
        if update_from is not None and fingerprint_digest(current) != update_from:
            raise ValueError("原安装在核对后已变化；不覆盖用户修改，请重新审查")
        if current == expected:
            return "已有安装内容完全一致"
        if update_from is None:
            raise ValueError("目标含不同内容，保留原安装；请审查后用--update-from绑定原指纹")
        backup = destination.parent / ("." + destination.name + ".previous-" + update_from)
        if backup.exists() or backup.is_symlink():
            if validator(backup) != current:
                raise ValueError("上一版保留目录与当前原安装不符，未覆盖任何版本")
    elif update_from is not None:
        raise ValueError("原安装不存在，不能按旧指纹更新")
    if verify:
        raise ValueError("目标尚未安装")
    if dry_run:
        return "校验通过；未创建目录、替换内容或修改宿主配置"
    destination.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=".video-install-", dir=destination.parent))
    displaced = stage / "original"
    published_identity = None
    try:
        payload = stage / "payload"
        shutil.copytree(source, payload)
        if validator(payload) != expected:
            raise ValueError("暂存完整文件校验失败，未安装")
        try:
            reject_links(destination)
            if current is not None:
                if validator(destination) != current:
                    raise ValueError("原安装在更新过程中变化，未覆盖")
                destination.rename(displaced)
                if validator(displaced) != current:
                    raise ValueError("原安装在切换期间变化，恢复原安装")
            elif destination.exists():
                raise ValueError("目标在安装过程中出现，未覆盖")
            payload.rename(destination)
            status = destination.stat()
            published_identity = (status.st_dev, status.st_ino)
            if validator(destination) != expected:
                raise ValueError("安装后完整文件校验失败，恢复原安装")
            if backup is not None:
                if backup.exists() or backup.is_symlink():
                    if validator(backup) != current:
                        raise ValueError("上一版保留目录在更新期间变化，恢复原安装")
                    displaced.rename(stage / "duplicate-backed-up-original")
                else:
                    displaced.rename(backup)
        except BaseException:
            if displaced.exists():
                try:
                    if destination.exists() or destination.is_symlink():
                        status = destination.lstat()
                        if published_identity is None or (status.st_dev, status.st_ino) != published_identity:
                            raise ValueError("目标已有其他文件，未删除或覆盖")
                        destination.rename(stage / "rejected")
                    displaced.rename(destination)
                except BaseException as error:
                    raise ValueError("恢复未完成；唯一原安装完整保留于 " + str(displaced) + "，未清理恢复目录") from error
            elif published_identity is not None and current is None and destination.exists():
                status = destination.lstat()
                if (status.st_dev, status.st_ino) == published_identity:
                    destination.rename(stage / "rejected")
            raise
    finally:
        # A failed restore must never delete the only displaced original.
        if not displaced.exists():
            shutil.rmtree(stage, ignore_errors=True)
    return (label + "已更新并保留上一版" if backup is not None else label + "已安装并验证") + "；宿主发现/工具权限仍需会话验收"


def install(source: Path, destination: Path, *, verify=False, dry_run=False,
            update_from: str | None = None) -> str:
    return _install(source, destination, fingerprints, verify=verify, dry_run=dry_run,
                    update_from=update_from, label="共用Skill")


def install_package(source: Path, destination: Path, host: str, *, verify=False, dry_run=False,
                    update_from: str | None = None) -> str:
    return _install(source, destination, lambda root: host_package_fingerprints(root, host),
                    verify=verify, dry_run=dry_run, update_from=update_from, label="完整宿主包")


def _rollback(destination: Path, previous_digest: str, expected_current: str, validator, installer, *, dry_run=False) -> str:
    if not re.fullmatch(r"[a-f0-9]{64}", previous_digest):
        raise ValueError("回滚须指定已保留上一版的64位指纹")
    previous = destination.parent / ("." + destination.name + ".previous-" + previous_digest)
    if fingerprint_digest(validator(previous)) != previous_digest:
        raise ValueError("上一版内容与保留指纹不符，不能回滚")
    result = installer(previous, destination, dry_run=dry_run, update_from=expected_current)
    return "回滚：" + result


def rollback(destination: Path, previous_digest: str, expected_current: str, *, dry_run=False) -> str:
    return _rollback(destination, previous_digest, expected_current, fingerprints, install, dry_run=dry_run)


def rollback_package(destination: Path, previous_digest: str, expected_current: str, host: str, *, dry_run=False) -> str:
    return _rollback(destination, previous_digest, expected_current,
                     lambda root: host_package_fingerprints(root, host),
                     lambda source, target, **options: install_package(source, target, host, **options), dry_run=dry_run)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True, choices=HOSTS)
    parser.add_argument("--destination", type=Path, required=True, help="用户选定的video技能目录；整包模式为完整插件/扩展根目录")
    parser.add_argument("--host-package", action="store_true", help="显式按完整宿主包校验、安装、更新或回滚")
    parser.add_argument("--package-source", type=Path, help="由package.py生成并经审查的完整宿主源包；仅供--host-package")
    parser.add_argument("--verify", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--fingerprint", action="store_true", help="只回读目标完整指纹，不读取认证或修改文件")
    parser.add_argument("--update-from", help="原安装经过审查的SHA-256；不同内容才更新并保留上一版")
    parser.add_argument("--rollback-from", help="已保留上一版的SHA-256；须同时指定--update-from绑定当前安装")
    args = parser.parse_args()
    source = Path(__file__).resolve().parent / "skills/video"
    try:
        destination = args.destination.absolute()
        if args.package_source and not args.host_package:
            raise ValueError("--package-source必须显式配合--host-package，不推断整包覆盖范围")
        validator = (lambda root: host_package_fingerprints(root, args.host)) if args.host_package else fingerprints
        if args.fingerprint:
            if args.verify or args.dry_run or args.update_from or args.rollback_from or args.package_source:
                raise ValueError("--fingerprint只读，不能与更新/回滚/验证或源包组合")
            print(fingerprint_digest(validator(destination)))
            return 0
        if args.rollback_from:
            if not args.update_from or args.verify or args.package_source:
                raise ValueError("回滚需--update-from绑定当前安装，不能与--verify或源包组合")
            result = (rollback_package(destination, args.rollback_from, args.update_from, args.host, dry_run=args.dry_run)
                      if args.host_package else rollback(destination, args.rollback_from, args.update_from, dry_run=args.dry_run))
        elif args.host_package:
            if args.package_source is None:
                raise ValueError("完整宿主包安装/验证须指定--package-source")
            result = install_package(args.package_source.absolute(), destination, args.host, verify=args.verify, dry_run=args.dry_run, update_from=args.update_from)
        else:
            result = install(source, destination, verify=args.verify, dry_run=args.dry_run, update_from=args.update_from)
        print(f"{args.host}：{result}。未配置模型、凭据、MCP或市场。")
        return 0
    except (OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
