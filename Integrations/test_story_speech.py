"""Pure literal timing rules, not an SDK/Core/media/service verification.

The boundary rows and duration numbers below are deliberately synthetic.
Actual production must supply and retain the real complete audio, ffprobe
measurement, normal SDK boundary original and independently verified sources.
"""
from copy import deepcopy
import math
import unittest

from examples.knowledge_delivery import presentation as delivery_presentation
from story_planning import StoryPlan
from story_speech import StorySpeechError, retime_presentation


def literal_plan():
    """Five unequal authored shots; two presentation sources, no Core trace."""
    brief = dict(version=1, title='纯规则夹具', knowledge_goal='验证五镜语音轴',
        viewer_question='呈现时间是否跟随完整原声？', context='甲乙在桌前演示',
        boundary='只有字面测试数据，没有真实声音或仿真执行', source_ids=['base', 'alternative'])
    cast = dict(actors=[dict(id='a', name='甲', role='演示者', motive='讲清动作', goal='完成演示',
        expected_benefit='看懂过程', stake='需要花时间')],
        objects=[dict(id='box', name='箱子', description='独立道具', purpose='观察拿放过程')])
    names = ['setup', 'choice', 'process', 'result', 'conclusion']
    purposes = ['setup', 'choice', 'process', 'consequence', 'conclusion']
    texts = ['甲来。', '乙等。', '箱到了。', '钱仍在。', '再比较。']
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


if __name__ == '__main__':
    unittest.main()
