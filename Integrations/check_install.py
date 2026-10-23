#!/usr/bin/env python3
"""Exercise real package copies and refusals without touching a host installation."""
import importlib.util
import contextlib
import io
import json
import os
import shutil
import tempfile
import unittest
from unittest import mock
from pathlib import Path


def load(name):
    spec = importlib.util.spec_from_file_location("video_check_" + name, Path(__file__).with_name(name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class CompleteHostPackageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="video-complete-host-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.installer, self.packager = load("install"), load("package")
        self.skill = Path(__file__).with_name("skills") / "video"

    def package(self, host="claude", version="1.0.0", *, changed=False):
        destination = self.root / (host + "-" + version)
        source = self.skill
        if changed:
            source = self.root / ("skill-" + host + "-" + version)
            shutil.copytree(self.skill, source)
            with (source / "SKILL.md").open("a") as stream:
                stream.write("\nReviewed instruction revision " + version + "\n")
        self.packager.package(source, destination, host, version)
        return destination

    def fingerprint(self, path, host="claude"):
        return self.installer.fingerprint_digest(self.installer.host_package_fingerprints(path, host))

    def installed(self):
        first = self.package()
        target = self.root / "installed-video"
        self.installer.install_package(first, target, "claude")
        return first, target, self.fingerprint(target)

    def testEveryHostUpdatesAndRollsBackMetadataAndSkillTogether(self):
        for host in self.packager.HOSTS:
            with self.subTest(host=host):
                old = self.package(host)
                new = self.package(host, "1.1.0", changed=True)
                target = self.root / ("installed-" + host)
                self.installer.install_package(old, target, host, dry_run=True)
                self.assertFalse(target.exists())
                self.installer.install_package(old, target, host)
                previous = self.fingerprint(target, host)
                self.installer.install_package(old, target, host, verify=True)
                self.assertIn("一致", self.installer.install_package(old, target, host))
                self.installer.install_package(new, target, host, update_from=previous, dry_run=True)
                self.assertEqual(self.fingerprint(target, host), previous)
                self.installer.install_package(new, target, host, update_from=previous)
                current = self.fingerprint(target, host)
                self.assertEqual(current, self.fingerprint(new, host))
                self.assertNotEqual(current, previous)
                backup = target.parent / ("." + target.name + ".previous-" + previous)
                self.assertEqual(self.fingerprint(backup, host), previous)
                self.installer.rollback_package(target, previous, current, host)
                self.assertEqual(self.fingerprint(target, host), previous)
                self.assertTrue((target.parent / ("." + target.name + ".previous-" + current)).is_dir())
                # Existing, hash-checked backups must not leak another staged original.
                self.installer.install_package(new, target, host, update_from=previous)
                self.installer.rollback_package(target, previous, current, host)
                self.assertEqual(self.fingerprint(target, host), previous)
                self.assertEqual(list(target.parent.glob(".video-install-*")), [])

    def testManifestOnlyUpgradeRequiresAndChangesTheWholePackageFingerprint(self):
        for host in ("claude", "grok", "gemini"):
            with self.subTest(host=host):
                old, new = self.package(host), self.package(host, "1.0.1")
                target = self.root / ("installed-" + host)
                self.installer.install_package(old, target, host)
                previous = self.fingerprint(target, host)
                skill_only = self.installer.fingerprint_digest(self.installer.fingerprints(target / "skills/video"))
                self.assertNotEqual(previous, self.fingerprint(new, host))
                with self.assertRaises(ValueError):
                    self.installer.install_package(new, target, host)
                with self.assertRaises(ValueError):
                    self.installer.install_package(new, target, host, update_from=skill_only)
                self.assertEqual(self.fingerprint(target, host), previous)
                self.installer.install_package(new, target, host, update_from=previous)
                self.assertEqual(self.fingerprint(target, host), self.fingerprint(new, host))
                relative = ".claude-plugin/plugin.json" if host != "gemini" else "gemini-extension.json"
                self.assertEqual(json.loads((target / relative).read_text())["version"], "1.0.1")

    def testUnknownFilesDirectoriesAndUnsafeManifestNeverReplaceUserState(self):
        first, target, previous = self.installed()
        new = self.package(version="1.0.1")
        manifest = new / ".claude-plugin/plugin.json"
        original = manifest.read_bytes()
        payload = json.loads(original)
        payload["mcpServers"] = {"unknown": {"command": "must-not-run"}}
        manifest.write_text(json.dumps(payload))
        with self.assertRaises(ValueError):
            self.installer.install_package(new, target, "claude", update_from=previous)
        self.assertEqual(self.fingerprint(target), previous)
        manifest.write_bytes(original)
        for name, directory in (("user-notes.txt", False), ("user-empty-directory", True)):
            path = target / name
            path.mkdir() if directory else path.write_text("User content must remain")
            with self.assertRaises(ValueError):
                self.installer.install_package(new, target, "claude", update_from=previous)
            self.assertTrue(path.exists())
            path.rmdir() if directory else path.unlink()
        manifest.write_text('{"name":"video","version":"1.0.1","version":"1.0.0"}')
        with self.assertRaises(ValueError):
            self.installer.host_package_fingerprints(new, "claude")
        manifest.write_bytes(original)
        (new / "NOTICE").write_text("Different root notice")
        with self.assertRaises(ValueError):
            self.installer.install_package(new, target, "claude", update_from=previous)
        self.assertEqual(self.fingerprint(target), self.fingerprint(first))

    def testNestedRootsLinksAndSpecialFilesAreRefusedBeforeCopying(self):
        source = self.package()
        for destination in (source, source / "nested", self.root):
            with self.subTest(destination=destination), self.assertRaises(ValueError):
                self.installer.install_package(source, destination, "claude")
        self.assertFalse((source / "nested").exists())
        link = self.root / "linked-parent"
        link.symlink_to(source, target_is_directory=True)
        with self.assertRaises(ValueError):
            self.installer.install_package(source, link / "nested", "claude")
        for kind in ("symlink", "hardlink", "fifo"):
            with self.subTest(kind=kind):
                entry = source / "untrusted"
                if kind == "symlink": entry.symlink_to(source / "LICENSE")
                elif kind == "hardlink": os.link(source / "LICENSE", entry)
                else: os.mkfifo(entry)
                with self.assertRaises(ValueError):
                    self.installer.host_package_fingerprints(source, "claude")
                entry.unlink()

    def testOversizedInventoryIsBoundedBeforeAnyInstallWrite(self):
        source = self.package()
        target = self.root / "not-created"
        for index in range(self.installer.MAX_FILES + 1):
            (source / ("extra-" + str(index))).write_text("untrusted")
        with self.assertRaisesRegex(ValueError, "文件数"):
            self.installer.install_package(source, target, "claude")
        self.assertFalse(target.exists())
        self.assertEqual(list(target.parent.glob(".video-install-*")), [])

    def testFailedPublicationRestoresTheWholeOriginalPackage(self):
        _, target, previous = self.installed()
        new = self.package(version="1.1.0", changed=True)
        rename = Path.rename
        def fail_publish(path, destination):
            if path.name == "payload" and destination == target:
                raise OSError("Injected whole-package publication failure")
            return rename(path, destination)
        with mock.patch.object(Path, "rename", fail_publish), self.assertRaises(OSError):
            self.installer.install_package(new, target, "claude", update_from=previous)
        self.assertEqual(self.fingerprint(target), previous)
        self.assertEqual(list(target.parent.glob(".video-install-*")), [])

    def testUserDestinationAppearingDuringStagingIsNeverOverwritten(self):
        source = self.package()
        target = self.root / "appeared-during-copy"
        copytree = shutil.copytree
        def create_user_destination(original, copied, *args, **options):
            result = copytree(original, copied, *args, **options)
            if Path(original) == source:
                target.mkdir()
                (target / "user.txt").write_text("Keep the other user's file")
            return result
        with mock.patch.object(shutil, "copytree", create_user_destination), self.assertRaises(ValueError):
            self.installer.install_package(source, target, "claude")
        self.assertEqual((target / "user.txt").read_text(), "Keep the other user's file")
        self.assertEqual(list(target.parent.glob(".video-install-*")), [])

    def testFailedRollbackPublicationKeepsTheCompleteCurrentPackage(self):
        _, target, previous = self.installed()
        new = self.package(version="1.1.0", changed=True)
        self.installer.install_package(new, target, "claude", update_from=previous)
        current = self.fingerprint(target)
        rename = Path.rename
        def fail_publish(path, destination):
            if path.name == "payload" and destination == target:
                raise OSError("Injected rollback publication failure")
            return rename(path, destination)
        with mock.patch.object(Path, "rename", fail_publish), self.assertRaises(OSError):
            self.installer.rollback_package(target, previous, current, "claude")
        self.assertEqual(self.fingerprint(target), current)
        retained = target.parent / ("." + target.name + ".previous-" + previous)
        self.assertEqual(self.fingerprint(retained), previous)
        self.assertEqual(list(target.parent.glob(".video-install-*")), [])

    def testFailedReadbackRestoresBothManifestAndSkill(self):
        _, target, previous = self.installed()
        new = self.package(version="1.1.0", changed=True)
        validate = self.installer.host_package_fingerprints
        def fail_new_readback(path, host):
            if path == target and json.loads((target / ".claude-plugin/plugin.json").read_text())["version"] == "1.1.0":
                raise ValueError("Injected published manifest/Skill readback failure")
            return validate(path, host)
        with mock.patch.object(self.installer, "host_package_fingerprints", fail_new_readback), self.assertRaises(ValueError):
            self.installer.install_package(new, target, "claude", update_from=previous)
        self.assertEqual(self.fingerprint(target), previous)
        self.assertEqual(list(target.parent.glob(".video-install-*")), [])

    def testFailedRestoreNeverDeletesTheOnlyDisplacedOriginal(self):
        _, target, previous = self.installed()
        new = self.package(version="1.1.0", changed=True)
        rename = Path.rename
        def fail_publish_and_restore(path, destination):
            if path.name in ("payload", "original") and destination == target:
                raise OSError("Injected publication and restore failures")
            return rename(path, destination)
        with mock.patch.object(Path, "rename", fail_publish_and_restore), self.assertRaisesRegex(ValueError, "唯一原安装完整保留"):
            self.installer.install_package(new, target, "claude", update_from=previous)
        retained = list(target.parent.glob(".video-install-*/original"))
        self.assertEqual(len(retained), 1)
        self.assertEqual(self.fingerprint(retained[0]), previous)

    def testRollbackRefusesATamperedRetainedManifest(self):
        _, target, previous = self.installed()
        new = self.package(version="1.0.1")
        self.installer.install_package(new, target, "claude", update_from=previous)
        current = self.fingerprint(target)
        backup = target.parent / ("." + target.name + ".previous-" + previous)
        manifest = backup / ".claude-plugin/plugin.json"
        data = json.loads(manifest.read_text()); data["version"] = "0.9.0"; manifest.write_text(json.dumps(data))
        with self.assertRaises(ValueError):
            self.installer.rollback_package(target, previous, current, "claude")
        self.assertEqual(self.fingerprint(target), current)

    def testCompletePackageCLIIsExplicitAndLegacySkillCLIStillWorks(self):
        source = self.package()
        target = self.root / "full-cli"
        base = ["install.py", "--host", "claude", "--destination", str(target)]
        with mock.patch("sys.argv", base + ["--package-source", str(source)]), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(self.installer.main(), 2)
        self.assertFalse(target.exists())
        with mock.patch("sys.argv", base + ["--host-package", "--package-source", str(source)]), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(self.installer.main(), 0)
        with mock.patch("sys.argv", base + ["--host-package", "--fingerprint"]), contextlib.redirect_stdout(io.StringIO()) as stream:
            self.assertEqual(self.installer.main(), 0)
        self.assertEqual(stream.getvalue().strip(), self.fingerprint(target))
        legacy = self.root / "legacy-skill"
        with mock.patch("sys.argv", ["install.py", "--host", "codex", "--destination", str(legacy)]), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(self.installer.main(), 0)
        self.assertEqual(self.installer.fingerprints(legacy), self.installer.fingerprints(self.skill))


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
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(CompleteHostPackageTests))
    if not result.wasSuccessful():
        raise SystemExit(1)


if __name__ == "__main__":
    main()
