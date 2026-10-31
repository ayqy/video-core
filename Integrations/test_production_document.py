"""Declaration boundary tests; literal protocol fixtures are not native media."""
from copy import deepcopy
from pathlib import Path
import plistlib
import tempfile
import unittest

from production_document import ProductionDocument, DocumentProduction
from production_workflow import sha
from production_workflow import data
from frozen_speech import FrozenSpeech
from test_knowledge_story import fixture, cost_fixture


class DocumentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.material = self.base/'unopened-fixture.png'
        self.material.write_bytes(b'explicit synthetic material bytes; normal Core must decode the real file')

    def declaration(self, maker=fixture):
        project, plan, _, _ = maker('pencil')
        scene = deepcopy(project['revisions'][-1]['scenes'][0])
        scene['layers'][0]['assetID'] = {'$asset': 'characters'}
        row = dict(path=self.material.name, sha256=sha(self.material.read_bytes()),
                   source='synthetic-boundary-fixture', owner='test', claim='no license or media claim', license='test only')
        return dict(version=1, name='独立内容声明', voice_identifier='explicit-voice', aspect='16:9', fps=30,
                    viewport=[1280,720], presentation=plan, scene=scene, materials=dict(characters=row))

    def load(self, value):
        path = self.base/'declaration.plist'
        path.write_bytes(plistlib.dumps(value, fmt=plistlib.FMT_BINARY))
        return ProductionDocument(path)

    def test_named_exchange_and_cost_intervention_use_one_interface_without_delivery_ids(self):
        for maker in (fixture, cost_fixture):
            value = self.declaration(maker)
            source_before = deepcopy(value['presentation']['sources'])
            declaration = self.load(value)
            current = dict(id='new-target', workspaceID='new-workspace', revisions=[dict(id='new-v1', scenes=[dict(id='new-stage')])])
            result = declaration.presentation_for(current, dict(exchange='new-exchange', retain='new-retain'))
            self.assertEqual({s['id'] for s in result['sources']}, {'exchange', 'retain'})
            self.assertEqual(result['target']['scene_id'], 'new-stage')
            self.assertEqual(result['sources'][0]['model'], source_before[0]['model'])
            self.assertEqual(result['sources'][1]['model'], source_before[1]['model'])
            self.assertEqual(value['presentation']['sources'], source_before)

    def test_real_material_binding_keeps_declared_source_and_receipt_ids(self):
        document = self.load(self.declaration())
        bindings = dict(characters=dict(asset_id='actual-import-id', evidence_id='actual-evidence-id'))
        self.assertEqual(document.bind({'$asset': 'characters'}, bindings), 'actual-import-id')
        source = document.bind({'$source': 'characters'}, bindings)
        self.assertEqual((source['assetID'], source['evidenceID'], source['hash']),
                         ('actual-import-id', 'actual-evidence-id', sha(self.material.read_bytes())))
        self.assertEqual(source['license'], 'test only')

    def test_stage_does_not_stretch_a_voice_axis_or_migrate_review(self):
        document = self.load(self.declaration())
        with self.assertRaisesRegex(ValueError, 'actual full voice axis'):
            document.stage('scene', dict(frames=481, axis=dict(fps=30)), {})
        scene = document.stage('scene', dict(frames=480, axis=dict(fps=30), captions=[]),
                               dict(characters=dict(asset_id='image', evidence_id='proof')))
        self.assertEqual(scene['evidenceIDs'], ['proof'])
        self.assertNotIn('voice', scene)

    def test_foreign_business_claims_captions_and_unknown_fields_reject_before_import(self):
        for key, value in [('voice', dict(listened=True)), ('storyCausality', dict(version=1)),
                           ('storyActions', [dict(id='fake')]), ('captions', [dict(confirmed=True)])]:
            doc = self.declaration(); doc['scene'][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError): self.load(doc)
        doc = self.declaration(); doc['command'] = 'shell'
        with self.assertRaises(ValueError): self.load(doc)

    def test_changed_material_unknown_symbol_and_wrong_narration_reject(self):
        doc = self.declaration(); doc['materials']['characters']['sha256'] = '0'*64
        with self.assertRaises(ValueError): self.load(doc)

    def test_material_voice_cannot_replace_the_reserved_actual_audio_binding(self):
        doc = self.declaration()
        doc['materials']['voice'] = doc['materials'].pop('characters')
        with self.assertRaisesRegex(ValueError, 'voice is reserved'): self.load(doc)
        doc = self.declaration(); doc['scene']['layers'][0]['assetID'] = {'$asset': 'undeclared'}
        with self.assertRaises(ValueError): self.load(doc)
        doc = self.declaration(); doc['scene']['narration'] = 'another full text'
        with self.assertRaises(ValueError): self.load(doc)

    def test_quantity_and_actor_names_are_model_values_not_a_three_coin_guard(self):
        doc = self.declaration()
        for source in doc['presentation']['sources']:
            model = source['model']
            model['participants'][0]['name'] = '新参与人'
            for rule in model['ruleTable']['rules']:
                for effect in rule['effects']:
                    if effect['kind'] == 'transfer': effect['amount'] = 17
        result = self.load(doc)
        self.assertEqual(result.value['presentation']['sources'][0]['model']['participants'][0]['name'], '新参与人')
        self.assertEqual(result.value['presentation']['sources'][0]['model']['ruleTable']['rules'][0]['effects'][0]['amount'], 17)
        # This is declaration acceptance only; Core alone can compute/validate it.

    def test_conflicting_executor_catalog_rejects_without_a_production_home(self):
        from argparse import Namespace
        doc = self.declaration(); path = self.base/'declaration.plist'
        path.write_bytes(plistlib.dumps(doc))
        args = Namespace(document=path, executor=self.material, catalog=None)
        with self.assertRaisesRegex(ValueError, 'both installed advanced'):
            DocumentProduction(args)


class FrozenSpeechTests(unittest.TestCase):
    """Synthetic archive shape rules only; none of these bytes are real media."""
    def setUp(self):
        import json
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        project, plan, recorded, source = fixture('pencil')
        scene = project['revisions'][-1]['scenes'][0]
        from story_planning import StoryPlan
        shots = StoryPlan.from_dict(plan['story']).stage('shots')['shots']
        captions = [dict(startFrame=s['start_frame'], endFrame=s['start_frame']+s['duration_frames'],
                         text=s['narration'], confirmed=False) for s in shots]
        self.voice = self.base/'voice-original.mp3'; self.voice.write_bytes(b'synthetic-audio-fixture')
        self.receipt = dict(audio_sha256=sha(self.voice.read_bytes()), **{
            'word_boundaries.sha256':'a'*64, 'word_boundaries.count':'8',
            'request.text':scene['narration'], 'inspection.container_duration':'16'})
        self.voice.with_suffix('.source.md').write_text('synthetic pinned receipt only')
        asset = dict(id='voice', workspaceID='workspace', hash=self.receipt['audio_sha256'],
                     durationFrames=480, mediaType='audio', bytes=self.voice.stat().st_size, ext='mp3')
        scene.update(voice=dict(assetID='voice', durationFrames=480, listened=False,
                                textDigest=sha(data(scene['narration']))), captions=captions)
        source['revisions'][-1]['id'] = recorded['revision']
        for native, row in zip(source['revisions'][-1]['scenes'], recorded['sources']):
            native['simulationRecording'] = dict(recordedFPS=30, recordedDurationFrames=510,
                recordedSpeed=1, recordedPauseFrames=0, knowledgeTrace=deepcopy(row['trace']))
        quote = dict(provider='native', confirmed=True)
        artifacts = [dict(id=str(i), path='exports/job/'+name, revision='target-v1', sha256='b'*64, bytes=1)
                     for i,name in enumerate(('video.mp4','cover.png','captions.srt','publication.txt'))]
        job = dict(id='job', projectID=project['id'], revisionID='target-v1', state='needs_review',
                   quote=quote, artifacts=artifacts)
        self.snapshot = dict(projects=[project,source], assets=[asset], jobs=[job])
        prepared = dict(project_id=project['id'],workspace_id='workspace',revision_id='target-v1',
            source_project_id=source['id'],voice_asset_id='voice',frames=480,recorded=recorded,plan=plan)
        axis = dict(frames=480,first_word_frame=0,captions=captions,presentation=plan,
            axis=dict(fps=30,duration_frames=480,duration_seconds='16',narration=scene['narration'],
                voice_listened=False,captions_confirmed=False,word_boundary_count=8,first_word_frame=0,
                segments=[dict(shot_id=s['id'],text=s['narration'],start_frame=s['start_frame'],
                               end_frame=s['start_frame']+s['duration_frames']) for s in shots]))
        self.records = dict(prepared=prepared,quote=quote,
            produced=dict(job_id='job',revision='target-v1',state='needs_review',artifacts=artifacts),
            inputs={str(p):sha(p.read_bytes()) for p in (self.voice,self.voice.with_suffix('.source.md'))},
            **{'speech-axis':axis})
        self.plan = plan
        self.archive_assets = {'assets/'+asset['hash']+'.mp3':self.voice.read_bytes()}

    def witness(self, *, ordinary=False):
        values = deepcopy(self.records)
        raw = data(self.snapshot)
        values['backup'] = dict(version=2,snapshot=raw,digest=sha(raw),assets=self.archive_assets)
        for name,value in values.items():
            (self.base/(name+'.plist')).write_bytes(plistlib.dumps(value))
        axis = self.base/'speech-axis.plist'
        if ordinary:
            proof = dict(version=1,axis_sha256=sha(axis.read_bytes()),
                inputs_sha256=sha((self.base/'inputs.plist').read_bytes()),voice_sha256=sha(self.voice.read_bytes()),
                source_receipt_sha256=sha(self.voice.with_suffix('.source.md').read_bytes()),
                word_boundaries_sha256='a'*64,kind='retained-complete-axis')
            name='speech-provenance'
        else:
            name='revision-inputs'; proof={str(axis):sha(axis.read_bytes()),'old/speech-axis.plist':sha(axis.read_bytes())}
        (self.base/(name+'.plist')).write_bytes(plistlib.dumps(proof))
        return {n:dict(path=str(self.base/(n+'.plist')),sha256=sha((self.base/(n+'.plist')).read_bytes()))
                for n in (*FrozenSpeech.NAMES,name)}

    def test_revision_lineage_and_ordinary_production_each_bind_the_same_frozen_axis(self):
        for ordinary in (False,True):
            result=FrozenSpeech(self.witness(ordinary=ordinary),self.voice,self.receipt,self.plan)
            self.assertEqual(result.timed['frames'],480)
            self.assertEqual(result.boundaries_sha256,'a'*64)

    def test_mismatched_spoken_shot_axis_rejects_even_when_caption_and_backup_agree(self):
        self.records['speech-axis']['axis']['segments'][0]['shot_id']='wrong-shot'
        with self.assertRaisesRegex(ValueError,'story shots'): FrozenSpeech(self.witness(),self.voice,self.receipt,self.plan)

    def test_incomplete_observations_reject_even_when_both_saved_copies_match(self):
        recorded=self.records['prepared']['recorded']['sources'][0]['trace']
        recorded['events'].pop()
        self.snapshot['projects'][1]['revisions'][-1]['scenes'][0]['simulationRecording']['knowledgeTrace']=deepcopy(recorded)
        with self.assertRaisesRegex(ValueError,'partial trace'): FrozenSpeech(self.witness(),self.voice,self.receipt,self.plan)

    def test_mixed_job_artifact_revision_or_workspace_reject(self):
        self.snapshot['jobs'][0]['artifacts'][0]['revision']='another-revision'
        with self.assertRaises(ValueError): FrozenSpeech(self.witness(),self.voice,self.receipt,self.plan)

    def test_changed_original_receipt_is_not_accepted_through_ordinary_axis_proof(self):
        witness=self.witness(ordinary=True)
        self.voice.with_suffix('.source.md').write_text('changed original')
        with self.assertRaises(ValueError): FrozenSpeech(witness,self.voice,self.receipt,self.plan)


if __name__ == '__main__': unittest.main()
