"""Compose an explicit imported image narrator over an independent story stage.

``compose(scene, timed, profile, materials, energy)`` reads only the supplied
material's bytes to verify its SHA256; it never decodes, draws or imports media.
The owner must first call ``speech_energy.analyze_take`` on the actual complete
take with ``actor_id=profile['id']``. RMS means volume, never phoneme timing.

Profile version 1 requires id, material_key, master_role, actual frames
[{role, sourceRect}], native clips/cues, x/y/width/height, anchor='bottom' and
layout='presenter'. No character, frame clock, crop or mouth shape is supplied
by this module. The caller authors transparent crop edges and bottom placement.
``materials[material_key]`` requires asset_id, evidence_id, path, sha256 and one
native ClassicSource dictionary under source. Optional receipt ``frames`` must
equal the profile's table, allowing a separately frozen source table to bind it.
Successful calls preserve all input objects and all non-layout business facts.
"""
from copy import deepcopy
import hashlib
import math
from pathlib import Path
import re
import unicodedata

from scene_layout import present


class PresenterCompositionError(ValueError):
    pass


def _need(condition, message):
    if not condition:
        raise PresenterCompositionError(message)


def _number(value):
    if type(value) not in (int, float):
        return False
    try:
        return math.isfinite(value)
    except OverflowError:
        return False


def _text(value, maximum=128):
    return (isinstance(value, str) and bool(value.strip())
            and len(value.encode('utf-8')) <= maximum
            and not any(unicodedata.category(c) == 'Cc' for c in value))


def _identifier(value):
    return isinstance(value, str) and re.fullmatch(r'[A-Za-z0-9._-]{1,80}', value) is not None


def _sha(value):
    return isinstance(value, str) and re.fullmatch(r'[0-9a-f]{64}', value) is not None


def _keys(value, required, label):
    _need(isinstance(value, dict) and set(value) == set(required),
          label + ' must contain exactly its declared contract fields')


def _profile(profile, duration):
    _keys(profile, ('version', 'id', 'material_key', 'master_role', 'frames',
                   'clips', 'cues', 'x', 'y', 'width', 'height', 'anchor', 'layout'),
          'Presenter profile')
    _need(type(profile['version']) is int and profile['version'] == 1
          and _identifier(profile['id']) and _text(profile['material_key'])
          and profile['anchor'] == 'bottom' and profile['layout'] == 'presenter',
          'An explicit version 1 independent bottom presenter profile is required')
    x, y, width, height = (profile[k] for k in ('x', 'y', 'width', 'height'))
    _need(all(_number(v) for v in (x, y, width, height))
          and .05 <= width <= 1 and .05 <= height <= 1
          and x-width/2 >= 0 and x+width/2 <= 1
          and y-height/2 >= 0 and y+height/2 <= 1,
          'The finite native presenter box must remain completely on stage')
    frames = profile['frames']
    _need(isinstance(frames, list) and 3 <= len(frames) <= 32,
          'Supply a finite native sprite table of actual source regions')
    roles, regions = set(), set()
    for row in frames:
        _keys(row, ('role', 'sourceRect'), 'Source frame')
        _need(_text(row['role']) and row['role'] not in roles,
              'Actual source frame roles must be valid and unique')
        roles.add(row['role'])
        rect = row['sourceRect']
        _keys(rect, ('x', 'y', 'width', 'height'), 'Source crop')
        _need(all(_number(rect[k]) for k in rect) and rect['x'] >= 0 and rect['y'] >= 0
              and rect['width'] > 0 and rect['height'] > 0
              and rect['x']+rect['width'] <= 1.000001
              and rect['y']+rect['height'] <= 1.000001,
              'Actual source regions must be finite normalized native crops')
        region = tuple(rect[k] for k in ('x', 'y', 'width', 'height'))
        _need(region not in regions, 'Distinct frame roles cannot alias one actual source crop')
        regions.add(region)
    _need(_text(profile['master_role']) and profile['master_role'] in roles,
          'The master role must reference an actual source frame')
    clips = profile['clips']
    _need(isinstance(clips, list) and 1 <= len(clips) <= 16,
          'Supply one to sixteen native clips; no clip is generated')
    clip_ids, count = set(), 0
    for clip in clips:
        _keys(clip, ('id', 'frameDurationFrames', 'frames'), 'Presenter clip')
        _need(_identifier(clip['id']) and clip['id'] not in clip_ids
              and type(clip['frameDurationFrames']) is int
              and 1 <= clip['frameDurationFrames'] <= 30
              and isinstance(clip['frames'], list) and 3 <= len(clip['frames']) <= 32,
              'Native clips need unique identities, finite cadence and actual mouth frames')
        clip_ids.add(clip['id']); count += len(clip['frames'])
        used, openness = set(), set()
        for row in clip['frames']:
            _keys(row, ('role', 'mouthOpen'), 'Clip frame')
            _need(_text(row['role']) and row['role'] in roles and row['role'] not in used
                  and _number(row['mouthOpen']) and 0 <= row['mouthOpen'] <= 1,
                  'Clip mouth frames must reference distinct actual sprite roles')
            used.add(row['role']); openness.add(row['mouthOpen'])
        _need(0 in openness and len(openness) >= 3,
              'A native clip requires a real closed mouth and three distinct openness values')
    _need(count <= 256, 'Native clips exceed the finite 256-frame budget')
    cues = profile['cues']
    _need(isinstance(cues, list) and 1 <= len(cues) <= 256,
          'Supply the complete finite native cue clock; no cue is generated')
    end = 0
    for cue in cues:
        _keys(cue, ('startFrame', 'endFrame', 'clipID', 'animationOffsetFrames'), 'Presenter cue')
        _need(type(cue['startFrame']) is int and type(cue['endFrame']) is int
              and cue['startFrame'] == end < cue['endFrame'] <= duration
              and _identifier(cue['clipID']) and cue['clipID'] in clip_ids
              and type(cue['animationOffsetFrames']) is int
              and 0 <= cue['animationOffsetFrames'] <= 216000,
              'Presenter cues must continuously cover the actual source using declared clips')
        end = cue['endFrame']
    _need(end == duration, 'Presenter cues must include the complete source tail')


def validate_profile(profile, duration):
    """Validate explicit native metadata before any project or import write."""
    _profile(profile, duration)
    return deepcopy(profile)


def _material(profile, materials):
    _need(isinstance(materials, dict) and profile['material_key'] in materials,
          'The explicit presenter material key has no imported source receipt')
    item = materials[profile['material_key']]
    required = {'asset_id', 'evidence_id', 'path', 'sha256', 'source'}
    _need(isinstance(item, dict) and required <= set(item)
          and set(item) <= required | {'frames'}
          and _identifier(item['asset_id']) and _identifier(item['evidence_id'])
          and _sha(item['sha256']), 'A finite actual material and evidence receipt is required')
    if 'frames' in item:
        _need(item['frames'] == profile['frames'],
              'The profile must retain the separately frozen actual source frame table')
    source = item['source']
    _keys(source, ('assetID', 'hash', 'source', 'owner', 'license', 'evidenceID'), 'ClassicSource')
    _need(source['assetID'] == item['asset_id'] and source['hash'] == item['sha256']
          and source['evidenceID'] == item['evidence_id']
          and all(_text(source[k], 16384) for k in ('source', 'owner', 'license')),
          'ClassicSource must identify this exact imported original and evidence receipt')
    _need(isinstance(item['path'], (str, Path)), 'An explicit actual original path is required')
    path = Path(item['path']).absolute()
    _need(path.is_file() and not path.is_symlink() and path.resolve() == path
          and 1 <= path.stat().st_size <= 64*1024*1024,
          'The original must be a bounded ordinary file, without symlink substitution')
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024*1024), b''):
            digest.update(chunk)
    _need(digest.hexdigest() == item['sha256'], 'The supplied original bytes differ from their source SHA256')
    return item


def _speech(scene, timed, energy, actor_id):
    frames, voice = scene['durationFrames'], scene.get('voice')
    _need(isinstance(voice, dict) and _identifier(voice.get('assetID'))
          and _sha(voice.get('textDigest')) and type(voice.get('durationFrames')) is int
          and voice['durationFrames'] == frames and isinstance(timed, dict)
          and _sha(timed.get('voice_sha256')) and type(timed.get('frames')) is int
          and timed['frames'] == frames,
          'The complete scene must retain its current voice and pinned timing source')
    _keys(energy, ('actorID', 'voiceAssetID', 'sourceSHA256', 'textDigest',
                   'durationFrames', 'energy'), 'Measured speech track')
    _need(energy['actorID'] == actor_id and energy['voiceAssetID'] == voice['assetID']
          and energy['sourceSHA256'] == timed['voice_sha256']
          and energy['textDigest'] == voice['textDigest']
          and type(energy['durationFrames']) is int and energy['durationFrames'] == frames,
          'Measured energy must bind this actor, complete current original voice and text')
    axis = timed.get('axis')
    segments = axis.get('segments') if isinstance(axis, dict) else None
    _need(isinstance(scene.get('captions'), list) and timed.get('captions') == scene['captions']
          and isinstance(segments, list) and 1 <= len(segments) <= 4096
          and all(isinstance(row, dict) and isinstance(row.get('text'), str) for row in segments)
          and isinstance(scene.get('narration'), str) and bool(scene['narration'].strip())
          and ''.join(row['text'] for row in segments) == scene['narration'],
          'Keep the complete current narration, captions and measured source axis')
    cues = energy['energy']
    _need(isinstance(cues, list) and 1 <= len(cues) <= 4096,
          'A finite measured complete RMS track is required')
    end = 0
    for cue in cues:
        _keys(cue, ('startFrame', 'endFrame', 'rms'), 'Measured RMS cue')
        _need(type(cue['startFrame']) is int and type(cue['endFrame']) is int
              and cue['startFrame'] == end < cue['endFrame'] <= frames
              and _number(cue['rms']) and 0 <= cue['rms'] <= 1,
              'RMS must continuously cover the original source; it is not phoneme timing')
        end = cue['endFrame']
    _need(end == frames, 'RMS must include the complete original tail')
    return deepcopy(energy)


def compose(scene, timed, profile, materials, energy):
    """Return a deeply independent native scene using only caller-supplied facts.

    This does not certify imported rights, actual acoustic measurement, alpha
    edges or visual acceptance. Those remain the owner's normal source/media
    checks. The byte receipt and current full-track identities are checked here.
    """
    _need(isinstance(scene, dict), 'An independent source scene is required')
    duration = scene.get('durationFrames')
    _need(type(duration) is int and 1 <= duration <= 54000
          and type(scene.get('sourceStartFrame')) is int and scene['sourceStartFrame'] == 0
          and _number(scene.get('speed')) and scene['speed'] == 1
          and type(scene.get('pauseFrames', 0)) is int and scene.get('pauseFrames', 0) == 0,
          'Compose only the complete unchanged source scene')
    _need(scene.get('kind') == '图文讲解' and isinstance(scene.get('storyCausality'), dict)
          and bool(scene['storyCausality']) and isinstance(scene.get('storyActions'), list)
          and bool(scene['storyActions']) and isinstance(scene.get('layers'), list)
          and bool(scene['layers'])
          and not any(scene.get(k) for k in ('gameWorld', 'cartoonRig', 'cartoonPerformance',
                                           'cartoonPresenter', 'classicArtwork')),
          'Finish the independent causal business stage before adding its narrator')
    _profile(profile, duration)
    _need(all(isinstance(row, dict) and row.get('id') != profile['id'] for row in scene['layers'])
          and all(isinstance(row, dict) and row.get('subjectID') != profile['id']
                  and row.get('targetID') != profile['id'] for row in scene['storyActions']),
          'The narrator must remain independent of every business subject and target')
    speech = _speech(scene, timed, energy, profile['id'])
    item = _material(profile, materials)
    projected = present(scene, 'presenter')
    result = deepcopy(scene)
    result['layers'], result['storyActions'] = projected['layers'], projected['storyActions']
    result.pop('paperPresentation', None)
    # SceneLayout bookkeeping is not part of the native Scene contract. A
    # previously projected source must not retain its stale prior projection.
    result.pop('layout_projection', None)
    result.pop('layout_profile', None)
    result.update(kind='原创卡通', body='', classicArtworkRequired=True,
        classicArtwork=dict(gameplay='横版跳跃',
            sprites=[dict(assetID=item['asset_id'], role=row['role'], **deepcopy(row['sourceRect']))
                     for row in profile['frames']],
            sources=[deepcopy(item['source'])], derivation='下载原件', originalAssetIDs=[], audioCues=[],
            transformation='复用已登记原件的显式图片解说员；RMS仅为音量嘴形'),
        cartoonPresenter=dict(version=1, id=profile['id'], masterRole=profile['master_role'],
            **{k:profile[k] for k in ('x', 'y', 'width', 'height', 'anchor')},
            clips=deepcopy(profile['clips']), cues=deepcopy(profile['cues']), speech=speech))
    result['evidenceIDs'] = list(dict.fromkeys(scene.get('evidenceIDs', []) + [item['evidence_id']]))
    return result
