"""Pure adapter rules. Literal synthetic traces are NOT native/Core evidence.

The fake invoke records boundary calls only; it does not validate or execute a
knowledge model. Production must use the shipped native CLI and its independent
StoryCausalRules verification. These fixtures must never be called real media,
real recordings, native validation, or human review.
"""
from copy import deepcopy
import unittest

from knowledge_story import KnowledgeStoryError, PHASES, record_sources, compile_presentation, apply_presentation, _behavior_changed
from story_planning import StoryPlan


def fixture(mode='game'):
    people = [dict(id=key, name=name, strategy='每轮出力', initialResources=amount)
              for key, name, amount in [('weaver', '织工', 12), ('grower', '菜农', 8)]]
    model = dict(version=3, knowledgeLabel='双方自愿交换的有限教学规则', resourceLabel='筹码', participants=people,
                 rounds=2, roundTicks=9, startTick=2, contributionCost=0, contributionUnits=1, threshold=1, benefit=0,
                 ruleTable=dict(version=1, initialPool=2, externalBudgetPerRound=0,
                     actions=[dict(id='offer', label='提出交换', cost=1, pose='act'), dict(id='wait', label='保留', cost=0, pose='idle')],
                     states=[dict(id='open', label='未交换', pose='idle'), dict(id='agreed', label='已交换', pose='celebrate')],
                     plans=[dict(actorID=person['id'], initialStateID='open', defaultActionID='offer', cycleActionIDs=[], decisions=[
                         dict(id='later-wait-'+person['id'], priority=0, conditions=[dict(kind='round', minimum=2, maximum=2)], actionID='wait')]) for person in people],
                     rules=[dict(id='swap', label='双方同意才交换', conditions=[dict(kind='actionCount', actionID='offer', minimum=2, maximum=2)], effects=[
                         dict(kind='transfer', sourceActorID='weaver', destinationActorID='grower', amount=3),
                         dict(kind='transfer', sourceActorID='grower', destinationActorID='weaver', amount=1),
                         dict(kind='setState', actorID='weaver', stateID='agreed'), dict(kind='setState', actorID='grower', stateID='agreed')])]))
    other = deepcopy(model)
    other['ruleTable']['plans'][1]['defaultActionID'] = 'wait'
    sources = [dict(id='exchange', scene_id='source-offer', model=model, seed=19, start_frame=0, end_frame=360),
               dict(id='retain', scene_id='source-retain', model=other, seed=19, start_frame=360, end_frame=480,
                    parent_id='exchange', intervention=dict(actorID='grower', plan=deepcopy(other['ruleTable']['plans'][1])))]
    brief = dict(version=1, title='一次双方同意的交换', knowledge_goal='理解交易需要双方同意，动作与收益来自明确规则',
                 viewer_question='如果对方不愿意交换呢？', context='两人各自决定是否提出交换', boundary='有限筹码教学模型，不预测现实成交',
                 source_ids=['exchange', 'retain'])
    cast = dict(actors=[dict(id=person['id'], name=person['name'], role='交换参与者', motive='需要对方的商品', goal='自愿交换',
                            expected_benefit='取得已说明条件下的交换结果', stake='可以保留自己的资源') for person in people],
                objects=[dict(id='coin', name='交换筹码', description='有明确所有者的一袋筹码', purpose='显示实际交接')])
    outline = dict(beats=[dict(id=key, purpose=purpose, question='对方如何选择？', change='观察实际行动和筹码后果',
                              actor_ids=['weaver','grower'], depends_on=deps, source_ids=[source])
                          for key,purpose,deps,source in [('setup','setup',[],'exchange'),('choice','choice',['setup'],'exchange'),
                                                         ('result','consequence',['choice'],'exchange'),('end','conclusion',['result'],'retain')]])
    rows = [('inspect','setup','react','weaver',4,'offer',[]), ('deposit','choice','pay','weaver',4,'deposit',['inspect']),
            ('money','result','pay','weaver',7,'swap',['deposit']), ('changed','result','react','weaver',7,'swap',['money']),
            ('kept','end','react','grower',4,'wait',[])]
    details = dict(actions=[dict(id=key, beat_id=beat, actor_id=actor, verb=verb, object_ids=['coin'],
                                visible_start='看见参与者持有的筹码', visible_process='观察明确选择后的可见过程', visible_end='看见该选择后的实际持有状态',
                                depends_on=deps, event_refs=[dict(source_id='retain' if beat=='end' else 'exchange',tick=tick,rule_id=rule)],
                                **(dict(recipient_id='grower') if verb=='pay' else {}))
                            for key,beat,verb,actor,tick,rule,deps in rows])
    shots = dict(shots=[dict(id='shot-'+beat['id'], beat_id=beat['id'], start_frame=i*120, duration_frames=120,
                             visual_goal='看清选择及其可核对结果', narration='双方同意才交换。',
                             action_ids=[row['id'] for row in details['actions'] if row['beat_id']==beat['id']], asset_names=['筹码与人物'])
                        for i,beat in enumerate(outline['beats'])],
                 asset_requirements=[dict(name='筹码与人物', description='明确的独立人物和筹码', style='熟悉游戏的真实素材', transparent=True)])
    story = StoryPlan(brief)
    for stage, content in zip(('cast','outline','details','shots'),(cast,outline,details,shots)):
        story = story.accept(stage,content,story.fingerprint)
    beat_rows = [dict(id='inspect', detail_id='inspect', shot_id='shot-setup', source_id='exchange', event=dict(round=1,phase=PHASES[2]),
                      effect=dict(kind='performedAction',actor_id='weaver',action_key='offer'), subject_id='person-weaver', start_frame=10,end_frame=40,requires=[],visual=dict(kind='show')),
                 dict(id='deposit',detail_id='deposit',shot_id='shot-choice',source_id='exchange',event=dict(round=1,phase=PHASES[2]),
                      effect=dict(kind='deposit',from_actor_id='weaver'), subject_id='coin-weaver',start_frame=130,end_frame=160,requires=['inspect'],
                      visual=dict(kind='transfer',target_subject_id='pool',from_anchor='left',to_anchor='center')),
                 dict(id='money',detail_id='money',shot_id='shot-result',source_id='exchange',event=dict(round=1,phase=PHASES[5]),
                      effect=dict(kind='transfer',rule_id='swap',from_actor_id='weaver',to_actor_id='grower'), subject_id='coin-weaver',start_frame=250,end_frame=280,requires=['deposit'],
                      visual=dict(kind='transfer',target_subject_id='person-grower',from_anchor='center',to_anchor='right',via_anchors=['upper'])),
                 dict(id='changed',detail_id='changed',shot_id='shot-result',source_id='exchange',event=dict(round=1,phase=PHASES[5]),
                      effect=dict(kind='stateChange',actor_id='weaver',rule_id='swap',from_state_id='open',to_state_id='agreed'), subject_id='result-weaver',start_frame=285,end_frame=310,requires=['money'],visual=dict(kind='show')),
                 dict(id='kept',detail_id='kept',shot_id='shot-end',source_id='retain',event=dict(round=1,phase=PHASES[2]),
                      effect=dict(kind='performedAction',actor_id='grower',action_key='wait'),subject_id='person-grower',start_frame=375,end_frame=410,requires=[],visual=dict(kind='hide'))]
    objects = ['person-weaver','person-grower','coin-weaver','result-weaver','pool']
    scene = dict(id='stage',kind='规则模拟' if mode=='game' else '图文讲解',durationFrames=480,narration='双方同意才交换。'*4,
                 sourceStartFrame=0,speed=1,pauseFrames=0,locked=False,captions=[],layers=[])
    if mode=='game':
        scene.update(classicArtwork=dict(sprites=[],sources=[]),gameWorld=dict(version=1,width=4,height=3,tiles=['floor']*12,
            entities=[dict(id=key,name=key,role='hero',x=1,y=1,scale=1,visible=True) for key in objects],updates=[]))
    else:
        scene['layers']=[dict(id=key,kind='rectangle',locked=False,startFrame=0,endFrame=480) for key in objects]
    project = dict(id='target-project',workspaceID='workspace',revisions=[dict(id='target-v1',fps=30,scenes=[scene])])
    plan = dict(version=1,story=story.to_dict(),target=dict(workspace_id='workspace',project_id='target-project',base_revision='target-v1',scene_id='stage',fps=30,mode=mode),
                sources=sources,actors=[dict(actor_id='weaver',subject_id=key) for key in ('person-weaver','coin-weaver','result-weaver')]
                    +[dict(actor_id='grower',subject_id='person-grower')],pool_subject_id='pool',anchors=dict(left=dict(x=.2,y=.5),center=dict(x=.5,y=.5),right=dict(x=.8,y=.5),upper=dict(x=.6,y=.4)),
                beats=beat_rows,balances=[])
    native = []
    for index, source in enumerate(sources):
        # Literal expected observations. Deliberately invalid digest cannot
        # establish native truth; actual Core dry-run must reject such a trace.
        events=[]
        initial=(12,8); after_cost=(11,7) if index==0 else (11,8); settled=(9,9) if index==0 else (11,8)
        for r in (1,2):
            for phase_index,phase in enumerate(PHASES):
                amounts=initial if r==1 and phase_index<2 else after_cost if r==1 and phase_index<5 else settled
                action='offer' if r==1 else 'wait'
                actors=[dict(id=key,resources=amount,cost=1 if r==1 and phase_index>=2 and (index==0 or key=='weaver') else 0,
                             contribution=0,benefit=0,passed=False,ruleStateID='agreed' if index==0 and (r==2 or phase_index==5) else 'open',
                             **(dict(executedActionID='wait' if index==1 and key=='grower' else action) if phase_index>=2 else {}))
                        for key,amount in zip(('weaver','grower'),amounts)]
                flows=[dict(ruleID='swap',sourceActorID='weaver',destinationActorID='grower',amount=3),dict(ruleID='swap',sourceActorID='grower',destinationActorID='weaver',amount=1)] if index==0 and r==1 and phase_index==5 else []
                changes=[dict(ruleID='swap',actorID=key,beforeStateID='open',afterStateID='agreed') for key in ('weaver','grower')] if flows else []
                events.append(dict(round=r,phase=phase,tick=2+(r-1)*9+phase_index,actors=actors,totalContribution=0,threshold=1,obstacleCleared=False,
                    ruleExecution=dict(poolBefore=2,poolAfter=4 if index==0 else 3,externalFunding=0,deposits=2 if index==0 else 1,matches=[],transfers=flows,stateChanges=changes)))
        trace=dict(version=3,seed=19,throughTick=16,inputDigest='f'*64,events=events,rounds=[dict(round=1),dict(round=2)],
                   finalResources=[dict(id=row['id'],resources=row['resources']) for row in events[-1]['actors']])
        native.append(dict(id=source['id'],model=deepcopy(source['model']),seed=19,trace=trace,startFrame=source['start_frame'],endFrame=source['end_frame'],
                           **(dict(parentID=source['parent_id'],intervention=deepcopy(source['intervention'])) if index else {})))
    recorded=dict(version=1,project_id='source-project',revision='source-v2',sources=native)
    source_scenes=[dict(id=s['scene_id'],kind='规则模拟',locked=False,sourceStartFrame=0,speed=1,pauseFrames=0,durationFrames=510,
                        simulation=dict(knowledge=deepcopy(s['model']),seed=19)) for s in sources]
    source_project=dict(id='source-project',workspaceID='workspace',revisions=[dict(id='source-v1',fps=30,scenes=source_scenes)])
    return project,plan,recorded,source_project


class NativeBoundary:
    """Synthetic protocol spy; never a native validation substitute."""
    def __init__(self,project,recorded):
        self.project=deepcopy(project);self.recorded=deepcopy(recorded);self.calls=[];self.reject=False
        self.source=fixture()[3]
        self.source['revisions'][0]['id']=recorded['revision']
        for scene,row in zip(self.source['revisions'][0]['scenes'],recorded['sources']):
            scene['simulationRecording']=dict(recordedFPS=30,recordedSpeed=1,recordedPauseFrames=0,recordedDurationFrames=510,
                                               knowledgeTrace=deepcopy(row['trace']))
    def __call__(self,command,body,dry):
        self.calls.append((command,deepcopy(body),dry))
        if self.reject:
            return dict(ok=False,state='error')
        if command=='projects list':
            return dict(ok=True,result=[deepcopy(self.project)]+([deepcopy(self.source)] if self.project['id']=='target-project' else []))
        if command=='knowledge compare':
            return dict(ok=True,result=dict(comparison=dict(baseline=deepcopy(self.recorded['sources'][0]['trace']),alternative=deepcopy(self.recorded['sources'][1]['trace']))))
        if dry:
            return dict(ok=True,state='dry_run')
        old=self.project['revisions'][-1];new=deepcopy(old);new['id']=self.recorded['revision'] if self.project['id']=='source-project' else 'target-v2'
        for edit in body['edits']:
            if 'recordSimulation' in edit:
                scene=next(s for s in new['scenes'] if s['id']==edit['recordSimulation']['_0'])
                index=next(i for i,s in enumerate(self.project['revisions'][0]['scenes']) if s['id']==scene['id'])
                scene['simulationRecording']=dict(recordedFPS=30,recordedSpeed=1,recordedPauseFrames=0,recordedDurationFrames=510,
                                                   knowledgeTrace=deepcopy(self.recorded['sources'][index]['trace']))
            elif 'replaceScene' in edit:
                index=next(i for i,s in enumerate(new['scenes']) if s['id']==edit['replaceScene']['_0'])
                new['scenes'][index]=deepcopy(edit['replaceScene']['_1'])
            else:
                raise AssertionError('unexpected synthetic mutation')
        self.project['revisions'].append(new)
        return dict(ok=True,state='needs_review',project_id=self.project['id'],revision=new['id'])


class KnowledgeStoryTests(unittest.TestCase):
    def test_speak_uses_only_actual_executed_action_and_resulting_state_labels(self):
        project,plan,recorded,_=fixture()
        plan['beats'][0]['visual']['kind']='speak';plan['beats'][3]['visual']['kind']='speak'
        scene=compile_presentation(project,plan,recorded)['edit_body']['edits'][0]['replaceScene']['_1']
        actions={row['id']:row for row in scene['storyActions']}
        self.assertEqual(actions['inspect']['text'],'提出交换')
        self.assertEqual(actions['changed']['text'],'已交换')
        self.assertNotIn('quantity',actions['changed'])
        plan['beats'][3]['visual']['text']='伪造的新结果'
        with self.assertRaises(KnowledgeStoryError):compile_presentation(project,plan,recorded)

    def test_speak_rejects_missing_or_overlong_actual_model_labels(self):
        for label in ('', '字'*49):
            project,plan,recorded,_=fixture();plan['beats'][0]['visual']['kind']='speak'
            for declaration,source in zip(plan['sources'],recorded['sources']):
                declaration['model']['ruleTable']['actions'][0]['label']=label
                source['model']['ruleTable']['actions'][0]['label']=label
            with self.assertRaisesRegex(KnowledgeStoryError,'spoken labels'):compile_presentation(project,plan,recorded)

    def test_requested_only_rejections_and_diagnostic_order_are_not_behavior(self):
        _,_,recorded,_=fixture()
        before=deepcopy(recorded['sources'][0]['trace']);after=deepcopy(before)
        for event in before['events']:
            for actor in event['actors']:
                actor.pop('executedActionID',None);actor['cost']=0;actor['requestedActionID']='unfunded-offer';actor['choice']='blocked'
        after=deepcopy(before)
        for event in after['events']:
            event['actors'].reverse()
            for actor in event['actors']:
                actor['requestedActionID']='another-unfunded-request';actor['choice']='another-rejection'
            for transfer in event['ruleExecution']['transfers']:
                transfer['ruleID']='renamed-rule'
        self.assertFalse(_behavior_changed(before,after))
        after['events'][2]['actors'][0]['executedActionID']='wait'
        self.assertTrue(_behavior_changed(before,after))

    def test_arbitrary_native_sources_generate_owned_flows_states_and_routes(self):
        project,plan,recorded,_=fixture();old=deepcopy((project,plan,recorded))
        result=compile_presentation(project,plan,recorded)
        scene=result['edit_body']['edits'][0]['replaceScene']['_1']
        actions={row['id']:row for row in scene['storyActions']}
        bindings={row['actionID']:row for row in scene['storyCausality']['bindings']}
        self.assertEqual(actions['deposit']['quantity'],1);self.assertEqual(actions['money']['quantity'],3)
        self.assertEqual(actions['money']['waypoints'],[dict(x=.6,y=.4)])
        self.assertEqual(bindings['changed']['fromStateID'],'open');self.assertEqual(bindings['changed']['toStateID'],'agreed')
        self.assertEqual(scene['storyCausality']['sources'],recorded['sources'])
        self.assertEqual((project,plan,recorded),old)
        self.assertNotIn('available_assets',str(plan));self.assertNotIn('inventory',str(plan))

    def test_pencil_reuses_the_same_actions_without_a_game_or_second_interpreter(self):
        project,plan,recorded,_=fixture('pencil')
        result=compile_presentation(project,plan,recorded)
        scene=result['edit_body']['edits'][0]['replaceScene']['_1']
        self.assertEqual(scene['kind'],'图文讲解');self.assertNotIn('gameWorld',scene)
        self.assertEqual(len(scene['storyActions']),5)

    def test_each_story_detail_and_each_shot_use_must_have_a_real_compiled_beat(self):
        project,plan,recorded,_=fixture();plan['beats']=[beat for beat in plan['beats'] if beat['id']!='changed']
        with self.assertRaisesRegex(KnowledgeStoryError,'every evaluated story detail'):compile_presentation(project,plan,recorded)
        project,plan,recorded,_=fixture()
        old=StoryPlan.from_dict(plan['story']);shots=old.stage('shots')
        # Split the result shot into two independently declared uses of the
        # same evaluated detail. One pre-existing compiled beat is insufficient.
        original=shots['shots'][2];first=deepcopy(original);first['duration_frames']=60
        later=deepcopy(original);later.update(id='second-result-shot',start_frame=300,duration_frames=60)
        shots['shots'][2:3]=[first,later]
        rebuilt=StoryPlan(old.to_dict()['brief'])
        for stage in ('cast','outline','details','shots'):
            rebuilt=rebuilt.accept(stage,shots if stage=='shots' else old.stage(stage),rebuilt.fingerprint)
        plan['story']=rebuilt.to_dict();project['revisions'][0]['scenes'][0]['narration']='双方同意才交换。'*5
        plan['beats'][3].update(start_frame=281,end_frame=295)
        with self.assertRaisesRegex(KnowledgeStoryError,'every shot action'):compile_presentation(project,plan,recorded)

    def test_recording_uses_one_normal_dry_cas_then_exact_query_and_compare(self):
        _,plan,recorded,source=fixture();spy=NativeBoundary(source,recorded)
        output=record_sources(source,plan,spy)
        self.assertEqual(output,recorded)
        self.assertEqual([row[0] for row in spy.calls],['edit apply','edit apply','projects list','knowledge compare'])
        self.assertTrue(spy.calls[0][2]);self.assertFalse(spy.calls[1][2])
        self.assertEqual(spy.project['revisions'][0],source['revisions'][0])
        self.assertTrue(all('recordSimulation' in edit for edit in spy.calls[1][1]['edits']))
        latest=deepcopy(spy.project);spy.calls=[]
        self.assertEqual(record_sources(latest,plan,spy),recorded)
        self.assertEqual([row[0] for row in spy.calls],['edit apply','projects list','knowledge compare'])
        self.assertTrue(spy.calls[0][2]);self.assertTrue(all('confirmSimulationRecording' in edit for edit in spy.calls[0][1]['edits']))
        self.assertEqual(spy.project,latest)

    def test_native_source_failure_stops_before_mutation_or_fabrication(self):
        _,plan,recorded,source=fixture();spy=NativeBoundary(source,recorded);spy.reject=True
        with self.assertRaises(KnowledgeStoryError):record_sources(source,plan,spy)
        self.assertEqual(len(spy.calls),1);self.assertTrue(spy.calls[0][2]);self.assertEqual(spy.project,source)

    def test_actual_presentation_dry_cas_and_refreshed_plan_are_idempotent(self):
        project,plan,recorded,_=fixture();spy=NativeBoundary(project,recorded)
        result=apply_presentation(project,plan,recorded,spy)
        self.assertTrue(result['changed']);self.assertEqual(result['revision'],'target-v2')
        self.assertEqual(len(spy.calls),3);self.assertEqual(spy.calls[0][0],'projects list');self.assertTrue(spy.calls[1][2]);self.assertFalse(spy.calls[2][2])
        plan['target']['base_revision']='target-v2';latest=deepcopy(spy.project);spy.calls=[]
        result=apply_presentation(latest,plan,recorded,spy)
        self.assertFalse(result['changed']);self.assertEqual([call[0] for call in spy.calls],['projects list']);self.assertEqual(spy.project,latest)
        self.assertEqual(latest['revisions'][0],project['revisions'][0])

    def test_native_presentation_rejects_before_real_cas(self):
        project,plan,recorded,_=fixture();spy=NativeBoundary(project,recorded);spy.reject=True
        with self.assertRaises(ValueError):apply_presentation(project,plan,recorded,spy)
        self.assertEqual(len(spy.calls),1);self.assertEqual(spy.calls[0][0],'projects list')

    def test_apply_verifies_real_source_project_revision_scene_and_persisted_trace(self):
        for mutate in [lambda spy:spy.source.update(id='invented-source'),
                       lambda spy:spy.source['revisions'][0].update(id='invented-revision'),
                       lambda spy:spy.source['revisions'][0]['scenes'][0].update(id='invented-scene'),
                       lambda spy:spy.source['revisions'][0]['scenes'][0]['simulationRecording']['knowledgeTrace']['events'][2]['actors'][0].update(resources=99)]:
            project,plan,recorded,_=fixture();spy=NativeBoundary(project,recorded);mutate(spy)
            with self.assertRaises(KnowledgeStoryError):apply_presentation(project,plan,recorded,spy)
            self.assertEqual([call[0] for call in spy.calls],['projects list'])
            self.assertEqual(spy.project,project)
        project,plan,recorded,_=fixture();spy=NativeBoundary(project,recorded)
        later=deepcopy(spy.source['revisions'][0]);later['id']='later-unrelated-source-revision';spy.source['revisions'].append(later)
        self.assertTrue(apply_presentation(project,plan,recorded,spy)['changed'])

    def test_source_identity_readback_does_not_replace_native_presentation_validation(self):
        project,plan,recorded,_=fixture();spy=NativeBoundary(project,recorded)
        def reject_edit(command,body,dry):
            if command=='edit apply':
                spy.calls.append((command,deepcopy(body),dry));return dict(ok=False,state='error')
            return spy(command,body,dry)
        with self.assertRaises(ValueError):apply_presentation(project,plan,recorded,reject_edit)
        self.assertEqual([call[0] for call in spy.calls],['projects list','edit apply']);self.assertTrue(spy.calls[-1][2])

    def test_requested_but_unfunded_action_is_not_a_performed_action(self):
        project,plan,recorded,_=fixture()
        event=recorded['sources'][0]['trace']['events'][2]
        event['actors'][0].pop('executedActionID');event['actors'][0]['requestedActionID']='offer'
        with self.assertRaises(KnowledgeStoryError):compile_presentation(project,plan,recorded)

    def test_matched_rule_without_applied_transfer_cannot_show_money(self):
        project,plan,recorded,_=fixture();event=recorded['sources'][0]['trace']['events'][5]
        event['ruleExecution']['transfers']=[];event['ruleExecution']['matches']=[dict(ruleID='swap',facts=[])]
        with self.assertRaises(KnowledgeStoryError):compile_presentation(project,plan,recorded)

    def test_both_transfer_endpoints_and_deposit_source_are_owned(self):
        for index,field,value in [(1,'subject_id','person-grower'),(2,'subject_id','person-grower')]:
            project,plan,recorded,_=fixture();plan['beats'][index][field]=value
            with self.assertRaises(KnowledgeStoryError):compile_presentation(project,plan,recorded)
        project,plan,recorded,_=fixture();plan['beats'][2]['visual']['target_subject_id']='person-weaver'
        with self.assertRaises(KnowledgeStoryError):compile_presentation(project,plan,recorded)
        project,plan,recorded,_=fixture();plan['actors'].append(dict(actor_id='grower',subject_id='coin-weaver'))
        with self.assertRaises(KnowledgeStoryError):compile_presentation(project,plan,recorded)

    def test_transfer_amount_is_read_from_the_actual_unique_flow_and_never_supplied(self):
        project,plan,recorded,_=fixture();plan['beats'][2]['effect']['amount']=9
        with self.assertRaises(KnowledgeStoryError):compile_presentation(project,plan,recorded)
        project,plan,recorded,_=fixture();flows=recorded['sources'][0]['trace']['events'][5]['ruleExecution']['transfers'];flows.append(deepcopy(flows[0]))
        with self.assertRaises(KnowledgeStoryError):compile_presentation(project,plan,recorded)
        for amount in (0,10000):
            project,plan,recorded,_=fixture();recorded['sources'][0]['trace']['events'][5]['ruleExecution']['transfers'][0]['amount']=amount
            with self.assertRaises(KnowledgeStoryError):compile_presentation(project,plan,recorded)

    def test_one_actual_transfer_cannot_be_claimed_twice(self):
        project,plan,recorded,_=fixture();extra=deepcopy(plan['beats'][2]);extra.update(id='money-again',start_frame=311,end_frame=330,requires=[])
        plan['beats'].insert(4,extra)
        with self.assertRaises(KnowledgeStoryError):compile_presentation(project,plan,recorded)

    def test_detail_dependencies_cannot_be_dropped_by_removing_beat_requires(self):
        project,plan,recorded,_=fixture()
        plan['beats'][3].update(start_frame=241,end_frame=249,requires=[])
        with self.assertRaisesRegex(KnowledgeStoryError,'all evaluated detail prerequisites'):compile_presentation(project,plan,recorded)

    def test_same_source_movement_must_continue_and_cross_source_reset_is_not_implicit(self):
        project,plan,recorded,_=fixture();plan['beats'][2]['visual']['from_anchor']='left'
        with self.assertRaisesRegex(KnowledgeStoryError,'previous actual endpoint'):compile_presentation(project,plan,recorded)
        project,plan,recorded,_=fixture()
        plan['beats'][4].update(subject_id='coin-weaver',effect=dict(kind='performedAction',actor_id='weaver',action_key='offer'),
                                visual=dict(kind='move',from_anchor='right',to_anchor='left'))
        old=StoryPlan.from_dict(plan['story']);details=old.stage('details')
        details['actions'][4].update(actor_id='weaver',event_refs=[dict(source_id='retain',tick=4,rule_id='offer')])
        rebuilt=StoryPlan(old.to_dict()['brief'])
        for stage in ('cast','outline','details','shots'):
            rebuilt=rebuilt.accept(stage,details if stage=='details' else old.stage(stage),rebuilt.fingerprint)
        plan['story']=rebuilt.to_dict()
        with self.assertRaisesRegex(KnowledgeStoryError,'cross-source movement'):compile_presentation(project,plan,recorded)

    def test_incorrect_native_state_and_false_outcome_are_rejected(self):
        project,plan,recorded,_=fixture();plan['beats'][3]['effect']['to_state_id']='sold'
        with self.assertRaises(KnowledgeStoryError):compile_presentation(project,plan,recorded)

    def test_state_change_cannot_borrow_another_story_actor(self):
        project,plan,recorded,_=fixture()
        old=StoryPlan.from_dict(plan['story']);details=old.stage('details');details['actions'][3]['actor_id']='grower'
        rebuilt=StoryPlan(old.to_dict()['brief'])
        for stage in ('cast','outline','details','shots'):
            rebuilt=rebuilt.accept(stage,details if stage=='details' else old.stage(stage),rebuilt.fingerprint)
        plan['story']=rebuilt.to_dict()
        with self.assertRaisesRegex(KnowledgeStoryError,'actual story actor'):compile_presentation(project,plan,recorded)

    def test_source_time_cannot_go_backwards_without_explicit_dependencies(self):
        project,plan,recorded,_=fixture()
        # A late occurrence of the earlier native debit remains in the same
        # valid shot; dependency removal must not create an implicit flashback.
        plan['beats'][2]['effect']=dict(kind='performedAction',actor_id='weaver',action_key='offer')
        plan['beats'][2]['event']=dict(round=1,phase=PHASES[2]);plan['beats'][2]['visual']=dict(kind='show')
        plan['beats'][2]['subject_id']='person-weaver';plan['beats'][2]['requires']=[]
        plan['beats'][2].update(start_frame=320,end_frame=340)
        plan['beats'][3]['requires']=[]
        old=StoryPlan.from_dict(plan['story']);details=old.stage('details');details['actions'][2]['event_refs']=[dict(source_id='exchange',tick=4,rule_id='offer')]
        details['actions'][3]['depends_on']=[]
        rebuilt=StoryPlan(old.to_dict()['brief'])
        for stage in ('cast','outline','details','shots'):
            rebuilt=rebuilt.accept(stage,details if stage=='details' else old.stage(stage),rebuilt.fingerprint)
        plan['story']=rebuilt.to_dict()
        with self.assertRaisesRegex(KnowledgeStoryError,'cannot run backwards'):compile_presentation(project,plan,recorded)
        project,plan,recorded,_=fixture()
        plan['balances']=[dict(source_id='exchange',event=dict(round=1,phase=PHASES[0]),actor_id='weaver',entity_id='person-weaver',frame=350)]
        with self.assertRaisesRegex(KnowledgeStoryError,'cannot run backwards'):compile_presentation(project,plan,recorded)
        project,plan,recorded,_=fixture();plan['beats'][3]['effect']=dict(kind='outcome',outcome=True)
        with self.assertRaises(KnowledgeStoryError):compile_presentation(project,plan,recorded)

    def test_windows_future_dependencies_and_scene_local_axis_are_strict(self):
        mutations=[lambda p:p['beats'][2].update(start_frame=359,end_frame=370),lambda p:p['beats'][1].update(requires=['money']),
                   lambda p:p['beats'][4].update(requires=['money']),lambda p:p['beats'][2].update(start_frame=155,end_frame=180),
                   lambda p:p['beats'][3].update(start_frame=270,end_frame=300)]
        for mutate in mutations:
            project,plan,recorded,_=fixture();mutate(plan)
            with self.assertRaises(KnowledgeStoryError):compile_presentation(project,plan,recorded)
        project,plan,recorded,_=fixture();project['revisions'][-1]['scenes'][0]['speed']=1.2
        with self.assertRaises(KnowledgeStoryError):compile_presentation(project,plan,recorded)

    def test_story_detail_event_and_actual_narration_must_match(self):
        for mutate in [lambda p:p['beats'][2].update(detail_id='changed'),lambda p:p['beats'][2].update(shot_id='shot-choice'),
                       lambda p:p['beats'][2]['event'].update(round=2)]:
            project,plan,recorded,_=fixture();mutate(plan)
            with self.assertRaises(KnowledgeStoryError):compile_presentation(project,plan,recorded)
        project,plan,recorded,_=fixture();project['revisions'][0]['scenes'][0]['narration']='不能套用别的故事原音'
        with self.assertRaises(KnowledgeStoryError):compile_presentation(project,plan,recorded)

    def test_balance_comes_from_the_actual_actor_and_merges_existing_update(self):
        project,plan,recorded,_=fixture();scene=project['revisions'][0]['scenes'][0]
        scene['gameWorld']['updates']=[dict(frame=315,entityID='person-weaver',visible=True)]
        plan['balances']=[dict(source_id='exchange',event=dict(round=1,phase=PHASES[5]),actor_id='weaver',entity_id='person-weaver',frame=315)]
        result=compile_presentation(project,plan,recorded)
        updates=result['edit_body']['edits'][0]['replaceScene']['_1']['gameWorld']['updates']
        self.assertEqual(updates,[dict(frame=315,entityID='person-weaver',visible=True,value=9)])
        scene['gameWorld']['updates'][0]['value']=999
        with self.assertRaises(KnowledgeStoryError):compile_presentation(project,plan,recorded)
        scene['gameWorld']['updates'][0].pop('value');plan['balances'][0]['frame']=250
        with self.assertRaises(KnowledgeStoryError):compile_presentation(project,plan,recorded)

    def test_corrupt_or_partial_sources_and_wrong_final_balances_are_rejected(self):
        for mutate in [lambda r:r['sources'][0]['trace']['events'].pop(),lambda r:r['sources'][0]['trace'].update(seed=24),
                       lambda r:r['sources'][0]['trace']['finalResources'][0].update(resources=999),
                       lambda r:r['sources'][0]['trace']['events'][0].update(tick=0)]:
            project,plan,recorded,_=fixture();mutate(recorded)
            with self.assertRaises(KnowledgeStoryError):compile_presentation(project,plan,recorded)

    def test_v1_v2_payment_delivery_and_rule_change_branches_are_explicitly_rejected(self):
        for version in (1,2):
            project,plan,recorded,_=fixture();plan['sources'][0]['model']['version']=version
            with self.assertRaisesRegex(KnowledgeStoryError,'v3'):compile_presentation(project,plan,recorded)
        for kind in ('payment','delivery'):
            project,plan,recorded,_=fixture();plan['beats'][2]['effect']['kind']=kind
            with self.assertRaisesRegex(KnowledgeStoryError,'unsupported effect'):compile_presentation(project,plan,recorded)
        project,plan,recorded,_=fixture();plan['sources'][1]['model']['threshold']=2
        with self.assertRaisesRegex(KnowledgeStoryError,'one actor-plan'):compile_presentation(project,plan,recorded)

    def test_source_project_is_separate_and_frozen_before_any_native_call(self):
        _,plan,recorded,source=fixture();source['id']='target-project';spy=NativeBoundary(source,recorded)
        with self.assertRaises(KnowledgeStoryError):record_sources(source,plan,spy)
        self.assertEqual(spy.calls,[])
        _,plan,recorded,source=fixture();source['revisions'][0]['scenes'][0]['simulation']['knowledge']['threshold']=2;spy=NativeBoundary(source,recorded)
        with self.assertRaises(KnowledgeStoryError):record_sources(source,plan,spy)
        self.assertEqual(spy.calls,[])

    def test_unknown_fields_nonfinite_anchors_stale_revisions_and_hidden_recipients_rejected(self):
        for mutate in [lambda p:p.update(arbitrary_shell='no'),lambda p:p['anchors']['left'].update(x=float('nan')),
                       lambda p:p['target'].update(base_revision='old'),lambda p:p['beats'][0]['visual'].update(target_subject_id='pool')]:
            project,plan,recorded,_=fixture();mutate(plan)
            with self.assertRaises(KnowledgeStoryError):compile_presentation(project,plan,recorded)


if __name__=='__main__':
    unittest.main()
