"""Deterministic authoring boundaries; these tests do not pass a visual TC."""
from copy import deepcopy
import json
from pathlib import Path
import tempfile
import unittest

from production_motion import MotionError, _read_json, _sample, apply_motion, compile_motion


class ProductionMotionTests(unittest.TestCase):
    def project(self):
        image = dict(id="drawing", kind="图片", assetID="actual-png", x=.5, y=.5,
                     width=.16, height=.24, startFrame=0, endFrame=120, locked=False,
                     keyframes=[], text="", color="FFFFFF", opacity=1)
        label = dict(id="number", kind="文字", x=.5, y=.7, width=.15, height=.07,
                     startFrame=0, endFrame=120, locked=False, keyframes=[], text="3枚")
        scene = dict(id="scene", kind="知识讲解", title="第三枚，改变结果", body="同一条件",
                     narration="先有两枚，补第三枚，才达到门槛。", durationFrames=120,
                     speed=1, pauseFrames=0, locked=False, layers=[image, label],
                     captions=[dict(id="cue", text="第三枚", startFrame=42, endFrame=80, confirmed=True)],
                     voice=dict(assetID="complete-source-voice", durationFrames=120, listened=True),
                     speechPlan=dict(source="原文", confirmed=True))
        return dict(id="project", workspaceID="workspace", revisions=[dict(id="revision", fps=30,
                    aspect="16:9", scenes=[scene], review=dict(sound=True, fullPreview=True))])

    def spec(self, **event):
        value = dict(scene_id="scene", layer_id="drawing", kind="pop", start_frame=42, duration_frames=12,
                     safe_rect=[.05, .22, .95, .76])
        value.update(event)
        return dict(version=1, base_revision="revision", fps=30, events=[value])

    def candidate(self, project, spec):
        return compile_motion(project, spec)["edits"][0]["replaceScene"]["_1"]

    def test_motion_changes_drawings_but_preserves_script_audio_cues_and_historical_review(self):
        project = self.project(); before = deepcopy(project)
        scene = self.candidate(project, self.spec())
        original = project["revisions"][-1]["scenes"][0]
        for field in ("title", "body", "narration", "durationFrames", "speed", "pauseFrames", "speechPlan"):
            self.assertEqual(scene[field], original[field])
        self.assertEqual(scene["voice"]["assetID"], original["voice"]["assetID"])
        self.assertFalse(scene["voice"]["listened"])
        self.assertFalse(scene["captions"][0]["confirmed"])
        self.assertEqual({k:v for k,v in scene["captions"][0].items() if k != "confirmed"},
                         {k:v for k,v in original["captions"][0].items() if k != "confirmed"})
        self.assertEqual(scene["layers"][1], original["layers"][1])
        self.assertEqual(project, before)

    def test_cue_is_not_pre_animated_and_attention_settles_quickly(self):
        layer = self.candidate(self.project(), self.spec())["layers"][0]
        for frame in (0, 20, 41):
            self.assertEqual(_sample(layer, frame), (.5, .5, 1))
        self.assertEqual(_sample(layer, 42), (.5, .5, .25))
        self.assertEqual(_sample(layer, 50), (.5, .5, 1.35))
        for frame in (54, 80, 119):
            self.assertEqual(_sample(layer, frame), (.5, .5, 1))

    def test_same_authored_motion_is_stable_and_repeating_creates_no_edit(self):
        project = self.project(); spec = self.spec()
        first = compile_motion(project, spec)
        self.assertEqual(first, compile_motion(project, spec))
        project["revisions"][-1]["scenes"][0] = first["edits"][0]["replaceScene"]["_1"]
        self.assertEqual(compile_motion(project, spec)["edits"], [])

    def test_separate_events_hold_previous_transfer_destination_without_preroll(self):
        project = self.project(); spec = self.spec(kind="transfer", start_frame=12, to=[.7, .6], arc=.1)
        spec["events"].append(dict(scene_id="scene", layer_id="drawing", kind="emphasis", start_frame=60,
                                   duration_frames=12, peak_scale=1.2, safe_rect=[.05, .22, .95, .8]))
        layer = self.candidate(project, spec)["layers"][0]
        self.assertEqual(_sample(layer, 24), (.7, .6, 1))
        self.assertEqual(_sample(layer, 59), (.7, .6, 1))
        self.assertEqual(_sample(layer, 60), (.7, .6, 1))
        self.assertEqual(_sample(layer, 72), (.7, .6, 1))

    def test_existing_authored_motion_needs_explicit_replace_and_locks_are_never_removed(self):
        project = self.project(); layer = project["revisions"][-1]["scenes"][0]["layers"][0]
        layer["keyframes"] = [dict(id="original", frame=0, x=.4, y=.5, scale=1)]
        with self.assertRaisesRegex(MotionError, "explicit replace_existing"):
            compile_motion(project, self.spec())
        self.assertEqual(len(compile_motion(project, self.spec(replace_existing=True))["edits"]), 1)
        for target in (project["revisions"][-1]["scenes"][0], layer):
            target["locked"] = True
            with self.assertRaisesRegex(MotionError, "locked"):
                compile_motion(project, self.spec(replace_existing=True))
            target["locked"] = False

    def test_text_and_numbers_cannot_receive_drawing_gestures(self):
        with self.assertRaisesRegex(MotionError, "readability"):
            compile_motion(self.project(), self.spec(layer_id="number"))

    def test_offscreen_arc_overshoot_and_reserved_text_area_fail_without_mutation(self):
        for patch in (dict(kind="transfer", to=[.8,.6], arc=.4), dict(peak_scale=2, safe_rect=[.4,.4,.6,.6]),
                      dict(kind="swoop", **{"from":[.02,.4]}), dict(safe_rect=[.05,.22,.95,.6])):
            project = self.project(); before = deepcopy(project)
            with self.subTest(patch=patch), self.assertRaises(MotionError):
                compile_motion(project, self.spec(**patch))
            self.assertEqual(project, before)

    def test_stale_revision_fps_unknown_fields_and_nonfinite_or_boolean_inputs_fail(self):
        variants = []
        for field, value in (("base_revision","old"),("fps",60),("fps",True),("version",True),("future",1)):
            spec=self.spec(); spec[field]=value; variants.append(spec)
        for field, value in (("start_frame",True),("duration_frames",3),("peak_scale",float("nan")),
                             ("peak_scale",float("inf")),("replace_existing",1),("future",1),("to",[.4,.5])):
            spec=self.spec(); spec["events"][0][field]=value; variants.append(spec)
        for spec in variants:
            with self.subTest(spec=spec), self.assertRaises(MotionError):
                compile_motion(self.project(),spec)

    def test_intervals_must_be_disjoint_visible_and_have_settle_frame(self):
        for patch in (dict(start_frame=110),dict(start_frame=-1),dict(duration_frames=54000)):
            with self.subTest(patch=patch), self.assertRaises(MotionError):
                compile_motion(self.project(),self.spec(**patch))
        spec=self.spec();spec["events"].append(deepcopy(spec["events"][0]))
        with self.assertRaisesRegex(MotionError,"overlap"):
            compile_motion(self.project(),spec)

    def test_source_frames_survive_speed_and_an_existing_pause_hold_contract(self):
        project=self.project(); scene=project["revisions"][-1]["scenes"][0]
        scene["speed"]=2
        layer=self.candidate(project,self.spec())["layers"][0]
        self.assertEqual(_sample(layer,2*25),(.5,.5,1.35))
        scene["pauseFrames"]=8
        with self.assertRaisesRegex(MotionError,"final-frame hold"):
            compile_motion(project,self.spec())
        scene["layers"][0]["entrance"]=dict(version=1,kind="fade",startFrame=0,endFrame=8)
        candidate=self.candidate(project,self.spec())
        self.assertEqual(candidate["pauseFrames"],8)
        self.assertEqual(candidate["layers"][0]["entrance"],scene["layers"][0]["entrance"])

    def test_reveal_keeps_offset_and_fast_window_and_never_invents_stroke_drawing(self):
        project=self.project(); layer=project["revisions"][-1]["scenes"][0]["layers"][0]
        layer["entrance"]=dict(version=1,kind="revealLeft",startFrame=12,endFrame=90,sourceOffsetFrames=20)
        new=self.candidate(project,self.spec(kind="reveal",start_frame=42,duration_frames=9))["layers"][0]
        self.assertEqual(new["keyframes"],[])
        self.assertEqual(new["entrance"],dict(version=1,kind="revealLeft",startFrame=62,endFrame=71,sourceOffsetFrames=20))
        self.assertEqual(layer["entrance"]["endFrame"],90)

    def test_real_editor_adapter_sends_one_dry_and_one_cas_transaction_only(self):
        project=self.project(); calls=[]
        def invoke(command,body,dry):
            calls.append((command,body,dry))
            return dict(ok=True,state="dry_run" if dry else "needs_review",project_id="project",revision="new")
        result=apply_motion(project,self.spec(),invoke)
        self.assertTrue(result["changed"])
        self.assertEqual([x[2] for x in calls],[True,False])
        self.assertEqual(calls[0][0],"edit apply")
        self.assertEqual(calls[0][1],calls[1][1])
        self.assertEqual(calls[0][1]["base_revision"],"revision")
        self.assertNotIn("events",calls[0][1])

    def test_dry_rejection_stops_mutation_and_matching_plan_does_not_call_editor(self):
        project=self.project();calls=[]
        def reject(command,body,dry):
            calls.append(dry);return dict(ok=False,state="rejected")
        with self.assertRaisesRegex(MotionError,"dry-run"):
            apply_motion(project,self.spec(),reject)
        self.assertEqual(calls,[True])
        project["revisions"][-1]["scenes"][0]=self.candidate(project,self.spec())
        calls.clear()
        self.assertFalse(apply_motion(project,self.spec(),reject)["changed"])
        self.assertEqual(calls,[])

    def test_input_rejects_duplicate_fields_and_nonfinite_json(self):
        with tempfile.TemporaryDirectory() as root:
            p=Path(root)/"input.json"
            for text in ('{"fps":30,"fps":60}', '{"peak_scale":NaN}'):
                p.write_text(text)
                with self.assertRaises(MotionError):_read_json(p)
            p.write_text(json.dumps(self.spec()))
            self.assertEqual(_read_json(p),self.spec())


if __name__ == "__main__":
    unittest.main()
