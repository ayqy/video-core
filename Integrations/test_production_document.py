"""Declaration boundary tests; literal protocol fixtures are not native media."""
from copy import deepcopy
from pathlib import Path
import plistlib
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import production_document as document_module
import production_workflow as workflow_module
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

    def test_plain_portrait_layout_uses_complete_motion_and_keeps_business_clock(self):
        from scene_layout import present
        from test_presenter_composition import inputs
        scene,_,_,_,_=inputs(self.base,duration=480)
        value=self.declaration();value.update(aspect='9:16',viewport=[720,1280],
            story_layout=dict(mode='plain',bounds=[.06,.10,.94,.88]))
        # The declaration has no injected causal claim; geometry is authored
        # before Core attaches the actual independent source facts.
        value['scene']['layers']=deepcopy(scene['layers'])
        value['motion_actions']=deepcopy(scene['storyActions'])
        document=self.load(value)
        before=deepcopy(scene)
        result=document.animate(scene,{}, {})
        expected=present(scene,'plain',viewport=(720,1280),target_bounds=(.06,.10,.94,.88))
        self.assertEqual(result['layers'],expected['layers'])
        self.assertEqual(result['storyActions'],expected['storyActions'])
        for key in ('voice','captions','storyCausality','durationFrames','narration'):
            self.assertEqual(result[key],before[key])
        self.assertEqual(scene,before)
        self.assertNotIn('layout_projection',result)
        self.assertNotIn('layout_profile',result)

    def test_presenter_portrait_viewport_reaches_the_actual_composer(self):
        from presenter_composition import compose
        from test_presenter_composition import inputs
        scene,timed,profile,materials,energy=inputs(self.base,duration=480,material='characters')
        profile.update(x=.5,y=.81,width=.62,height=.38)
        value=self.declaration();value.update(aspect='9:16',viewport=[720,1280],presenter=profile)
        value['scene']['layers']=deepcopy(scene['layers'])
        value['motion_actions']=deepcopy(scene['storyActions'])
        document=self.load(value);document.energy=energy;document.voice_sha256=timed['voice_sha256']
        row=document.rows['characters']
        source=dict(assetID=materials['characters']['asset_id'],evidenceID=materials['characters']['evidence_id'],
            hash=row['sha256'],source=row['source'],owner=row['owner'],license=row['license'])
        actual=dict(characters=dict(materials['characters'],path=str(row['path']),sha256=row['sha256'],source=source))
        result=document.animate(scene,timed,materials)
        self.assertEqual(result,compose(scene,timed,profile,actual,energy,viewport=(720,1280)))

    def test_invalid_or_conflicting_story_layout_rejects_before_import(self):
        for layout in (dict(mode='game'),dict(mode='plain',bounds=[0,0,0,.8]),
                       dict(mode='plain',bounds=[0,0,1,2]),dict(mode='plain',unknown=True)):
            doc=self.declaration();doc['story_layout']=layout
            with self.subTest(layout=layout),self.assertRaises(ValueError):self.load(doc)
        from test_presenter_composition import inputs
        scene,_,profile,_,_=inputs(self.base,duration=480,material='characters')
        profile.update(x=.5,y=.81,width=.62,height=.38,story_bounds=[.06,.06,.061,.061])
        doc=self.declaration();doc.update(aspect='9:16',viewport=[720,1280],presenter=profile)
        doc['scene']['layers']=deepcopy(scene['layers'])
        with self.assertRaisesRegex(ValueError,'Native .01..1'):self.load(doc)


class AuthorEstimateDocumentTests(unittest.TestCase):
    """Literal non-media bytes and patched sample observations, never a decoder."""
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.base=Path(self.temp.name).resolve();self.material=self.base/'material.fixture'
        self.material.write_bytes(b'UNIT explicit non-image bytes')
        self.voice=self.base/'original.wav';self.voice.write_bytes(b'UNIT explicit non-audio bytes')
        self.receipt=self.base/'source.md';self.samples=384000
        design=document_module.voice_design
        self.value=DocumentTests.declaration(self)
        self.value['voice_identifier']='adult-taiwan-warm-narrative-v1'
        engine=dict(engine=design.ENGINE,model=design.MODEL_REVISION,source_wheel=design.SOURCE_WHEEL_SHA256,
            runtime_sha256='a'*64,adapter_sha256='b'*64,source_list_sha256=design.SOURCE_MANIFEST_SHA256)
        self.request,self.key=design.request_identity(engine,self.value['scene']['narration'],
            self.value['voice_identifier'],design.DESIGNS[self.value['voice_identifier']]['instruction'],1986)
        self.original_receipt=design.receipt(self.request,self.key,self.voice,self.samples)
        self.receipt.write_text(self.original_receipt)
        self.binary=self.base/'cli.fixture';self.binary.write_bytes(b'UNIT never-executed binary')
        for name in ('ffmpeg','ffprobe'):(self.base/name).write_bytes(b'UNIT never-executed tool')

    def declaration(self):
        value=deepcopy(self.value)
        value['speech_timing']=dict(version=1,kind='authored-sentence-estimate',
            source_receipt=dict(path=str(self.receipt),sha256=sha(self.receipt.read_bytes())))
        return value

    def args(self,value=None,label='valid',boundaries=None):
        path=self.base/(label+'.plist');path.write_bytes(plistlib.dumps(value or self.declaration()))
        return SimpleNamespace(document=path,voice=self.voice,boundaries=boundaries,
            home=self.base/(label+'-home'),output=self.base/(label+'-out'),binary=self.binary,
            binary_sha256=sha(self.binary.read_bytes()),previous_inputs_sha256=None)

    def construct(self,args):
        with patch.object(document_module.voice_design,'inspect_wave',return_value=(self.samples,24000)) as measurement, \
             patch.object(workflow_module.shutil,'which',side_effect=lambda name:str(self.base/name)):
            host=DocumentProduction(args)
        self.addCleanup(host.state.close)
        return host,measurement

    def test_explicit_mode_freezes_full_source_and_has_estimated_axis_without_word_metadata(self):
        host,measurement=self.construct(self.args())
        self.assertGreaterEqual(measurement.call_count,1)
        self.assertEqual(host.source_speech_inputs(),(self.voice,self.receipt))
        self.assertIsNone(host.boundaries);self.assertEqual(host.timed['frames'],480)
        self.assertEqual(host.timed['axis']['kind'],'authored-sentence-estimate')
        self.assertNotIn('first_word_frame',host.timed['axis'])
        self.assertNotIn('word_boundary_count',host.timed['axis'])
        self.assertTrue(all(c['alignment']=='estimated_sentence_no_word_timestamps'
                            and c['confirmed'] is False for c in host.timed['captions']))
        proof=workflow_module.read(host.home/'speech-provenance.plist')
        self.assertEqual(proof['version'],2);self.assertEqual(proof['kind'],'authored-sentence-estimate')
        self.assertEqual(proof['measured_samples'],self.samples);self.assertEqual(proof['sample_rate'],24000)
        self.assertEqual(proof['source_receipt_sha256'],sha(self.receipt.read_bytes()))
        self.assertNotIn('word_boundaries_sha256',proof)
        self.assertFalse(proof['voice_listened']);self.assertFalse(proof['captions_confirmed'])
        pins=workflow_module.read(host.home/'inputs.plist')
        self.assertEqual(pins[str(self.voice)],sha(self.voice.read_bytes()))
        self.assertEqual(pins[str(self.receipt)],sha(self.receipt.read_bytes()))
        self.assertEqual(host.document.value['scene']['narration'],self.value['scene']['narration'])
        self.assertIn('无词时间戳',host.production_description())

    def test_estimate_schema_rejects_unknown_modes_versions_approvals_and_retained_mix(self):
        changes=[lambda v:v['speech_timing'].update(version=True),
            lambda v:v['speech_timing'].update(version=2),lambda v:v['speech_timing'].update(kind='WordBoundary'),
            lambda v:v['speech_timing'].update(confirmed=True),lambda v:v.update(retained_speech={}),
            lambda v:v['speech_timing']['source_receipt'].update(sha256='0'*64)]
        for index,change in enumerate(changes):
            value=self.declaration();change(value);args=self.args(value,label='invalid-'+str(index))
            with self.subTest(index=index),self.assertRaises(ValueError):ProductionDocument(args.document)
            self.assertFalse(args.home.exists())

    def test_estimate_cannot_claim_sdk_words_or_inherit_a_different_voice_text_or_generation_receipt(self):
        args=self.args(label='with-words',boundaries=self.base/'unused-boundaries')
        with self.assertRaisesRegex(ValueError,'cannot carry SDK'):DocumentProduction(args)
        self.assertFalse(args.home.exists())
        substitutions=[('|text|'+self.request['text']+'|','|text|different whole script|'),
            ('|voice|adult-taiwan-warm-narrative-v1|','|voice|different-voice|'),
            ('|cache_key|'+self.key+'|','|cache_key|'+'0'*64+'|'),
            ('|samples|384000|','|samples|384001|'),
            ('|speed|1.0|','|speed|1.1|'),
            ('|instruction|'+self.request['instruction']+'|','|instruction|changed instruction|')]
        for index,(old,new) in enumerate(substitutions):
            self.assertIn(old,self.original_receipt)
            self.receipt.write_text(self.original_receipt.replace(old,new))
            args=self.args(label='bad-source-'+str(index))
            with self.subTest(index=index),patch.object(document_module.voice_design,'inspect_wave',return_value=(self.samples,24000)), \
                 self.assertRaises(ValueError):DocumentProduction(args)
            self.assertFalse(args.home.exists())

    def test_changed_original_receipt_or_sample_observation_cannot_reuse_the_saved_estimate(self):
        args=self.args();host,_=self.construct(args)
        before=(host.home/'speech-axis.plist').read_bytes()
        with patch.object(document_module.voice_design,'inspect_wave',return_value=(self.samples+1,24000)), \
             self.assertRaisesRegex(ValueError,'receipt or measured samples'):
            DocumentProduction(args)
        self.assertEqual((host.home/'speech-axis.plist').read_bytes(),before)
        self.receipt.write_text(self.original_receipt+'changed provenance\n')
        with self.assertRaisesRegex(ValueError,'complete original voice receipt'):
            ProductionDocument(args.document)


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

    def test_author_estimate_provenance_cannot_be_relabelled_as_retained_observed_axis(self):
        witness=self.witness(ordinary=True)
        row=witness['speech-provenance'];path=Path(row['path'])
        proof=plistlib.loads(path.read_bytes())
        proof.update(version=2,kind='authored-sentence-estimate',timing_basis='authored-shot-proportions')
        proof.pop('word_boundaries_sha256')
        path.write_bytes(plistlib.dumps(proof));row['sha256']=sha(path.read_bytes())
        with self.assertRaisesRegex(ValueError,'complete axis and original input identities'):
            FrozenSpeech(witness,self.voice,self.receipt,self.plan)


if __name__ == '__main__': unittest.main()
