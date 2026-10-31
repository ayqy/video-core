"""Bind an authored knowledge presentation to one complete original voice take.

This module only maps presentation frames from actual ReadAloud WordBoundary
observations. It never generates audio, changes a rule/event/tick, retimes a
source recording, or grants listening, subtitle or whole-film approval. The
normal Core compiler still verifies the returned presentation against its real
source project and the actual material-backed target scene.
"""
from __future__ import annotations

from copy import deepcopy
from decimal import Decimal, InvalidOperation, ROUND_CEILING
import hashlib

from readaloud_tts import spoken_text
from story_planning import StoryPlan, StoryPlanningError


TICKS_PER_SECOND = 10_000_000


class StorySpeechError(ValueError):
    """A bounded author-input error; it contains no service response or URL."""


def _need(condition, message):
    if not condition:
        raise StorySpeechError(message)


def _frame(value, high):
    return type(value) is int and 0 <= value <= high


def retime_presentation(presentation, boundaries, duration_seconds, *, fps=30):
    """Return ``{presentation, captions, frames, first_word_frame, axis}``.

    ``boundaries`` is the actual complete SDK sequence of dictionaries with
    type=WordBoundary and integer 100 ns offset/duration fields. ``duration_seconds``
    is the complete original audio's measured ffprobe duration. The caller must
    retain and pin those originals; accepting their values here does not prove
    that a service or decoder was run.

    Every shot needs explicit spoken text and must end at an SDK word boundary.
    If one SDK word crosses a shot boundary, there is no observed timing for the
    split, so it is rejected instead of inventing character timings. Shot zero
    starts at frame zero and the final shot includes the entire measured tail.
    Inside each shot the existing visual action order is mapped proportionally;
    a positive action interval which would collapse to zero frames is rejected.
    Source *display* windows change; all source models, native ticks, event
    selectors, interventions and other semantics remain byte-for-byte values.
    """
    _need(isinstance(presentation, dict), 'an explicit knowledge presentation is required')
    _need(type(fps) is int and 1 <= fps <= 120, 'fps must be an integer from 1 to 120')
    _need(isinstance(presentation.get('target'), dict) and presentation['target'].get('fps') == fps,
          'the actual presentation target fps must match the audio frame axis')
    try:
        story = StoryPlan.from_dict(presentation.get('story'))
    except (StoryPlanningError, TypeError, KeyError) as error:
        raise StorySpeechError('a complete valid StoryPlan is required') from error
    _need(story.complete, 'finish every StoryPlan layer before binding a complete voice')
    shots_content = story.stage('shots')
    shots = shots_content['shots']
    old_frames = shots[-1]['start_frame'] + shots[-1]['duration_frames']
    texts = [row['narration'] for row in shots]
    clean_texts = [spoken_text(text) for text in texts]
    _need(all(clean_texts), 'each shot needs explicit spoken text; a silent shot needs separate authored timing')
    narration = ''.join(texts)
    _need(type(duration_seconds) in (int, float, str) and not isinstance(duration_seconds, bool),
          'the complete measured original audio duration is required')
    _need(not isinstance(duration_seconds, str) or len(duration_seconds) <= 64,
          'the measured original audio duration must be a bounded number')
    try:
        duration = Decimal(str(duration_seconds))
    except (InvalidOperation, ValueError):
        raise StorySpeechError('the complete measured original audio duration must be finite') from None
    _need(duration.is_finite() and duration > 0, 'the complete measured original audio duration must be positive and finite')
    _need(duration <= Decimal(54000) / fps,
          'the complete voice exceeds the existing finite scene frame budget')
    frames = int((duration * fps).to_integral_value(rounding=ROUND_CEILING))
    _need(1 <= frames <= 54000, 'the complete voice exceeds the existing finite scene frame budget')
    _need(isinstance(boundaries, list) and 1 <= len(boundaries) <= 2048,
          'a bounded complete SDK WordBoundary sequence is required')
    words, previous_end = [], 0
    for row in boundaries:
        _need(isinstance(row, dict) and set(row) == {'type', 'offset', 'duration', 'text'}
              and row['type'] == 'WordBoundary' and type(row['offset']) is int
              and type(row['duration']) is int and row['offset'] >= previous_end
              and row['duration'] > 0 and isinstance(row['text'], str)
              and len(row['text']) <= 16384
              and bool(spoken_text(row['text'])),
              'SDK word boundaries need positive nonoverlapping observed intervals and spoken text')
        previous_end = row['offset'] + row['duration']
        words.append((spoken_text(row['text']), row['offset']))
    _need(Decimal(previous_end) <= duration * TICKS_PER_SECOND + Decimal(417),
          'the complete original voice duration does not cover the last observed SDK word')
    _need(boundaries[0]['offset'] < TICKS_PER_SECOND,
          'the first observed spoken word must begin before one second')
    _need(''.join(text for text, _ in words) == ''.join(clean_texts),
          'the complete SDK spoken text must cover every authored shot exactly and in order')

    # Only whole observed words can establish a new shot start. In particular,
    # do not distribute a multi-character word's time over its characters.
    starts, word_index = [0], 0
    for index, expected in enumerate(clean_texts):
        consumed = ''
        while len(consumed) < len(expected):
            _need(word_index < len(words), 'a shot is not covered by the actual SDK words')
            consumed += words[word_index][0]
            word_index += 1
        _need(consumed == expected, 'a shot boundary falls inside an SDK word or its observed text differs')
        if index + 1 < len(shots):
            _need(word_index < len(words), 'an authored shot lacks an observed first word')
            starts.append(words[word_index][1] * fps // TICKS_PER_SECOND)
    _need(word_index == len(words), 'all original SDK words must belong to the complete story')
    ends = starts[1:] + [frames]
    _need(all(0 <= a < b <= frames for a, b in zip(starts, ends)),
          'actual SDK shot windows must retain a positive frame span')

    segments = []
    for shot, a, b in zip(shots, starts, ends):
        segments.append(dict(shot_id=shot['id'], text=shot['narration'], start_frame=a, end_frame=b,
                             original_start_frame=shot['start_frame'],
                             original_end_frame=shot['start_frame'] + shot['duration_frames']))

    def map_frame(frame):
        _need(_frame(frame, old_frames), 'a visual frame lies outside the authored story axis')
        if frame == old_frames:
            return frames
        for segment in segments:
            a, b = segment['original_start_frame'], segment['original_end_frame']
            if a <= frame < b:
                return segment['start_frame'] + (frame - a) * (segment['end_frame'] - segment['start_frame']) // (b - a)
        raise StorySpeechError('a visual frame is not covered by the contiguous authored shots')

    result = deepcopy(presentation)
    for shot, segment in zip(shots_content['shots'], segments):
        shot['start_frame'] = segment['start_frame']
        shot['duration_frames'] = segment['end_frame'] - segment['start_frame']
    result['story'] = story.rewrite('shots', shots_content,
        '绑定完整新原音的实际逐词镜头窗；仅修改呈现时间，保留原生因果来源').to_dict()
    source_rows = result.get('sources')
    _need(isinstance(source_rows, list) and 1 <= len(source_rows) <= 3,
          'one to three explicit source display windows are required')
    sources, old_source_windows = {}, {}
    for source in source_rows:
        _need(isinstance(source, dict) and isinstance(source.get('id'), str) and source['id']
              and source['id'] not in sources, 'unique explicit source identities are required')
        a, b = source.get('start_frame'), source.get('end_frame')
        _need(_frame(a, old_frames) and _frame(b, old_frames) and a < b,
              'a source display window exceeds the authored story axis')
        _need(all(b <= x or a >= y for x, y in old_source_windows.values()),
              'source display windows must not overlap')
        old_source_windows[source['id']] = (a, b)
        source['start_frame'], source['end_frame'] = map_frame(a), map_frame(b)
        _need(source['start_frame'] < source['end_frame'], 'a source display window collapsed after speech alignment')
        sources[source['id']] = source
    old_shots = {row['id']: row for row in story.stage('shots')['shots']}
    beat_rows = result.get('beats')
    _need(isinstance(beat_rows, list) and 1 <= len(beat_rows) <= 256,
          'a bounded nonempty presentation action sequence is required')
    beats = {}
    for beat in beat_rows:
        _need(isinstance(beat, dict) and isinstance(beat.get('id'), str) and beat['id']
              and beat['id'] not in beats and beat.get('shot_id') in old_shots
              and beat.get('source_id') in sources, 'actions need unique identities and existing shot/source references')
        a, b = beat.get('start_frame'), beat.get('end_frame')
        shot = old_shots[beat['shot_id']]
        x, y = old_source_windows[beat['source_id']]
        _need(_frame(a, old_frames) and _frame(b, old_frames) and a < b
              and shot['start_frame'] <= a < b <= shot['start_frame'] + shot['duration_frames']
              and x <= a < b <= y, 'an action must keep its positive authored shot and source window')
        beat['start_frame'], beat['end_frame'] = map_frame(a), map_frame(b)
        _need(beat['start_frame'] < beat['end_frame'],
              'a positive authored action collapses to zero frames; revise its actual shot timing')
        beats[beat['id']] = beat
    for beat in beat_rows:
        _need(isinstance(beat.get('requires'), list) and all(identity in beats
              and beats[identity]['source_id'] == beat['source_id']
              and beats[identity]['end_frame'] <= beat['start_frame'] for identity in beat['requires']),
              'speech alignment must preserve every same-source action prerequisite')
    balances = result.get('balances', [])
    _need(isinstance(balances, list) and len(balances) <= 1024, 'invalid balance observation budget')
    for balance in balances:
        _need(isinstance(balance, dict) and balance.get('source_id') in sources,
              'balance observations need an existing source')
        a, b = old_source_windows[balance['source_id']]
        _need(_frame(balance.get('frame'), old_frames) and a <= balance['frame'] < b,
              'a balance observation lies outside its authored source window')
        balance['frame'] = map_frame(balance['frame'])
    captions = [dict(id='speech-shot-' + hashlib.sha256(segment['shot_id'].encode()).hexdigest()[:32],
        text=segment['text'], startFrame=segment['start_frame'], endFrame=segment['end_frame'],
        alignment='actual_original_readaloud_word_boundaries_unconfirmed', confirmed=False)
        for segment in segments]
    first_word_frame = boundaries[0]['offset'] * fps // TICKS_PER_SECOND
    return dict(presentation=result, captions=captions, frames=frames, first_word_frame=first_word_frame,
        axis=dict(fps=fps, duration_seconds=str(duration), duration_frames=frames,
                  original_duration_frames=old_frames, narration=narration,
                  word_boundary_count=len(boundaries), first_word_frame=first_word_frame,
                  segments=segments, voice_listened=False, captions_confirmed=False))
