"""Reuse a complete, provenance-bound voice axis without reconstructing words.

This accepts an existing production's exact timing, not replacement narration
or a new SDK observation. All paths are supplied explicitly by the caller.
There is no project-specific voice, frame count, actor, branch or shot count.
"""
from copy import deepcopy
from decimal import Decimal
import hashlib
import json
from pathlib import Path
import plistlib

from story_planning import StoryPlan
from knowledge_story import _trace


def need(value, message):
    if not value:
        raise ValueError(message)


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True,
                      separators=(',', ':'), allow_nan=False).encode()


def semantic_plan(plan):
    result = deepcopy(plan)
    result['target'] = {k: v for k, v in result['target'].items()
                        if k not in ('workspace_id', 'project_id', 'base_revision', 'scene_id')}
    for source in result['sources']:
        source.pop('scene_id')
    return result


class FrozenSpeech:
    """Validate an explicit immutable witness before creating a new home."""
    NAMES = ('prepared', 'quote', 'produced', 'inputs', 'speech-axis', 'backup')

    def __init__(self, witness, voice, receipt, presentation):
        need(isinstance(witness, dict) and set(self.NAMES) <= set(witness)
             and set(witness) - set(self.NAMES) in ({'revision-inputs'}, {'speech-provenance'}),
             'the complete retained voice witness is required')
        names = self.NAMES + tuple(set(witness) - set(self.NAMES))
        self.paths = []
        records = {}
        for name in names:
            row = witness[name]
            need(isinstance(row, dict) and set(row) == {'path', 'sha256'}, 'explicit witness path/hash required')
            path = Path(row['path'])
            need(path.is_absolute() and path.is_file() and not path.is_symlink(), 'ordinary witness file required')
            raw = path.read_bytes()
            need(digest(raw) == row['sha256'], 'retained witness hash differs: ' + name)
            self.paths.append(path.resolve())
            records[name] = plistlib.loads(raw)
        prepared, archive = records['prepared'], records['backup']
        need(archive['version'] == 2 and digest(archive['snapshot']) == archive['digest'],
             'complete retained backup snapshot digest differs')
        snapshot = json.loads(archive['snapshot'])
        targets = [p for p in snapshot['projects'] if p['id'] == prepared['project_id']]
        need(len(targets) == 1 and len(targets[0]['revisions'][-1]['scenes']) == 1, 'one original voice scene required')
        revision = targets[0]['revisions'][-1]
        scene = revision['scenes'][0]
        take = scene['voice']
        assets = [a for a in snapshot['assets'] if a['id'] == prepared['voice_asset_id']]
        need(len(assets) == 1 and targets[0]['workspaceID'] == prepared['workspace_id']
             and assets[0]['workspaceID'] == prepared['workspace_id']
             and revision['id'] == prepared['revision_id'] and take['assetID'] == assets[0]['id'],
             'original revision and complete voice identity differ')
        asset = assets[0]
        audio = Path(voice).read_bytes()
        need(asset['hash'] == receipt['audio_sha256'] == digest(audio)
             and asset['mediaType'] == 'audio' and asset['bytes'] == len(audio)
             and archive['assets']['assets/' + asset['hash'] + '.' + asset['ext']] == audio,
             'retained backup must contain the same complete original audio bytes')
        inputs = records['inputs']
        for path in (Path(voice), Path(voice).with_suffix('.source.md')):
            need([h for p, h in inputs.items() if Path(p).name == path.name] == [digest(path.read_bytes())],
                 'original audio and source receipt pins differ')
        # The SDK file may already be unavailable. Its identity is historical,
        # from the pinned original receipt; this path never asserts new words.
        self.boundaries_sha256 = receipt['word_boundaries.sha256']
        need(isinstance(self.boundaries_sha256, str) and len(self.boundaries_sha256) == 64
             and all(c in '0123456789abcdef' for c in self.boundaries_sha256), 'historical word metadata identity required')
        axis_path = self.paths[names.index('speech-axis')]
        if 'revision-inputs' in records:
            axes = [h for p, h in records['revision-inputs'].items() if Path(p).name == axis_path.name]
            need(axes and set(axes) == {digest(axis_path.read_bytes())},
                 'the original revision must pin one unchanged complete axis across its retained lineage')
        else:
            proof = records['speech-provenance']
            need(proof['version'] == 1 and proof['axis_sha256'] == digest(axis_path.read_bytes())
                 and proof['inputs_sha256'] == witness['inputs']['sha256']
                 and proof['voice_sha256'] == digest(audio)
                 and proof['source_receipt_sha256'] == digest(Path(voice).with_suffix('.source.md').read_bytes())
                 and proof['word_boundaries_sha256'] == self.boundaries_sha256
                 and proof['kind'] in ('observed-sdk-words', 'retained-complete-axis'),
                 'the original production must bind the complete axis and original input identities')
        axis = records['speech-axis']; core = axis['axis']
        frames = axis['frames']; fps = revision['fps']
        need(type(frames) is int and type(fps) is int and 1 <= fps <= 120 and 1 <= frames <= 54000
             and frames == prepared['frames'] == take['durationFrames'] == asset['durationFrames']
             == scene['durationFrames'] == core['duration_frames']
             and core['fps'] == fps and core['narration'] == scene['narration'] == receipt['request.text']
             and take['listened'] is False and core['voice_listened'] is False
             and core['captions_confirmed'] is False
             and Decimal(core['duration_seconds']) == Decimal(receipt['inspection.container_duration'])
             and str(core['word_boundary_count']) == receipt['word_boundaries.count']
             and type(core['first_word_frame']) is int
             and 0 <= axis['first_word_frame'] == core['first_word_frame'] < fps,
             'retained full voice duration, text, historical word count or review state differs')
        speech = scene.get('speechPlan')
        if speech is None:
            expected = digest(canonical(scene['narration']))
        else:
            need(speech['source'] == scene['narration'], 'original speech normalization differs')
            normalized = {k: deepcopy(speech[k]) for k in ('source', 'normalized', 'dictionary', 'rate')}
            if speech.get('voiceIdentifier') is not None:
                normalized['voice'] = speech['voiceIdentifier']
            expected = digest(canonical(normalized))
        need(take['textDigest'] == expected, 'original complete VoiceTake text digest differs')
        segments, captions = core['segments'], axis['captions']
        need(isinstance(segments, list) and segments and len(segments) == len(captions)
             and captions == scene['captions'] and segments[0]['start_frame'] == 0
             and segments[-1]['end_frame'] == frames
             and ''.join(s['text'] for s in segments) == core['narration'], 'complete retained segments differ')
        end = 0
        for segment, caption in zip(segments, captions):
            need(segment['start_frame'] == end < segment['end_frame'] <= frames
                 and caption['confirmed'] is False
                 and (caption['startFrame'], caption['endFrame'], caption['text']) ==
                 (segment['start_frame'], segment['end_frame'], segment['text']),
                 'retain every complete unconfirmed caption and segment interval')
            end = segment['end_frame']
        story = StoryPlan.from_dict(axis['presentation']['story'])
        shots = story.stage('shots')['shots']
        need(len(shots) == len(segments)
             and all((s['id'], s['narration'], s['start_frame'], s['start_frame'] + s['duration_frames']) ==
                     (t['shot_id'], t['text'], t['start_frame'], t['end_frame']) for s, t in zip(shots, segments)),
             'the retained story shots and complete spoken segments must share one exact axis')
        need(story.complete and semantic_plan(axis['presentation']) == semantic_plan(presentation)
             and semantic_plan(axis['presentation']) == semantic_plan(prepared['plan']),
             'retained timing cannot authorize another story, source rule, action, layout or narration')
        jobs = [j for j in snapshot['jobs'] if j['id'] == records['produced']['job_id']]
        produced = records['produced']
        def artifacts(rows):
            result = []
            for artifact in rows:
                row = deepcopy(artifact)
                path = Path(row.pop('path'))
                suffix = Path('exports') / produced['job_id'] / path.name
                need(path.as_posix() == suffix.as_posix() or path.as_posix().endswith('/' + suffix.as_posix()),
                     'retained artifact must belong to the exact original job export directory')
                result.append(dict(row, path=suffix.as_posix()))
            return result
        need(len(jobs) == 1 and jobs[0]['projectID'] == prepared['project_id']
             and jobs[0]['revisionID'] == prepared['revision_id']
             and produced['revision'] == prepared['revision_id']
             and jobs[0]['state'] == produced['state'] == 'needs_review'
             and artifacts(jobs[0]['artifacts']) == artifacts(produced['artifacts']) and len(produced['artifacts']) == 4
             and all(a['revision'] == prepared['revision_id'] for a in produced['artifacts'])
             and jobs[0]['quote'] == records['quote'], 'original quote/job provenance differs')
        sources = [p for p in snapshot['projects'] if p['id'] == prepared['source_project_id']]
        need(len(sources) == 1 and sources[0]['workspaceID'] == prepared['workspace_id']
             and sources[0]['revisions'][-1]['id'] == prepared['recorded']['revision'],
             'complete original source history differs')
        by_id = {s['id']: s for s in sources[0]['revisions'][-1]['scenes']}
        recorded = {s['id']: s for s in prepared['recorded']['sources']}
        for source in prepared['plan']['sources']:
            actual = by_id[source['scene_id']]
            need(actual['simulation']['knowledge'] == source['model']
                 and actual['simulation']['seed'] == source['seed']
                 and _trace(source, actual, fps) == recorded[source['id']]['trace'],
                 'original model or complete recorded source differs')
        self.timed = deepcopy(axis)
        self.timed['presentation'] = deepcopy(presentation)
