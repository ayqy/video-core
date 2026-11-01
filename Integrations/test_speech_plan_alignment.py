"""Meaningful pure boundary cases; no Native, network, audio or fake timing."""
from copy import deepcopy
import hashlib
import json
import unittest

from speech_plan_alignment import SpeechPlanAlignmentError, map_shot_texts


def plan(segments):
    source = normalized = ''
    mappings, dictionary = [], []
    for original, spoken, kind in segments:
        mappings.append(dict(sourceStart=len(source.encode('utf-16-le'))//2,
            sourceLength=len(original.encode('utf-16-le'))//2,
            normalizedStart=len(normalized.encode('utf-16-le'))//2,
            normalizedLength=len(spoken.encode('utf-16-le'))//2,kind=kind))
        source += original; normalized += spoken
        if kind == 'dictionary':
            row = dict(term=original, pronunciation=spoken)
            if row not in dictionary:
                dictionary.append(row)
    return dict(source=source,normalized=normalized,dictionary=dictionary,mappings=mappings,
                rate=.5,confirmed=True,notes=['标准Core计划'],voiceIdentifier='explicit-test-voice')


class SpeechPlanAlignmentTests(unittest.TestCase):
    def rejected(self, texts, value):
        with self.assertRaises(SpeechPlanAlignmentError):
            map_shot_texts(texts,value)

    def test_dictionary_expansion_and_number_preserve_original_shots(self):
        value = plan([('API','人工智能','dictionary'),('成本','成本','unchanged'),
                      ('99','九十九','number'),('元。下一句。','元。下一句。','unchanged')])
        before = deepcopy(value)
        mapped = map_shot_texts(['API成本99元。','下一句。'],value)
        self.assertEqual(mapped['normalized_texts'],['人工智能成本九十九元。','下一句。'])
        self.assertEqual(value,before)
        self.assertEqual(mapped['binding']['source_sha256'],hashlib.sha256(value['source'].encode()).hexdigest())
        self.assertEqual(mapped['binding']['plan_sha256'],hashlib.sha256(json.dumps(value,
            sort_keys=True,ensure_ascii=False,separators=(',',':'),allow_nan=False).encode()).hexdigest())
        self.assertIn('no_word_or_character_timing',mapped['binding']['precision'])

    def test_dictionary_contraction_retains_exact_following_boundary(self):
        value = plan([('应用程序接口','API','dictionary'),('。下一句。','。下一句。','unchanged')])
        self.assertEqual(map_shot_texts(['应用程序接口。','下一句。'],value)['normalized_texts'],['API。','下一句。'])

    def test_utf16_astral_scalar_cuts_do_not_use_python_character_offsets(self):
        value = plan([('甲😀','甲😀','unchanged'),('API','人工智能','dictionary'),('。乙','。乙','unchanged')])
        self.assertEqual(map_shot_texts(['甲','😀','API。','乙'],value)['normalized_texts'],['甲','😀','人工智能。','乙'])

    def test_shot_inside_rewrite_is_refused_even_for_equal_lengths(self):
        for value in (plan([('API','人工智能','dictionary'),('。','。','unchanged')]),
                      plan([('API','甲乙丙','dictionary'),('。','。','unchanged')])):
            self.rejected(['A','PI。'],value)

    def test_complete_manual_document_is_whole_shot_only(self):
        value = plan([('原稿。下一句。','新读法。继续。','manual_document')])
        self.assertEqual(map_shot_texts([value['source']],value)['normalized_texts'],[value['normalized']])
        self.rejected(['原稿。','下一句。'],value)
        value = plan([('原稿。','新读法。','manual_document'),('下一句。','下一句。','unchanged')])
        self.rejected([value['source']],value)

    def test_both_axes_require_full_gapless_nonoverlapping_coverage(self):
        original = plan([('甲','甲','unchanged'),('乙','二','number')])
        for field,value in [('sourceStart',0),('sourceStart',2),('normalizedStart',0),('normalizedStart',2)]:
            bad = deepcopy(original);bad['mappings'][1][field] = value
            self.rejected(['甲乙'],bad)
        for field in ('sourceLength','normalizedLength'):
            bad = plan([('甲乙','甲乙','unchanged')]);bad['mappings'][0][field] = 1
            self.rejected(['甲乙'],bad)
        bad = deepcopy(original);bad['mappings'] = []
        self.rejected(['甲乙'],bad)

    def test_invalid_offset_types_and_unknown_fields_or_kinds_refuse(self):
        original = plan([('甲','甲','unchanged')])
        for field in ('sourceStart','sourceLength','normalizedStart','normalizedLength'):
            for replacement in (True,False,0.0,-1,10**100):
                bad = deepcopy(original);bad['mappings'][0][field] = replacement
                self.rejected(['甲'],bad)
        for addition in ('plan','mapping'):
            bad = deepcopy(original)
            (bad if addition == 'plan' else bad['mappings'][0])['unknown'] = 1
            self.rejected(['甲'],bad)
        bad = deepcopy(original);bad['mappings'][0]['kind'] = 'invented'
        self.rejected(['甲'],bad)

    def test_unchanged_is_exact_and_dictionary_is_explicit(self):
        self.rejected(['甲'],plan([('甲','乙','unchanged')]))
        bad = plan([('API','人工智能','dictionary')]);bad['dictionary'][0]['pronunciation'] = '另一读法'
        self.rejected(['API'],bad)

    def test_mapping_cannot_cut_source_or_normalized_surrogate_pair(self):
        original = plan([('😀','😀','unchanged'),('甲','甲','unchanged')])
        for left,right in (('sourceLength','sourceStart'),('normalizedLength','normalizedStart')):
            bad = deepcopy(original);bad['mappings'][0][left] = 1;bad['mappings'][1][right] = 1
            bad['mappings'][1][left] = 2
            self.rejected(['😀甲'],bad)

    def test_invalid_unicode_and_non_core_plan_shapes_fail_closed(self):
        original = plan([('甲','甲','unchanged')])
        for key in ('source','normalized'):
            bad = deepcopy(original);bad[key] = '\ud800'
            self.rejected(['甲'],bad)
        for key in ('source','normalized','dictionary','mappings','rate','confirmed','notes'):
            bad = deepcopy(original);del bad[key]
            self.rejected(['甲'],bad)
        for key,value in [('rate',True),('rate',float('nan')),('rate',10**1000),('confirmed',1),('notes',['\udfff'])]:
            bad = deepcopy(original);bad[key] = value
            self.rejected(['甲'],bad)

    def test_original_shots_cannot_be_missing_reordered_empty_or_replaced(self):
        value = plan([('甲。乙。','甲。乙。','unchanged')])
        for texts in ([],['甲。'],['乙。','甲。'],['甲。','','乙。'],['甲。','丙。']):
            self.rejected(texts,value)

    def test_unchanged_legacy_text_is_identity_without_time_or_sdk_fields(self):
        texts = ['四个邻居想修路。','凑够三枚硬币，就能开工。']
        value = plan([(''.join(texts),''.join(texts),'unchanged')])
        mapped = map_shot_texts(texts,value)
        self.assertEqual(mapped['normalized_texts'],texts)
        self.assertEqual(set(mapped),{'normalized_texts','binding'})
        self.assertEqual(set(mapped['binding']),{'kind','source_sha256','normalized_sha256',
            'plan_sha256','mapping_count','precision'})


if __name__ == '__main__':
    unittest.main()
