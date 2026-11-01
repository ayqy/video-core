"""Map authored shot text to complete Core TN segments, without inventing time.

The caller still verifies the complete original audio, same-request SDK words,
and actual duration.  This module never modifies SDK word text or timestamps;
the retimer must reject any shot cut falling inside an observed SDK word.
"""
from __future__ import annotations

import hashlib
import json
import math


class SpeechPlanAlignmentError(ValueError):
    """The supplied Core plan cannot prove exact shot-text boundaries."""


def _need(value, message):
    if not value:
        raise SpeechPlanAlignmentError(message)


def _scalar_offsets(value, label):
    _need(type(value) is str, label + ' must be Unicode text')
    try:
        value.encode('utf-8')
    except UnicodeEncodeError:
        raise SpeechPlanAlignmentError(label + ' contains an invalid Unicode scalar') from None
    offsets, offset = {0: 0}, 0
    for index, scalar in enumerate(value, 1):
        offset += 2 if ord(scalar) > 0xffff else 1
        offsets[offset] = index
    return offsets, offset


def _digest(value):
    return hashlib.sha256(value).hexdigest()


def map_shot_texts(texts, speech_plan):
    """Return exact normalized slices and a binding to the complete Core plan.

    Both UTF-16 axes must be covered once, continuously and on Unicode scalar
    boundaries.  An unchanged segment permits exact interior text cuts; every
    rewritten segment remains indivisible.  A manual_document is usable only
    as one complete shot.  These are text boundaries, never word timing.
    """
    required = {'source','normalized','dictionary','mappings','rate','confirmed','notes'}
    _need(type(speech_plan) is dict and required <= set(speech_plan)
          and set(speech_plan) <= required | {'voiceIdentifier'}, 'a complete standard Core SpeechPlan is required')
    source, normalized = speech_plan['source'], speech_plan['normalized']
    source_offsets, source_count = _scalar_offsets(source, 'source')
    normalized_offsets, normalized_count = _scalar_offsets(normalized, 'normalized')
    _need(source.strip() and normalized.strip() and source_count <= 4000 and normalized_count <= 8000,
          'complete source/normalized text must retain the Core size limits')
    rate = speech_plan['rate']
    _need(type(rate) in (int,float) and .2 <= rate <= .65 and math.isfinite(rate)
          and type(speech_plan['confirmed']) is bool, 'Core rate and confirmation types are required')
    notes = speech_plan['notes']
    _need(type(notes) is list, 'Core notes must be a text array')
    for note in notes:
        _scalar_offsets(note, 'note')
    voice = speech_plan.get('voiceIdentifier')
    if voice is not None:
        _scalar_offsets(voice, 'voiceIdentifier')
    dictionary = speech_plan['dictionary']
    _need(type(dictionary) is list and len(dictionary) <= 200, 'the complete bounded Core dictionary is required')
    terms, pairs = set(), set()
    for row in dictionary:
        _need(type(row) is dict and set(row) == {'term','pronunciation'}, 'unknown Core dictionary field')
        _, term_count = _scalar_offsets(row['term'], 'term')
        _, pronunciation_count = _scalar_offsets(row['pronunciation'], 'pronunciation')
        _need(0 < term_count <= 100 and 0 < pronunciation_count <= 200 and row['term'] not in terms,
              'dictionary terms must be unique, nonempty and within Core limits')
        terms.add(row['term']); pairs.add((row['term'],row['pronunciation']))
    _need(type(texts) in (list,tuple) and 1 <= len(texts) <= source_count,
          'a nonempty bounded shot-text sequence is required')
    source_cuts, cursor = [0], 0
    for text in texts:
        _, count = _scalar_offsets(text, 'shot')
        _need(count > 0, 'each original shot must contain text')
        cursor += count; source_cuts.append(cursor)
    _need(''.join(texts) == source, 'all original shots must cover the exact Core source in order')
    mappings = speech_plan['mappings']
    fields = {'sourceStart','sourceLength','normalizedStart','normalizedLength','kind'}
    kinds = {'unchanged','dictionary','date','currency','percentage','number','acronym','manual_document'}
    _need(type(mappings) is list and 1 <= len(mappings) <= source_count,
          'complete nonempty Core TN mappings are required')
    source_cursor = normalized_cursor = 0
    normalized_cuts = {0: 0}
    segments = []
    for row in mappings:
        _need(type(row) is dict and set(row) == fields and type(row['kind']) is str
              and row['kind'] in kinds, 'unknown Core TN mapping field or kind')
        _need(all(type(row[key]) is int for key in fields - {'kind'}), 'UTF-16 offsets must be integer values, never bool')
        start, length = row['sourceStart'], row['sourceLength']
        target, target_length = row['normalizedStart'], row['normalizedLength']
        _need(start == source_cursor and target == normalized_cursor and length > 0 and target_length > 0
              and start <= source_count and length <= source_count - start
              and target <= normalized_count and target_length <= normalized_count - target,
              'TN mappings must continuously and completely cover both axes without overlaps or gaps')
        end, target_end = start + length, target + target_length
        _need(start in source_offsets and end in source_offsets
              and target in normalized_offsets and target_end in normalized_offsets,
              'TN mapping boundaries must not split a UTF-16 surrogate pair')
        original = source[source_offsets[start]:source_offsets[end]]
        spoken = normalized[normalized_offsets[target]:normalized_offsets[target_end]]
        if row['kind'] == 'unchanged':
            _need(original.encode('utf-8') == spoken.encode('utf-8'), 'an unchanged TN segment must preserve exact text bytes')
        if row['kind'] == 'dictionary':
            _need((original,spoken) in pairs, 'dictionary mapping must match one explicit Core term and pronunciation')
        if row['kind'] == 'manual_document':
            _need(len(mappings) == len(texts) == 1 and start == target == 0
                  and end == source_count and target_end == normalized_count,
                  'manual_document permits one complete original shot only')
        normalized_cuts[start], normalized_cuts[end] = target, target_end
        segments.append((start,end,target,row['kind']))
        source_cursor, normalized_cursor = end, target_end
    _need(source_cursor == source_count and normalized_cursor == normalized_count,
          'TN mappings must include the complete source and normalized tails')
    for cut in source_cuts:
        if cut in normalized_cuts:
            continue
        segment = next((row for row in segments if row[0] < cut < row[1]), None)
        _need(segment is not None and segment[3] == 'unchanged', 'a shot boundary cannot cut inside a rewritten TN segment')
        target = segment[2] + cut - segment[0]
        _need(cut in source_offsets and target in normalized_offsets, 'shot cuts must preserve Unicode scalar boundaries')
        normalized_cuts[cut] = target
    offsets = [normalized_cuts[cut] for cut in source_cuts]
    _need(all(left < right for left,right in zip(offsets,offsets[1:])), 'each normalized shot must retain a positive exact text span')
    result = [normalized[normalized_offsets[left]:normalized_offsets[right]] for left,right in zip(offsets,offsets[1:])]
    _need(''.join(result) == normalized, 'normalized shot slices must preserve the entire actual request text')
    plan_bytes = json.dumps(speech_plan,sort_keys=True,ensure_ascii=False,separators=(',',':'),allow_nan=False).encode('utf-8')
    return dict(normalized_texts=result, binding=dict(kind='speech-plan-utf16-whole-segment-v1',
        source_sha256=_digest(source.encode('utf-8')), normalized_sha256=_digest(normalized.encode('utf-8')),
        plan_sha256=_digest(plan_bytes), mapping_count=len(mappings),
        precision='shot_text_boundaries_only; no_word_or_character_timing; sdk_words_unchanged'))
