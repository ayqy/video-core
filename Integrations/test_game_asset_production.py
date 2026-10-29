"""Finite production-contract tests; tiny test PNGs are not visual acceptance."""
import copy
from datetime import datetime, timezone
import hashlib
import struct
import tempfile
import unittest
import zlib
from pathlib import Path

from asset_reuse import AssetCache, AssetReuseError, AssetRights, GeneratedAsset
from game_asset_production import GameAssetError, GameContentDesign, GameStyle, produce_game_assets
from test_asset_reuse import png


class GameAssetProductionTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        self.cache = AssetCache(self.root / "cache")
        self.anchor = self.root / "native-game-reference.png"
        self.anchor.write_bytes(png(marker=3))
        self.anchor_hash = hashlib.sha256(self.anchor.read_bytes()).hexdigest()
        self.style = GameStyle.from_dict(dict(name="固定魔塔风格", description="参考原图相同俯视角度、像素轮廓、有限配色和场内尺度",
                                             anchors=[dict(path=str(self.anchor), sha256=self.anchor_hash)]))
        self.design = GameContentDesign.from_dict(dict(version=1, title="货物怎样运出去", concept="内容先决定需要一辆空货车，角色和货物分开。",
            elements=[dict(name="独立空木货车", description="完整独立空车，不含人物或货物，用于通路运货和断路受阻。", transparent=True)]))
        self.request = self.style.requests(self.design)[0]
        self.original = self.root / "generated-cart.png"
        self.original.write_bytes(png(marker=11))
        self.sha = hashlib.sha256(self.original.read_bytes()).hexdigest()
        self.rights = AssetRights("生成记录持有人", "https://openai.com/policies/terms-of-use/", "仅本任务本地教学审稿；独立补件不是上游原图", verified=True)
        self.generated = GeneratedAsset(self.original, self.sha, self.request.generation_prompt, "本次真实生成工具完整回执（测试边界）", self.rights)
        self.proofs = {self.request.name: dict(origin="generated", source=self.rights.source, owner=self.rights.owner, license="本次独立生成素材；本地教学用途",
            claim=self.rights.claim, verified=True, commercial_allowed=False, upload_consent=False, expires_at=None,
            actual_prompt=self.generated.prompt, provenance=self.generated.provenance, original_asset_ids=["upstream"],
            checked_at=datetime.now(timezone.utc).isoformat())}
        self.binding = [dict(name=self.request.name, scene_id="scene", role="cargo_cart")]
        self.image_sources = {"upstream": dict(path=str(self.anchor), sha256=self.anchor_hash)}
        asset = dict(id="upstream", workspaceID="workspace", hash=self.anchor_hash, ext="png", bytes=self.anchor.stat().st_size,
                     mediaType="image", evidenceID="upstream-evidence")
        self.assets = [asset]
        source = dict(assetID="upstream", hash=self.anchor_hash, source="https://raw.githubusercontent.com/upstream/npcs.png",
                      owner="upstream author", license="BSD3", evidenceID="upstream-evidence")
        scene = dict(id="scene", kind="规则模拟", locked=False, narration="原稿", durationFrames=300, speed=1, storyActions=[],
                     voice=dict(assetID="voice", listened=True), captions=[dict(text="原字幕", startFrame=2, endFrame=30, confirmed=True)],
                     evidenceIDs=["upstream-evidence"],
                     gameWorld=dict(version=1, width=1, height=1, tiles=["floor"], entities=[dict(id="seller", name="商人", role="floor")], updates=[]),
                     classicArtwork=dict(gameplay="推箱子", derivation="下载原件", transformation="固定上游原图", originalAssetIDs=["upstream"],
                                         sprites=[dict(role="floor", assetID="upstream", x=0, y=0, width=1, height=1)], sources=[source], audioCues=[]))
        self.project = dict(id="project", workspaceID="workspace", revisions=[dict(id="base", review=dict(sound=True, picture=True), scenes=[scene])])
        self.calls = []

    def invoke(self, command, body, dry=False):
        self.calls.append((command, copy.deepcopy(body), dry))
        if command == "assets list":
            return dict(ok=True, result=copy.deepcopy(self.assets))
        if dry:
            return dict(ok=True, state="dry_run")
        if command == "assets import":
            data = Path(body["path"]).read_bytes()
            sha = hashlib.sha256(data).hexdigest()
            matches = [row for row in self.assets if row["hash"] == sha]
            if not matches:
                self.assets.append(dict(id="actual-cart", workspaceID="workspace", hash=sha, ext="png", bytes=len(data), mediaType="image"))
            return dict(ok=True, result=copy.deepcopy(next(row for row in self.assets if row["hash"] == sha)))
        if command == "evidence add":
            evidence = body["evidence"]
            asset = next(row for row in self.assets if row["id"] == evidence["assetID"])
            asset["evidenceID"] = evidence["id"]
            return dict(ok=True, result=evidence["id"])
        if command == "edit apply":
            self.assertEqual(body["base_revision"], self.project["revisions"][-1]["id"])
            latest = copy.deepcopy(self.project["revisions"][-1])
            latest["id"] = "new-revision"
            latest["review"] = dict(sound=False, picture=False)
            for edit in body["edits"]:
                replacement = edit["replaceScene"]
                for i, old in enumerate(latest["scenes"]):
                    if old["id"] == replacement["_0"]:
                        latest["scenes"][i] = copy.deepcopy(replacement["_1"])
            self.project["revisions"].append(latest)
            return dict(ok=True, state="needs_review", project_id="project", revision=latest["id"])
        self.fail("unexpected normal command: " + command)

    def call(self, **kwargs):
        return produce_game_assets(self.design, self.style, self.cache, self.project, self.binding, self.invoke,
                                   proofs=self.proofs, image_sources=self.image_sources, **kwargs)

    def ready(self):
        self.cache.register(self.request, self.generated)

    def writes(self, command):
        return [row for row in self.calls if row[0] == command and row[2] is False]

    def test_missing_returns_exact_prompt_and_references_without_native_calls(self):
        digest = self.design.digest
        output = self.call(apply=True)
        self.assertEqual(output["state"], "needs_generation")
        self.assertEqual(output["missing"][0]["prompt"], self.request.generation_prompt)
        self.assertEqual(output["missing"][0]["references"], (dict(path=str(self.anchor), sha256=self.anchor_hash),))
        self.assertEqual(self.design.digest, digest)
        self.assertEqual(self.calls, [])

    def test_one_missing_generator_gets_content_prompt_only_then_cache_is_reused(self):
        prompts = []
        def generate(prompt):
            prompts.append(prompt)
            return self.generated
        first = self.call(generator=generate)
        second = self.call(generator=generate)
        self.assertEqual(first["state"], "planned")
        self.assertEqual(second["state"], "planned")
        self.assertEqual(prompts, [self.request.generation_prompt])
        self.assertNotIn(str(self.cache.directory), prompts[0])
        self.assertNotIn("cache", prompts[0])
        self.assertEqual(self.writes("assets import"), [])

    def test_normal_source_binding_is_one_cas_and_repeat_is_unchanged(self):
        self.ready()
        before = copy.deepcopy(self.project)
        output = self.call(apply=True)
        self.assertEqual(output["state"], "needs_review")
        self.assertEqual(len(self.writes("edit apply")), 1)
        self.assertEqual(len(self.writes("evidence add")), 1)
        self.assertEqual(self.project["revisions"][0], before["revisions"][0])
        scene = self.project["revisions"][-1]["scenes"][0]
        self.assertEqual(scene["gameWorld"], before["revisions"][0]["scenes"][0]["gameWorld"])
        self.assertEqual(scene["narration"], "原稿")
        self.assertEqual(scene["voice"]["assetID"], "voice")
        self.assertFalse(scene["voice"]["listened"])
        self.assertFalse(scene["captions"][0]["confirmed"])
        artwork = scene["classicArtwork"]
        self.assertEqual(artwork["derivation"], "下载原件")
        self.assertEqual(artwork["originalAssetIDs"], ["upstream"])
        self.assertEqual([row["role"] for row in artwork["sprites"]], ["floor", "cargo_cart"])
        self.assertIn(self.generated.prompt, artwork["transformation"])
        self.assertIn(self.generated.provenance, artwork["transformation"])
        self.assertIn(self.anchor_hash, artwork["transformation"])
        self.assertEqual(artwork["sources"][-1]["hash"], self.sha)
        again = self.call(apply=True)
        self.assertEqual(again["state"], "unchanged")
        self.assertEqual(again["imported"], 0)
        self.assertEqual(len(self.writes("edit apply")), 1)
        self.assertEqual(len(self.writes("evidence add")), 1)

    def test_style_change_is_a_miss_and_preserves_content_design_digest(self):
        self.ready()
        other = GameStyle.from_dict(dict(name="另一固定风格", description="同内容新的视角要求",
            anchors=[dict(path=str(self.anchor), sha256=self.anchor_hash)]))
        output = produce_game_assets(self.design, other, self.cache, self.project, self.binding, self.invoke, apply=True)
        self.assertEqual(output["state"], "needs_generation")
        self.assertEqual(output["content_sha256"], self.design.digest)
        self.assertEqual(self.calls, [])

    def test_revocation_or_corruption_cannot_reuse_old_selection(self):
        self.ready()
        self.cache.revoke(self.request)
        self.assertEqual(self.call(apply=True)["state"], "needs_generation")
        self.assertEqual(self.calls, [])

    def test_unverified_or_mismatched_provenance_never_imports(self):
        self.ready()
        for field, value in (("actual_prompt", "替代提示"), ("provenance", "伪来源"), ("verified", False),
                             ("commercial_allowed", True), ("checked_at", "2099-01-01T00:00:00+00:00")):
            with self.subTest(field=field):
                old = self.proofs[self.request.name][field]
                self.proofs[self.request.name][field] = value
                with self.assertRaises((GameAssetError, AssetReuseError)):
                    self.call(apply=True)
                self.proofs[self.request.name][field] = old
        self.assertEqual(self.calls, [])

    def test_wrong_or_missing_original_style_identity_is_rejected_before_import(self):
        self.ready()
        self.proofs[self.request.name]["original_asset_ids"] = ["not-this-original"]
        with self.assertRaises(GameAssetError):
            self.call(apply=True)
        self.assertEqual(self.writes("assets import"), [])

    def test_unknown_map_role_locked_scene_or_sprite_overflow_is_rejected_first(self):
        self.ready()
        original = copy.deepcopy(self.project)
        for mode in ("unknown", "locked", "overflow"):
            self.project = copy.deepcopy(original)
            scene = self.project["revisions"][-1]["scenes"][0]
            if mode == "unknown":
                scene["gameWorld"]["tiles"] = ["unbound-role"]
            elif mode == "locked":
                scene["locked"] = True
            else:
                scene["classicArtwork"]["sprites"] = [dict(role="floor" if i == 0 else "role" + str(i), assetID="upstream") for i in range(128)]
            with self.subTest(mode=mode), self.assertRaises(GameAssetError):
                self.call(apply=True)
        self.assertEqual(self.calls, [])

    def test_source_bank_overflow_or_bad_image_pin_does_not_import(self):
        self.ready()
        scene = self.project["revisions"][-1]["scenes"][0]
        original_sources = copy.deepcopy(scene["classicArtwork"]["sources"])
        scene["classicArtwork"]["sources"] += [dict(assetID="old" + str(i)) for i in range(63)]
        with self.assertRaises(GameAssetError):
            self.call(apply=True)
        scene["classicArtwork"]["sources"] = original_sources
        self.image_sources["upstream"]["sha256"] = "0" * 64
        with self.assertRaises(GameAssetError):
            self.call(apply=True)
        self.assertEqual(self.writes("assets import"), [])

    def test_stale_generated_selection_during_import_stops_editor(self):
        self.ready()
        def invoke(command, body, dry=False):
            if command == "assets import" and dry:
                self.cache.revoke(self.request)
            return self.invoke(command, body, dry)
        with self.assertRaises(ValueError):
            produce_game_assets(self.design, self.style, self.cache, self.project, self.binding, invoke,
                                proofs=self.proofs, image_sources=self.image_sources, apply=True)
        self.assertEqual(self.writes("edit apply"), [])
        self.assertEqual(self.writes("assets import"), [])

    def test_old_palette_png_is_accepted_but_full_bank_pixel_budget_is_enforced(self):
        self.ready()
        def source_png(width, height, color=3):
            def chunk(kind, body):
                return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xffffffff)
            # Old source decode belongs to native importer/Host. These passive
            # pinned bytes exercise palette-header/accounting, not image quality.
            return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, color, 0, 0, 0)) + chunk(b"IEND", b"")
        scene = self.project["revisions"][-1]["scenes"][0]
        for i in range(3):
            file = self.root / ("bank" + str(i) + ".png")
            file.write_bytes(source_png(4096, 4096))
            digest = hashlib.sha256(file.read_bytes()).hexdigest()
            asset_id = "large-" + str(i)
            self.assets.append(dict(id=asset_id, workspaceID="workspace", hash=digest, ext="png", bytes=file.stat().st_size, mediaType="image"))
            self.image_sources[asset_id] = dict(path=str(file), sha256=digest)
            scene["classicArtwork"]["sprites"].append(dict(role="large-" + str(i), assetID=asset_id))
        # Two old 16Mpx palette originals fit the 48M bank with the new tiny PNG.
        removed = scene["classicArtwork"]["sprites"].pop()
        self.assertEqual(self.call()["state"], "planned")
        scene["classicArtwork"]["sprites"].append(removed)
        with self.assertRaises(GameAssetError):
            self.call(apply=True)
        self.assertEqual(self.writes("assets import"), [])

    def test_too_many_image_sources_is_rejected_without_native_mutation(self):
        self.ready()
        scene = self.project["revisions"][-1]["scenes"][0]
        for i in range(31):
            asset_id = "separate-" + str(i)
            self.assets.append(dict(id=asset_id, workspaceID="workspace", hash=self.anchor_hash, ext="png", bytes=self.anchor.stat().st_size, mediaType="image"))
            self.image_sources[asset_id] = self.image_sources["upstream"]
            scene["classicArtwork"]["sprites"].append(dict(role="separate-" + str(i), assetID=asset_id))
        with self.assertRaises(GameAssetError):
            self.call(apply=True)
        self.assertEqual(self.writes("assets import"), [])

    def test_native_rejection_or_wrong_evidence_stops_revision(self):
        self.ready()
        def invoke(command, body, dry=False):
            response = self.invoke(command, body, dry)
            if command == "evidence add" and not dry:
                self.assets[-1]["evidenceID"] = "different-evidence"
            return response
        with self.assertRaises(GameAssetError):
            produce_game_assets(self.design, self.style, self.cache, self.project, self.binding, invoke,
                                proofs=self.proofs, image_sources=self.image_sources, apply=True)
        self.assertEqual(self.writes("edit apply"), [])

    def test_failed_dry_run_with_success_like_state_never_imports(self):
        self.ready()
        def invoke(command, body, dry=False):
            if command == "assets import" and dry:
                return dict(ok=False, state="dry_run")
            return self.invoke(command, body, dry)
        with self.assertRaises(GameAssetError):
            produce_game_assets(self.design, self.style, self.cache, self.project, self.binding, invoke,
                                proofs=self.proofs, image_sources=self.image_sources, apply=True)
        self.assertEqual(self.writes("assets import"), [])


if __name__ == "__main__":
    unittest.main()
