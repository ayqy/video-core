"""Pure authoring tests. Synthetic fixture is NOT native/Core evidence.

Literal fixture facts exercise the compiler boundary; production receives only
normal recordSimulation output, which Host independently recomputes in full.
"""
from copy import deepcopy
import unittest

from causal_story import (BRANCHES, CausalStoryError, SOURCE_WINDOWS, check_trace_shape,
                         compile_causal_story, make_models, make_simulation, recording_edits)


ACTORS=('a','b','c','d','buyer','builder','fund','road')
PHASES=('本轮开始','同时选择','实际出力与扣费','清障判定','通行或受阻','收益结算')


def synthetic_sources():
    # Fixed expected observations, not an interpreter, rule evaluator or provider.
    balances={
      'base':[(3,3,3,3,8,0,0,0),(2,2,2,3,8,0,3,0),(2,2,2,3,8,0,3,0),(2,2,2,3,8,0,3,0),
              (2,2,2,3,8,1,2,0),(2,2,2,3,8,2,1,0),(2,2,2,3,8,3,0,0),(2,2,2,3,8,3,0,0),(2,2,2,3,8,3,0,0),(4,4,4,5,0,3,0,0)],
      'refund':[(3,3,3,3,8,0,0,0),(2,2,2,3,8,0,3,0)]+[(2,2,3,3,8,0,2,0)]*8,
      'rescue':[(3,3,3,3,8,0,0,0),(2,2,2,3,8,0,3,0),(2,2,3,3,8,0,2,0),(2,2,3,2,8,0,3,0),
                (2,2,3,2,8,1,2,0),(2,2,3,2,8,2,1,0),(2,2,3,2,8,3,0,0),(2,2,3,2,8,3,0,0),(2,2,3,2,8,3,0,0),(4,4,5,4,0,3,0,0)]}
    sources={}
    for branch in BRANCHES:
        events=[]
        for tick in range(54):
            r,phase=tick//6+1,tick%6;settled=r if phase==5 else r-1
            state_road='closed' if branch=='refund' or settled<4 else 'building' if settled<6 else 'open'
            state_good='stocked' if branch=='refund' or settled<7 else 'loaded' if settled==7 else 'delivered' if settled==8 else 'sold'
            actors=[dict(id=a,resources=balances[branch][settled][i],contribution=0,cost=0,benefit=0,passed=False,
                         ruleStateID=state_road if a=='road' else state_good if a in ('a','b','c','d') else 'idle',executedActionID='wait') for i,a in enumerate(ACTORS)]
            if phase==2:
                selected={1:dict(a='pay',b='pay',c='pay'),2:dict(c='refund' if branch!='base' else 'wait'),
                          3:dict(d='pay' if branch=='rescue' else 'wait')}
                if branch!='refund':selected.update({4:dict(builder='build'),5:dict(builder='build'),6:dict(builder='build'),
                    7:dict(a='load',b='load',c='load',d='load'),8:dict(a='deliver',b='deliver',c='deliver',d='deliver'),
                    9:dict(a='sell',b='sell',c='sell',d='sell',buyer='buy')})
                for actor in actors:actor['executedActionID']=selected.get(r,{}).get(actor['id'],'wait')
            flows=[];changes=[]
            if phase==5:
                if r==1:flows=[dict(ruleID='initial-pay-'+a,sourceActorID=a,destinationActorID='fund',amount=1) for a in ('a','b','c')]
                if r==2 and branch!='base':flows=[dict(ruleID='c-refund',sourceActorID='fund',destinationActorID='c',amount=1)]
                if r==3 and branch=='rescue':flows=[dict(ruleID='d-rescue',sourceActorID='d',destinationActorID='fund',amount=1)]
                if branch!='refund':
                    if r in (4,5,6):flows=[dict(ruleID='build-'+str(r),sourceActorID='fund',destinationActorID='builder',amount=1)]
                    if r in (4,6):changes=[dict(ruleID='build-'+str(r),actorID='road',beforeStateID='closed' if r==4 else 'building',afterStateID='building' if r==4 else 'open')]
                    if r in (7,8,9):changes=[dict(ruleID=('load-' if r==7 else 'deliver-' if r==8 else 'sale-')+a,actorID=a,
                        beforeStateID='stocked' if r==7 else 'loaded' if r==8 else 'delivered',afterStateID='loaded' if r==7 else 'delivered' if r==8 else 'sold') for a in ('a','b','c','d')]
                    if r==9:flows=[dict(ruleID='sale-'+a,sourceActorID='buyer',destinationActorID=a,amount=2) for a in ('a','b','c','d')]
            events.append(dict(tick=tick,round=r,phase=PHASES[phase],actors=actors,totalContribution=0,threshold=0,obstacleCleared=False,
                               ruleExecution=dict(poolBefore=0,poolAfter=0,externalFunding=0,deposits=0,matches=[],transfers=flows,stateChanges=changes)))
        # This deliberately non-native digest cannot be used as production proof.
        trace=dict(version=3,seed=24,throughTick=53,inputDigest='f'*64,events=events,
                   rounds=[dict(round=r) for r in range(1,10)],finalResources=[dict(id=a['id'],resources=a['resources']) for a in events[-1]['actors']])
        sources[branch]=dict(id=branch,model=make_models()[branch],seed=24,trace=trace)
    return sources


def anchors():
    result={key:dict(x=.4,y=.4) for key in ('fund','builder','buyer','supply','road-1','road-2','road-3')}
    for index,actor in enumerate(('a','b','c','d')):
        for suffix in ('','_pocket','_hand','_load','_arrive','_goods','_receive'):
            result[actor+suffix]=dict(x=.1+index*.15,y=.3 if suffix not in ('_load','_arrive') else .6)
    return result


class CausalStoryTests(unittest.TestCase):
    def test_three_models_have_only_the_two_explicit_single_plan_changes(self):
        models=make_models();original=deepcopy(models)
        for left,right,actor in (('base','refund','c'),('refund','rescue','d')):
            patched=deepcopy(models[left]);table=patched['ruleTable'];i=next(i for i,p in enumerate(table['plans']) if p['actorID']==actor)
            table['plans'][i]=deepcopy(next(p for p in models[right]['ruleTable']['plans'] if p['actorID']==actor))
            self.assertEqual(patched,models[right])
        self.assertEqual(original,models)
        for model in models.values():
            self.assertEqual(sum(a['initialResources'] for a in model['participants']),20)
            self.assertEqual(len(model['participants']),8);self.assertEqual(len(model['ruleTable']['states']),8)
            self.assertTrue(all(a['cost']==0 for a in model['ruleTable']['actions']))
            self.assertEqual(model['ruleTable']['initialPool'],0);self.assertEqual(model['ruleTable']['externalBudgetPerRound'],0)

    def test_compile_consumes_facts_without_mutating_any_native_source(self):
        sources=synthetic_sources();before=deepcopy(sources);plan=compile_causal_story(sources,anchors())
        self.assertEqual(sources,before);self.assertLessEqual(len(plan['actions']),256)
        self.assertEqual([(s['startFrame'],s['endFrame']) for s in plan['causality']['sources']],list(SOURCE_WINDOWS.values()))
        self.assertEqual(len(plan['causality']['sources']),3)
        self.assertEqual(plan['causality']['sources'][1]['parentID'],'base');self.assertEqual(plan['causality']['sources'][2]['parentID'],'refund')
        self.assertTrue(all(b['kind']!='outcome' for b in plan['causality']['bindings']))

    def test_actual_money_is_bound_once_and_delivery_precedes_each_payment(self):
        plan=compile_causal_story(synthetic_sources(),anchors());actions={a['id']:a for a in plan['actions']};bindings={b['actionID']:b for b in plan['causality']['bindings']}
        payments=[b for b in bindings.values() if b['kind']=='payment'];self.assertEqual(len(payments),8)
        for binding in payments:
            self.assertEqual(binding['amount'],2);self.assertEqual(binding['fromActorID'],'buyer')
            prior=bindings[binding['requires'][0]];self.assertEqual(prior['kind'],'delivery')
            self.assertEqual(prior['actorID'],binding['toActorID']);self.assertEqual(prior['toActorID'],'buyer')
            self.assertNotIn('amount',prior);self.assertEqual(actions[prior['actionID']]['quantity'],1)
            self.assertLessEqual(actions[prior['actionID']]['endFrame'],actions[binding['actionID']]['startFrame'])
        keys=[(b['sourceID'],b['eventID'],b['ruleID']) for b in bindings.values() if b['kind'] in ('transfer','payment')]
        self.assertEqual(len(keys),len(set(keys)))

    def test_blocked_branch_has_no_construction_delivery_or_sales(self):
        plan=compile_causal_story(synthetic_sources(),anchors())
        bound=[b for b in plan['causality']['bindings'] if b['sourceID']=='refund']
        self.assertEqual([b['ruleID'] for b in bound if b['kind']=='transfer'],['c-refund'])
        self.assertFalse(any(b['kind'] in ('delivery','payment','stateChange') for b in bound))
        observed=next(v for v in plan['observations'] if v['sourceID']=='refund' and v['frame']==522)
        self.assertEqual(next(a['resources'] for a in observed['actors'] if a['id']=='fund'),2)

    def test_partial_recording_or_wrong_source_model_is_rejected(self):
        variants=[]
        partial=synthetic_sources();partial['base']['trace']['events'].pop();variants.append(partial)
        seed=synthetic_sources();seed['rescue']['seed']=25;variants.append(seed)
        rule=synthetic_sources();rule['refund']['model']['threshold']=4;variants.append(rule)
        for value in variants:
            with self.assertRaises(CausalStoryError):compile_causal_story(value,anchors())

    def test_nonconservation_and_fabricated_final_balances_are_rejected(self):
        value=synthetic_sources();value['base']['trace']['events'][1]['actors'][0]['resources']+=1
        with self.assertRaises(CausalStoryError):compile_causal_story(value,anchors())
        value=synthetic_sources();value['rescue']['trace']['finalResources'][0]['resources']+=1
        with self.assertRaises(CausalStoryError):compile_causal_story(value,anchors())

    def test_matching_rule_without_applied_money_is_not_a_payment(self):
        value=synthetic_sources();event=value['base']['trace']['events'][53]
        event['ruleExecution']['matches']=[dict(ruleID='sale-a',facts=[])];event['ruleExecution']['transfers']=[]
        with self.assertRaises(CausalStoryError):compile_causal_story(value,anchors())

    def test_wrong_transfer_amount_or_extra_blocked_sale_is_rejected(self):
        value=synthetic_sources();value['base']['trace']['events'][5]['ruleExecution']['transfers'][0]['amount']=2
        with self.assertRaises(CausalStoryError):compile_causal_story(value,anchors())
        value=synthetic_sources();value['refund']['trace']['events'][53]['ruleExecution']['transfers'].append(dict(ruleID='sale-a',sourceActorID='buyer',destinationActorID='a',amount=2))
        with self.assertRaises(CausalStoryError):compile_causal_story(value,anchors())

    def test_missing_actual_action_and_wrong_goods_transition_are_rejected(self):
        value=synthetic_sources();value['base']['trace']['events'][20]['actors'][5]['executedActionID']='wait'
        with self.assertRaises(CausalStoryError):compile_causal_story(value,anchors())
        value=synthetic_sources();value['base']['trace']['events'][47]['ruleExecution']['stateChanges'][0]['beforeStateID']='stocked'
        with self.assertRaises(CausalStoryError):compile_causal_story(value,anchors())

    def test_explicit_points_and_distinct_normal_record_operations_are_required(self):
        points=anchors();points['a_hand']['x']=float('nan')
        with self.assertRaises(CausalStoryError):compile_causal_story(synthetic_sources(),points)
        with self.assertRaises(CausalStoryError):recording_edits(dict(base='a',refund='a',rescue='c'))
        self.assertEqual(len(recording_edits(dict(base='a',refund='b',rescue='c'))),3)
        self.assertEqual(make_simulation(make_models()['base'])['capacity'],20)
        with self.assertRaises(CausalStoryError):make_models(25)


if __name__=='__main__':unittest.main()
