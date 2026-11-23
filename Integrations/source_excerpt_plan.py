"""Plan complete, source-bound excerpts before normal production authoring.

Design reference: AutoClip 49fa8e859e6573a5e32a9135502dfddcefd834cb,
pipeline/clip_finder.py, studio/boundaries.py and services/platform_strategy.py
(MIT, Copyright (c) 2024 AutoClip Team). This adapter is independently written.

Units are explicit complete thoughts or observed operations supplied by an
author, not punctuation-based guesses at word times. Dependencies expand one
continuous source window; nothing is padded, spliced, retimed or rendered here.
Existing confirmed narration is protected: only its entire file can be planned.
Frame/duration metadata still needs the normal media importer. A plan grants
neither audiovisual approval nor permission to publish a source.
"""
from __future__ import annotations

from dataclasses import dataclass
import hashlib
import math
from pathlib import Path
import re


class ExcerptPlanError(ValueError):
    pass


def _need(value, message):
    if not value:
        raise ExcerptPlanError(message)


def _text(value, label, maximum=4000):
    try:
        valid = type(value) is str and bool(value.strip()) and len(value.encode('utf-8')) <= maximum
    except UnicodeEncodeError:
        valid = False
    _need(valid, label + ' must be explicit bounded text')


@dataclass(frozen=True)
class Source:
    id: str
    sha256: str
    frames: int
    fps: int
    purpose: str  # reference, recording, or protected_narration


@dataclass(frozen=True)
class Unit:
    id: str
    start: int
    end: int
    text: str
    depends_on: tuple[str, ...] = ()


@dataclass(frozen=True)
class Candidate:
    id: str
    first: str
    last: str
    score: float
    reason: str


@dataclass(frozen=True)
class OutputIntent:
    id: str
    aspect: str
    maximum_frames: int | None = None


def _source(source):
    _need(type(source) is Source, 'an explicit source clock and identity are required')
    _text(source.id, 'source id', 200)
    _need(type(source.sha256) is str and re.fullmatch('[0-9a-f]{64}', source.sha256),
          'source SHA256 is required')
    _need(type(source.fps) is int and 1 <= source.fps <= 120
          and type(source.frames) is int and 0 < source.frames <= source.fps * 86400,
          'finite whole-frame source duration and fps are required')
    _need(type(source.purpose) is str and source.purpose in {'reference', 'recording', 'protected_narration'},
          'source purpose must distinguish protected narration from excerptable media')


def verify_source_file(path, source):
    """Read only: hash the actual regular file and bind it to the planned source."""
    _source(source)
    path = Path(path)
    _need(path.is_file() and not path.is_symlink(), 'a regular source file is required')
    before = path.stat()
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        while block := stream.read(1024 * 1024):
            digest.update(block)
    after = path.stat()
    _need((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
          == (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
          and digest.hexdigest() == source.sha256, 'source identity changed or does not match')
    return dict(source_id=source.id, path=str(path.resolve()), bytes=after.st_size,
                sha256=digest.hexdigest(), metadata_basis='caller_must_bind_normal_media_probe')


def plan_excerpts(source, units, candidates, intents, *, minimum_score, maximum_selected):
    """Return source windows and explicit omissions; never execute a media edit.

    Unit intervals are half open and may contain gaps on the original clock.
    All earlier context dependencies must be included, including their source
    gaps. Overlapping candidates keep the highest score; equal scores retain
    input order. Hard destination limits report an unavailable variant rather
    than cutting a sentence or manufacturing duration. No platform list or
    recommendation is silently promoted to a required output or hard limit.
    """
    _source(source)
    _need(type(units) in (tuple, list) and 1 <= len(units) <= 20000,
          'complete ordered source units are required')
    _need(type(candidates) in (tuple, list) and len(candidates) <= 2000,
          'a bounded explicit candidate list is required')
    _need(type(intents) in (tuple, list) and 1 <= len(intents) <= 32,
          'explicit output intents are required')
    _need(type(minimum_score) in (int, float) and 0 <= minimum_score <= 1
          and math.isfinite(minimum_score) and type(maximum_selected) is int
          and 1 <= maximum_selected <= 100, 'explicit finite selection limits are required')
    by_id, previous = {}, 0
    for index, unit in enumerate(units):
        _need(type(unit) is Unit, 'every unit must be an explicit whole thought or operation')
        _text(unit.id, 'unit id', 200); _text(unit.text, 'unit text')
        _need(unit.id not in by_id and type(unit.start) is int and type(unit.end) is int
              and previous <= unit.start < unit.end <= source.frames,
              'unit identities and source intervals must be unique, ordered and in range')
        _need(type(unit.depends_on) is tuple and all(type(key) is str and key in by_id for key in unit.depends_on)
              and len(set(unit.depends_on)) == len(unit.depends_on),
              'dependencies must name distinct earlier complete source units')
        by_id[unit.id] = index; previous = unit.end
    intent_ids = set()
    for intent in intents:
        _need(type(intent) is OutputIntent, 'a typed output intent is required')
        _text(intent.id, 'output intent', 200)
        _need(intent.id not in intent_ids and type(intent.aspect) is str
              and intent.aspect in {'source', '16:9', '9:16', '1:1'}
              and (intent.maximum_frames is None or (type(intent.maximum_frames) is int
                   and 0 < intent.maximum_frames <= source.fps * 86400)), 'invalid or duplicate output intent')
        intent_ids.add(intent.id)
    rows, omitted, ids = [], [], set()
    for order, candidate in enumerate(candidates):
        _need(type(candidate) is Candidate, 'a typed content candidate is required')
        _text(candidate.id, 'candidate id', 200); _text(candidate.reason, 'candidate reason')
        _need(candidate.id not in ids and type(candidate.first) is str and type(candidate.last) is str
              and candidate.first in by_id and candidate.last in by_id
              and by_id[candidate.first] <= by_id[candidate.last]
              and type(candidate.score) in (int, float) and 0 <= candidate.score <= 1
              and math.isfinite(candidate.score), 'invalid candidate identity, units or score')
        ids.add(candidate.id)
        first, last = by_id[candidate.first], by_id[candidate.last]
        requested = (first, last)
        # Earlier-only dependencies form a finite DAG. Expand to one continuous
        # interval instead of concatenating separated sentences or operations.
        while True:
            earlier = min([first] + [by_id[key] for unit in units[first:last+1]
                                    for key in unit.depends_on])
            if earlier == first:
                break
            first = earlier
        reason = None
        if candidate.score < minimum_score:
            reason = 'below_explicit_score'
        elif source.purpose == 'protected_narration' and (first != 0 or last != len(units)-1):
            reason = 'protected_narration_requires_whole_source'
        start, end = units[first].start, units[last].end
        if source.purpose == 'protected_narration' and reason is None:
            start, end = 0, source.frames  # retain every leading/trailing audio sample window
        variants = [dict(id=intent.id, aspect=intent.aspect,
            status=('duration_exceeds_explicit_limit' if intent.maximum_frames is not None
                    and end-start > intent.maximum_frames else
                    'source_frame_preserved' if intent.aspect == 'source' else 'authored_layout_required'))
            for intent in intents]
        if reason is None and all(v['status'] == 'duration_exceeds_explicit_limit' for v in variants):
            reason = 'no_destination_fits_whole_content'
        if reason:
            omitted.append(dict(id=candidate.id, reason=reason))
            continue
        rows.append(dict(id=candidate.id, source_id=source.id, source_sha256=source.sha256,
            source_purpose=source.purpose, source_frames=source.frames,
            sourceStartFrame=start, sourceEndFrame=end, durationFrames=end-start,
            unit_ids=[u.id for u in units[first:last+1]], score=candidate.score,
            reason=candidate.reason, context_expanded=(first, last) != requested,
            variants=variants, _order=order))
    kept = []
    for row in sorted(rows, key=lambda r: (-r['score'], r['_order'])):
        overlap = next((other for other in kept if max(row['sourceStartFrame'], other['sourceStartFrame'])
                       < min(row['sourceEndFrame'], other['sourceEndFrame'])), None)
        if overlap:
            omitted.append(dict(id=row['id'], reason='overlaps_selected_content', selected_id=overlap['id']))
        elif len(kept) >= maximum_selected:
            omitted.append(dict(id=row['id'], reason='explicit_selection_limit'))
        else:
            kept.append(row)
    for row in kept:
        del row['_order']
    kept.sort(key=lambda row: row['sourceStartFrame'])
    return dict(kind='complete-source-excerpt-plan-v1', source_id=source.id,
                source_sha256=source.sha256, fps=source.fps, source_frames=source.frames,
                selected=kept, omitted=omitted, media_modified=False,
                source_audio_spliced_or_retimed=False, audiovisual_review_granted=False,
                purpose=source.purpose)


def recording_scene_fields(window, imported_asset):
    """Map one planned recording window to existing normal Scene source fields.

    The producer still owns normal source import, readable framing, captions,
    complete narration, review and export. This does not construct a new voice.
    """
    _need(type(window) is dict and type(imported_asset) is dict
          and type(imported_asset.get('id')) is str and bool(imported_asset['id'])
          and window.get('source_purpose') == 'recording' and imported_asset.get('mediaType') == 'video'
          and type(window.get('source_sha256')) is str
          and re.fullmatch('[0-9a-f]{64}',window['source_sha256']) is not None
          and imported_asset.get('hash') == window.get('source_sha256'),
          'normal imported asset must match the actual planned source hash')
    start, end = window.get('sourceStartFrame'), window.get('sourceEndFrame')
    _need(type(start) is int and type(end) is int and type(window.get('source_frames')) is int
          and 0 <= start < end <= window['source_frames']
          and type(window.get('durationFrames')) is int
          and window['durationFrames'] == end-start, 'complete whole-frame window required')
    return dict(assetID=imported_asset['id'], sourceStartFrame=start, sourceEndFrame=end,
                durationFrames=end-start, speed=1, preservePitch=True)
