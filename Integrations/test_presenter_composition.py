"""Synthetic metadata rules, never Native/real-media or visual acceptance proof.

Fixtures write labelled synthetic bytes solely to test source hashing. Literal
timing, receipts, source regions and RMS are not claimed to be normal imports,
decoded takes, real mouth drawings or approved rights. No media is opened.
"""
from copy import deepcopy
import hashlib
from pathlib import Path
import tempfile
import unittest

from presenter_composition import compose, PresenterCompositionError
from scene_layout import present


def inputs(folder, *, actor='fixture-guide', material='fixture-sheet', duration=83,
           amount=7, business='fixture-courier', suffix='one'):
    path = Path(folder).resolve()/('synthetic-'+suffix+'.fixture')
    path.write_bytes(('SYNTHETIC METADATA HASH FIXTURE '+suffix).encode())
    sha = hashlib.sha256(path.read_bytes()).hexdigest()
    voice = dict(assetID='fixture-take-'+suffix, textDigest=hashlib.sha256(suffix.encode()).hexdigest(),
                 durationFrames=duration, listened=False, method='synthetic metadata only')
    narration = '合成说明：交付数量为'+str(amount)+'。'
    captions = [dict(id='fixture-caption', text=narration, startFrame=0, endFrame=duration,
                     confirmed=False)]
    scene = dict(id='fixture-scene-'+suffix, kind='图文讲解', title='合成业务标题', body='旧正文',
        narration=narration, durationFrames=duration, sourceStartFrame=0, speed=1,
        pauseFrames=0, preservePitch=True, voice=voice, captions=captions,
        narrativeSources=['fixture-original-story-'+suffix], evidenceIDs=['fixture-business-proof'],
        layers=[dict(id=business, kind='图片', x=.2, y=.5, width=.2, height=.3, opacity=1,
                     keyframes=[dict(frame=0, x=.2, y=.5, scale=1)],
                     assetID='fixture-business-picture', sourceRect=dict(x=.1,y=.2,width=.3,height=.4),
                     imageFlipHorizontal=True),
                dict(id='fixture-destination',kind='图片',x=.8,y=.5,width=.2,height=.3,
                     opacity=1,keyframes=[]),
                dict(id='fixture-resource-pool', kind='色块', x=.01,y=.01,width=.01,height=.01,
                     opacity=0,keyframes=[])],
        storyActions=[dict(id='fixture-delivery-'+suffix, kind='transfer', subjectID=business,
                          targetID='fixture-destination', quantity=amount, startFrame=0,
                          endFrame=duration, **{'from':dict(x=.2,y=.5),'to':dict(x=.8,y=.5)},
                          waypoints=[dict(x=.5,y=.6)])],
        storyCausality=dict(sources=[dict(id='fixture-source',trace='synthetic fact')],
                            bindings=[dict(actionID='fixture-delivery-'+suffix,amount=amount)]),
        paperPresentation=dict(version=1,layout='explanation',paperColor='FFFFFF'))
    frames = [dict(role='fixture-mouth-'+str(i),sourceRect=dict(x=i/4,y=0,width=.25,height=1))
              for i in range(4)]
    clip_frames = [dict(role=row['role'],mouthOpen=openness)
                   for row,openness in zip(frames,(0,.25,.65,1))]
    profile = dict(version=1,id=actor,material_key=material,master_role=frames[0]['role'],
        frames=frames, clips=[dict(id='fixture-authored',frameDurationFrames=4,frames=clip_frames)],
        cues=[dict(startFrame=0,endFrame=duration,clipID='fixture-authored',animationOffsetFrames=2)],
        x=.82,y=.55,width=.3,height=.9,anchor='bottom',layout='presenter')
    item = dict(asset_id='fixture-import-'+suffix,evidence_id='fixture-proof-'+suffix,
        path=path,sha256=sha,frames=deepcopy(frames),
        source=dict(assetID='fixture-import-'+suffix,hash=sha,source='synthetic fixture source',
                    owner='synthetic metadata rules',license='fixture only, not production permission',
                    evidenceID='fixture-proof-'+suffix))
    timed = dict(frames=duration,voice_sha256=hashlib.sha256(('voice-'+suffix).encode()).hexdigest(),
                 captions=deepcopy(captions),axis=dict(segments=[dict(text=narration,
                     start_frame=0,end_frame=duration)]))
    energy = dict(actorID=actor,voiceAssetID=voice['assetID'],sourceSHA256=timed['voice_sha256'],
                  textDigest=voice['textDigest'],durationFrames=duration,
                  energy=[dict(startFrame=0,endFrame=duration,rms=.04)])
    return scene,timed,profile,{material:item},energy


class PresenterCompositionRules(unittest.TestCase):
    def setUp(self):
        self.folder=tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)

    def fixture(self,**kwargs):
        return inputs(self.folder.name,**kwargs)

    def reject(self,mutate,**kwargs):
        values=self.fixture(**kwargs);before=deepcopy(values)
        mutate(*values)
        invalid=deepcopy(values)
        with self.assertRaises(PresenterCompositionError):compose(*values)
        self.assertEqual(values,invalid,'Rejected metadata must not modify any input')
        return before

    def test_arbitrary_actor_material_duration_quantity_and_business_ids_compose(self):
        for i,(duration,amount) in enumerate(((1,1),(59,19),(1807,450),(54000,9999))):
            with self.subTest(duration=duration,amount=amount):
                values=self.fixture(actor='guide-'+str(i),material='sheet-'+str(i),duration=duration,
                                    amount=amount,business='carrier-'+str(i),suffix=str(i))
                result=compose(*values)
                self.assertEqual(result['cartoonPresenter']['id'],'guide-'+str(i))
                self.assertEqual(result['durationFrames'],duration)
                self.assertEqual(result['storyActions'][0]['quantity'],amount)
                self.assertEqual(result['classicArtwork']['sources'],[values[3]['sheet-'+str(i)]['source']])

    def test_scene_voice_captions_sources_title_and_causality_remain_independent(self):
        values=self.fixture();before=deepcopy(values);result=compose(*values)
        self.assertEqual(values,before)
        for key in ('id','title','narration','voice','captions','storyCausality','narrativeSources',
                    'durationFrames','sourceStartFrame','speed','pauseFrames','preservePitch'):
            self.assertEqual(result[key],values[0][key])
        result['voice']['listened']=True
        result['captions'][0]['confirmed']=True
        result['storyCausality']['bindings'][0]['amount']=99
        result['classicArtwork']['sources'][0]['owner']='changed'
        result['cartoonPresenter']['clips'][0]['frames'][0]['mouthOpen']=.1
        result['cartoonPresenter']['speech']['energy'][0]['rms']=.9
        self.assertEqual(values,before)

    def test_only_shared_layout_geometry_changes_business_actions_and_layers(self):
        values=self.fixture();scene=values[0];result=compose(*values);projected=present(scene,'presenter')
        self.assertEqual(result['layers'],projected['layers'])
        self.assertEqual(result['storyActions'],projected['storyActions'])
        for old,new in zip(scene['storyActions'],result['storyActions']):
            self.assertEqual({k:v for k,v in old.items() if k not in ('from','to','waypoints')},
                             {k:v for k,v in new.items() if k not in ('from','to','waypoints')})
        self.assertEqual(result['layers'][-1]['width'],.01)
        self.assertEqual(result['layers'][0]['sourceRect'],scene['layers'][0]['sourceRect'])
        self.assertEqual(result['layers'][0]['imageFlipHorizontal'],True)
        self.assertNotIn('layout_projection',result)
        self.assertNotIn('layout_profile',result)

    def test_prior_shared_layout_is_rebased_without_stale_native_scene_metadata(self):
        values=self.fixture();values=(present(values[0],'plain'),*values[1:])
        before=deepcopy(values);expected=present(values[0],'presenter');result=compose(*values)
        self.assertEqual(values,before)
        self.assertEqual(result['layers'],expected['layers'])
        self.assertEqual(result['storyActions'],expected['storyActions'])
        self.assertNotIn('layout_projection',result)
        self.assertNotIn('layout_profile',result)

    def test_title_is_metadata_body_empty_and_paper_presentation_removed(self):
        values=self.fixture();result=compose(*values)
        self.assertEqual(result['title'],values[0]['title'])
        self.assertEqual(result['body'],'')
        self.assertEqual(result['kind'],'原创卡通')
        self.assertNotIn('paperPresentation',result)
        self.assertEqual([row['id'] for row in result['layers']],[row['id'] for row in values[0]['layers']])
        self.assertNotIn('title',result['cartoonPresenter'])

    def test_supplied_clips_cues_box_and_rms_are_not_synthesized_or_retimed(self):
        values=self.fixture(duration=97);profile=values[2]
        profile['cues']=[dict(startFrame=0,endFrame=8,clipID='fixture-authored',animationOffsetFrames=31),
                         dict(startFrame=8,endFrame=97,clipID='fixture-authored',animationOffsetFrames=0)]
        values[4]['energy']=[dict(startFrame=0,endFrame=12,rms=0),dict(startFrame=12,endFrame=97,rms=.2)]
        result=compose(*values);host=result['cartoonPresenter']
        for key in ('clips','cues','x','y','width','height','anchor'):self.assertEqual(host[key],profile[key])
        self.assertEqual(host['speech'],values[4])
        self.assertEqual(set(host['speech']['energy'][0]),{'startFrame','endFrame','rms'})

    def test_actual_frame_table_is_stable_for_the_same_original_across_takes(self):
        values=self.fixture();first=compose(*values)
        other=deepcopy(values);other[0]['voice']['assetID']='fixture-other-take'
        other[1]['voice_sha256']='9'*64
        other[4].update(voiceAssetID='fixture-other-take',sourceSHA256='9'*64)
        second=compose(*other)
        self.assertEqual(first['classicArtwork'],second['classicArtwork'])
        self.assertEqual(first['cartoonPresenter']['clips'],second['cartoonPresenter']['clips'])
        self.reject(lambda s,t,p,m,e:m[p['material_key']]['frames'][0]['sourceRect'].update(width=.2))

    def test_minimum_required_material_receipt_works_without_an_extra_frame_manifest(self):
        values=self.fixture();values[3][values[2]['material_key']].pop('frames')
        result=compose(*values)
        self.assertEqual(len(result['classicArtwork']['sprites']),4)
        self.assertEqual(result['evidenceIDs'],['fixture-business-proof','fixture-proof-one'])

    def test_material_key_asset_evidence_hash_and_classic_source_must_agree(self):
        mutations=[lambda s,t,p,m,e:p.update(material_key='missing'),
            lambda s,t,p,m,e:m[p['material_key']].update(sha256='0'*64),
            lambda s,t,p,m,e:m[p['material_key']]['source'].update(assetID='other'),
            lambda s,t,p,m,e:m[p['material_key']]['source'].update(evidenceID='other'),
            lambda s,t,p,m,e:m[p['material_key']]['source'].update(hash='0'*64),
            lambda s,t,p,m,e:m[p['material_key']]['source'].update(owner=' '),
            lambda s,t,p,m,e:m[p['material_key']]['source'].update(license='x'*16385),
            lambda s,t,p,m,e:m[p['material_key']]['source'].update(unapproved=True)]
        for mutate in mutations:
            with self.subTest(mutate=mutate):self.reject(mutate)

    def test_changed_missing_empty_or_symlink_original_is_rejected(self):
        for mode in ('changed','missing','empty','symlink'):
            values=self.fixture(suffix=mode);item=values[3][values[2]['material_key']];path=item['path']
            if mode=='changed':path.write_bytes(b'OTHER SYNTHETIC BYTES')
            elif mode=='missing':path.unlink()
            elif mode=='empty':path.write_bytes(b'')
            else:
                link=path.with_suffix('.link');link.symlink_to(path);item['path']=link
            with self.subTest(mode=mode),self.assertRaises(PresenterCompositionError):compose(*values)

    def test_profile_requires_all_explicit_contract_fields_and_no_unknown_defaults(self):
        for key in ('id','material_key','master_role','frames','clips','cues','anchor','layout','version'):
            with self.subTest(key=key):self.reject(lambda s,t,p,m,e:p.pop(key))
        for mutate in (lambda s,t,p,m,e:p.update(version=True),lambda s,t,p,m,e:p.update(layout='plain'),
                       lambda s,t,p,m,e:p.update(anchor='center'),lambda s,t,p,m,e:p.update(fallback=True)):
            self.reject(mutate)

    def test_unknown_master_missing_clip_role_and_duplicate_role_or_crop_reject(self):
        mutations=[lambda s,t,p,m,e:p.update(master_role='unknown'),
            lambda s,t,p,m,e:p['clips'][0]['frames'][0].update(role='unknown'),
            lambda s,t,p,m,e:p['frames'][1].update(role=p['frames'][0]['role']),
            lambda s,t,p,m,e:p['frames'][1].update(sourceRect=deepcopy(p['frames'][0]['sourceRect'])),
            lambda s,t,p,m,e:p['clips'][0]['frames'][1].update(role=p['clips'][0]['frames'][0]['role'])]
        for mutate in mutations:self.reject(mutate)

    def test_nonfinite_bad_typed_or_outside_crop_and_box_reject(self):
        for value in (float('nan'),float('inf'),True,'0.4',10**1000):
            self.reject(lambda s,t,p,m,e:p.update(x=value))
            self.reject(lambda s,t,p,m,e:p['frames'][0]['sourceRect'].update(width=value))
        for mutate in (lambda s,t,p,m,e:p.update(x=.99),lambda s,t,p,m,e:p.update(width=.049),
                       lambda s,t,p,m,e:p['frames'][0]['sourceRect'].update(x=-.1),
                       lambda s,t,p,m,e:p['frames'][0]['sourceRect'].update(width=0),
                       lambda s,t,p,m,e:p['frames'][0]['sourceRect'].update(width=2)):
            self.reject(mutate)

    def test_clips_obey_native_mouth_and_frame_contract(self):
        for mutate in (lambda s,t,p,m,e:p['clips'][0].update(frameDurationFrames=0),
                       lambda s,t,p,m,e:p['clips'][0].update(frameDurationFrames=True),
                       lambda s,t,p,m,e:p['clips'][0].update(frameDurationFrames=31),
                       lambda s,t,p,m,e:p['clips'][0].update(frames=p['clips'][0]['frames'][:2]),
                       lambda s,t,p,m,e:p['clips'][0]['frames'][0].update(mouthOpen=.1),
                       lambda s,t,p,m,e:[row.update(mouthOpen=0) for row in p['clips'][0]['frames']],
                       lambda s,t,p,m,e:p['clips'][0]['frames'][1].update(mouthOpen=float('nan')),
                       lambda s,t,p,m,e:p['clips'][0]['frames'][1].update(phoneme='invented'),
                       lambda s,t,p,m,e:p['clips'].append(deepcopy(p['clips'][0]))):
            self.reject(mutate)

    def test_cue_clock_rejects_missing_tail_gaps_overlap_unknown_clip_and_offsets(self):
        for mutate in (lambda s,t,p,m,e:p['cues'][0].update(startFrame=1),
                       lambda s,t,p,m,e:p['cues'][0].update(endFrame=82),
                       lambda s,t,p,m,e:p['cues'][0].update(endFrame=84),
                       lambda s,t,p,m,e:p['cues'][0].update(clipID='absent'),
                       lambda s,t,p,m,e:p['cues'][0].update(animationOffsetFrames=-1),
                       lambda s,t,p,m,e:p['cues'][0].update(animationOffsetFrames=216001),
                       lambda s,t,p,m,e:p['cues'].append(deepcopy(p['cues'][0])),
                       lambda s,t,p,m,e:p.update(cues=[])):
            self.reject(mutate)

    def test_finite_metadata_budgets_reject_excess_sprite_clip_and_cue_counts(self):
        self.reject(lambda s,t,p,m,e:p.update(frames=p['frames']*9))
        self.reject(lambda s,t,p,m,e:p.update(clips=p['clips']*17))
        self.reject(lambda s,t,p,m,e:p.update(cues=p['cues']*257))
        self.reject(lambda s,t,p,m,e:e.update(energy=e['energy']*4097))

    def test_native_maximum_sprite_clip_frame_and_cue_budgets_are_accepted(self):
        values=self.fixture(duration=512);profile=values[2]
        profile['frames']=[dict(role='fixture-bound-'+str(i),
            sourceRect=dict(x=i/32,y=0,width=1/32,height=1)) for i in range(32)]
        profile['master_role']=profile['frames'][0]['role']
        profile['clips']=[dict(id='fixture-clip-'+str(i),frameDurationFrames=30,
            frames=[dict(role=row['role'],mouthOpen=j/15)
                    for j,row in enumerate(profile['frames'][:16])]) for i in range(16)]
        profile['cues']=[dict(startFrame=i*2,endFrame=(i+1)*2,clipID='fixture-clip-'+str(i%16),
                             animationOffsetFrames=216000) for i in range(256)]
        values[3][profile['material_key']]['frames']=deepcopy(profile['frames'])
        result=compose(*values)
        self.assertEqual(len(result['classicArtwork']['sprites']),32)
        self.assertEqual(sum(len(c['frames']) for c in result['cartoonPresenter']['clips']),256)
        self.assertEqual(len(result['cartoonPresenter']['cues']),256)
        for clip in profile['clips']:
            clip['frames'].append(dict(role=profile['frames'][16]['role'],mouthOpen=.6))
        with self.assertRaises(PresenterCompositionError):compose(*values)

    def test_native_maximum_continuous_rms_budget_is_accepted(self):
        values=self.fixture(duration=4096)
        values[4]['energy']=[dict(startFrame=i,endFrame=i+1,rms=(i%2)*.2) for i in range(4096)]
        self.assertEqual(compose(*values)['cartoonPresenter']['speech']['energy'],values[4]['energy'])

    def test_interior_holes_and_overlaps_reject_even_with_matching_head_and_tail(self):
        for second_start in (9,11):
            values=self.fixture();p=values[2]
            p['cues']=[dict(startFrame=0,endFrame=10,clipID='fixture-authored',animationOffsetFrames=0),
                       dict(startFrame=second_start,endFrame=83,clipID='fixture-authored',animationOffsetFrames=0)]
            with self.subTest(clock='presenter',second_start=second_start),self.assertRaises(PresenterCompositionError):
                compose(*values)
            values=self.fixture()
            values[4]['energy']=[dict(startFrame=0,endFrame=10,rms=.1),
                                 dict(startFrame=second_start,endFrame=83,rms=.2)]
            with self.subTest(clock='rms',second_start=second_start),self.assertRaises(PresenterCompositionError):
                compose(*values)

    def test_energy_cannot_mix_actor_voice_source_text_or_duration(self):
        for key,value in (('actorID','different-actor'),('voiceAssetID','different-voice'),
                          ('sourceSHA256','c'*64),('textDigest','d'*64),
                          ('durationFrames',82),('durationFrames',True)):
            with self.subTest(key=key,value=value):self.reject(lambda s,t,p,m,e:e.update({key:value}))
        self.reject(lambda s,t,p,m,e:t.pop('voice_sha256'))
        self.reject(lambda s,t,p,m,e:t.update(voice_sha256='not-a-hash'))
        self.reject(lambda s,t,p,m,e:s['voice'].update(textDigest='not-a-digest'))

    def test_rms_rejects_missing_head_tail_gaps_overlaps_invalid_values_and_phonemes(self):
        for mutate in (lambda s,t,p,m,e:e['energy'][0].update(startFrame=1),
                       lambda s,t,p,m,e:e['energy'][0].update(endFrame=82),
                       lambda s,t,p,m,e:e['energy'][0].update(endFrame=84),
                       lambda s,t,p,m,e:e['energy'][0].update(rms=-.1),
                       lambda s,t,p,m,e:e['energy'][0].update(rms=1.1),
                       lambda s,t,p,m,e:e['energy'][0].update(rms=True),
                       lambda s,t,p,m,e:e['energy'][0].update(rms=float('nan')),
                       lambda s,t,p,m,e:e['energy'][0].update(phoneme='invented'),
                       lambda s,t,p,m,e:e['energy'].append(deepcopy(e['energy'][0])),
                       lambda s,t,p,m,e:e.update(energy=[])):
            self.reject(mutate)

    def test_changed_narration_captions_and_timing_duration_are_not_silently_repaired(self):
        for mutate in (lambda s,t,p,m,e:t['captions'][0].update(text='另一个合成文本'),
                       lambda s,t,p,m,e:t['axis']['segments'][0].update(text='另一个合成台词'),
                       lambda s,t,p,m,e:t.update(frames=82),
                       lambda s,t,p,m,e:s['voice'].update(durationFrames=82)):
            self.reject(mutate)

    def test_existing_advanced_scene_trim_speed_or_pause_cannot_be_hidden(self):
        for mutate in (lambda s,t,p,m,e:s.update(cartoonRig={'actors':['other']}),
                       lambda s,t,p,m,e:s.update(classicArtwork={'sprites':['other']}),
                       lambda s,t,p,m,e:s.update(cartoonPresenter={'id':'other'}),
                       lambda s,t,p,m,e:s.update(cartoonPerformance={'actors':['other']}),
                       lambda s,t,p,m,e:s.update(gameWorld={'entities':['other']}),
                       lambda s,t,p,m,e:s.update(kind='规则模拟'),
                       lambda s,t,p,m,e:s.update(sourceStartFrame=1),
                       lambda s,t,p,m,e:s.update(speed=.9),
                       lambda s,t,p,m,e:s.update(pauseFrames=1)):
            self.reject(mutate)

    def test_presenter_cannot_alias_business_layer_subject_or_target(self):
        self.reject(lambda s,t,p,m,e:p.update(id=s['layers'][0]['id']))
        self.reject(lambda s,t,p,m,e:s['storyActions'][0].update(subjectID=p['id']))
        self.reject(lambda s,t,p,m,e:s['storyActions'][0].update(targetID=p['id']))


if __name__=='__main__':unittest.main()
