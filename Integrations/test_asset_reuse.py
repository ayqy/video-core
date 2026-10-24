"""Small synthetic PNGs exercise storage rules, never stand in for shipped art."""
from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import struct
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
import zlib

from asset_reuse import AssetCache, AssetRequest, AssetRights, AssetReuseError, GeneratedAsset, _png
from codex_production import resolve_sources
from codex_events import ProtocolError


def png(*, alpha=0, marker=20, method=0):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
    raw = bytes((method, marker, 30, 40, alpha))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


class AssetReuseTests(unittest.TestCase):
    def setUp(self):
        root = Path.cwd() / ".cache" / "asset-reuse-tests"
        root.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=root)
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.cache = AssetCache(self.root / "cache")
        self.request = AssetRequest("沙漏", "一只放在桌上的沙漏，正面", "彩铅手绘、大面积留白")
        self.original = self.root / "original.png"
        self.original.write_bytes(png())
        self.rights = AssetRights("生成记录持有人", "本次工具生成回执", "本地效果审稿；商用与上传未授权")

    def generated(self, request=None, path=None, rights=None):
        request, path = request or self.request, path or self.original
        return GeneratedAsset(path, hashlib.sha256(path.read_bytes()).hexdigest(), request.generation_prompt,
                              "真实测试原件来源\n完整回执应由生产调用方提供", rights or self.rights)

    def test_missing_without_adapter_does_not_claim_generation(self):
        plan = resolve_sources(self.cache, [self.request])
        self.assertFalse(plan.ready)
        self.assertEqual(plan.missing[0].state, "needs_generation")
        self.assertFalse(plan.missing[0].generated)
        with self.assertRaises(ProtocolError):
            plan.file_pins()
        self.assertEqual(list((self.root / "cache" / "objects").iterdir()), [])

    def test_arbitrary_name_original_is_reused_by_second_project(self):
        prompts = []
        def generate(prompt):
            prompts.append(prompt)
            return self.generated()
        first = resolve_sources(self.cache, [self.request], generator=generate)
        second = resolve_sources(AssetCache(self.root / "cache"), [self.request], generator=generate)
        self.assertTrue(first.ready and second.ready)
        self.assertTrue(first.items[0].generated)
        self.assertFalse(second.items[0].generated)
        self.assertEqual(len(prompts), 1)
        self.assertEqual(first.file_pins(), second.file_pins())
        self.assertEqual(first.items[0].path.read_bytes(), self.original.read_bytes())
        self.assertEqual(first.items[0].rights, self.rights)

    def test_only_one_missing_dependency_reaches_generator(self):
        self.cache.register(self.request, self.generated())
        new = AssetRequest("风筝", "一只带长尾的风筝", "彩铅手绘")
        seen = []
        def generate(prompt):
            seen.append(prompt)
            return self.generated(new)
        result = resolve_sources(self.cache, [self.request, new], generator=generate)
        self.assertTrue(result.ready)
        self.assertEqual(seen, [new.generation_prompt])
        self.assertEqual([item.generated for item in result.items], [False, True])

    def test_prompt_is_content_only_and_unchanged_after_cache_changes(self):
        before = self.request.generation_prompt
        other = AssetRequest("火箭", "蓝红色，向右上飞行", "彩铅")
        self.cache.register(other, self.generated(other))
        self.assertEqual(before, self.request.generation_prompt)
        for forbidden in ("火箭", "cache", "inventory", str(self.cache.directory), self.request.key):
            self.assertNotIn(forbidden, before)

    def test_changed_visual_contract_does_not_reuse_wrong_original(self):
        self.cache.register(self.request, self.generated())
        for request in (replace(self.request, description="侧面朝左"), replace(self.request, style="油画"),
                        replace(self.request, transparent=False), replace(self.request, name="时钟")):
            self.assertEqual(self.cache.resolve(request).reason, "not_found")
        latin = AssetRequest("Hour Glass", "front", "pencil")
        self.assertEqual(latin.key, AssetRequest("Ｈｏｕｒ  Glass", "front", "pencil").key)

    def test_source_pin_and_actual_alpha_are_required(self):
        bad_pin = replace(self.generated(), sha256="0" * 64)
        with self.assertRaises(AssetReuseError):
            self.cache.register(self.request, bad_pin)
        self.original.write_bytes(png(alpha=255))
        with self.assertRaises(AssetReuseError):
            self.cache.register(self.request, self.generated())
        self.assertEqual(self.cache.resolve(self.request).reason, "not_found")

    def test_corrupt_original_invalidates_without_overwriting_history(self):
        available = self.cache.register(self.request, self.generated())
        available.path.write_bytes(png(marker=80))
        self.assertEqual(self.cache.resolve(self.request).reason, "integrity_failed")
        with sqlite3.connect(self.cache.database) as connection:
            self.assertEqual(connection.execute("SELECT state FROM originals").fetchone()[0], "invalid")
            self.assertEqual(connection.execute("SELECT count(*) FROM failures").fetchone()[0], 1)
        with self.assertRaises(AssetReuseError):
            self.cache.register(self.request, self.generated())
        self.assertEqual(available.path.read_bytes(), png(marker=80))

    def test_expired_or_revoked_source_is_not_reused(self):
        future = (datetime.now(timezone.utc) + timedelta(hours=1)).isoformat()
        self.cache.register(self.request, self.generated(rights=replace(self.rights, expires_at=future)))
        with sqlite3.connect(self.cache.database) as connection:
            rights = json.loads(connection.execute("SELECT rights FROM originals").fetchone()[0])
            rights["expires_at"] = "2000-01-01T00:00:00+00:00"
            connection.execute("UPDATE originals SET rights=?", (json.dumps(rights),))
        self.assertEqual(self.cache.resolve(self.request).reason, "expired")
        self.cache.revoke(self.request)
        self.assertEqual(self.cache.resolve(self.request).reason, "revoked")
        with self.assertRaises(AssetReuseError):
            self.cache.register(self.request, self.generated())

    def test_cache_does_not_grant_commercial_or_upload_rights(self):
        self.cache.register(self.request, self.generated())
        self.assertEqual(self.cache.resolve(self.request, use="commercial").reason, "use_not_permitted")
        self.assertEqual(self.cache.resolve(self.request, use="upload").reason, "use_not_permitted")
        with self.assertRaises(AssetReuseError):
            self.cache.register(self.request, self.generated(), use="commercial")
        self.assertEqual(self.cache.resolve(self.request).rights, self.rights)

    def test_live_conflict_is_refused_and_original_preserved(self):
        first = self.cache.register(self.request, self.generated())
        changed = self.root / "different.png"
        changed.write_bytes(png(marker=99))
        with self.assertRaises(AssetReuseError):
            self.cache.register(self.request, self.generated(path=changed))
        self.assertEqual(self.cache.resolve(self.request).sha256, first.sha256)

    def test_revocation_applies_to_same_original_across_different_requests(self):
        alternative = replace(self.request, description="同一沙漏，换一个描述")
        self.cache.register(self.request, self.generated())
        self.cache.register(alternative, self.generated(alternative))
        self.cache.revoke(self.request)
        self.assertEqual(self.cache.resolve(alternative).reason, "revoked")
        third = replace(self.request, style="彩铅，另一个标签")
        with self.assertRaises(AssetReuseError):
            self.cache.register(third, self.generated(third))
        self.assertEqual(self.cache.resolve(third).reason, "not_found")

    def test_stale_selection_cannot_pin_after_revocation_or_expiry(self):
        rights = replace(self.rights, verified=True, commercial_allowed=True,
                         expires_at="2099-01-01T00:00:00+00:00")
        self.cache.register(self.request, self.generated(rights=rights))
        selected = resolve_sources(self.cache, [self.request], use="commercial")
        self.assertTrue(selected.ready)
        with patch("asset_reuse.time.time", return_value=5_000_000_000):
            self.assertFalse(selected.ready)
            with self.assertRaises(ProtocolError):
                selected.file_pins()
        self.cache.revoke(self.request)
        self.assertFalse(selected.ready)
        with self.assertRaises(ProtocolError):
            selected.file_pins()

    def test_linked_objects_are_refused_before_any_outside_write(self):
        objects = self.cache.directory / "objects"
        objects.rename(self.cache.directory / "objects-original")
        outside = self.root / "outside"
        outside.mkdir()
        objects.symlink_to(outside)
        writes = []
        actual = os.fsync
        def observe(descriptor):
            writes.extend(outside.iterdir())
            return actual(descriptor)
        with patch("asset_reuse.os.fsync", side_effect=observe):
            with self.assertRaises(AssetReuseError):
                self.cache.register(self.request, self.generated())
        self.assertEqual(writes, [])
        self.assertEqual(list(outside.iterdir()), [])

    def test_object_parent_replacement_cannot_redirect_a_started_write(self):
        objects = self.cache.directory / "objects"
        outside = self.root / "outside"
        outside.mkdir()
        actual, changed = os.fsync, []
        def replace_parent(descriptor):
            if not changed:
                changed.append(True)
                objects.rename(self.cache.directory / "objects-original")
                objects.symlink_to(outside)
            return actual(descriptor)
        with patch("asset_reuse.os.fsync", side_effect=replace_parent):
            with self.assertRaises(AssetReuseError):
                self.cache.register(self.request, self.generated())
        self.assertTrue(changed)
        self.assertEqual(list(outside.iterdir()), [])
        self.assertEqual(list((self.cache.directory / "objects-original").iterdir()), [])

    def test_index_and_lock_links_are_rejected_without_outside_mutation(self):
        outside = self.root / "outside.sqlite"
        with sqlite3.connect(outside) as connection:
            connection.execute("CREATE TABLE keep (value INTEGER)")
        initial = outside.read_bytes()
        self.cache.database.rename(self.cache.directory / "previous.sqlite")
        self.cache.database.symlink_to(outside)
        with self.assertRaises((AssetReuseError, OSError)):
            self.cache.resolve(self.request)
        self.assertEqual(outside.read_bytes(), initial)
        locks = self.cache.directory / "locks"
        locks.rename(self.cache.directory / "locks-original")
        outside_locks = self.root / "outside-locks"
        outside_locks.mkdir()
        locks.symlink_to(outside_locks)
        with self.assertRaises(AssetReuseError):
            self.cache.resolve(self.request)
        self.assertEqual(list(outside_locks.iterdir()), [])

    def test_generator_failure_or_wrong_prompt_leaves_no_success_entry(self):
        def failed(prompt):
            raise RuntimeError("adapter failed")
        with self.assertRaises(RuntimeError):
            self.cache.ensure(self.request, failed)
        with self.assertRaises(AssetReuseError):
            self.cache.ensure(self.request, lambda prompt: replace(self.generated(), prompt="wrong prompt"))
        self.assertEqual(self.cache.resolve(self.request).reason, "not_found")
        with sqlite3.connect(self.cache.database) as connection:
            self.assertEqual(connection.execute("SELECT count(*) FROM originals").fetchone()[0], 0)
            self.assertEqual(connection.execute("SELECT count(*) FROM failures").fetchone()[0], 2)

    def test_concurrent_ensure_generates_once_under_same_key_lock(self):
        seen, guard = [], threading.Lock()
        def generate(prompt):
            with guard:
                seen.append(prompt)
            time.sleep(.04)
            return self.generated()
        with ThreadPoolExecutor(max_workers=4) as executor:
            results = list(executor.map(lambda _: AssetCache(self.root / "cache").ensure(self.request, generate), range(4)))
        self.assertEqual(len(seen), 1)
        self.assertEqual(sum(value.generated for value in results), 1)
        self.assertEqual(len({value.sha256 for value in results}), 1)
        self.assertEqual(list((self.cache.directory / "objects").glob(".original-*")), [])

    def test_provenance_and_prompt_are_retained_exactly(self):
        source = self.generated()
        self.cache.register(self.request, source)
        self.cache.register(self.request, source)
        with sqlite3.connect(self.cache.database) as connection:
            rows = connection.execute("SELECT prompt,provenance,rights FROM originals").fetchall()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0][0], source.prompt)
        self.assertEqual(rows[0][1], source.provenance)
        self.assertFalse(json.loads(rows[0][2])["verified"])

    def test_links_unknown_fields_and_invalid_usage_are_refused(self):
        linked = self.root / "link.png"
        linked.symlink_to(self.original)
        with self.assertRaises(AssetReuseError):
            self.cache.register(self.request, self.generated(path=linked))
        with self.assertRaises(AssetReuseError):
            AssetRequest.from_dict({"name": "x", "description": "y", "style": "z", "transparent": True, "inventory": []})
        with self.assertRaises(AssetReuseError):
            self.cache.resolve(self.request, use="anything")
        with self.assertRaises(ProtocolError):
            resolve_sources(self.cache, [self.request, self.request])

    def test_png_checksum_stream_bounds_filter_and_trailing_data_are_refused(self):
        good = png()
        self.assertEqual(_png(good, transparent=True), (1, 1))
        for bad in (good[:-1], good + b"extra", good[:30] + b"x" + good[31:], png(method=5)):
            with self.assertRaises(AssetReuseError):
                _png(bad, transparent=True)


if __name__ == "__main__":
    unittest.main()
