"""Pure complete-video-Skill inventory shared by native hosts and installers.

No host, model, credential, sibling-module or runtime configuration dependency.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re
import stat


def verify_skill(directory: Path, pins: tuple[tuple[Path, str], ...]) -> dict:
    root = Path(directory)
    if (not root.is_absolute() or str(root) != str(root.resolve(strict=True)) or
            any(p.is_symlink() for p in (root, *root.parents))):
        raise ValueError("symlink_or_noncanonical_skill_path_refused")
    expected = {"SKILL.md", "LICENSE", "NOTICE", "agents/openai.yaml", "references/protocol.md",
                "references/narration-writing.md"}
    directories = {"agents", "references"}
    if (not root.is_dir() or not isinstance(pins, tuple) or len(pins) != len(expected) or
            any(not isinstance(pin, tuple) or len(pin) != 2 or not isinstance(pin[0], Path) or
                not isinstance(pin[1], str) or not re.fullmatch(r"[a-f0-9]{64}", pin[1]) for pin in pins)):
        raise ValueError("video_skill_complete_pins_required")
    actual, total = {}, 0
    for count, path in enumerate(root.rglob("*"), 1):
        if count > len(expected) + len(directories):
            raise ValueError("video_skill_layout_refused")
        if (str(path) != str(path.resolve(strict=True)) or
                any(p.is_symlink() for p in (path, *path.parents))):
            raise ValueError("symlink_path_refused")
        relative = path.relative_to(root).as_posix()
        info = path.stat()
        if stat.S_ISDIR(info.st_mode):
            if relative not in directories:
                raise ValueError("video_skill_layout_refused")
            continue
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or relative not in expected:
            raise ValueError("video_skill_layout_refused")
        total += info.st_size
        if not 0 < info.st_size <= 256 * 1024 or total > 1024 * 1024:
            raise ValueError("video_skill_byte_bound")
        actual[path] = relative
    if set(actual.values()) != expected or {pin[0] for pin in pins} != set(actual):
        raise ValueError("video_skill_complete_pins_required")
    for path, digest in pins:
        if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise ValueError("file_pin_mismatch")
    entry = root / "SKILL.md"
    if not entry.read_bytes().startswith(b"---\nname: video\n"):
        raise ValueError("video_skill_identity_refused")
    package = {actual[path]: digest for path, digest in pins}
    digest = hashlib.sha256(json.dumps(package, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    return {"name": "video", "path": str(entry), "sha256": package["SKILL.md"], "package_sha256": digest}
