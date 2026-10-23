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
        root = Path(temporary).resolve()
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
        approved = module.fingerprint_digest(module.fingerprints(target))
        module.install(source, target, update_from=approved, dry_run=True)
        assert (target / "SKILL.md").read_bytes() == changed
        try:
            module.install(source, target, update_from="0" * 64)
        except ValueError:
            pass
        else:
            raise AssertionError("stale approved fingerprint replaced current content")
        module.install(source, target, update_from=approved)
        assert module.fingerprints(target) == module.fingerprints(source)
        retained = target.parent / ("." + target.name + ".previous-" + approved)
        assert (retained / "SKILL.md").read_bytes() == changed
        current = module.fingerprint_digest(module.fingerprints(target))
        module.rollback(target, approved, current)
        assert (target / "SKILL.md").read_bytes() == changed
        assert module.fingerprint_digest(module.fingerprints(target)) == approved
        # No arbitrary previous directory or tampered backup can be restored.
        (retained / "SKILL.md").write_text("changed after retention")
        try:
            module.rollback(target, approved, approved)
        except ValueError:
            pass
        else:
            raise AssertionError("tampered retained version was accepted")
        link = root / "link"
        link.symlink_to(target, target_is_directory=True)
        try:
            module.install(source, link)
        except ValueError:
            pass
        else:
            raise AssertionError("symlink target was silently accepted")
    print("Skill安装检查通过：真实复制、哈希校验、无修改dry-run、重复安装、绑定原指纹更新与保留上一版、真实回滚、拒绝旧指纹/篡改/符号链接；未声称宿主发现或市场发布。")


if __name__ == "__main__":
    main()
