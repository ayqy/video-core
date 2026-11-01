"""Pure literal timing rules, not an SDK/Core/media/service verification.

The boundary rows and duration numbers below are deliberately synthetic.
Actual production must supply and retain the real complete audio, ffprobe
measurement, normal SDK boundary original and independently verified sources.
"""
from copy import deepcopy
from decimal import Decimal
import hashlib
import json
import math
import unittest

from examples.knowledge_delivery import presentation as delivery_presentation
from story_planning import StoryPlan
from story_speech import StorySpeechError, retime_presentation, retime_presentation_author_estimate


def literal_plan(texts=None):
    """Five unequal authored shots; two presentation sources, no Core trace."""
    brief = dict(version=1, title='纯规则夹具', knowledge_goal='验证五镜语音轴',
        viewer_question='呈现时间是否跟随完整原声？', context='甲乙在桌前演示',
        boundary='只有字面测试数据，没有真实声音或仿真执行', source_ids=['base', 'alternative'])
    cast = dict(actors=[dict(id='a', name='甲', role='演示者', motive='讲清动作', goal='完成演示',
        expected_benefit='看懂过程', stake='需要花时间')],
        objects=[dict(id='box', name='箱子', description='独立道具', purpose='观察拿放过程')])
    names = ['setup', 'choice', 'process', 'result', 'conclusion']
    purposes = ['setup', 'choice', 'process', 'consequence', 'conclusion']
    texts = ['甲来。', '乙等。', '箱到了。', '钱仍在。', '再比较。'] if texts is None else texts
    lengths = [60, 90, 150, 120, 180]
    outline = dict(beats=[dict(id=name, purpose=purpose, question='如何看清？', change='展示'+name,
        actor_ids=['a'], depends_on=[] if i == 0 else [names[i-1]],
        source_ids=['base' if i < 3 else 'alternative'])
        for i, (name, purpose) in enumerate(zip(names, purposes))])
    details = dict(actions=[dict(id='act-'+name, beat_id=name, actor_id='a', verb='react',
        object_ids=['box'], visible_start='开始观察'+name, visible_process='持续展示'+name,
        visible_end='结束这一镜'+name, depends_on=[], event_refs=[])
        for name in names])
    at, shots, beats = 0, [], []
    for i, (name, text, length) in enumerate(zip(names, texts, lengths)):
        shots.append(dict(id='shot-'+name, beat_id=name, start_frame=at, duration_frames=length,
            visual_goal='看清'+name, narration=text, action_ids=['act-'+name], asset_names=['独立道具']))
        beats.append(dict(id='act-'+name, detail_id='act-'+name, shot_id='shot-'+name,
            source_id='base' if i < 3 else 'alternative', event=dict(round=1, phase='收益结算'),
            effect=dict(kind='stateChange', actor_id='a', rule_id='literal-rule',
                        from_state_id='before', to_state_id='after'),
            subject_id='box', start_frame=at+3, end_frame=at+length-3, requires=[],
            visual=dict(kind='show')))
        at += length
    content = dict(shots=shots, asset_requirements=[dict(name='独立道具', description='箱子原件',
        style='透明插画', transparent=True)])
    story = StoryPlan(brief)
    for stage, value in zip(('cast', 'outline', 'details', 'shots'), (cast, outline, details, content)):
        story = story.accept(stage, value, story.fingerprint)
    return dict(version=1, story=story.to_dict(), target=dict(fps=30, mode='pencil'),
        sources=[dict(id='base', scene_id='source-base', model=dict(literal_only=True, startTick=19),
                      seed=7, start_frame=0, end_frame=300),
                 dict(id='alternative', scene_id='source-other', model=dict(literal_only=True, startTick=19),
                      seed=7, parent_id='base', intervention=dict(actorID='a', plan=dict(literal_only=True)),
                      start_frame=300, end_frame=600)],
        actors=[dict(actor_id='a', subject_id='box')], pool_subject_id='pool', anchors={},
        beats=beats, balances=[dict(source_id='base', event=dict(round=1, phase='收益结算'),
            actor_id='a', entity_id='person-a', frame=299),
            dict(source_id='alternative', event=dict(round=1, phase='收益结算'),
            actor_id='a', entity_id='person-a', frame=599)])


def literal_boundaries(plan, offsets=(2_000_000, 10_000_000, 25_000_000, 40_000_000, 55_000_000)):
    texts = [shot['narration'] for shot in StoryPlan.from_dict(plan['story']).stage('shots')['shots']]
    return [dict(type='WordBoundary', text=text, offset=offset, duration=3_000_000)
            for text, offset in zip(texts, offsets)]


class StorySpeechRulesTests(unittest.TestCase):
    def setUp(self):
        self.plan = literal_plan()
        self.words = literal_boundaries(self.plan)

    def align(self, **kwargs):
        return retime_presentation(kwargs.pop('plan', self.plan), kwargs.pop('words', self.words),
                                   kwargs.pop('duration', 6.1), **kwargs)

    def test_five_unequal_shots_follow_observed_words_and_keep_complete_tail(self):
        result = self.align()
        self.assertEqual(result['frames'], 183)
        self.assertEqual(result['first_word_frame'], 6)
        self.assertEqual([(c['startFrame'], c['endFrame']) for c in result['captions']],
                         [(0, 30), (30, 75), (75, 120), (120, 165), (165, 183)])
        self.assertTrue(all(c['confirmed'] is False for c in result['captions']))
        self.assertEqual(result['axis']['narration'], '甲来。乙等。箱到了。钱仍在。再比较。')
        self.assertEqual(result['axis']['word_boundary_count'], 5)
        rebuilt = StoryPlan.from_dict(result['presentation']['story'])
        self.assertTrue(rebuilt.complete)
        self.assertNotEqual(rebuilt.fingerprint, StoryPlan.from_dict(self.plan['story']).fingerprint)
        # Captured from the unmodified pre-estimate implementation, not computed
        # from the current output as a new expectation.
        raw=json.dumps(result,ensure_ascii=False,sort_keys=True,separators=(',',':'),allow_nan=False).encode()
        self.assertEqual(hashlib.sha256(raw).hexdigest(),
                         '68fc1c91efcb4fe663ac6a96457fbaf2116de31d08e936afeaaf951cded98fd4')

    def test_mapping_preserves_semantics_source_native_axis_and_inputs(self):
        original, words = deepcopy(self.plan), deepcopy(self.words)
        result = self.align()['presentation']
        self.assertEqual(self.plan, original)
        self.assertEqual(self.words, words)
        for before, after in zip(original['sources'], result['sources']):
            self.assertEqual({k:v for k,v in before.items() if k not in ('start_frame', 'end_frame')},
                             {k:v for k,v in after.items() if k not in ('start_frame', 'end_frame')})
        self.assertEqual([(s['start_frame'], s['end_frame']) for s in result['sources']], [(0,120),(120,183)])
        for before, after in zip(original['beats'], result['beats']):
            self.assertEqual({k:v for k,v in before.items() if k not in ('start_frame', 'end_frame')},
                             {k:v for k,v in after.items() if k not in ('start_frame', 'end_frame')})
        self.assertEqual([b['frame'] for b in result['balances']], [119,182])
        for stage in ('cast','outline','details'):
            self.assertEqual(StoryPlan.from_dict(result['story']).stage(stage), StoryPlan.from_dict(original['story']).stage(stage))

    def test_original_delivery_adapter_remains_600_frames_and_all_effects_are_unchanged(self):
        project = dict(id='literal-project', workspaceID='literal-workspace', revisions=[dict(id='literal-revision', scenes=[dict(id='literal-scene')])])
        plan = delivery_presentation(project, dict(delivered='literal-source1', withheld='literal-source2'))
        words = literal_boundaries(plan, offsets=(0, 10_000_000, 25_000_000, 40_000_000))
        result = retime_presentation(plan, words, 6.1)
        self.assertEqual(StoryPlan.from_dict(plan['story']).stage('shots')['shots'][-1]['start_frame'] +
                         StoryPlan.from_dict(plan['story']).stage('shots')['shots'][-1]['duration_frames'], 600)
        self.assertEqual(result['frames'], 183)
        self.assertEqual([b['effect'] for b in plan['beats']], [b['effect'] for b in result['presentation']['beats']])
        self.assertEqual(result['presentation']['beats'][2]['requires'], ['deliver-parcel'])
        for beat in result['presentation']['beats']:
            self.assertGreater(beat['end_frame'], beat['start_frame'])

    def test_multiword_rows_align_without_inventing_character_timing(self):
        words = [dict(type='WordBoundary', text='甲', offset=0, duration=100_000),
                 dict(type='WordBoundary', text='来。', offset=1_000_000, duration=100_000)] + deepcopy(self.words[1:])
        self.assertEqual(self.align(words=words)['captions'][1]['startFrame'], 30)
        words = [dict(type='WordBoundary', text='甲来乙', offset=0, duration=100_000),
                 dict(type='WordBoundary', text='等', offset=2_000_000, duration=100_000)] + deepcopy(self.words[2:])
        with self.assertRaisesRegex(StorySpeechError, 'inside an SDK word'):
            self.align(words=words)

    def test_no_missing_reordered_or_extra_spoken_content_is_accepted(self):
        for wrong in ('甲去。', '甲来来。', '乙等。'):
            words=deepcopy(self.words);words[0]['text']=wrong
            with self.subTest(wrong=wrong), self.assertRaisesRegex(StorySpeechError, 'cover every authored shot'):
                self.align(words=words)

    def test_only_punctuation_and_space_may_differ_from_original_text(self):
        words=deepcopy(self.words);words[0]['text']='甲 来！'
        self.assertEqual(self.align(words=words)['captions'][0]['text'], '甲来。')

    def test_first_spoken_word_must_precede_one_second_even_before_quantization(self):
        for offset in (10_000_000, 10_000_001):
            words=deepcopy(self.words)
            shift=offset-words[0]['offset']
            for row in words:row['offset'] += shift
            with self.subTest(offset=offset), self.assertRaisesRegex(StorySpeechError, 'before one second'):
                self.align(words=words, duration=7.1)

    def test_the_measured_complete_audio_must_cover_the_last_sdk_word(self):
        with self.assertRaisesRegex(StorySpeechError, 'last observed SDK word'):
            self.align(duration=5.79)

    def test_positive_action_that_would_disappear_is_rejected(self):
        plan=deepcopy(self.plan);plan['beats'][0].update(start_frame=2, end_frame=3)
        with self.assertRaisesRegex(StorySpeechError, 'collapses to zero frames'):
            self.align(plan=plan)

    def test_word_windows_cannot_collapse_a_whole_shot(self):
        words=deepcopy(self.words);words[0].update(offset=0,duration=1);words[1].update(offset=2,duration=1)
        with self.assertRaisesRegex(StorySpeechError, 'positive frame span'):
            self.align(words=words)

    def test_word_rows_must_be_finite_ordered_nonoverlapping_and_typed(self):
        for field,value in [('offset', -1), ('offset', True), ('duration', 0), ('duration', '3'), ('type', 'SentenceBoundary')]:
            words=deepcopy(self.words);words[0][field]=value
            with self.subTest(field=field,value=value), self.assertRaises(StorySpeechError):
                self.align(words=words)
        words=deepcopy(self.words);words[1]['offset']=3_000_000
        with self.assertRaisesRegex(StorySpeechError, 'nonoverlapping'):
            self.align(words=words)

    def test_duration_and_fps_cannot_silently_change_frame_contract(self):
        for duration in (0,-1,math.nan,math.inf,True,'not-a-duration',1801):
            with self.subTest(duration=duration), self.assertRaises(StorySpeechError):
                self.align(duration=duration)
        for fps in (True,0,24,121):
            with self.subTest(fps=fps), self.assertRaises(StorySpeechError):
                self.align(fps=fps)

    def test_unknown_shot_source_or_outside_balance_and_action_are_rejected(self):
        for mutation in ('shot', 'source', 'balance', 'action'):
            plan=deepcopy(self.plan)
            if mutation=='shot':plan['beats'][0]['shot_id']='missing'
            if mutation=='source':plan['beats'][0]['source_id']='missing'
            if mutation=='balance':plan['balances'][0]['frame']=300
            if mutation=='action':plan['beats'][0]['end_frame']=61
            with self.subTest(mutation=mutation), self.assertRaises(StorySpeechError):
                self.align(plan=plan)

    def test_causal_dependencies_cannot_be_reordered_by_invalid_authored_windows(self):
        plan=deepcopy(self.plan);plan['beats'][0]['requires']=[plan['beats'][1]['id']]
        with self.assertRaisesRegex(StorySpeechError, 'prerequisite'):
            self.align(plan=plan)

    def test_non_30_fps_uses_explicit_target_axis_and_ceil_keeps_fractional_tail(self):
        plan=deepcopy(self.plan);plan['target']['fps']=24
        result=retime_presentation(plan,self.words,'6.10001',fps=24)
        self.assertEqual(result['frames'],147)
        self.assertEqual(result['captions'][-1]['endFrame'],147)
        self.assertEqual(result['axis']['fps'],24)


class SpeechPlanIntegrationRulesTests(unittest.TestCase):
    """Literal TN plans/word rows only, never claims of recorded SDK events."""

    def case(self, *, contracted=False):
        original = ['3枚。','API到。','箱到了。','钱仍在。','再比较。']
        spoken = ['三枚。','人工智能到。',*original[2:]]
        term, pronunciation = 'API','人工智能'
        if contracted:
            original[1], spoken[1] = '应用程序接口到。','API到。'
            term, pronunciation = '应用程序接口','API'
        presentation = literal_plan(original)
        pieces = [('3','三','number'),('枚。','枚。','unchanged'),
                  (term,pronunciation,'dictionary'),
                  (''.join(original)[len('3枚。'+term):],''.join(spoken)[len('三枚。'+pronunciation):],'unchanged')]
        source = normalized = ''
        mappings = []
        for left,right,kind in pieces:
            mappings.append(dict(sourceStart=len(source.encode('utf-16-le'))//2,
                sourceLength=len(left.encode('utf-16-le'))//2,
                normalizedStart=len(normalized.encode('utf-16-le'))//2,
                normalizedLength=len(right.encode('utf-16-le'))//2,kind=kind))
            source += left; normalized += right
        speech = dict(source=source,normalized=normalized,dictionary=[dict(term=term,pronunciation=pronunciation)],
            mappings=mappings,rate=.5,confirmed=True,notes=['纯规则夹具，未生成声音'])
        words = [dict(type='WordBoundary',text=text,offset=offset,duration=3_000_000)
            for text,offset in zip(spoken,(2_000_000,10_000_000,25_000_000,40_000_000,55_000_000))]
        return presentation,speech,words

    def test_normalized_words_keep_original_caption_text_and_exact_observed_word_values(self):
        for contracted in (False,True):
            with self.subTest(contracted=contracted):
                presentation,speech,words = self.case(contracted=contracted)
                original, before_speech, before_words = deepcopy(presentation),deepcopy(speech),deepcopy(words)
                result = retime_presentation(presentation,words,6.1,speech_plan=speech)
                texts = [s['narration'] for s in StoryPlan.from_dict(original['story']).stage('shots')['shots']]
                self.assertEqual([cue['text'] for cue in result['captions']],texts)
                self.assertEqual(result['axis']['narration'],speech['source'])
                self.assertEqual(result['axis']['normalized_narration'],speech['normalized'])
                self.assertEqual(result['axis']['speech_plan_binding']['kind'],'speech-plan-utf16-whole-segment-v1')
                self.assertEqual([(c['startFrame'],c['endFrame']) for c in result['captions']],
                    [(0,30),(30,75),(75,120),(120,165),(165,183)])
                self.assertEqual(result['axis']['word_boundary_count'],5)
                self.assertEqual([s['narration'] for s in StoryPlan.from_dict(result['presentation']['story']).stage('shots')['shots']],texts)
                self.assertFalse(result['axis']['voice_listened']);self.assertFalse(result['axis']['captions_confirmed'])
                self.assertTrue(all(cue['confirmed'] is False for cue in result['captions']))
                self.assertEqual((presentation,speech,words),(original,before_speech,before_words))

    def test_tn_shot_cut_inside_an_actual_whole_word_is_still_rejected(self):
        presentation,speech,words = self.case()
        # Exact complete normalized text still matches, but the first observed
        # word crosses the shot cut. The adapter must never subdivide its time.
        words[0]['text'],words[1]['text'] = '三枚人工','智能到。'
        original = deepcopy(words)
        with self.assertRaisesRegex(StorySpeechError,'inside an SDK word'):
            retime_presentation(presentation,words,6.1,speech_plan=speech)
        self.assertEqual(words,original)

    def test_tn_cannot_relabel_original_word_text_as_corrected_observations(self):
        presentation,speech,words = self.case()
        words[0]['text'],words[1]['text'] = '3枚。','API到。'
        with self.assertRaisesRegex(StorySpeechError,'cover every authored shot'):
            retime_presentation(presentation,words,6.1,speech_plan=speech)

    def test_explicit_none_keeps_the_preexisting_frozen_legacy_output(self):
        presentation = literal_plan();words = literal_boundaries(presentation)
        implicit = retime_presentation(presentation,words,6.1)
        explicit = retime_presentation(presentation,words,6.1,speech_plan=None)
        self.assertEqual(implicit,explicit)
        encoded = json.dumps(explicit,ensure_ascii=False,sort_keys=True,separators=(',',':'),allow_nan=False).encode()
        self.assertEqual(hashlib.sha256(encoded).hexdigest(),
                         '68fc1c91efcb4fe663ac6a96457fbaf2116de31d08e936afeaaf951cded98fd4')
        self.assertNotIn('normalized_narration',explicit['axis'])
        self.assertNotIn('speech_plan_binding',explicit['axis'])


class AuthorEstimateSpeechRulesTests(unittest.TestCase):
    """Literal authored windows only; no SDK, audio measurement or listening."""
    def test_explicit_estimate_uses_authored_proportions_and_never_invents_observed_words(self):
        plan=literal_plan();before=deepcopy(plan)
        timed=retime_presentation_author_estimate(plan,'6.1')
        self.assertEqual(plan,before);self.assertEqual(timed['frames'],183)
        self.assertEqual([(s['start_frame'],s['end_frame']) for s in timed['axis']['segments']],
                         [(0,18),(18,45),(45,91),(91,128),(128,183)])
        self.assertEqual(timed['axis']['kind'],'authored-sentence-estimate')
        self.assertEqual(timed['axis']['timing_basis'],'authored-shot-proportions')
        self.assertFalse(timed['axis']['voice_listened']);self.assertFalse(timed['axis']['captions_confirmed'])
        for key in ('first_word_frame','word_boundary_count','word_boundaries_sha256'):
            self.assertNotIn(key,timed);self.assertNotIn(key,timed['axis'])
        self.assertTrue(all(c['alignment']=='estimated_sentence_no_word_timestamps'
                            and c['confirmed'] is False for c in timed['captions']))
        self.assertEqual(''.join(c['text'] for c in timed['captions']),timed['axis']['narration'])

    def test_estimated_axis_reuses_causal_mapping_without_changing_events_inputs_or_full_tail(self):
        plan=literal_plan();snapshot=deepcopy(plan)
        timed=retime_presentation_author_estimate(plan,'6.10001')
        self.assertEqual(timed['frames'],184);self.assertEqual(timed['captions'][-1]['endFrame'],184)
        for old,new in zip(plan['sources'],timed['presentation']['sources']):
            self.assertEqual({k:v for k,v in old.items() if k not in ('start_frame','end_frame')},
                             {k:v for k,v in new.items() if k not in ('start_frame','end_frame')})
        for old,new in zip(plan['beats'],timed['presentation']['beats']):
            self.assertEqual({k:v for k,v in old.items() if k not in ('start_frame','end_frame')},
                             {k:v for k,v in new.items() if k not in ('start_frame','end_frame')})
        self.assertEqual(plan,snapshot)
        self.assertEqual(timed['axis']['segments'][-1]['original_end_frame'],600)
        self.assertTrue(StoryPlan.from_dict(timed['presentation']['story']).complete)

    def test_estimates_reject_collapsed_actions_or_shots_and_keep_default_word_gate_strict(self):
        plan=literal_plan();plan['beats'][0].update(start_frame=2,end_frame=3)
        with self.assertRaisesRegex(StorySpeechError,'collapses to zero'):
            retime_presentation_author_estimate(plan,'6.1')
        with self.assertRaisesRegex(StorySpeechError,'positive frame span'):
            retime_presentation_author_estimate(literal_plan(),'.01')
        for duration in (0,True,math.nan,math.inf,'bad',1801):
            with self.subTest(duration=duration),self.assertRaises(StorySpeechError):
                retime_presentation_author_estimate(literal_plan(),duration)
        with self.assertRaisesRegex(StorySpeechError,'SDK WordBoundary'):
            retime_presentation(literal_plan(),None,'6.1')

    def test_actual_integer_sample_clock_keeps_exact_frame_boundary_without_rewriting_audio(self):
        samples=241600;rate=24000;duration=str(Decimal(samples)/rate)
        timed=retime_presentation_author_estimate(literal_plan(),duration,
            measured_samples=samples,sample_rate=rate)
        self.assertEqual(timed['frames'],302)
        self.assertEqual(timed['axis']['measured_samples'],samples)
        self.assertEqual(timed['axis']['sample_rate'],rate)
        self.assertEqual(timed['captions'][-1]['endFrame'],302)
        for clock in (dict(measured_samples=True,sample_rate=rate),dict(measured_samples=samples),
                      dict(measured_samples=samples,sample_rate=0)):
            with self.subTest(clock=clock),self.assertRaises(StorySpeechError):
                retime_presentation_author_estimate(literal_plan(),duration,**clock)
        with self.assertRaisesRegex(StorySpeechError,'sample clock must agree'):
            retime_presentation_author_estimate(literal_plan(),'6',measured_samples=samples,sample_rate=rate)


if __name__ == '__main__':
    unittest.main()
