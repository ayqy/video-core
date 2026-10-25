#!/usr/bin/env python3
"""Generate/check native Skill guidance from the compiled Swift authority."""
from __future__ import annotations
import argparse
import hashlib
from pathlib import Path
import re

SWIFT = Path(__file__).resolve().parents[1] / "Sources/VideoCore/NarrationWritingRules.swift"
REFERENCE = Path("references/narration-writing.md")


def instructions(source: Path = SWIFT) -> tuple[str, str]:
    text = source.read_bytes().decode("utf-8")
    if "\r" in text:
        raise ValueError("写作规则Swift源须保持明确的LF字面结构")
    def literal(name: str, *, raw: bool) -> str:
        opening = "    public static let " + name + (' = #"""\n' if raw else ' = """\n')
        closing = '\n"""#' if raw else '\n    """'
        if text.count(opening) != 1:
            raise ValueError("写作规则Swift字面结构不受支持：" + name)
        remainder = text.split(opening, 1)[1]
        if closing not in remainder:
            raise ValueError("写作规则Swift字面量未闭合：" + name)
        body, suffix = remainder.split(closing, 1)
        if not suffix.startswith("\n"):
            raise ValueError("写作规则Swift结束结构不受支持：" + name)
        if raw:
            return body
        # Swift strips this exact common indentation. Refuse escapes or
        # interpolation rather than approximate another Swift representation.
        if "\\" in body or any(line and not line.startswith("    ") for line in body.split("\n")):
            raise ValueError("故事指导只接受当前无转义的四空格Swift字面量")
        return "\n".join(line[4:] if line else "" for line in body.split("\n"))
    original = literal("originalText", raw=True)
    guidance = literal("storyGuidance", raw=False)
    digest = re.findall(r'^    public static let sourceSHA256 = "([a-f0-9]{64})"$', text, re.M)
    byte_count = re.findall(r"^    public static let sourceByteCount = ([0-9]+)$", text, re.M)
    if len(digest) != 1 or len(byte_count) != 1 or hashlib.sha256(original.encode()).hexdigest() != digest[0] or len(original.encode()) != int(byte_count[0]):
        raise ValueError("管理员原文的Swift字节数或SHA-256不符，不生成或打包")
    if not guidance.strip():
        raise ValueError("缺少故事与跨形式指导")
    return original, guidance


def rendered_reference(source: Path = SWIFT) -> bytes:
    original, guidance = instructions(source)
    return ("# 解说写作规则\n\n## 自然汉语规则\n\n```text\n" + original +
            "\n```\n\n## 故事与镜头\n\n" + guidance + "\n").encode("utf-8")


def verify_reference(skill: Path, source: Path = SWIFT) -> None:
    path = skill / REFERENCE
    if path.is_symlink() or not path.is_file() or path.read_bytes() != rendered_reference(source):
        raise ValueError("原生Skill写作引用与当前Swift权威规则不一致；先生成并复核，不打包漂移内容")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--write", action="store_true")
    args = parser.parse_args()
    skill = Path(__file__).resolve().parent / "skills/video"
    try:
        if args.write:
            expected = rendered_reference()
            target = skill / REFERENCE
            if target.is_symlink():
                raise ValueError("不覆盖符号链接引用")
            target.write_bytes(expected)
        verify_reference(skill)
        print("native_narration_reference: same-source UTF-8 verified; original text and story guidance preserved")
        return 0
    except (OSError, UnicodeError, ValueError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    raise SystemExit(main())
