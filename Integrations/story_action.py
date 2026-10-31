"""Author continuous object actions once for game, cartoon and pencil scenes.

This stage consumes the already designed story and declared assets. It does
not list caches, design narration around inventory, fabricate rule results,
generate voices or grant review. All times use the scene's local source axis.
The only mutation API is the shipped editor's dry-run plus one CAS edit.
"""
from __future__ import annotations

import copy
import hashlib
import json
import math
from typing import Callable


class StoryError(ValueError):
    pass


def need(condition, message):
    if not condition:
        raise StoryError(message)


def integer(value, low, high):
    return type(value) is int and low <= value <= high


def object_fields(value, required, optional=()):
    need(isinstance(value, dict) and set(required) <= value.keys()
         and not value.keys() - set(required) - set(optional), 'missing or unsupported story fields')


def actions_for_scene(actions, subjects, duration):
    need(isinstance(actions, list) and len(actions) <= 256, 'too many actions')
    ids, windows = set(), {}
    for action in actions:
        object_fields(action, ('id', 'kind', 'subjectID', 'startFrame', 'endFrame'),
                      ('targetID', 'from', 'to', 'quantity', 'text', 'waypoints'))
        need(isinstance(action['id'], str) and 1 <= len(action['id']) <= 128
             and action['id'] not in ids and action['subjectID'] in subjects,
             'duplicate action or undeclared object')
        ids.add(action['id'])
        kind = action['kind']
        need(kind in ('move', 'transfer', 'build', 'show', 'hide', 'speak'), 'unsupported continuous action')
        a, b = action['startFrame'], action['endFrame']
        need(integer(a, 0, duration - 1) and integer(b, a + 1, duration), 'action exceeds source interval')
        if 'targetID' in action:
            need(action['targetID'] in subjects and action['targetID'] != action['subjectID'],
                 'recipient must be another declared object')
        if kind == 'transfer':
            need('targetID' in action, 'a handover must identify its actual recipient')
        if kind in ('move', 'transfer'):
            for key in ('from', 'to'):
                point = action.get(key)
                object_fields(point, ('x', 'y'))
                need(all(type(n) in (int, float) and math.isfinite(n) and 0 <= n <= 1
                         for n in point.values()), 'action position is outside the full stage')
        else:
            need('from' not in action and 'to' not in action, 'non-movement has hidden positions')
        if 'waypoints' in action:
            points=action['waypoints']
            need(kind in ('move','transfer') and isinstance(points,list) and 1<=len(points)<=32,
                 'only complete bounded movement accepts route points')
            for point in points:
                object_fields(point,('x','y'))
                need(all(type(n) in (int,float) and math.isfinite(n) and 0<=n<=1 for n in point.values()),
                     'route point is outside the full stage')
            route=[action['from']]+points+[action['to']]
            need(all(math.hypot(a['x']-b['x'],a['y']-b['y'])>1e-7 for a,b in zip(route,route[1:])),
                 'route has duplicate adjacent points')
        if kind == 'speak':
            need(isinstance(action.get('text'), str) and 1 <= len(action['text']) <= 48
                 and 'quantity' not in action, 'bubble must have short real dialogue')
        else:
            need('text' not in action, 'only a real dialogue bubble may contain text')
        if 'quantity' in action:
            need(integer(action['quantity'], 1, 9999), 'invalid actual transfer quantity')
        group = 'position' if kind in ('move', 'transfer') else 'speech' if kind == 'speak' else 'visibility'
        windows.setdefault((action['subjectID'], group), []).append((a, b))
    for intervals in windows.values():
        ordered = sorted(intervals)
        need(all(left[1] <= right[0] for left, right in zip(ordered, ordered[1:])),
             'overlapping actions for the same object')


def compile_story(project: dict, spec: dict) -> dict:
    """Build normal replaceScene edits. The original project remains unchanged.

    scenes entries explicitly choose mode (game/cartoon/pencil), actions and
    their complete world/rig/layers. Switching to a native rig explicitly
    retires the old game-art presentation from this new revision only.
    """
    object_fields(spec, ('version', 'base_revision', 'fps', 'scenes'))
    need(type(spec['version']) is int and spec['version'] == 1, 'unsupported story version')
    revisions = project.get('revisions')
    need(isinstance(revisions, list) and revisions and isinstance(revisions[-1], dict), 'no current revision')
    revision = revisions[-1]
    need(spec['base_revision'] == revision['id'] and spec['fps'] == revision['fps'], 'stale story source axis')
    entries = spec['scenes']
    need(isinstance(entries, list) and 1 <= len(entries) <= 128, 'empty or unbounded story')
    scenes = {scene['id']: scene for scene in revision['scenes']}
    need(len(scenes) == len(revision['scenes']), 'duplicate scene identity')
    edits, seen = [], set()
    for entry in entries:
        object_fields(entry, ('scene_id', 'mode', 'actions'), ('world', 'rig', 'layers', 'artwork', 'duration_frames', 'causality'))
        identity = entry['scene_id']; mode = entry['mode']
        need(identity in scenes and identity not in seen and mode in ('game', 'cartoon', 'pencil'),
             'unknown, duplicate scene or presentation mode')
        seen.add(identity)
        scene = copy.deepcopy(scenes[identity])
        need(not scene.get('locked') and not any(layer.get('locked') for layer in scene.get('layers', [])),
             'unlock the authored scene and layers before replacing their story')
        duration = entry.get('duration_frames', scene['durationFrames'])
        need(integer(duration, 1, 54000) and duration >= (scene.get('voice') or {}).get('durationFrames', 0),
             'story must retain the entire original take')
        need(all(c['endFrame'] <= duration for c in scene.get('captions', [])), 'captions exceed new duration')
        scene['durationFrames'] = duration
        scene['storyActions'] = copy.deepcopy(entry['actions'])
        # Explicit Host-only evidence. No PluginVisualProps payload is added.
        # A presentation replacement clears stale prior causal bindings unless
        # this author supplies a complete new typed causal contract.
        scene.pop('storyCausality', None)
        if 'causality' in entry:
            object_fields(entry['causality'], ('version','poolSubjectID','actors','sources','bindings'))
            need(entry['causality']['version'] == 1, 'unsupported typed story causality')
            scene['storyCausality'] = copy.deepcopy(entry['causality'])
        # The author makes a complete explicit presentation replacement. All
        # original audio, content, rule recording and previous revisions stay.
        for old in ('gameWorld', 'cartoonRig', 'cartoonPerformance', 'paperPresentation'):
            scene.pop(old, None)
        # A game world uses scene-local frames for its drawings, but the saved
        # knowledge window still identifies the original recorded business facts.
        # Dropping it would revoke that recording and its existing complete take.
        if mode != 'game':
            scene.pop('simulationPresentation', None)
        if 'layers' in entry:
            need(isinstance(entry['layers'], list) and len(entry['layers']) <= 32, 'invalid stage layers')
            scene['layers'] = copy.deepcopy(entry['layers'])
        subjects = {v['id'] for v in scene.get('layers', [])}
        if mode == 'game':
            need('world' in entry and 'rig' not in entry, 'game needs its full world, without a cartoon rig')
            world = entry['world']
            object_fields(world, ('version', 'width', 'height', 'tiles', 'entities', 'updates'))
            need(world['version'] == 1 and integer(world['width'], 1, 64)
                 and integer(world['height'], 1, 64) and isinstance(world['tiles'], list)
                 and len(world['tiles']) == world['width'] * world['height'], 'map must contain every tile')
            need(isinstance(world['entities'], list) and 1 <= len(world['entities']) <= 64, 'invalid world entities')
            subjects.update(v['id'] for v in world['entities'])
            scene.update(kind='规则模拟', gameWorld=copy.deepcopy(world), classicArtworkRequired=True)
            if 'artwork' in entry:
                scene['classicArtwork'] = copy.deepcopy(entry['artwork'])
            need(scene.get('classicArtwork'), 'game world needs its actual source art')
        elif mode == 'cartoon':
            need('rig' in entry and 'world' not in entry and 'artwork' not in entry,
                 'independent cartoon requires its own rig, never game art')
            rig = entry['rig']
            object_fields(rig, ('version', 'actors', 'cues'), ('speech',))
            need(type(rig['version']) is int and rig['version'] in (1, 2) and isinstance(rig['actors'], list)
                 and 1 <= len(rig['actors']) <= (4 if rig['version'] == 1 else 8),
                 'invalid independent cartoon cast')
            subjects.update(v['id'] for v in rig['actors'])
            if scene.get('voice'):
                take, speech = scene['voice'], rig.get('speech')
                need(isinstance(speech, dict) and speech.get('voiceAssetID') == take['assetID']
                     and speech.get('textDigest') == take['textDigest']
                     and speech.get('durationFrames') == take['durationFrames'],
                     'mouth cues must be reanalyzed for the current complete voice')
            scene.update(kind='原创卡通', cartoonRig=copy.deepcopy(rig), classicArtworkRequired=False)
            scene.pop('classicArtwork', None)
            scene.pop('simulationRecording', None)
            scene['simulationRecordingConfirmed'] = False
        else:
            need(not {'world', 'rig', 'artwork'} & entry.keys(), 'pencil stage has hidden plugin payload')
            scene.update(kind='图文讲解', classicArtworkRequired=False)
            scene.pop('classicArtwork', None)
        actions_for_scene(entry['actions'], subjects, duration)
        if scene != scenes[identity]:
            if scene.get('voice'):
                scene['voice']['listened'] = False
            for caption in scene.get('captions', []):
                caption['confirmed'] = False
            edits.append({'replaceScene': {'_0': identity, '_1': scene}})
    return dict(workspace_id=project['workspaceID'], project_id=project['id'],
                base_revision=revision['id'], edits=edits,
                text='按真实故事连续编排完整地图、独立卡通与共用对象动作；声音、字幕和整片分别待审')


def apply_story(project: dict, spec: dict, invoke: Callable) -> dict:
    body = compile_story(project, spec)
    if not body['edits']:
        return dict(changed=False, revision=body['base_revision'], scenes=0)
    canonical = json.dumps(body, sort_keys=True, ensure_ascii=False, separators=(',', ':'), allow_nan=False).encode()
    body['request_id'] = 'story-actions-v1-' + hashlib.sha256(canonical).hexdigest()
    dry = invoke('edit apply', copy.deepcopy(body), True)
    need(dry.get('ok') and dry.get('state') == 'dry_run', 'normal editor refused the complete story plan')
    result = invoke('edit apply', copy.deepcopy(body), False)
    need(result.get('ok') and result.get('state') == 'needs_review'
         and result.get('project_id') == project['id'] and result.get('revision'),
         'normal editor did not return this project revision')
    return dict(changed=True, revision=result['revision'], scenes=len(body['edits']))
