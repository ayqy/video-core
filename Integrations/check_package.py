#!/usr/bin/env python3
"""Check real same-source native wrapper layouts, without authenticating a model."""
from pathlib import Path
import importlib.util
import hashlib
import json
import shutil
import tempfile


def main():
    script = Path(__file__).with_name("package.py")
    spec = importlib.util.spec_from_file_location("video_host_package", script)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    installer_spec = importlib.util.spec_from_file_location("video_package_installer", script.with_name("install.py"))
    installer = importlib.util.module_from_spec(installer_spec)
    installer_spec.loader.exec_module(installer)
    source = script.parent / "skills/video"
    reference_spec = importlib.util.spec_from_file_location("video_narration_reference", script.with_name("narration_reference.py"))
    reference = importlib.util.module_from_spec(reference_spec)
    reference_spec.loader.exec_module(reference)
    reference.verify_reference(source)
    original, guidance = reference.instructions()
    assert len(original.encode()) == 4798
    assert hashlib.sha256(original.encode()).hexdigest() == "c0f8e5a5f9619585e538b38eb55234cc2af03c4e4fb2ac291200d55a45d94ea5"
    assert original.count("\u200b") == 1 and not original.endswith("\n")
    reference_bytes = reference.rendered_reference()
    assert (source / reference.REFERENCE).read_bytes() == reference_bytes
    assert original.encode() in reference_bytes and guidance.encode() in reference_bytes
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
            assert (destination / relative / reference.REFERENCE).read_bytes() == reference_bytes
            complete = installer.host_package_fingerprints(destination, host)
            assert set(complete) == {p.relative_to(destination).as_posix() for p in destination.rglob("*") if p.is_file()}
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
        isolated = root / "isolated-skill"
        shutil.copytree(source, isolated)
        def inventory():
            return (installer.fingerprints(isolated), sorted(path.relative_to(isolated).as_posix() for path in isolated.rglob("*")))
        # Packaging must refuse edited or stale guidance before any destination
        # is created, in both dry-run and normal publishing modes.
        original_reference = (isolated / reference.REFERENCE).read_bytes()
        (isolated / reference.REFERENCE).write_bytes(original_reference + b"\nchanged\n")
        for dry_run in (False, True):
            stale_destination = root / ("stale-dry" if dry_run else "stale-real")
            try:
                module.package(isolated, stale_destination, "codex", "1.0.0", dry_run=dry_run)
            except ValueError as error:
                assert "Swift" in str(error)
            else:
                raise AssertionError("drifting native narration rules were packaged")
            assert not stale_destination.exists()
            assert (isolated / reference.REFERENCE).read_bytes() == original_reference + b"\nchanged\n"
        (isolated / reference.REFERENCE).write_bytes(original_reference)
        # Extraction must fail closed when the Swift literal representation or
        # immutable original fingerprint changes; it is not a Swift evaluator.
        authority = reference.SWIFT.read_bytes()
        unsupported = root / "UnsupportedRules.swift"
        for invalid in [authority.replace(b'originalText = #"""', b'originalText = """', 1),
                        authority.replace(b'storyGuidance = """', b'storyGuidance = String(', 1),
                        authority.replace(b'c0f8e5a5f9619585e538b38eb55234cc2af03c4e4fb2ac291200d55a45d94ea5', b'0' * 64, 1)]:
            unsupported.write_bytes(invalid)
            try:
                reference.rendered_reference(unsupported)
            except ValueError:
                pass
            else:
                raise AssertionError("unsupported Swift rules were approximated")
        original = inventory()
        for dry_run in (False, True):
            for target in (isolated, isolated / "out/pkg", isolated / "out/../out/pkg", root):
                try:
                    module.package(isolated, target, "claude", "1.0.0", dry_run=dry_run)
                except ValueError:
                    pass
                else:
                    raise AssertionError("source/package containment was accepted")
                assert inventory() == original, "rejected packaging mutated its source files or directory inventory"
                assert not (isolated / "out").exists(), "packaging created staging parents inside its own source"
    print("native_host_package: passed 6 routes, exact shared Skill and complete host inventories, dry-run, native manifests, verbatim same-source narration guidance and stale/literal drift refusal, refusal of overwrite/symlinks and source/destination containment with zero source writes; not a model or marketplace test")


if __name__ == "__main__":
    main()
