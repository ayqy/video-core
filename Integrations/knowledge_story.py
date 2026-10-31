"""Compile explicit knowledge-story plans using normal native-Core recordings.

This is an author adapter, never a rule interpreter or a review grant. Models
and complete traces stay in Host provenance. A selected *applied* observation
supplies money/state facts; the evaluated StoryPlan supplies its purpose and
the author supplies stage objects, timing and routes. Native edit validation
recomputes every source independently before any presentation is persisted.

Public entry points use invoke(command, body, dry_run). The supported source
contract is v3 finite rule tables, at most three sources, and the existing
single-actor-plan intervention. Matrix/public-good models and payment/delivery
semantics are explicitly unsupported here, rather than silently converted.
"""
from __future__ import annotations

from copy import deepcopy
import hashlib
import json
import math
import re

from story_action import compile_story, apply_story, actions_for_scene
from story_planning import StoryPlan


class KnowledgeStoryError(ValueError):
    pass


PHASES = ('本轮开始', '同时选择', '实际出力与扣费', '清障判定', '通行或受阻', '收益结算')
_KINDS = {'performedAction', 'deposit', 'transfer', 'stateChange', 'outcome'}


def _need(condition, message):
    if not condition:
        raise KnowledgeStoryError(message)


def _object(value, required, optional=()):
    _need(isinstance(value, dict) and set(required) <= value.keys()
          and not value.keys() - set(required) - set(optional), 'missing or unsupported knowledge-story fields')


def _integer(value, low, high):
    return type(value) is int and low <= value <= high


def _identity(value):
    return isinstance(value, str) and re.fullmatch(r'[A-Za-z0-9._-]{1,80}', value) is not None


def _canonical(value):
    try:
        data = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()
    except (ValueError, TypeError) as error:
        raise KnowledgeStoryError('plan must contain finite JSON data') from error
    _need(len(data) <= 8 * 1024 * 1024, 'knowledge-story data exceeds the finite author budget')
    return data


def _digest(value):
    return hashlib.sha256(_canonical(value)).hexdigest()


def _unique(rows, field, label):
    _need(isinstance(rows, list) and all(isinstance(row, dict) and _identity(row.get(field)) for row in rows), label)
    result = {row[field]: row for row in rows}
    _need(len(result) == len(rows), 'duplicate ' + label)
    return result


def _last_tick(model):
    _need(isinstance(model, dict) and type(model.get('version')) is int and model['version'] == 3
          and isinstance(model.get('ruleTable'), dict) and model.get('payoffMatrix') is None,
          'only native v3 finite rule tables are supported; use the existing KnowledgeStoryboardPlan for v1/v2')
    _need(_integer(model.get('rounds'), 1, 64) and _integer(model.get('roundTicks'), 6, 30)
          and _integer(model.get('startTick'), 0, 1800), 'invalid finite model time axis')
    tick = model['startTick'] + (model['rounds'] - 1) * model['roundTicks'] + 5
    _need(tick <= 1800, 'model exceeds the native finite recording horizon')
    participants = _unique(model.get('participants'), 'id', 'model participant')
    _need(2 <= len(participants) <= 8, 'native model needs two to eight participants')
    return tick


def _plan(value):
    _object(value, ('version', 'story', 'target', 'sources', 'actors', 'pool_subject_id', 'anchors', 'beats'), ('balances',))
    _need(type(value['version']) is int and value['version'] == 1, 'unsupported knowledge-story version')
    _canonical(value)
    story = StoryPlan.from_dict(value['story'])
    _need(story.complete, 'evaluate the complete StoryPlan before compiling presentation')
    target = value['target']
    _object(target, ('workspace_id', 'project_id', 'base_revision', 'scene_id', 'fps', 'mode'))
    _need(all(isinstance(target[key], str) and target[key] for key in ('workspace_id', 'project_id', 'base_revision', 'scene_id'))
          and _integer(target['fps'], 1, 120) and target['mode'] in ('game', 'pencil'), 'invalid explicit target')
    sources = _unique(value['sources'], 'id', 'source identity')
    _need(1 <= len(sources) <= 3 and len({s.get('scene_id') for s in sources.values()}) == len(sources),
          'one to three distinct real source scenes required')
    _need(set(sources) <= set(story.to_dict()['brief']['source_ids']), 'sources must be declared before material design')
    previous, windows, participant_ids = {}, [], None
    for source in value['sources']:
        _object(source, ('id', 'scene_id', 'model', 'seed', 'start_frame', 'end_frame'), ('parent_id', 'intervention'))
        _need(isinstance(source['scene_id'], str) and source['scene_id'] and _integer(source['seed'], 0, 2**64 - 1),
              'real scene identity and native UInt64 seed required')
        _last_tick(source['model'])
        ids = {row['id'] for row in source['model']['participants']}
        _need(participant_ids is None or participant_ids == ids, 'all sources must preserve participant identities')
        participant_ids = ids
        a, b = source['start_frame'], source['end_frame']
        _need(_integer(a, 0, 53999) and _integer(b, a + 1, 54000)
              and all(b <= x or a >= y for x, y in windows), 'source display windows overlap or exceed the finite stage')
        windows.append((a, b))
        if 'parent_id' in source:
            parent = previous.get(source['parent_id'])
            intervention = source.get('intervention')
            _object(intervention, ('actorID', 'plan'))
            _need(isinstance(intervention['plan'], dict) and parent is not None and parent['seed'] == source['seed'] and parent['end_frame'] <= a
                  and intervention['actorID'] == intervention['plan'].get('actorID'), 'invalid earlier same-seed parent intervention')
            expected = deepcopy(parent['model'])
            plans = expected['ruleTable'].get('plans', [])
            indices = [i for i, plan in enumerate(plans) if plan.get('actorID') == intervention['actorID']]
            _need(len(indices) == 1 and plans[indices[0]] != intervention['plan'], 'intervention must change one real actor plan')
            plans[indices[0]] = deepcopy(intervention['plan'])
            _need(expected == source['model'], 'this source contract only permits one actor-plan change; rule/matrix conversion is unsupported')
        else:
            _need(not previous and 'intervention' not in source, 'exactly one root source is allowed')
        previous[source['id']] = source
    actors = value['actors']
    _need(isinstance(actors, list) and 1 <= len(actors) <= 64, 'explicit bounded actor ownership required')
    ownership = {}
    for actor in actors:
        _object(actor, ('actor_id', 'subject_id'))
        _need(actor['actor_id'] in participant_ids and _identity(actor['subject_id'])
              and actor['subject_id'] not in ownership, 'each stage subject has exactly one actual actor owner')
        ownership[actor['subject_id']] = actor['actor_id']
    _need(_identity(value['pool_subject_id']) and value['pool_subject_id'] not in ownership,
          'the pool is a separate, unowned actual stage object')
    anchors = value['anchors']
    _need(isinstance(anchors, dict) and len(anchors) <= 256, 'invalid anchor budget')
    for name, point in anchors.items():
        _object(point, ('x', 'y'))
        _need(_identity(name) and all(type(n) in (int, float) and math.isfinite(n) and 0 <= n <= 1 for n in point.values()),
              'anchors must be finite normalized stage points')
    beats = _unique(value['beats'], 'id', 'presentation beat')
    _need(1 <= len(beats) <= 256, 'bounded nonempty presentation required')
    return story, sources, ownership


def _project(project):
    _need(isinstance(project, dict) and isinstance(project.get('revisions'), list) and project['revisions'], 'current project required')
    revision = project['revisions'][-1]
    _unique(revision.get('scenes'), 'id', 'scene')
    return revision


def _result(response):
    _need(isinstance(response, dict) and response.get('ok') is True, 'normal native command failed')
    return response.get('result')


def _read_project(original, invoke):
    rows = _result(invoke('projects list', {'workspace_id': original['workspaceID']}, False))
    _need(isinstance(rows, list), 'normal projects list did not return projects')
    rows = [row for row in rows if isinstance(row, dict) and row.get('id') == original['id']]
    _need(len(rows) == 1 and rows[0].get('workspaceID') == original['workspaceID'], 'normal query lost the selected project')
    return rows[0]


def _trace(source, scene, fps):
    """Check persisted identity/completeness, never evaluate rules or outcomes."""
    model, seed = source['model'], source['seed']
    _need(scene.get('kind') == '规则模拟' and scene.get('simulation', {}).get('knowledge') == model
          and scene['simulation'].get('seed') == seed and not scene.get('locked'), 'source scene differs from its frozen model/seed or is locked')
    last = _last_tick(model)
    _need(scene.get('sourceStartFrame') == 0 and scene.get('speed') == 1 and scene.get('pauseFrames') == 0
          and scene.get('simulationPresentation') is None and scene.get('durationFrames') == (last + 1) * fps,
          'source scene must contain the full unretimed native recording axis')
    recording = scene.get('simulationRecording')
    _need(isinstance(recording, dict) and recording.get('recordedFPS') == fps
          and recording.get('recordedDurationFrames') == scene['durationFrames'] and recording.get('recordedSpeed') == 1
          and recording.get('recordedPauseFrames') == 0 and recording.get('recordedPresentation') is None,
          'source recording axis is missing or stale')
    trace = recording.get('knowledgeTrace')
    _need(isinstance(trace, dict) and trace.get('version') == 3 and trace.get('seed') == seed
          and trace.get('throughTick') == last and isinstance(trace.get('inputDigest'), str)
          and re.fullmatch('[0-9a-f]{64}', trace['inputDigest']) is not None, 'complete native trace identity required')
    events = trace.get('events')
    _need(isinstance(events, list) and len(events) == model['rounds'] * 6
          and isinstance(trace.get('rounds'), list) and len(trace['rounds']) == model['rounds'], 'partial trace cannot authorize a complete story')
    ids = {row['id'] for row in model['participants']}
    for index, event in enumerate(events):
        _need(isinstance(event, dict) and event.get('round') == index // 6 + 1 and event.get('phase') == PHASES[index % 6]
              and event.get('tick') == model['startTick'] + index // 6 * model['roundTicks'] + index % 6,
              'native semantic events are incomplete or reordered')
        actors = _unique(event.get('actors'), 'id', 'observed actor')
        _need(set(actors) == ids and all(_integer(row.get('resources'), 0, 1_000_000) for row in actors.values()), 'native participant observations are incomplete')
    expected = [{'id': row['id'], 'resources': row['resources']} for row in events[-1]['actors']]
    _need(trace.get('finalResources') == expected, 'final resources must be the recorded final observation')
    return deepcopy(trace)


def record_sources(source_project, plan, invoke):
    """Record/verify explicit existing source scenes through normal dry-run/CAS.

    Reusing a present recording requires native confirmSimulationRecording only
    in dry-run; no actual confirmation is ever written. Absent recordings use
    one actual recordSimulation edit. A corrupt present recording is rejected,
    not silently replaced. All comparisons are native recomputations.
    """
    _, _, _ = _plan(plan)
    revision = _project(source_project)
    _need(callable(invoke) and source_project['id'] != plan['target']['project_id']
          and source_project['workspaceID'] == plan['target']['workspace_id']
          and revision.get('fps') == plan['target']['fps'], 'use a separate same-workspace source project with the explicit frame rate')
    scenes = {row['id']: row for row in revision['scenes']}
    edits = []
    for source in plan['sources']:
        _need(source['scene_id'] in scenes, 'explicit source scene is absent')
        scene = scenes[source['scene_id']]
        # Identity and axis checks are shared with persisted extraction. This
        # skeleton supplies no rules, outcomes or trace to the normal Host.
        _need(scene.get('simulation', {}).get('knowledge') == source['model'] and scene['simulation'].get('seed') == source['seed']
              and scene.get('kind') == '规则模拟' and not scene.get('locked'), 'source model/seed/lock differs from frozen plan')
        _need(scene.get('sourceStartFrame') == 0 and scene.get('speed') == 1 and scene.get('pauseFrames') == 0
              and scene.get('simulationPresentation') is None and scene.get('durationFrames') == (_last_tick(source['model']) + 1) * revision['fps'],
              'full unretimed source axis required before recording')
        edits.append({'confirmSimulationRecording' if scene.get('simulationRecording') is not None else 'recordSimulation': {'_0': source['scene_id']}})
    common = dict(workspace_id=source_project['workspaceID'], project_id=source_project['id'], base_revision=revision['id'])
    dry_body = dict(common, edits=edits, text='核验明确的完整知识来源；不写入确认')
    dry_body['request_id'] = 'knowledge-source-check-' + _digest(dry_body)
    dry = invoke('edit apply', deepcopy(dry_body), True)
    _need(dry.get('ok') is True and dry.get('state') == 'dry_run', 'native source recording/verification dry-run failed')
    actual_edits = [edit for edit in edits if 'recordSimulation' in edit]
    current = source_project
    if actual_edits:
        body = dict(common, edits=actual_edits, text='正常Core记录完整知识实迹；声音字幕与整片仍待审')
        body['request_id'] = 'knowledge-source-record-' + _digest(body)
        response = invoke('edit apply', deepcopy(body), False)
        _need(response.get('ok') is True and response.get('state') == 'needs_review'
              and response.get('project_id') == source_project['id'] and isinstance(response.get('revision'), str),
              'normal source recording did not persist the selected project')
        current = _read_project(source_project, invoke)
        _need(current['revisions'][:-1] == source_project['revisions'] and current['revisions'][-1]['id'] == response['revision'],
              'source history or returned revision was not preserved')
    else:
        current = _read_project(source_project, invoke)
        _need(current == source_project, 'source changed during native verification')
    revision = _project(current)
    scenes = {row['id']: row for row in revision['scenes']}
    typed = []
    by_source = {row['id']: row for row in plan['sources']}
    for source in plan['sources']:
        trace = _trace(source, scenes[source['scene_id']], revision['fps'])
        row = dict(id=source['id'], model=deepcopy(source['model']), seed=source['seed'], trace=trace,
                   startFrame=source['start_frame'], endFrame=source['end_frame'])
        if 'parent_id' in source:
            row.update(parentID=source['parent_id'], intervention=deepcopy(source['intervention']))
            parent = by_source[source['parent_id']]
            response = invoke('knowledge compare', dict(workspace_id=current['workspaceID'], project_id=current['id'],
                base_revision=revision['id'], scene_id=parent['scene_id'], comparison_scene_id=source['scene_id']), False)
            comparison = _result(response)
            # Codable exposes actual traces, not the computed convenience
            # property hasBehaviorDifference. Observe only applied behavior.
            _need(isinstance(comparison, dict) and isinstance(comparison.get('comparison'), dict), 'native comparison response is absent')
            observed = comparison['comparison']
            parent_trace = next(item['trace'] for item in typed if item['id'] == source['parent_id'])
            _need(observed.get('baseline') == parent_trace and observed.get('alternative') == trace,
                  'comparison is not bound to the actual recorded source pair')
            _need(_behavior_changed(parent_trace, trace), 'labels, clock or inactive rules alone cannot authorize a changed-behavior story')
        typed.append(row)
    return dict(version=1, project_id=current['id'], revision=revision['id'], sources=typed)


def _behavior_changed(left, right):
    """Read semantic observations; never evaluate a model or infer a cause."""
    _need(len(left['events']) == len(right['events']), 'counterfactual event counts differ')
    for a, b in zip(left['events'], right['events']):
        _need((a['round'], a['phase']) == (b['round'], b['phase']), 'counterfactual semantic events differ')
        def actors(event):
            # Requested choices, rejection labels and diagnostic identifiers
            # alone are not executed behavior. In particular, two unfunded
            # requests must not manufacture an observable intervention result.
            keys = ('id', 'resources', 'ruleStateID', 'executedActionID', 'contribution', 'cost', 'benefit', 'passed')
            return sorted((_canonical({key: row.get(key) for key in keys}) for row in event['actors']))
        if actors(a) != actors(b) or any(a.get(field) != b.get(field) for field in ('totalContribution', 'obstacleCleared', 'matrixPool')):
            return True
        for field in ('poolBefore', 'poolAfter', 'externalFunding', 'deposits'):
            if (a.get('ruleExecution') or {}).get(field, 0) != (b.get('ruleExecution') or {}).get(field, 0):
                return True
        for field, keys in [('transfers', ('sourceActorID', 'destinationActorID', 'amount')),
                            ('stateChanges', ('actorID', 'beforeStateID', 'afterStateID'))]:
            def facts(event):
                return sorted((_canonical({key: row.get(key) for key in keys}) for row in (event.get('ruleExecution') or {}).get(field, [])
                               if (field == 'stateChanges' and row.get('beforeStateID') != row.get('afterStateID'))
                               or (field == 'transfers' and _integer(row.get('amount'), 1, 1_000_000))))
            if facts(a) != facts(b):
                return True
    return False


def _event(source, selector):
    _object(selector, ('round', 'phase'))
    _need(_integer(selector['round'], 1, source['model']['rounds']) and selector['phase'] in PHASES, 'invalid semantic event selector')
    matches = [event for event in source['trace']['events'] if event.get('round') == selector['round'] and event.get('phase') == selector['phase']]
    _need(len(matches) == 1, 'event selector must match exactly one actual event')
    return matches[0]


def _resolve(effect, event):
    _need(isinstance(effect, dict) and effect.get('kind') in _KINDS,
          'unsupported effect; payment/delivery and v1/v2 conversion are not implemented by this adapter')
    kind = effect['kind']
    if kind == 'performedAction':
        _object(effect, ('kind', 'actor_id', 'action_key'))
        rows = [a for a in event['actors'] if a['id'] == effect['actor_id'] and a.get('executedActionID') == effect['action_key']]
        _need(event['phase'] == PHASES[2] and len(rows) == 1, 'only an actually executed action may be performed')
        return dict(kind=kind, actorID=effect['actor_id'], actionKey=effect['action_key'])
    if kind == 'deposit':
        _object(effect, ('kind', 'from_actor_id'))
        rows = [a for a in event['actors'] if a['id'] == effect['from_actor_id'] and _integer(a.get('cost'), 1, 9999)]
        _need(event['phase'] == PHASES[2] and len(rows) == 1, 'deposit needs one actual positive native debit')
        return dict(kind=kind, fromActorID=effect['from_actor_id'], amount=rows[0]['cost'])
    if kind == 'transfer':
        _object(effect, ('kind', 'rule_id', 'from_actor_id', 'to_actor_id'))
        rows = [row for row in (event.get('ruleExecution') or {}).get('transfers', [])
                if row.get('ruleID') == effect['rule_id'] and row.get('sourceActorID') == effect['from_actor_id']
                and row.get('destinationActorID') == effect['to_actor_id']]
        _need(event['phase'] == PHASES[5] and len(rows) == 1 and _integer(rows[0].get('amount'), 1, 9999)
              and effect['from_actor_id'] != effect['to_actor_id'], 'transfer needs a unique applied positive native route')
        binding = dict(kind=kind, ruleID=effect['rule_id'], amount=rows[0]['amount'])
        if effect['from_actor_id'] is not None:
            binding['fromActorID'] = effect['from_actor_id']
        if effect['to_actor_id'] is not None:
            binding['toActorID'] = effect['to_actor_id']
        return binding
    if kind == 'stateChange':
        _object(effect, ('kind', 'actor_id', 'rule_id', 'from_state_id', 'to_state_id'))
        rows = [row for row in (event.get('ruleExecution') or {}).get('stateChanges', [])
                if row.get('actorID') == effect['actor_id'] and row.get('ruleID') == effect['rule_id']
                and row.get('beforeStateID') == effect['from_state_id'] and row.get('afterStateID') == effect['to_state_id']]
        _need(event['phase'] == PHASES[5] and len(rows) == 1 and effect['from_state_id'] != effect['to_state_id'],
              'state presentation needs a unique applied native transition')
        return dict(kind=kind, actorID=effect['actor_id'], ruleID=effect['rule_id'], fromStateID=rows[0]['beforeStateID'], toStateID=rows[0]['afterStateID'])
    _object(effect, ('kind', 'outcome'))
    _need(type(effect['outcome']) is bool and event['phase'] in PHASES[3:]
          and effect['outcome'] == event.get('obstacleCleared'), 'outcome must equal an already published native result')
    return dict(kind=kind, outcome=event['obstacleCleared'])


def compile_presentation(target_project, plan, recorded):
    """Compile selected native observations into existing scene objects.

    Timing is editorial: each beat must belong to its evaluated detail and shot,
    and its selected native event must be cited by that detail. No event decides
    a route, character motive, dialogue, asset, or conclusion on the author's behalf.
    """
    story, declarations, ownership = _plan(plan)
    revision = _project(target_project)
    target = plan['target']
    _need(target_project.get('id') == target['project_id'] and target_project.get('workspaceID') == target['workspace_id']
          and revision.get('id') == target['base_revision'] and revision.get('fps') == target['fps'], 'target identity, revision or frame rate is stale')
    _object(recorded, ('version', 'project_id', 'revision', 'sources'))
    _need(type(recorded['version']) is int and recorded['version'] == 1 and _identity(recorded['project_id'])
          and _identity(recorded['revision']) and recorded['project_id'] != target_project['id'], 'separate explicitly identified recorded sources required')
    sources = _unique(recorded['sources'], 'id', 'recorded source')
    _need(set(sources) == set(declarations), 'recorded source identities differ from the plan')
    for key, source in sources.items():
        declared = declarations[key]
        _object(source, ('id', 'model', 'seed', 'trace', 'startFrame', 'endFrame'), ('parentID', 'intervention'))
        _need(all(source[a] == declared[b] for a, b in [('model', 'model'), ('seed', 'seed'), ('startFrame', 'start_frame'), ('endFrame', 'end_frame')])
              and source.get('parentID') == declared.get('parent_id') and source.get('intervention') == declared.get('intervention'),
              'source model/seed/window/intervention changed since the explicit plan')
        # Same shape checks as actual extraction; this does not grant a native
        # proof. apply_presentation always obtains Core's independent dry-run.
        probe = dict(kind='规则模拟', simulation=dict(knowledge=source['model'], seed=source['seed']), sourceStartFrame=0,
                     speed=1, pauseFrames=0, durationFrames=(_last_tick(source['model']) + 1) * target['fps'],
                     simulationRecording=dict(recordedFPS=target['fps'], recordedSpeed=1, recordedPauseFrames=0,
                        recordedDurationFrames=(_last_tick(source['model']) + 1) * target['fps'], knowledgeTrace=source['trace']))
        _trace(declared, probe, target['fps'])
    scenes = {row['id']: row for row in revision['scenes']}
    _need(target['scene_id'] in scenes, 'target scene is absent')
    scene = scenes[target['scene_id']]
    shots = {row['id']: row for row in story.stage('shots')['shots']}
    details = {row['id']: row for row in story.stage('details')['actions']}
    duration = max(row['start_frame'] + row['duration_frames'] for row in shots.values())
    _need(scene.get('durationFrames') == duration and all(s['endFrame'] <= duration for s in sources.values()), 'story/scene/source display axes differ')
    _need(scene.get('narration') == ''.join(row['narration'] for row in story.stage('shots')['shots']),
          'target narration must equal the complete evaluated story narration; do not reuse an unrelated original take')
    _need(scene.get('sourceStartFrame') == 0 and scene.get('speed') == 1 and scene.get('pauseFrames') == 0,
          'source-local presentation requires an explicit unretimed target scene')
    _need(scene.get('cartoonPresenter') is None and scene.get('cartoonRig') is None,
          'this adapter targets existing game or pencil objects; presenter reauthoring is a separate capability')
    subjects = {row['id'] for row in scene.get('layers', [])}
    world = deepcopy(scene.get('gameWorld'))
    if target['mode'] == 'game':
        _need(isinstance(world, dict) and isinstance(scene.get('classicArtwork'), dict), 'actual existing game world and source artwork required')
        entities = _unique(world.get('entities'), 'id', 'world entity')
        _need(not subjects.intersection(entities), 'stage subject identity is ambiguous across world and layers')
        subjects.update(entities)
    else:
        _need(world is None and scene.get('cartoonPerformance') is None, 'pencil mode cannot silently retire an advanced performance')
        entities = {}
    pool = plan['pool_subject_id']
    _need(pool in subjects and set(ownership) <= subjects, 'pool and actor subjects must exist in the target stage')
    def owns(actor, subject):
        return subject == pool if actor is None else ownership.get(subject) == actor
    beats, actions, bindings, observations = {}, [], [], []
    used_money = set()
    for beat in plan['beats']:
        _object(beat, ('id', 'detail_id', 'shot_id', 'source_id', 'event', 'effect', 'subject_id', 'start_frame', 'end_frame', 'requires', 'visual'))
        _need(beat['detail_id'] in details and beat['shot_id'] in shots and beat['source_id'] in sources, 'beat must reference an evaluated detail, shot and actual source')
        detail, shot, source = details[beat['detail_id']], shots[beat['shot_id']], sources[beat['source_id']]
        event = _event(source, beat['event'])
        _need(beat['detail_id'] in shot['action_ids'] and detail['beat_id'] == shot['beat_id'], 'shot does not contain the selected story detail')
        _need(isinstance(beat['effect'], dict), 'typed effect selector required')
        rule_id = beat['effect'].get('rule_id', beat['effect'].get('action_key', beat['effect'].get('kind')))
        _need(dict(source_id=beat['source_id'], tick=event['tick'], rule_id=rule_id) in detail['event_refs'], 'detail must cite the actual selected source event and rule/action')
        a, b = beat['start_frame'], beat['end_frame']
        _need(_integer(a, 0, duration - 1) and _integer(b, a + 1, duration)
              and source['startFrame'] <= a < b <= source['endFrame']
              and shot['start_frame'] <= a < b <= shot['start_frame'] + shot['duration_frames'], 'presentation exceeds its source or story shot window')
        _need(isinstance(beat['requires'], list) and len(beat['requires']) <= 32 and len(set(beat['requires'])) == len(beat['requires']), 'invalid action dependency budget')
        for required in beat['requires']:
            previous = beats.get(required)
            _need(previous is not None and previous['source_id'] == beat['source_id'] and previous['end_frame'] <= a
                  and _event(source, previous['event'])['tick'] <= event['tick'], 'dependency is future, missing or from another branch')
            _need(previous['detail_id'] == beat['detail_id'] or previous['detail_id'] in detail['depends_on'], 'presentation dependency is absent from the evaluated story detail')
        binding = _resolve(beat['effect'], event)
        subject, visual, kind = beat['subject_id'], beat['visual'], binding['kind']
        _need(subject in subjects, 'action subject is absent')
        _object(visual, ('kind',), ('from_anchor', 'to_anchor', 'via_anchors', 'target_subject_id'))
        actor = binding.get('actorID', binding.get('fromActorID'))
        if kind in ('performedAction', 'stateChange'):
            _need(owns(actor, subject), 'action/state subject is not owned by the actual actor')
        if kind == 'performedAction':
            _need(detail['actor_id'] == actor and visual['kind'] in ('move', 'show', 'hide', 'build', 'speak'), 'performed action differs from its acting story character')
        elif kind in ('deposit', 'transfer'):
            target_subject = visual.get('target_subject_id')
            _need(visual['kind'] == 'transfer' and owns(actor, subject) and target_subject in subjects
                  and target_subject != subject and owns(binding.get('toActorID'), target_subject), 'money must leave the actual payer/pool and reach the actual receiver/pool')
            _need(actor is None or detail['actor_id'] == actor, 'story payer differs from the applied transfer')
            key = (beat['source_id'], event['round'], event['phase'], kind, binding.get('ruleID'), actor, binding.get('toActorID'))
            _need(key not in used_money, 'one actual debit/transfer cannot be claimed twice')
            used_money.add(key)
        elif kind == 'stateChange':
            _need(detail['actor_id'] == actor and visual['kind'] in ('show', 'hide', 'build', 'speak'),
                  'state changes belong to their actual story actor and only reveal/build/hide that owned subject')
        else:
            _need(visual['kind'] in ('show', 'hide'), 'outcome presentation must explicitly reveal or hide an actual object')
        action = dict(id=beat['id'], kind=visual['kind'], subjectID=subject, startFrame=a, endFrame=b)
        if visual['kind'] in ('move', 'transfer'):
            _need(visual.get('from_anchor') in plan['anchors'] and visual.get('to_anchor') in plan['anchors'], 'movement needs two declared anchors')
            action['from'] = deepcopy(plan['anchors'][visual['from_anchor']])
            action['to'] = deepcopy(plan['anchors'][visual['to_anchor']])
            if 'via_anchors' in visual:
                names = visual['via_anchors']
                _need(isinstance(names, list) and 1 <= len(names) <= 32 and all(name in plan['anchors'] for name in names), 'invalid declared route anchors')
                action['waypoints'] = [deepcopy(plan['anchors'][name]) for name in names]
        else:
            _need(not {'from_anchor', 'to_anchor', 'via_anchors', 'target_subject_id'}.intersection(visual), 'non-movement cannot hide a route or recipient')
        if kind in ('deposit', 'transfer'):
            action.update(targetID=visual['target_subject_id'], quantity=binding['amount'])
        else:
            _need('target_subject_id' not in visual, 'non-transfer has a hidden recipient')
        if visual['kind'] == 'speak':
            table = source['model']['ruleTable']
            field, identity = ('actions', binding['actionKey']) if kind == 'performedAction' else ('states', binding['toStateID'])
            labels = [row.get('label') for row in table[field] if row.get('id') == identity]
            _need(len(labels) == 1 and isinstance(labels[0], str) and 1 <= len(labels[0]) <= 48,
                  'spoken labels must be unique bounded text from the actual executed action or resulting native state')
            action['text'] = labels[0]
        binding.update(actionID=beat['id'], sourceID=beat['source_id'], eventID=str(event['round']) + '-' + event['phase'], requires=deepcopy(beat['requires']))
        actions.append(action); bindings.append(binding); beats[beat['id']] = beat
        observations.append(dict(beat_id=beat['id'], detail_id=beat['detail_id'], shot_id=beat['shot_id'], source_id=beat['source_id'],
                                 tick=event['tick'], event_id=binding['eventID'], effect=deepcopy(binding)))
    _need({row['sourceID'] for row in bindings} == set(sources), 'each recorded source needs an actual selected presentation')
    _need({beat['detail_id'] for beat in beats.values()} == set(details),
          'every evaluated story detail needs a compiled beat; unsupported noncausal/static details must be authored outside this causal plan')
    expected_uses = {(shot_id, detail_id) for shot_id, shot in shots.items() for detail_id in shot['action_ids']}
    _need({(beat['shot_id'], beat['detail_id']) for beat in beats.values()} == expected_uses,
          'every shot action must have its own compiled beat in that shot; the adapter cannot silently drop a planned process')
    detail_windows = {}
    for beat in beats.values():
        a, b = detail_windows.get(beat['detail_id'], (duration, 0))
        detail_windows[beat['detail_id']] = (min(a, beat['start_frame']), max(b, beat['end_frame']))
    for detail_id, detail in details.items():
        for dependency in detail['depends_on']:
            _need(detail_windows[dependency][1] <= detail_windows[detail_id][0],
                  'all evaluated detail prerequisites must finish before this process; omitting beat.requires cannot discard the story dependency')
    movements = {}
    for action in actions:
        if action['kind'] in ('move', 'transfer'):
            movements.setdefault(action['subjectID'], []).append(action)
    for rows in movements.values():
        ordered = sorted(rows, key=lambda action: (action['startFrame'], action['id']))
        for previous, current in zip(ordered, ordered[1:]):
            _need(beats[previous['id']]['source_id'] == beats[current['id']]['source_id'],
                  'cross-source movement of the same subject needs an explicit branch reset; this adapter requires distinct branch subjects instead of silently teleporting')
            _need(math.hypot(previous['to']['x'] - current['from']['x'], previous['to']['y'] - current['from']['y']) <= 1e-7,
                  'consecutive movements of one source subject must continue from the previous actual endpoint')
    actions_for_scene(actions, subjects, duration)
    balances = plan.get('balances', [])
    _need(isinstance(balances, list) and len(balances) <= 2048 and (not balances or target['mode'] == 'game'), 'balance observations need existing game entities')
    updates = {}
    moments = {key: [] for key in sources}
    for beat in beats.values():
        moments[beat['source_id']].append((beat['start_frame'], beat['end_frame'], _event(sources[beat['source_id']], beat['event'])['tick']))
    def merge(update):
        _need(isinstance(update, dict) and 'entityID' in update and 'frame' in update, 'invalid existing world update')
        key = (update['entityID'], update['frame'])
        current = updates.setdefault(key, dict(entityID=key[0], frame=key[1]))
        for field, value in update.items():
            _need(field not in current or current[field] == value, 'same-frame world updates conflict')
            current[field] = deepcopy(value)
    if world is not None:
        for update in world.get('updates', []):
            merge(update)
    for balance in balances:
        _object(balance, ('source_id', 'event', 'actor_id', 'entity_id', 'frame'))
        _need(balance['source_id'] in sources and balance['entity_id'] in entities and owns(balance['actor_id'], balance['entity_id']), 'balance must identify an owned actual game entity')
        source = sources[balance['source_id']]
        event = _event(source, balance['event'])
        _need(_integer(balance['frame'], source['startFrame'], source['endFrame'] - 1), 'balance observation exceeds its branch')
        _need(all(row['end_frame'] <= balance['frame'] for row in beats.values()
                  if row['source_id'] == balance['source_id'] and _event(source, row['event'])['tick'] <= event['tick']),
              'a balance cannot precede the selected event process or its earlier visible prerequisites')
        actors = [actor for actor in event['actors'] if actor['id'] == balance['actor_id']]
        _need(len(actors) == 1 and _integer(actors[0]['resources'], 0, 999999), 'native balance exceeds the visible entity contract')
        merge(dict(entityID=balance['entity_id'], frame=balance['frame'], value=actors[0]['resources']))
        moments[balance['source_id']].append((balance['frame'], balance['frame'], event['tick']))
    for rows in moments.values():
        last_tick, group_end, last_start = -1, -1, -1
        for start, end, tick in sorted(rows):
            _need(last_tick <= tick and (last_tick == tick or group_end <= start)
                  and (last_start != start or last_tick == tick),
                  'source events cannot run backwards, overlap different ticks, or place old balances after later outcomes; author a separate source window for a flashback')
            group_end = max(group_end, end) if tick == last_tick else end
            last_tick, last_start = tick, start
    causality = dict(version=1, poolSubjectID=pool, actors=[dict(actorID=a['actor_id'], subjectID=a['subject_id']) for a in plan['actors']],
                     sources=[deepcopy(sources[row['id']]) for row in plan['sources']], bindings=bindings)
    entry = dict(scene_id=target['scene_id'], mode=target['mode'], actions=actions, causality=causality)
    if world is not None:
        world['updates'] = [updates[key] for key in sorted(updates, key=lambda key: (key[1], key[0]))]
        _need(len(world['updates']) <= 2048, 'compiled world update budget exceeded')
        entry['world'] = world
    spec = dict(version=1, base_revision=revision['id'], fps=revision['fps'], scenes=[entry])
    body = compile_story(target_project, spec)
    return dict(edit_body=body, story_spec=spec, plan_digest=_digest(plan), observations=observations)


def apply_presentation(target_project, plan, recorded, invoke):
    """Read frozen real source identity, then normal Core dry-run/one CAS edit.

    Pure compilation does not prove that a declared source project exists.
    This normal entry therefore reads its exact retained revision and recordings
    before allowing the native independently verified presentation edit.
    """
    compiled = compile_presentation(target_project, plan, recorded)
    projects = _result(invoke('projects list', {'workspace_id': target_project['workspaceID']}, False))
    _need(isinstance(projects, list), 'normal source query did not return projects')
    matches = [row for row in projects if isinstance(row, dict) and row.get('id') == recorded['project_id']
               and row.get('workspaceID') == target_project['workspaceID']]
    _need(len(matches) == 1, 'recorded source project is not present in this workspace')
    revisions = [row for row in matches[0].get('revisions', []) if row.get('id') == recorded['revision']]
    _need(len(revisions) == 1 and revisions[0].get('fps') == plan['target']['fps'], 'frozen source revision is missing or has another frame rate')
    source_scenes = _unique(revisions[0].get('scenes'), 'id', 'persisted source scene')
    sources = {row['id']: row for row in recorded['sources']}
    for declaration in plan['sources']:
        _need(declaration['scene_id'] in source_scenes, 'declared scene is absent from the persisted source revision')
        actual = _trace(declaration, source_scenes[declaration['scene_id']], revisions[0]['fps'])
        _need(actual == sources[declaration['id']]['trace'], 'caller-supplied trace differs from the persisted normal recording')
    result = apply_story(target_project, compiled['story_spec'], invoke)
    return dict(result, plan_digest=compiled['plan_digest'])
