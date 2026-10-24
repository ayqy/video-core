import copy
import hashlib
import tempfile
import unittest
from pathlib import Path

from asset_reuse import AssetCache, AssetRights, GeneratedAsset
from pencil_production import ContentDesign, ProductionError, produce_drawings
from test_asset_reuse import png


class PencilProductionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.cache = AssetCache(self.root / "cache")
        self.design = ContentDesign.from_dict(dict(version=1, title="为什么第三枚改变结果？", concept="先定因果，再决定画面所需路障。",
            drawings=[dict(name="任意新名红白路障", description="独立完整路障", style="彩铅", transparent=True)]))
        self.request = self.design.drawings[0]
        self.path = self.root / "original.png"
        self.path.write_bytes(png())
        self.digest = hashlib.sha256(self.path.read_bytes()).hexdigest()
        self.generated = GeneratedAsset(self.path, self.digest, self.request.generation_prompt, "真实生成器来源记录", AssetRights("owner", "source", "local draft"))
        self.project = dict(id="project", workspaceID="workspace", revisions=[dict(id="base", review=dict(sound=True), scenes=[
            dict(id="scene", locked=False, narration="原稿", durationFrames=300, speed=1, voice=dict(assetID="voice", listened=True),
                 captions=[dict(text="原字幕", startFrame=2, endFrame=30, confirmed=True)],
                 layers=[dict(id="layer", kind="图片", assetID="old", locked=False, keyframes=[])])])])
        self.bindings = [dict(name=self.request.name, scene_id="scene", layer_id="layer")]
        self.calls = []

    def invoke(self, command, body, dry=False):
        self.calls.append((command, copy.deepcopy(body), dry))
        if command == "assets list":
            return dict(ok=True, result=[])
        if dry:
            return dict(ok=True, state="dry_run")
        if command == "assets import":
            return dict(ok=True, result=dict(id="new-original", workspaceID="workspace", hash=self.digest, ext="png"))
        return dict(ok=True, state="needs_review", project_id="project", revision="next")

    def test_missing_is_an_explicit_handoff_without_any_native_mutation(self):
        result = produce_drawings(self.design, self.cache, self.project, self.bindings, self.invoke, apply=True)
        self.assertEqual(result["state"], "needs_generation")
        self.assertEqual(result["missing"][0][2], self.request.generation_prompt)
        self.assertEqual(self.calls, [])

    def test_actual_original_is_imported_and_bound_without_changing_script_audio_or_review_history(self):
        self.cache.register(self.request, self.generated)
        before = copy.deepcopy(self.project)
        result = produce_drawings(self.design, self.cache, self.project, self.bindings, self.invoke, apply=True)
        self.assertEqual(result["state"], "needs_review")
        self.assertEqual(result["imported"], 1)
        self.assertEqual(self.project, before)
        edit = self.calls[-1][1]["edits"][0]["replaceScene"]["_1"]
        self.assertEqual(edit["layers"][0]["assetID"], "new-original")
        self.assertEqual(edit["voice"]["assetID"], "voice")
        self.assertFalse(edit["voice"]["listened"])
        self.assertFalse(edit["captions"][0]["confirmed"])
        self.assertEqual(edit["captions"][0]["startFrame"], 2)
        self.assertEqual(edit["narration"], "原稿")
        self.assertEqual([c[0] for c in self.calls], ["assets list", "assets import", "assets import", "edit apply", "edit apply"])
        self.assertEqual(self.calls[-1][1], self.calls[-2][1])

    def test_unchanged_native_binding_checks_workspace_bytes_without_new_asset_or_revision(self):
        self.cache.register(self.request, self.generated)
        self.project["revisions"][-1]["scenes"][0]["layers"][0]["assetID"] = "new-original"
        commands = []
        def invoke(command, body, dry):
            commands.append((command, dry))
            asset = dict(id="new-original", workspaceID="workspace", hash=self.digest, ext="png")
            if command == "assets list":
                return dict(ok=True, result=[asset])
            self.assertEqual(command, "assets import")
            return dict(ok=True, state="dry_run") if dry else dict(ok=True, result=asset)
        result = produce_drawings(self.design, self.cache, self.project, self.bindings, invoke, apply=True)
        self.assertEqual(result["state"], "unchanged")
        self.assertEqual(result["imported"], 0)
        self.assertEqual(commands, [("assets list", False), ("assets import", True), ("assets import", False)])

    def test_changed_inventory_does_not_change_frozen_content_or_prompt(self):
        digest, prompt = self.design.digest, self.request.generation_prompt
        self.cache.register(self.request, self.generated)
        planned = produce_drawings(self.design, self.cache, self.project, self.bindings, self.invoke)
        self.cache.revoke(self.request)
        missing = produce_drawings(self.design, self.cache, self.project, self.bindings, self.invoke)
        self.assertEqual(planned["content_sha256"], missing["content_sha256"])
        self.assertEqual(self.design.digest, digest)
        self.assertEqual(missing["missing"][0][2], prompt)
        self.assertEqual(self.calls, [])

    def test_invalid_or_locked_target_is_rejected_before_source_import(self):
        self.cache.register(self.request, self.generated)
        for locked in ("scene", "layer"):
            project = copy.deepcopy(self.project)
            scene = project["revisions"][-1]["scenes"][0]
            (scene if locked == "scene" else scene["layers"][0])["locked"] = True
            with self.assertRaises(ProductionError):
                produce_drawings(self.design, self.cache, project, self.bindings, self.invoke, apply=True)
        self.assertEqual(self.calls, [])

    def test_native_dry_rejection_or_wrong_original_stops_editor(self):
        self.cache.register(self.request, self.generated)
        for wrong in (False, True):
            commands = []
            def invoke(command, body, dry):
                commands.append(command)
                if command == "assets list":
                    return dict(ok=True, result=[])
                if dry:
                    return dict(ok=True, state="dry_run" if wrong else "needs_review")
                return dict(ok=True, result=dict(id="new", workspaceID="workspace", ext="png", hash="0" * 64))
            with self.assertRaises(ProductionError):
                produce_drawings(self.design, self.cache, self.project, self.bindings, invoke, apply=True)
            self.assertNotIn("edit apply", commands)

    def test_explicit_generator_sees_only_the_missing_content_prompt(self):
        prompts = []
        def generate(prompt):
            prompts.append(prompt)
            return self.generated
        result = produce_drawings(self.design, self.cache, self.project, self.bindings, self.invoke, generator=generate)
        self.assertEqual(result["state"], "planned")
        produce_drawings(self.design, self.cache, self.project, self.bindings, self.invoke, generator=generate)
        self.assertEqual(prompts, [self.request.generation_prompt])
        self.assertEqual(self.calls, [])


if __name__ == "__main__":
    unittest.main()
