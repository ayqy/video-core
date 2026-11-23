"""Source-excerpt planning rules, with no model, network or media modification."""
from copy import deepcopy
from dataclasses import replace
import hashlib
from pathlib import Path
import tempfile
import unittest

from source_excerpt_plan import (Candidate, ExcerptPlanError, OutputIntent, Source,
                                 Unit, plan_excerpts, recording_scene_fields,
                                 verify_source_file)


class ExcerptPlanTests(unittest.TestCase):
    def setUp(self):
        self.source = Source('observed-recording', 'a'*64, 300, 30, 'recording')
        self.units = (Unit('setup', 10, 40, '条件已经出现。'),
                      Unit('choice', 70, 100, '角色实际作出选择。', ('setup',)),
                      Unit('result', 140, 190, '后果已经发生。', ('choice',)),
                      Unit('other', 220, 280, '另一个完整主题。'))
        self.intents = (OutputIntent('landscape', '16:9'),)

    def plan(self, candidates, **options):
        return plan_excerpts(options.pop('source', self.source), options.pop('units', self.units),
                             candidates, options.pop('intents', self.intents),
                             minimum_score=options.pop('minimum_score', .5),
                             maximum_selected=options.pop('maximum_selected', 4), **options)

    def test_context_dependencies_keep_one_continuous_original_source_interval(self):
        original = deepcopy(self.units)
        p = self.plan([Candidate('answer', 'result', 'result', .9, '选择和后果必须一起看。')])
        row = p['selected'][0]
        self.assertEqual((row['sourceStartFrame'], row['sourceEndFrame'], row['durationFrames']), (10, 190, 180))
        self.assertEqual(row['unit_ids'], ['setup', 'choice', 'result'])
        self.assertTrue(row['context_expanded'])
        self.assertFalse(p['media_modified'])
        self.assertFalse(p['source_audio_spliced_or_retimed'])
        self.assertEqual(self.units, original)

    def test_overlaps_keep_higher_score_and_return_original_source_order(self):
        p = self.plan([Candidate('later', 'other', 'other', .95, '独立后续主题。'),
                       Candidate('partial', 'choice', 'choice', .7, '同一段的短候选。'),
                       Candidate('whole', 'setup', 'result', .9, '完整因果过程。')])
        self.assertEqual([r['id'] for r in p['selected']], ['whole', 'later'])
        self.assertIn(dict(id='partial', reason='overlaps_selected_content', selected_id='whole'), p['omitted'])

    def test_touching_half_open_windows_are_not_overlaps_and_equal_scores_are_stable(self):
        units = (Unit('a', 0, 40, '第一段。'), Unit('b', 40, 80, '第二段。'))
        p = self.plan([Candidate('first', 'a', 'a', .7, '第一候选。'),
                       Candidate('duplicate', 'a', 'a', .7, '等分重复。'),
                       Candidate('next', 'b', 'b', .7, '相邻主题。')], units=units)
        self.assertEqual([r['id'] for r in p['selected']], ['first', 'next'])

    def test_protected_narration_keeps_complete_file_including_head_and_tail(self):
        source = replace(self.source, purpose='protected_narration')
        p = self.plan([Candidate('partial', 'setup', 'result', 1., '虽完整但不是全部原音。'),
                       Candidate('whole', 'setup', 'other', .8, '保留全部原旁白。')], source=source)
        self.assertEqual([(r['sourceStartFrame'], r['sourceEndFrame']) for r in p['selected']], [(0, 300)])
        self.assertIn(dict(id='partial', reason='protected_narration_requires_whole_source'), p['omitted'])

    def test_destination_limit_never_truncates_or_pads_content(self):
        intents = (OutputIntent('portrait-request', '9:16', 100), OutputIntent('original', 'source', 900))
        p = self.plan([Candidate('whole', 'result', 'result', .9, '完整问答而不凑时长。')], intents=intents)
        row = p['selected'][0]
        self.assertEqual((row['sourceStartFrame'], row['sourceEndFrame']), (10, 190))
        self.assertEqual([r['status'] for r in row['variants']], ['duration_exceeds_explicit_limit', 'source_frame_preserved'])
        self.assertFalse(p['audiovisual_review_granted'])

    def test_no_fitting_destination_omits_candidate_instead_of_shortening_it(self):
        p = self.plan([Candidate('whole', 'result', 'result', .9, '完整过程。')],
                      intents=(OutputIntent('tiny', '9:16', 50),))
        self.assertEqual(p['selected'], [])
        self.assertEqual(p['omitted'], [dict(id='whole', reason='no_destination_fits_whole_content')])

    def test_missing_future_or_cyclic_context_is_rejected(self):
        for units in [(Unit('a', 0, 10, '片段。', ('absent',)),),
                      (Unit('a', 0, 10, '问题。', ('b',)), Unit('b', 10, 20, '回答。', ('a',))),
                      (Unit('a', 0, 10, '片段。', ([],)),)]:
            with self.subTest(units=units), self.assertRaises(ExcerptPlanError):
                self.plan([], units=units)

    def test_invalid_source_clock_and_unbounded_or_nonfinite_scores_are_rejected(self):
        for source in [replace(self.source, fps=True), replace(self.source, frames=True),
                       replace(self.source, sha256='wrong'), replace(self.source, purpose=[])]:
            with self.subTest(source=source), self.assertRaises(ExcerptPlanError):
                self.plan([], source=source)
        for score in [True, float('nan'), float('inf'), 10**500, -1]:
            with self.subTest(score=score), self.assertRaises(ExcerptPlanError):
                self.plan([Candidate('bad', 'setup', 'result', score, '无效评分。')])

    def test_duplicate_unknown_or_partial_unit_intervals_are_rejected(self):
        for units in [(Unit('a', 10, 30, '前半。'), Unit('a', 40, 50, '后半。')),
                      (Unit('a', 20, 40, '重叠。'), Unit('b', 30, 60, '重叠。')),
                      (Unit('a', 0, 301, '越界。'),), (Unit('a', False, 30, '布尔帧。'),)]:
            with self.subTest(units=units), self.assertRaises(ExcerptPlanError):
                self.plan([], units=units)
        with self.assertRaises(ExcerptPlanError):
            self.plan([Candidate('missing', 'unknown', 'result', .8, '不存在的完整单元。')])

    def test_selection_limit_and_threshold_are_explicit_and_have_omission_reasons(self):
        p = self.plan([Candidate('whole', 'setup', 'result', .9, '完整过程。'),
                       Candidate('low', 'other', 'other', .4, '低分。'),
                       Candidate('later', 'other', 'other', .8, '后续。')], maximum_selected=1)
        self.assertEqual([r['id'] for r in p['selected']], ['whole'])
        self.assertEqual({r['reason'] for r in p['omitted']}, {'below_explicit_score', 'explicit_selection_limit'})
        with self.assertRaises(ExcerptPlanError): self.plan([], intents=())

    def test_actual_file_identity_is_required_without_changing_the_source(self):
        raw = b'an unchanged actual source'
        source = replace(self.source, sha256=hashlib.sha256(raw).hexdigest())
        with tempfile.TemporaryDirectory() as scratch:
            path = Path(scratch)/'source.mp4'; path.write_bytes(raw)
            self.assertEqual(verify_source_file(path, source)['bytes'], len(raw))
            self.assertEqual(path.read_bytes(), raw)
            path.write_bytes(b'changed')
            with self.assertRaises(ExcerptPlanError): verify_source_file(path, source)

    def test_existing_normal_scene_fields_require_same_source_video_and_never_make_a_voice(self):
        row = self.plan([Candidate('whole', 'result', 'result', .9, '完整过程。')])['selected'][0]
        asset = dict(id='unit-fixture-only', hash=self.source.sha256, mediaType='video')
        fields = recording_scene_fields(row, asset)
        self.assertEqual(fields, dict(assetID=asset['id'], sourceStartFrame=10, sourceEndFrame=190,
                                      durationFrames=180, speed=1, preservePitch=True))
        for bad in [{**asset, 'hash': 'b'*64}, {**asset, 'mediaType': 'audio'}]:
            with self.assertRaises(ExcerptPlanError): recording_scene_fields(row, bad)
        with self.assertRaises(ExcerptPlanError):
            recording_scene_fields({**row, 'source_purpose': 'protected_narration'}, asset)
        with self.assertRaises(ExcerptPlanError):
            recording_scene_fields({**row, 'source_sha256': None}, {**asset, 'hash': None})
        with self.assertRaises(ExcerptPlanError):
            recording_scene_fields({**row, 'sourceEndFrame': 11, 'durationFrames': True}, asset)


if __name__ == '__main__':
    unittest.main()
