"""Pure integration contracts; synthetic history/bytes are never media evidence.

No test starts a native product, decoder, importer, signing tool or renderer.
The histories below only exercise author-side identity and resume boundaries.
"""
from argparse import Namespace
from copy import deepcopy
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

import production_document as document
import production_runtime as runtime
from production_workflow import ProductionWorkflow, sha
from story_planning import StoryPlan
from test_knowledge_story import fixture
from test_presenter_composition import inputs as presenter_inputs
import test_production_document as document_fixture


def source_history():
    """Literal identity history; a fake recording is not a Core observation."""
    scene = dict(id='source-scene', kind='规则模拟', durationFrames=510,
                 sourceStartFrame=0, speed=1, pauseFrames=0, locked=False,
                 simulation=dict(seed=19, knowledge=dict(version=3, label='synthetic-model')))
    base = dict(id='source-base', fps=30, aspect='16:9', scenes=[scene])
    recorded = deepcopy(base)
    recorded.update(id='source-recorded', parentID=base['id'])
    recorded['scenes'][0]['simulationRecording'] = dict(
        recordedFPS=30, recordedDurationFrames=510,
        knowledgeTrace=dict(label='synthetic-history-only'))
    recorded['scenes'][0]['simulationRecordingConfirmed'] = False
    again = deepcopy(recorded)
    again.update(id='source-verified', parentID=recorded['id'])
    project = dict(id='source-project', workspaceID='source-workspace',
                   revisions=[base, recorded, again])
    receipt = dict(workspaceID=project['workspaceID'], projectID=project['id'],
                   baseRevision=base['id'])
    return receipt, project


class SourceRevisionRules(unittest.TestCase):
    def test_new_import_requires_the_exact_current_revision(self):
        receipt, project = source_history()
        with self.assertRaises(ValueError):
            document.validate_source_revision(receipt, project, False)
        receipt['baseRevision'] = project['revisions'][-1]['id']
        document.validate_source_revision(receipt, project, False)

    def test_reused_import_survives_normal_recording_successors_without_mutation(self):
        receipt, project = source_history()
        for number, revision in enumerate(project['revisions']):
            revision.update(number=number, createdAt='synthetic-'+str(number),
                            change='synthetic normal history metadata', invalidated=[],
                            dependencies=dict(capturedAt='synthetic-'+str(number), inputs=[]))
        before = deepcopy((receipt, project))
        document.validate_source_revision(receipt, project, True)
        self.assertEqual((receipt, project), before)
        project['revisions'] = project['revisions'][:1]
        document.validate_source_revision(receipt, project, True)

    def test_foreign_workspace_project_missing_or_duplicate_base_reject(self):
        changes = [lambda r, p: r.update(workspaceID='foreign-workspace'),
                   lambda r, p: r.update(projectID='foreign-project'),
                   lambda r, p: r.update(baseRevision='missing-base'),
                   lambda r, p: p['revisions'].insert(0, deepcopy(p['revisions'][0]))]
        for change in changes:
            receipt, project = source_history()
            change(receipt, project)
            with self.subTest(change=change), self.assertRaises(ValueError):
                document.validate_source_revision(receipt, project, True)

    def test_recording_cannot_hide_model_seed_time_scene_identity_or_branch_changes(self):
        changes = [lambda s: s['simulation']['knowledge'].update(label='changed-model'),
                   lambda s: s['simulation'].update(seed=20),
                   lambda s: s.update(durationFrames=511),
                   lambda s: s.update(id='other-scene'),
                   lambda s: s.update(sourceStartFrame=1),
                   lambda s: s.update(speed=2),
                   lambda s: s.update(pauseFrames=1),
                   lambda s: s.update(simulationRecordingConfirmed=True),
                   lambda s: s.update(simulationRecordingConfirmed=0)]
        for change in changes:
            receipt, project = source_history()
            change(project['revisions'][1]['scenes'][0])
            with self.subTest(change=change), self.assertRaises(ValueError):
                document.validate_source_revision(receipt, project, True)
        for field, value in [('fps', 24), ('parentID', 'unrelated-branch')]:
            receipt, project = source_history()
            project['revisions'][1][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                document.validate_source_revision(receipt, project, True)
        receipt, project = source_history()
        project['revisions'][1]['scenes'].append(deepcopy(project['revisions'][1]['scenes'][0]))
        with self.assertRaises(ValueError):
            document.validate_source_revision(receipt, project, True)

    def test_an_existing_recording_cannot_be_replaced_or_removed_on_resume(self):
        for remove in (False, True):
            receipt, project = source_history()
            scene = project['revisions'][-1]['scenes'][0]
            if remove:
                scene.pop('simulationRecording')
            else:
                scene['simulationRecording']['knowledgeTrace']['label'] = 'replacement-observation'
            with self.subTest(remove=remove), self.assertRaises(ValueError):
                document.validate_source_revision(receipt, project, True)


class ProjectionRules(unittest.TestCase):
    def test_only_mode_anchors_and_existing_balance_subjects_change(self):
        _, plan, _, _ = fixture('pencil')
        plan['balances'] = [dict(source_id='exchange', event=dict(round=1, phase='settlement'),
                                 actor_id='weaver', entity_id='coin-weaver', frame=350)]
        before = deepcopy(plan)
        projection = dict(mode='game', anchors={key: dict(x=.4, y=.6) for key in plan['anchors']},
                          balance_subjects=dict(weaver='person-weaver'))
        projected = document.project_presentation(plan, projection)
        expected = deepcopy(before)
        expected['target']['mode'] = 'game'
        expected['anchors'] = deepcopy(projection['anchors'])
        expected['balances'][0]['entity_id'] = 'person-weaver'
        self.assertEqual(projected, expected)
        self.assertEqual(plan, before)
        projected['sources'][0]['model']['knowledgeLabel'] = 'output-local-change'
        projected['story']['brief']['title'] = 'output-local-title'
        self.assertEqual(plan, before)

    def test_projection_cannot_inject_sources_story_or_new_observations(self):
        _, plan, _, _ = fixture('pencil')
        for key in ('sources', 'story', 'beats'):
            projection = dict(mode='game', anchors=deepcopy(plan['anchors']), **{key: []})
            with self.subTest(key=key), self.assertRaises(ValueError):
                document.project_presentation(plan, projection)
        with self.assertRaises(ValueError):
            document.project_presentation(plan, dict(mode='game', anchors=plan['anchors'],
                                                    balance_subjects=dict(foreign='invented-observation')))
        original = deepcopy(plan)
        projected = document.project_presentation(plan, None)
        projected['target']['mode'] = 'game'
        self.assertEqual(plan, original)


class PresenterPreflightRules(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.base = Path(folder.name).resolve()
        self.material = self.base/'unopened-fixture.png'
        self.material.write_bytes(b'SYNTHETIC HASH FIXTURE ONLY; never decode')

    def declaration(self, factor=1):
        value = document_fixture.DocumentTests.declaration(self)
        if factor != 1:
            old = StoryPlan.from_dict(value['presentation']['story'])
            rebuilt = StoryPlan(deepcopy(old.to_dict()['brief']))
            for stage in ('cast', 'outline', 'details', 'shots'):
                content = deepcopy(old.stage(stage))
                if stage == 'shots':
                    for shot in content['shots']:
                        shot['start_frame'] *= factor
                        shot['duration_frames'] *= factor
                rebuilt = rebuilt.accept(stage, content, rebuilt.fingerprint)
            value['presentation']['story'] = rebuilt.to_dict()
            for row in value['presentation']['sources'] + value['presentation']['beats']:
                row['start_frame'] *= factor
                row['end_frame'] *= factor
            value['scene']['durationFrames'] *= factor
        duration = value['scene']['durationFrames']
        _, _, profile, _, _ = presenter_inputs(self.base, duration=duration, material='characters')
        value['presenter'] = profile
        return value

    def assert_reject_before_writes(self, value):
        path = self.base/'declaration.plist'
        path.write_bytes(plistlib.dumps(value))
        with self.assertRaises(ValueError):
            document.ProductionDocument(path)
        home = self.base/'must-not-create'
        with patch.object(ProductionWorkflow, '__init__', side_effect=AssertionError('write boundary crossed')):
            with self.assertRaises(ValueError):
                document.DocumentProduction(Namespace(document=path, home=home))
        self.assertFalse(home.exists())

    def test_bad_profile_rejects_before_runtime_or_workspace_writes(self):
        for change in (lambda p: p.update(material_key='undeclared'),
                       lambda p: p.update(id='person-weaver'),
                       lambda p: p['cues'][0].update(endFrame=479),
                       lambda p: p.update(unknown_approval=True)):
            value = self.declaration()
            change(value['presenter'])
            with self.subTest(change=change):
                self.assert_reject_before_writes(value)

    def test_over_sixty_second_energy_input_rejects_at_declaration_boundary(self):
        value = self.declaration(factor=4)
        self.assertGreater(value['scene']['durationFrames'], 60*value['fps'])
        ordinary = deepcopy(value)
        ordinary.pop('presenter')
        path = self.base/'valid-long-ordinary.plist'
        path.write_bytes(plistlib.dumps(ordinary))
        document.ProductionDocument(path)
        self.assert_reject_before_writes(value)

    def test_optional_styles_leave_a_normal_free_declaration_usable(self):
        value = document_fixture.DocumentTests.declaration(self)
        path = self.base/'ordinary.plist'
        path.write_bytes(plistlib.dumps(value))
        parsed = document.ProductionDocument(path)
        self.assertNotIn('presenter', parsed.value)
        self.assertNotIn('sdk_import', parsed.value)
        self.assertEqual(parsed.narration, value['scene']['narration'])

    def test_real_adapter_join_keeps_the_frozen_timed_object_and_business_facts(self):
        scene, timed, profile, materials, energy = presenter_inputs(self.base)
        item = materials[profile['material_key']]
        scene['evidenceIDs'].append(item['evidence_id'])
        voice = self.base/'synthetic-voice.fixture'
        voice.write_bytes(b'SYNTHETIC ORIGINAL VOICE IDENTITY; NEVER DECODE')
        energy['sourceSHA256'] = sha(voice.read_bytes())
        timed.pop('voice_sha256')
        before = deepcopy((scene, timed, materials, energy))
        author = document.ProductionDocument.__new__(document.ProductionDocument)
        author.value = dict(presenter=profile)
        author.rows = {profile['material_key']:dict(path=item['path'],sha256=item['sha256'],
            **{key:item['source'][key] for key in ('source','owner','license')})}
        owner = document.DocumentProduction.__new__(document.DocumentProduction)
        owner.document = owner.author = author
        owner.voice, owner.home, owner.ffmpeg = voice, self.base, self.base/'decoder-never-started'
        owner.timed, owner.FPS = timed, 30
        with patch.object(document, 'analyze_take', return_value=energy) as measurement:
            result = owner.animate_scene(scene, materials)
        self.assertEqual((scene, timed, materials, energy), before)
        self.assertNotIn('voice_sha256', timed)
        self.assertEqual(measurement.call_args.kwargs['voice_asset_id'], scene['voice']['assetID'])
        self.assertEqual(measurement.call_args.kwargs['text_digest'], scene['voice']['textDigest'])
        for key in ('voice','captions','narration','storyCausality','durationFrames'):
            self.assertEqual(result[key], scene[key])
        for original, projected in zip(scene['storyActions'], result['storyActions']):
            self.assertEqual({k:v for k,v in original.items() if k not in ('from','to','waypoints')},
                             {k:v for k,v in projected.items() if k not in ('from','to','waypoints')})


class ImporterProvenanceRules(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.base = Path(folder.name).resolve()
        self.helper = self.base/'ImportSynthetic.fixture'
        self.helper.write_bytes(b'SYNTHETIC EXECUTABLE HASH FIXTURE; NEVER RUN')
        self.helper.chmod(0o700)
        self.digest = sha(self.helper.read_bytes())
        self.runtime = self.base/'runtime'
        self.runtime.mkdir()
        self.native = 'a'*64
        (self.runtime/'verified-runtime.plist').write_bytes(plistlib.dumps(dict(native_input_sha256=self.native)))
        self.source = Path(document.__file__).resolve().parent/'native/ImportMotaMaterials.swift'
        raw = self.source.read_bytes()
        self.link = dict(version=1, stage='current-normal-sdk-link', source_sha256=sha(raw),
            native_input_sha256=self.native, newly_executed_rules=0,
            inputs={'Integrations/native/ImportMotaMaterials.swift':dict(bytes=len(raw), sha256=sha(raw))},
            product=dict(path=str(self.helper), bytes=self.helper.stat().st_size, sha256=self.digest))
        self.receipt = self.base/'sdk-link.plist'

    def check(self, link=None, digest=None):
        self.receipt.write_bytes(plistlib.dumps(self.link if link is None else link))
        return runtime.checked_importer(self.helper, digest or self.digest, self.receipt, self.runtime)

    def test_exact_importer_source_and_runtime_return_frozen_input_pins(self):
        pins = self.check()
        self.assertEqual(pins[str(self.helper)], self.digest)
        self.assertEqual(pins[str(self.receipt)], sha(self.receipt.read_bytes()))
        self.assertEqual(pins[str(self.source)], sha(self.source.read_bytes()))

    def test_wrong_binary_source_native_stage_or_rule_claim_rejects(self):
        changes = [lambda r: r['product'].update(sha256='b'*64),
                   lambda r: r['product'].update(bytes=1),
                   lambda r: r['product'].update(path=str(self.base/'other-helper')),
                   lambda r: r.update(source_sha256='b'*64),
                   lambda r: r['inputs']['Integrations/native/ImportMotaMaterials.swift'].update(sha256='b'*64),
                   lambda r: r['inputs']['Integrations/native/ImportMotaMaterials.swift'].update(bytes=1),
                   lambda r: r.update(native_input_sha256='b'*64),
                   lambda r: r.update(stage='obsolete-link'),
                   lambda r: r.update(newly_executed_rules=1)]
        for change in changes:
            link = deepcopy(self.link)
            change(link)
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.check(link)
        with self.assertRaises(ValueError):
            self.check(digest='b'*64)


if __name__ == '__main__':
    unittest.main()
