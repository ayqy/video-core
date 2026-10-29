"""Content-first causal story production using native-Core traces.

This module constructs finite rule-table data and compiles visible object
processes. It never executes or reimplements the knowledge interpreter. Native
recordSimulation/knowledge compare and the Host's typed storyCausality validator
remain authoritative for decisions, resource flows, state changes and reviews.
"""
from __future__ import annotations

from copy import deepcopy
import hashlib
import json


class CausalStoryError(ValueError):
    pass


def need(condition, message):
    if not condition:
        raise CausalStoryError(message)


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()


def digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


BRANCHES = ('base', 'refund', 'rescue')
HOUSEHOLDS = ('a', 'b', 'c', 'd')
SEED = 24
APPROVED_AUDIO_SHA256 = '95b579214058dcb89bcd11c8b8c69143f2d13f4e1a496cb5fc2143d561c42479'
APPROVED_NARRATION = '四个邻居想修路。凑够三枚硬币，就能开工。别人已经出了三枚，小陈把自己那枚收了回去。路修好了，他照样走，钱也省下了。把时间倒回去。小周也收回硬币，只剩两枚，路修不成。这时，小陈补上一枚，路就能修好。路修好了，没出钱的人也能走。有人就想等别人掏钱，这就是搭便车。'


def road_models():
    """Three explicit educational inputs, not computed results or native traces.

    One good/order per household is encoded by finite states. Funds are actor
    money, not an implicit pool. No external income is supplied to the model.
    """
    round_is = lambda r: dict(kind='round', minimum=r, maximum=r)
    state_is = lambda actor, value: dict(kind='state', actorID=actor, stateID=value)
    action_is = lambda actor, value: dict(kind='action', actorID=actor, actionID=value)
    resources = lambda actor, value: dict(kind='resources', actorID=actor, minimum=value, maximum=1_000_000)
    transfer = lambda source, target, value: dict(kind='transfer', sourceActorID=source, destinationActorID=target, amount=value)
    set_state = lambda actor, value: dict(kind='setState', actorID=actor, stateID=value)
    names = dict(a='小林', b='小吴', c='小周', d='小陈', buyer='买家', builder='施工者', fund='修路基金', road='道路')
    initial = dict(a=3, b=3, c=3, d=3, buyer=8, builder=0, fund=0, road=0)
    actions = [dict(id=key, label=label, cost=0, pose=pose) for key, label, pose in (
        ('wait', '等待', 'idle'), ('pay', '交一枚修路钱', 'act'), ('refund', '取回一枚修路钱', 'object'),
        ('build', '铺一段路', 'act'), ('load', '装一件货', 'act'), ('deliver', '把同一件货运到商店', 'walk'),
        ('sell', '卖出已运抵的一件货', 'celebrate'), ('buy', '支付四件货款', 'act'))]
    states = [dict(id=key, label=label, pose=pose) for key, label, pose in (
        ('closed', '道路未施工', 'object'), ('building', '道路施工中', 'act'), ('open', '道路已通', 'celebrate'),
        ('stocked', '一件货仍在家', 'idle'), ('loaded', '同一件货已装车', 'act'),
        ('delivered', '同一件货已运抵', 'walk'), ('sold', '该件货已售出', 'celebrate'), ('idle', '等待', 'idle'))]
    participants = [dict(id=actor, name=names[actor], initialResources=amount, strategy='每轮出力') for actor, amount in initial.items()]
    plans = []
    for actor in initial:
        decisions = []
        def choose(identity, conditions, action):
            decisions.append(dict(id=identity, priority=len(decisions), conditions=conditions, actionID=action))
        if actor in ('a', 'b', 'c'):
            choose(actor+'-initial-pay', [round_is(1), resources(actor, 1)], 'pay')
        if actor == 'c':
            choose('c-round2-choice', [round_is(2), resources('fund', 1)], 'wait')
        if actor == 'd':
            choose('d-round3-choice', [round_is(3), resources('d', 1)], 'wait')
        if actor in HOUSEHOLDS:
            choose(actor+'-load', [round_is(7), state_is('road', 'open'), state_is(actor, 'stocked')], 'load')
            choose(actor+'-deliver', [round_is(8), state_is('road', 'open'), state_is(actor, 'loaded')], 'deliver')
            choose(actor+'-sell', [round_is(9), state_is('road', 'open'), state_is(actor, 'delivered')], 'sell')
        if actor == 'builder':
            for r, state, amount in ((4, 'closed', 3), (5, 'building', 2), (6, 'building', 1)):
                choose('build-'+str(r), [round_is(r), state_is('road', state), resources('fund', amount)], 'build')
        if actor == 'buyer':
            choose('buy-four-delivered-goods', [round_is(9), resources('buyer', 8), state_is('road', 'open')]
                   + [state_is(person, 'delivered') for person in HOUSEHOLDS], 'buy')
        plans.append(dict(actorID=actor, initialStateID='closed' if actor == 'road' else 'stocked' if actor in HOUSEHOLDS else 'idle',
                          defaultActionID='wait', cycleActionIDs=[], decisions=decisions))
    rules = []
    def rule(identity, label, conditions, effects):
        rules.append(dict(id=identity, label=label, conditions=conditions, effects=effects))
    for actor in ('a', 'b', 'c'):
        rule('initial-pay-'+actor, names[actor]+'实际交一枚', [round_is(1), action_is(actor, 'pay'), resources(actor, 1)],
             [transfer(actor, 'fund', 1)])
    rule('c-refund', '小周从现有基金取回一枚', [round_is(2), action_is('c', 'refund'), resources('fund', 1)], [transfer('fund', 'c', 1)])
    rule('d-rescue', '小陈实际补上一枚', [round_is(3), action_is('d', 'pay'), resources('d', 1)], [transfer('d', 'fund', 1)])
    for r, state, amount in ((4, 'closed', 3), (5, 'building', 2), (6, 'building', 1)):
        effects = [transfer('fund', 'builder', 1)]
        if r in (4, 6):
            effects.append(set_state('road', 'building' if r == 4 else 'open'))
        rule('build-'+str(r), '支付已执行的第'+str(r-3)+'段施工',
             [round_is(r), action_is('builder', 'build'), state_is('road', state), resources('fund', amount)], effects)
    for actor in HOUSEHOLDS:
        for r, action, before, after in ((7, 'load', 'stocked', 'loaded'), (8, 'deliver', 'loaded', 'delivered')):
            rule(action+'-'+actor, names[actor]+('装载同一件货' if r == 7 else '运抵同一件货'),
                 [round_is(r), action_is(actor, action), state_is('road', 'open'), state_is(actor, before)], [set_state(actor, after)])
        rule('sale-'+actor, '买家支付'+names[actor]+'实际运抵货款',
             [round_is(9), action_is(actor, 'sell'), action_is('buyer', 'buy'), state_is('road', 'open'),
              state_is(actor, 'delivered'), resources('buyer', 8)], [transfer('buyer', actor, 2), set_state(actor, 'sold')])
    base = dict(version=3, knowledgeLabel='公共道路与搭便车：一户一件货、一件一单的有限教学模型', resourceLabel='硬币',
        participants=participants, rounds=9, roundTicks=6, startTick=0, contributionCost=0, contributionUnits=1,
        threshold=3, benefit=0, ruleTable=dict(version=1, actions=actions, states=states, plans=plans, rules=rules,
                                            initialPool=0, externalBudgetPerRound=0))
    models = {name:deepcopy(base) for name in BRANCHES}
    for branch in ('refund', 'rescue'):
        next(row for plan in models[branch]['ruleTable']['plans'] for row in plan['decisions'] if row['id'] == 'c-round2-choice')['actionID'] = 'refund'
    next(row for plan in models['rescue']['ruleTable']['plans'] for row in plan['decisions'] if row['id'] == 'd-round3-choice')['actionID'] = 'pay'
    return models


def make_models(seed=SEED):
    """Return {base: KnowledgeSimulation, refund: ..., rescue: ...} as wire data."""
    need(type(seed) is int and seed == SEED, 'this approved road story uses the explicit same seed24')
    return road_models()


def make_simulation(model):
    """Outer normal Simulation wire value for a native trace-reference scene."""
    need(model in make_models().values(), 'one exact declared road-story model required')
    return dict(seed=SEED, unit='硬币', initial=20, capacity=20, events=[], knowledge=deepcopy(model))


def native_sources(project, scene_ids):
    """Extract actual persisted Core recordings; never manufacture a trace.

    The normal Host subsequently recomputes every embedded complete source.
    This extraction performs only shape, explicit model and saved-axis checks.
    """
    models = make_models(); scenes = {s['id']:s for s in project['revisions'][-1]['scenes']}
    need(set(scene_ids) == set(BRANCHES) and len(set(scene_ids.values())) == 3,
         'three actual distinct native source scenes required')
    sources = {}
    for branch in BRANCHES:
        need(scene_ids[branch] in scenes, 'native source scene absent from current project')
        scene = scenes[scene_ids[branch]]; recording = scene.get('simulationRecording') or {}
        need(scene.get('kind') == '规则模拟' and scene.get('simulation') == make_simulation(models[branch])
             and recording.get('recordedFPS') == 30 and recording.get('recordedDurationFrames') == 1620
             and recording.get('recordedSpeed') == 1 and recording.get('recordedPauseFrames') == 0,
             'exact complete native road-model scene and recording axis required')
        trace = deepcopy(recording.get('knowledgeTrace'))
        check_trace_shape(branch, trace)
        sources[branch] = dict(id=branch, model=deepcopy(models[branch]), seed=SEED, trace=trace)
    return sources


def check_trace_shape(branch, trace):
    need(branch in BRANCHES and isinstance(trace, dict) and trace.get('version') == 3
         and trace.get('seed') == SEED and trace.get('throughTick') == 53
         and isinstance(trace.get('inputDigest'), str) and len(trace['inputDigest']) == 64
         and isinstance(trace.get('events'), list) and len(trace['events']) == 54
         and isinstance(trace.get('rounds'), list) and len(trace['rounds']) == 9,
         'actual complete native v3 trace with all nine rounds required; Python never fills missing events')
    phases = ('本轮开始', '同时选择', '实际出力与扣费', '清障判定', '通行或受阻', '收益结算')
    actor_ids = {row['id'] for row in make_models()[branch]['participants']}
    for i, event in enumerate(trace['events']):
        need(event.get('tick') == i and event.get('round') == i//6+1 and event.get('phase') == phases[i%6]
             and len(event.get('actors', [])) == len(actor_ids)
             and {a['id'] for a in event['actors']} == actor_ids, 'complete ordered native semantic events required')
        execution = event.get('ruleExecution') or {}
        need(execution.get('externalFunding') == execution.get('deposits') == execution.get('poolBefore') == execution.get('poolAfter') == 0
             and sum(a['resources'] for a in event['actors']) == 20,
             'road story has only funded actor money: zero external/pool flow and twenty conserved coins')
    need(trace['finalResources'] == [dict(id=a['id'], resources=a['resources']) for a in trace['events'][-1]['actors']],
         'native final balance observation must match its own last event')
    return trace


def recording_edits(scene_ids):
    """Normal Core operations; callers execute these through CLI dry-run/CAS."""
    need(isinstance(scene_ids, dict) and set(scene_ids) == set(BRANCHES)
         and len(set(scene_ids.values())) == 3, 'three distinct actual native trace scene identities required')
    return [dict(recordSimulation={'_0':scene_ids[branch]}) for branch in BRANCHES]


def comparison_requests(project, scene_ids):
    revision = project['revisions'][-1]
    need(set(scene_ids) == set(BRANCHES) and set(scene_ids.values()) <= {scene['id'] for scene in revision['scenes']},
         'same-current-revision trace sources required')
    common = dict(workspace_id=project['workspaceID'], project_id=project['id'], base_revision=revision['id'])
    return [dict(common, scene_id=scene_ids[left], comparison_scene_id=scene_ids[right])
            for left, right in (('base', 'refund'), ('refund', 'rescue'))]


SOURCE_WINDOWS = dict(base=(0, 420), refund=(420, 629), rescue=(629, 972))


def _event(source, round_number, phase='收益结算'):
    rows = [v for v in source['trace']['events'] if v['round'] == round_number and v['phase'] == phase]
    need(len(rows) == 1, 'one actual semantic source event required')
    return rows[0]


def _event_id(event):
    return str(event['round']) + '-' + event['phase']


def compile_causal_story(sources, anchors):
    """Compile the same observed causal processes for game/cartoon/pencil.

    ``sources`` comes from native_sources or the normal source driver's persisted
    output. Anchors explicitly declare stage points; this function consumes
    actual applied transfers and state changes, never simulates rule outcomes.
    Core independently verifies each full source again on normal edit/production.
    """
    models = make_models()
    need(isinstance(sources, dict) and set(sources) == set(BRANCHES), 'all three complete native sources required')
    for branch in BRANCHES:
        row = sources[branch]
        need(isinstance(row, dict) and row.get('model') == models[branch] and row.get('seed') == SEED,
             'source model/seed differs from the explicit three-coin story')
        check_trace_shape(branch, row.get('trace'))
    expected = dict(base=dict(a=4,b=4,c=4,d=5,buyer=0,builder=3,fund=0,road=0),
                    refund=dict(a=2,b=2,c=3,d=3,buyer=8,builder=0,fund=2,road=0),
                    rescue=dict(a=4,b=4,c=5,d=4,buyer=0,builder=3,fund=0,road=0))
    for branch in BRANCHES:
        actual = {a['id']:a['resources'] for a in sources[branch]['trace']['events'][-1]['actors']}
        need(actual == expected[branch], 'actual native final balances do not describe the approved story')
    # Match complete applied-flow inventories, including facts established
    # before a branch's editorial starting snapshot. Never accept extra hidden
    # construction/sales in the blocked branch or 'matched' rules as money.
    for branch in BRANCHES:
        expected_flows=[(1,'initial-pay-'+a,a,'fund',1) for a in ('a','b','c')]
        if branch!='base':expected_flows.append((2,'c-refund','fund','c',1))
        if branch=='rescue':expected_flows.append((3,'d-rescue','d','fund',1))
        if branch!='refund':
            expected_flows += [(r,'build-'+str(r),'fund','builder',1) for r in (4,5,6)]
            expected_flows += [(9,'sale-'+a,'buyer',a,2) for a in HOUSEHOLDS]
        actual_flows=[(event['round'],f.get('ruleID'),f.get('sourceActorID'),f.get('destinationActorID'),f.get('amount'))
                      for event in sources[branch]['trace']['events']
                      for f in (event.get('ruleExecution') or {}).get('transfers',[])]
        need(sorted(actual_flows)==sorted(expected_flows),'full native branch contains missing or additional financial events')
    required_points = {'fund','builder','buyer','supply'}
    required_points.update(v + suffix for v in HOUSEHOLDS for suffix in ('','_pocket','_hand','_load','_arrive','_goods','_receive'))
    required_points.update('road-'+str(i) for i in (1,2,3))
    need(isinstance(anchors, dict) and required_points <= anchors.keys(), 'complete explicit ownership and handover anchors required')
    for point in anchors.values():
        need(isinstance(point, dict) and set(point) == {'x','y'} and all(type(n) in (int,float) and 0<=n<=1 for n in point.values()),
             'story anchors must be finite normalized stage points')
    actions, bindings, observations, cues = [], [], [], []
    def add(identity, kind, subject, a, b, **extra):
        row = dict(id=identity,kind=kind,subjectID=subject,startFrame=a,endFrame=b,**extra)
        actions.append(row); return row
    def bind(action, source, event, kind, requires=(), **extra):
        bindings.append(dict(actionID=action['id'],sourceID=source,eventID=_event_id(event),kind=kind,requires=list(requires),**extra))
    def move(identity, subject, a,b, left,right, **extra):
        return add(identity,'move',subject,a,b,**{'from':deepcopy(left),'to':deepcopy(right)},**extra)
    def observation(branch, round_number, frame):
        event=_event(sources[branch],round_number)
        observations.append(dict(frame=frame,sourceID=branch,eventID=_event_id(event),actors=deepcopy(event['actors'])))
    def action_event(branch,actor,key,round_number):
        event=_event(sources[branch],round_number,'实际出力与扣费')
        need(any(a['id']==actor and a.get('executedActionID')==key for a in event['actors']),
             'visible process lacks an actually executed native action')
        return event
    def transfer(branch,rule,payer,recipient,amount,round_number,a,b,requires=(),payment=False,destination=None):
        event=_event(sources[branch],round_number)
        flows=(event.get('ruleExecution') or {}).get('transfers',[])
        matches=[f for f in flows if f.get('ruleID')==rule and f.get('sourceActorID')==payer and f.get('destinationActorID')==recipient and f.get('amount')==amount]
        need(len(matches)==1, 'payment must use one actual applied transfer with exact route and amount')
        identity=branch+'-'+rule
        left=anchors[payer+'_hand'] if payer in HOUSEHOLDS else anchors[payer]
        right=destination or (anchors[recipient+'_receive'] if recipient in HOUSEHOLDS else anchors.get(recipient+'_receive',anchors[recipient]))
        add(identity+'-show','show','money-token',a,a+1)
        row=add(identity,'transfer','money-token',a,b,targetID='neighbor-'+recipient if recipient in HOUSEHOLDS else recipient+'-account' if recipient=='fund' else recipient,
                quantity=amount,**{'from':deepcopy(left),'to':deepcopy(right)})
        bind(row,branch,event,'payment' if payment else 'transfer',requires,ruleID=rule,fromActorID=payer,toActorID=recipient,amount=amount)
        add(identity+'-hide','hide','money-token',b,b+1)
        if amount==2:
            # The second actual coin is an accompanying visual, not a second
            # financial claim or invented transfer. Core binds the pair once.
            offset=lambda p:dict(x=min(.98,p['x']+.018),y=p['y'])
            add(identity+'-pair-show','show','money-pair',a,a+1)
            move(identity+'-pair','money-pair',a,b,offset(left),offset(right))
            add(identity+'-pair-hide','hide','money-pair',b,b+1)
        return row['id']
    def state(branch,round_number,rule,actor,before,after):
        event=_event(sources[branch],round_number)
        need(sum(c.get('ruleID')==rule and c.get('actorID')==actor and c.get('beforeStateID')==before and c.get('afterStateID')==after
                 for c in (event.get('ruleExecution') or {}).get('stateChanges',[]))==1, 'state animation lacks an actual applied state change')
        return event
    # Complete original sources remain embedded; interventions change exactly
    # one native actor plan along the same seed, not the rule table or budget.
    typed_sources=[]
    for branch in BRANCHES:
        row=deepcopy(sources[branch]); row['id']=branch
        row['startFrame'],row['endFrame']=SOURCE_WINDOWS[branch]
        if branch!='base':
            parent,actor=('base','c') if branch=='refund' else ('refund','d')
            row.update(parentID=parent,intervention=dict(actorID=actor,plan=deepcopy(next(p for p in models[branch]['ruleTable']['plans'] if p['actorID']==actor))))
        typed_sources.append(row)
    aliases=[]
    for actor in HOUSEHOLDS:
        for subject in ('neighbor-'+actor,'cart-'+actor,'goods-'+actor): aliases.append(dict(actorID=actor,subjectID=subject))
    aliases += [dict(actorID='buyer',subjectID='buyer'),dict(actorID='builder',subjectID='builder'),
                dict(actorID='fund',subjectID='fund-account'),dict(actorID='road',subjectID='road-open')]
    aliases += [dict(actorID='builder',subjectID='road-'+str(i)) for i in (1,2,3)]
    add('base-closed','show','road-open',0,1)
    # Rewind to actual settled observations. It is an editorial cut, not an
    # invented financial refund, transaction or new rule event.
    initial_event=_event(sources['base'],1,'本轮开始')
    observations.append(dict(frame=0,sourceID='base',eventID=_event_id(initial_event),actors=deepcopy(initial_event['actors'])))
    observation('refund',1,420);observation('rescue',2,629)
    for branch,start in (('base',0),('refund',420),('rescue',629)):
        for actor in HOUSEHOLDS:
            move(branch+'-reset-goods-'+actor,'goods-'+actor,start,start+1,anchors[actor+'_goods'],anchors[actor+'_goods'])
            move(branch+'-reset-cart-'+actor,'cart-'+actor,start,start+1,anchors[actor+'_load'],anchors[actor+'_load'])
            move(branch+'-reset-person-'+actor,'neighbor-'+actor,start,start+1,anchors[actor],anchors[actor])
        move(branch+'-reset-builder','builder',start,start+1,anchors['builder'],anchors['builder'])
        if branch!='base':
            for i in (1,2,3):add(branch+'-road-reset-'+str(i),'hide','road-'+str(i),start,start+1)
            add(branch+'-closed','show','road-open',start,start+1)
    # Initial three contributions: pocket -> hand -> actual fund recipient.
    for actor,start in zip(('a','b','c'),(166,190,214)):
        performed=action_event('base',actor,'pay',1)
        body=move('base-prepare-'+actor,'neighbor-'+actor,start-6,start,anchors[actor],anchors[actor])
        bind(body,'base',performed,'performedAction',actorID=actor,actionKey='pay')
        add('base-pocket-visible-'+actor,'show','money-token',start-6,start-5)
        move('base-pocket-'+actor,'money-token',start-6,start,anchors[actor+'_pocket'],anchors[actor+'_hand'])
        transfer('base','initial-pay-'+actor,actor,'fund',1,1,start,start+16,(body['id'],))
        cues.append(dict(actorID='neighbor-'+actor,startFrame=start-6,endFrame=start+17,expression='neutral',gesture='offer'))
    observation('base',1,231)
    # D only withdraws a still-owned coin: there is no fabricated D->Fund flow.
    wait=action_event('base','d','wait',1)
    row=add('base-d-keeps-own-coin','speak','neighbor-d',238,258,text='我先留着。')
    bind(row,'base',wait,'performedAction',actorID='d',actionKey='wait')
    add('base-own-coin-show','show','money-token',238,239)
    move('base-own-coin-out','money-token',238,248,anchors['d_pocket'],anchors['d_hand'])
    move('base-own-coin-back','money-token',248,258,anchors['d_hand'],anchors['d_pocket'])
    add('base-own-coin-hide','hide','money-token',258,259)
    cues.append(dict(actorID='neighbor-d',startFrame=238,endFrame=258,expression='thinking',gesture='withdraw'))
    # The counterfactual applies a genuine one-coin Fund->C refund, then keeps
    # the remaining two in escrow; no construction, delivery or sale is added.
    prepared=move('refund-c-prepares','neighbor-c',479,489,anchors['c'],anchors['c'])
    bind(prepared,'refund',action_event('refund','c','refund',2),'performedAction',actorID='c',actionKey='refund')
    transfer('refund','c-refund','fund','c',1,2,489,522,(prepared['id'],))
    observation('refund',2,522)
    cues.append(dict(actorID='neighbor-c',startFrame=479,endFrame=523,expression='worried',gesture='withdraw'))
    row=add('refund-still-two','speak','neighbor-c',535,588,text='还差一枚，先别开工。')
    # Rescue changes only D's round-three plan and transfers its existing coin.
    prepared=move('rescue-d-prepares','neighbor-d',630,640,anchors['d'],anchors['d'])
    bind(prepared,'rescue',action_event('rescue','d','pay',3),'performedAction',actorID='d',actionKey='pay')
    add('rescue-d-pocket-visible','show','money-token',630,631)
    move('rescue-d-pocket','money-token',630,640,anchors['d_pocket'],anchors['d_hand'])
    transfer('rescue','d-rescue','d','fund',1,3,640,669,(prepared['id'],))
    observation('rescue',3,669)
    cues.append(dict(actorID='neighbor-d',startFrame=630,endFrame=670,expression='happy',gesture='offer'))
    for branch,construction,loading,travel,unload,sales in (
            ('base',(258,277,296,315),(316,333),(334,363),(363,373),374),
            ('rescue',(671,693,715,737),(758,774),(774,810),(810,820),822)):
        completed=[]
        for i,(a,b) in enumerate(zip(construction,construction[1:]),1):
            road='road-'+str(i);round_number=i+3
            # Worker approaches material, carries this road piece to its exact
            # gap, then progressively lays it. The wage is a real Fund transfer.
            split=a+max(4,(b-a)//3);laid=b-7
            move(branch+'-worker-'+str(i),'builder',a,split,anchors['supply'] if i==1 else anchors['road-'+str(i-1)],anchors[road])
            add(branch+'-carry-visible-'+str(i),'show',road,a,a+1)
            move(branch+'-carry-'+str(i),road,a,split,anchors['supply'],anchors[road])
            build=add(branch+'-lay-'+str(i),'build',road,split,laid)
            bind(build,branch,action_event(branch,'builder','build',round_number),'performedAction',actorID='builder',actionKey='build')
            completed.append(build['id'])
            transfer(branch,'build-'+str(round_number),'fund','builder',1,round_number,laid,b-1,(build['id'],),destination=dict(x=min(.98,anchors[road]['x']+.06),y=anchors[road]['y']-.012))
            observation(branch,round_number,b-1)
            cues.append(dict(actorID='builder',startFrame=a,endFrame=b,expression='neutral',gesture='offer'))
        opened=add(branch+'-road-opens','hide','road-open',construction[-1]-1,construction[-1])
        bind(opened,branch,state(branch,6,'build-6','road','building','open'),'stateChange',completed,
             actorID='road',ruleID='build-6',fromStateID='building',toStateID='open')
        deliveries={}
        for index,actor in enumerate(HOUSEHOLDS):
            walk_start=dict(x=anchors[actor+'_load']['x'],y=anchors[actor+'_load']['y']-.14)
            walk_end=dict(x=anchors[actor+'_arrive']['x'],y=anchors[actor+'_arrive']['y']-.14)
            move(branch+'-owner-load-'+actor,'neighbor-'+actor,*loading,anchors[actor],walk_start)
            move(branch+'-owner-trip-'+actor,'neighbor-'+actor,*travel,walk_start,walk_end)
            loaded=move(branch+'-load-'+actor,'goods-'+actor,*loading,anchors[actor+'_goods'],anchors[actor+'_load'])
            bind(loaded,branch,state(branch,7,'load-'+actor,actor,'stocked','loaded'),'stateChange',(opened['id'],),actorID=actor,ruleID='load-'+actor,fromStateID='stocked',toStateID='loaded')
            move(branch+'-cart-trip-'+actor,'cart-'+actor,*travel,anchors[actor+'_load'],anchors[actor+'_arrive'])
            move(branch+'-same-cargo-trip-'+actor,'goods-'+actor,*travel,anchors[actor+'_load'],anchors[actor+'_arrive'])
            delivery=add(branch+'-delivery-'+actor,'transfer','goods-'+actor,*unload,targetID='buyer',quantity=1,
                         **{'from':deepcopy(anchors[actor+'_arrive']),'to':deepcopy(anchors.get('buyer_goods_'+actor,anchors['buyer']))})
            bind(delivery,branch,state(branch,8,'deliver-'+actor,actor,'loaded','delivered'),'delivery',(loaded['id'],),actorID=actor,toActorID='buyer',ruleID='deliver-'+actor,fromStateID='loaded',toStateID='delivered')
            deliveries[actor]=delivery['id']
            transfer(branch,'sale-'+actor,'buyer',actor,2,9,sales+index*10,sales+index*10+8,(delivery['id'],),payment=True,destination=dict(x=min(.98,walk_end['x']+.03),y=walk_end['y']+.014))
        observation(branch,7,loading[1]);observation(branch,8,unload[1]);observation(branch,9,sales+38)
    for actor in ('c','d'):
        cues.append(dict(actorID='neighbor-'+actor,startFrame=374,endFrame=416,expression='happy',gesture='celebrate'))
        cues.append(dict(actorID='neighbor-'+actor,startFrame=822,endFrame=862,expression='happy',gesture='celebrate'))
    cues.append(dict(actorID='neighbor-c',startFrame=523,endFrame=629,expression='worried',gesture='idle'))
    cues.append(dict(actorID='neighbor-d',startFrame=479,endFrame=629,expression='worried',gesture='idle'))
    for a,b in ((315,334),(737,758)):
        cues.append(dict(actorID='builder',startFrame=a,endFrame=b,expression='happy',gesture='celebrate'))
    # These one-frame viewpoint resets are an explicit editorial conclusion
    # cut after completed trade, never an invented return trip or transaction.
    for actor in HOUSEHOLDS:
        move('conclusion-person-'+actor,'neighbor-'+actor,862,863,anchors[actor],anchors[actor])
    # No dialogue is an out-of-scene explanatory poster; short actual speaker
    # lines use the native game's own skin or cartoon speech bubbles.
    from story_action import actions_for_scene
    subjects={a['subjectID'] for a in aliases}|{'pool-unused','money-token','money-pair','host'}
    actions_for_scene(actions,subjects,972)
    need(len(actions)<=256 and len(bindings)<=256, 'bounded native process budget exceeded')
    return dict(actions=actions,causality=dict(version=1,poolSubjectID='pool-unused',actors=aliases,sources=typed_sources,bindings=bindings),
                observations=sorted(observations,key=lambda r:r['frame']),cues=cues,
                limitations=['一户一件货、一件一单的有限教学状态；收货人为作者明确声明，实迹未建模多资源库存。',
                             'A/B/买家沿用实际静态人物原件，尚缺独立手臂rig；不能把全身平移称为完整掏递动作验收。'])
