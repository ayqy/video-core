#!/usr/bin/env python3
"""Check real same-source native wrapper layouts, without authenticating a model."""
from pathlib import Path
import importlib.util
import json
import tempfile


def main():
    script = Path(__file__).with_name("package.py")
    spec = importlib.util.spec_from_file_location("video_host_package", script)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    source = script.parent / "skills/video"
    with tempfile.TemporaryDirectory(prefix="video-host-package-") as folder:
        root = Path(folder).resolve()
        expected = {p.relative_to(source): p.read_bytes() for p in source.rglob("*") if p.is_file()}
        for host in module.HOSTS:
            destination = root / host
            module.package(source, destination, host, "1.0.0", dry_run=True)
            assert not destination.exists()
            module.package(source, destination, host, "1.0.0")
            relative = ".qwen/skills/video" if host == "deepseek-qwen" else ".agents/skills/video" if host in ("codex", "deepseek-codex") else "skills/video"
            actual = {p.relative_to(destination / relative): p.read_bytes()
                      for p in (destination / relative).rglob("*") if p.is_file()}
            assert actual == expected
            if host in ("claude", "grok"):
                manifest = json.loads((destination / ".claude-plugin/plugin.json").read_text())
                assert manifest["name"] == "video" and manifest["version"] == "1.0.0"
                assert "mcpServers" not in manifest
            if host == "gemini":
                manifest = json.loads((destination / "gemini-extension.json").read_text())
                assert manifest == {"name": "video", "version": "1.0.0",
                                    "description": "Free native video production Skill using the installed video CLI."}
            try:
                module.package(source, destination, host, "1.0.1")
            except ValueError:
                pass
            else:
                raise AssertionError("existing host package was replaced")
        link = root / "link"
        link.symlink_to(root / "codex", target_is_directory=True)
        try:
            module.package(source, link / "nested", "codex", "1.0.0")
        except ValueError:
            pass
        else:
            raise AssertionError("host package followed symlink destination")
    print("native_host_package: passed 6 routes, exact shared Skill, dry-run, native manifests, refusal of overwrite/symlinks; not a model or marketplace test")


if __name__ == "__main__":
    main()
