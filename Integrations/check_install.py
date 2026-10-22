#!/usr/bin/env python3
"""Exercise real package copies and refusals without touching a host installation."""
import importlib.util
import tempfile
from pathlib import Path


def main():
    script = Path(__file__).resolve().parent / "install.py"
    spec = importlib.util.spec_from_file_location("video_skill_installer", script)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    source = script.parent / "skills/video"
    with tempfile.TemporaryDirectory(prefix="video-skill-check-") as temporary:
        root = Path(temporary)
        target = root / "new/project/skills/video"
        module.install(source, target, dry_run=True)
        assert not target.parent.exists(), "dry-run must not create parent directories"
        module.install(source, target)
        assert module.fingerprints(target) == module.fingerprints(source)
        module.install(source, target, verify=True)
        module.install(source, target)
        original = (target / "SKILL.md").read_bytes()
        changed = original + b"\nUser customization\n"
        (target / "SKILL.md").write_bytes(changed)
        try:
            module.install(source, target)
        except ValueError:
            pass
        else:
            raise AssertionError("modified installation was overwritten")
        assert (target / "SKILL.md").read_bytes() == changed
        link = root / "link"
        link.symlink_to(target, target_is_directory=True)
        try:
            module.install(source, link)
        except ValueError:
            pass
        else:
            raise AssertionError("symlink target was silently accepted")
    print("Skill安装检查通过：真实复制、哈希校验、无修改dry-run、重复安装、拒绝覆盖/符号链接；未声称宿主发现或市场发布。")


if __name__ == "__main__":
    main()
