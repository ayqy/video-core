"""Content-first, dependency-checked story planning before material resolution.

A caller supplies the author/model for each finite stage. There is no default
model, network, cache inventory or implicit approval. Native Core recordings
remain the authority for financial/state consequences; event references here
are author requirements which the normal production editor must verify.
"""
from __future__ import annotations

from copy import deepcopy
import hashlib
import json
from pathlib import Path
import plistlib

STAGES = ('cast', 'outline', 'details', 'shots')
VERBS = {'walk', 'take', 'hand_over', 'receive', 'build', 'load', 'deliver',
         'unload', 'sell', 'react', 'unlock', 'pay', 'refund'}
SOURCE_ACTIONS = {'pay', 'refund', 'build', 'load', 'deliver', 'sell'}
PURPOSES = {'setup', 'choice', 'process', 'consequence', 'counterfactual', 'conclusion'}


class StoryPlanningError(ValueError):
    def __init__(self, layer, message):
        self.layer = layer
        super().__init__(layer + ': ' + message)


def _need(condition, layer, message):
    if not condition:
        raise StoryPlanningError(layer, message)


def _object(value, required, optional, layer):
    _need(isinstance(value, dict) and set(required) <= value.keys()
          and not value.keys() - set(required) - set(optional), layer,
          'missing or unsupported fields')
    return value


def _text(value, layer, limit=4000):
    _need(isinstance(value, str) and bool(value.strip()) and len(value.encode()) <= limit,
          layer, 'a bounded, explicit description is required')
    return value


def _list(value, layer, low=1, high=96):
    _need(isinstance(value, list) and low <= len(value) <= high, layer,
          'collection is missing or outside its finite budget')
    return value


def _integer(value, layer, low=0, high=54000):
    _need(type(value) is int and low <= value <= high, layer, 'invalid integer interval')
    return value


def _ids(rows, layer):
    _need(all(isinstance(row, dict) and 'id' in row for row in rows), layer, 'an identified object is required')
    values = [_text(row['id'], layer, 200) for row in rows]
    _need(len(set(values)) == len(values), layer, 'duplicate identity')
    return set(values)


def _references(value, known, layer, low=1, high=96):
    _list(value, layer, low, high)
    _need(all(isinstance(item, str) and item in known for item in value)
          and len(set(value)) == len(value), layer, 'unknown or duplicate reference')


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True,
                      separators=(',', ':'), allow_nan=False).encode()


def digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def _brief(value):
    _object(value, {'version', 'title', 'knowledge_goal', 'viewer_question',
                    'context', 'boundary', 'source_ids'}, set(), 'brief')
    _need(type(value['version']) is int and value['version'] == 1, 'brief', 'unsupported version')
    for name in ('title', 'knowledge_goal', 'viewer_question', 'context', 'boundary'):
        _text(value[name], 'brief.' + name)
    _list(value['source_ids'], 'brief.source_ids', high=32)
    _need(all(isinstance(v, str) and v.strip() and len(v.encode()) <= 200 for v in value['source_ids'])
          and len(set(value['source_ids'])) == len(value['source_ids']), 'brief', 'explicit source identities required')


def _cast(value, brief):
    _object(value, {'actors', 'objects'}, set(), 'cast')
    _list(value['actors'], 'cast.actors', high=16)
    _list(value['objects'], 'cast.objects', high=64)
    for actor in value['actors']:
        _object(actor, {'id', 'name', 'role', 'motive', 'goal', 'expected_benefit', 'stake'}, set(), 'cast.actor')
        for name, text in actor.items():
            _text(text, 'cast.actor.' + name)
    for item in value['objects']:
        _object(item, {'id', 'name', 'description', 'purpose'}, set(), 'cast.object')
        for name, text in item.items():
            _text(text, 'cast.object.' + name)
    _ids(value['actors'], 'cast.actors'); _ids(value['objects'], 'cast.objects')


def _outline(value, brief, cast):
    _object(value, {'beats'}, set(), 'outline')
    beats = _list(value['beats'], 'outline.beats', low=3)
    actor_ids = {row['id'] for row in cast['actors']}
    _ids(beats, 'outline.beats')
    seen, introduced, purposes = set(), set(), set()
    for beat in beats:
        _object(beat, {'id', 'purpose', 'question', 'change', 'actor_ids', 'depends_on', 'source_ids'}, set(), 'outline.beat')
        _need(isinstance(beat['purpose'], str) and beat['purpose'] in PURPOSES, 'outline', 'unsupported beat purpose')
        for name in ('id', 'question', 'change'):
            _text(beat[name], 'outline.' + name)
        _references(beat['actor_ids'], actor_ids, 'outline.actors', high=16)
        _references(beat['depends_on'], seen, 'outline.dependencies', low=0)
        _references(beat['source_ids'], set(brief['source_ids']), 'outline.sources', low=0, high=32)
        if beat['purpose'] == 'setup':
            introduced.update(beat['actor_ids'])
        else:
            _need(set(beat['actor_ids']) <= introduced, 'outline',
                  'show the acting character motive before the choice or consequence')
            _need(bool(beat['depends_on']), 'outline', 'a non-setup beat must follow an explicit cause')
        seen.add(beat['id']); purposes.add(beat['purpose'])
    _need(beats[0]['purpose'] == 'setup' and beats[-1]['purpose'] == 'conclusion'
          and {'choice', 'consequence'} <= purposes, 'outline',
          'the story must establish motives, show a choice and result, then explain its scope')


def _details(value, brief, cast, outline):
    _object(value, {'actions'}, set(), 'details')
    actions = _list(value['actions'], 'details.actions', high=256)
    _ids(actions, 'details.actions')
    actors = {row['id'] for row in cast['actors']}; objects = {row['id'] for row in cast['objects']}
    beats = {row['id']: row for row in outline['beats']}
    order = {row['id']: i for i, row in enumerate(outline['beats'])}
    seen, last = set(), -1
    for action in actions:
        _object(action, {'id', 'beat_id', 'actor_id', 'verb', 'object_ids', 'visible_start',
                         'visible_process', 'visible_end', 'depends_on', 'event_refs'}, {'recipient_id'}, 'details.action')
        for field in ('id', 'beat_id', 'actor_id', 'verb'):
            _text(action[field], 'details.' + field, 200)
        _need(action['beat_id'] in beats and action['actor_id'] in beats[action['beat_id']]['actor_ids']
              and action['verb'] in VERBS, 'details', 'action must belong to an established actor and beat')
        _need(order[action['beat_id']] >= last, 'details', 'action order contradicts its story outline')
        last = order[action['beat_id']]
        for field in ('visible_start', 'visible_process', 'visible_end'):
            _text(action[field], 'details.' + field)
        _need(len({action[k].strip() for k in ('visible_start', 'visible_process', 'visible_end')}) == 3,
              'details', 'an action needs distinct beginning, process and result, not three copies of its name')
        _references(action['object_ids'], objects, 'details.objects', low=0, high=64)
        _references(action['depends_on'], seen, 'details.dependencies', low=0, high=256)
        if 'recipient_id' in action:
            _text(action['recipient_id'], 'details.recipient_id', 200)
            _need(action['recipient_id'] in actors and action['recipient_id'] != action['actor_id'],
                  'details', 'handover recipient must be another declared actor')
        if action['verb'] in {'hand_over', 'receive', 'pay', 'refund', 'sell'}:
            _need(bool(action['object_ids']) and 'recipient_id' in action, 'details',
                  'show who hands what to whom')
        refs = _list(action['event_refs'], 'details.events', low=1 if action['verb'] in SOURCE_ACTIONS else 0, high=32)
        for ref in refs:
            _object(ref, {'source_id', 'tick', 'rule_id'}, set(), 'details.event')
            _text(ref['source_id'], 'details.event.source_id', 200)
            _need(ref['source_id'] in brief['source_ids'], 'details', 'event source was not declared in the brief')
            _integer(ref['tick'], 'details.event.tick'); _text(ref['rule_id'], 'details.event.rule_id', 200)
        seen.add(action['id'])


def _shots(value, brief, cast, outline, details):
    _object(value, {'shots', 'asset_requirements'}, set(), 'shots')
    shots = _list(value['shots'], 'shots.shots')
    _ids(shots, 'shots.shots')
    beats = {row['id']: row for row in outline['beats']}
    actions = {row['id']: row for row in details['actions']}
    assets = _list(value['asset_requirements'], 'shots.asset_requirements', high=64)
    names = set()
    for asset in assets:
        _object(asset, {'name', 'description', 'style', 'transparent'}, set(), 'shots.asset')
        for field in ('name', 'description', 'style'):
            _text(asset[field], 'shots.asset.' + field)
        _need(type(asset['transparent']) is bool and asset['name'] not in names,
              'shots.asset', 'unique named visual requirement and explicit transparency required')
        names.add(asset['name'])
    at, used_actions, used_beats, used_assets = 0, set(), set(), set()
    for shot in shots:
        _object(shot, {'id', 'beat_id', 'start_frame', 'duration_frames', 'visual_goal',
                       'narration', 'action_ids', 'asset_names'}, {'silence_reason'}, 'shots.shot')
        _text(shot['beat_id'], 'shots.beat_id', 200)
        _need(shot['beat_id'] in beats and shot['start_frame'] == at, 'shots',
              'shots must retain the complete contiguous story axis')
        _integer(shot['start_frame'], 'shots.start_frame')
        at += _integer(shot['duration_frames'], 'shots.duration_frames', low=1)
        _need(at <= 54000, 'shots', 'story exceeds the existing finite scene budget')
        _text(shot['visual_goal'], 'shots.visual_goal')
        _need(isinstance(shot['narration'], str) and len(shot['narration']) <= 160, 'shots', 'keep narration bounded and explicit')
        if not shot['narration'].strip():
            _text(shot.get('silence_reason'), 'shots.silence_reason')
        _references(shot['action_ids'], set(actions), 'shots.actions', high=256)
        _need(all(actions[k]['beat_id'] == shot['beat_id'] for k in shot['action_ids']),
              'shots', 'a shot cannot silently borrow an action from another causal beat')
        _references(shot['asset_names'], names, 'shots.assets', high=64)
        used_actions.update(shot['action_ids']); used_beats.add(shot['beat_id']); used_assets.update(shot['asset_names'])
    _need(used_actions == set(actions) and used_beats == set(beats) and used_assets == names,
          'shots', 'all designed actions, beats and material needs must have a real shot use')


class StoryPlan:
    """Immutable-by-copy stages; rewriting a layer invalidates all dependants."""
    def __init__(self, brief, records=()):
        _brief(brief); self._brief = deepcopy(brief); self._records = []
        for record in records:
            _object(record, {'stage', 'parent_digest', 'content'}, set(), 'plan.record')
            next_plan = self.accept(record['stage'], record['content'], record['parent_digest'])
            self._records = next_plan._records

    @property
    def complete(self): return len(self._records) == len(STAGES)

    @property
    def fingerprint(self): return digest(self.to_dict())

    def to_dict(self):
        return dict(version=1, brief=deepcopy(self._brief), stages=deepcopy(self._records))

    @classmethod
    def from_dict(cls, value):
        _object(value, {'version', 'brief', 'stages'}, set(), 'plan')
        _need(type(value['version']) is int and value['version'] == 1 and isinstance(value['stages'], list)
              and len(value['stages']) <= 4, 'plan', 'unsupported plan version or stage budget')
        return cls(value['brief'], value['stages'])

    def stage(self, name):
        matches = [r['content'] for r in self._records if r['stage'] == name]
        _need(len(matches) == 1, name, 'required parent layer is not ready')
        return deepcopy(matches[0])

    def accept(self, stage, content, parent_digest):
        _need(not self.complete and stage == STAGES[len(self._records)], 'plan', 'generate and evaluate each parent layer before the next')
        _need(parent_digest == self.fingerprint, stage, 'parent content changed; regenerate this layer')
        inputs = [self._brief] + [r['content'] for r in self._records]
        {'cast': _cast, 'outline': _outline, 'details': _details, 'shots': _shots}[stage](content, *inputs)
        result = object.__new__(StoryPlan)
        result._brief = deepcopy(self._brief)
        result._records = deepcopy(self._records) + [dict(stage=stage, parent_digest=parent_digest, content=deepcopy(content))]
        return result

    def rewrite(self, stage, content, reason):
        _text(reason, 'revision.reason')
        _need(stage in STAGES and any(r['stage'] == stage for r in self._records), 'revision', 'only an existing layer may be revised')
        parent = StoryPlan(self._brief, self._records[:STAGES.index(stage)])
        return parent.accept(stage, content, parent.fingerprint)

    def prompt(self):
        _need(not self.complete, 'plan', 'all content layers are already present')
        stage = STAGES[len(self._records)]
        instruction = {
            'cast': '先设计人物的处境、目标、行动理由、代价和预期收益，以及故事必需的物体。',
            'outline': '先铺垫人物为何行动，再安排选择、过程、后果、反事实和知识回收；每镜推进必要信息。',
            'details': '逐个展开谁从哪里行动、拿什么、交给谁、过程如何发生及结果；知识后果引用给定事件来源。',
            'shots': '把动作安排为连续镜头，说明每镜让观众看懂什么、简练旁白和所需图片的名称与外观。'
        }[stage]
        return dict(stage=stage, parent_digest=self.fingerprint, instruction=instruction,
                    brief=deepcopy(self._brief), parents={r['stage']:deepcopy(r['content']) for r in self._records})

    def drawing_design(self):
        _need(self.complete, 'materials', 'finish the content layers before resolving material originals')
        # This is the existing normal material stage's input. The stage, not the
        # content author, chooses an existing original or a missing-item generator.
        return dict(version=1, title=self._brief['title'], concept=self._brief['knowledge_goal'],
                    drawings=self.stage('shots')['asset_requirements'])


def generate_story(brief, generate):
    """An explicit caller-provided model/author, one evaluated layer per call."""
    _need(callable(generate), 'generator', 'supply a real finite author; no default generation or network')
    plan = StoryPlan(brief)
    while not plan.complete:
        request = plan.prompt()
        response = generate(deepcopy(request))
        plan = plan.accept(request['stage'], response, request['parent_digest'])
    return plan


def main():
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--plan', type=Path, required=True, help='finite content plan plist; no review grants')
    parser.add_argument('--material-design', type=Path, help='write the existing normal drawing stage input as plist')
    args = parser.parse_args()
    plan = StoryPlan.from_dict(plistlib.loads(args.plan.read_bytes()))
    if args.material_design:
        args.material_design.write_bytes(plistlib.dumps(plan.drawing_design(), sort_keys=True))
    print('story content: ' + ('ready for material resolution' if plan.complete else 'needs ' + plan.prompt()['stage'])
          + '; SHA256=' + plan.fingerprint + '; visual/audio review remains required')


if __name__ == '__main__':
    main()
