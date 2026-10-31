"""Delivery/payment adapter rules, using literal SYNTHETIC observations only.

These fixtures do not execute a model and cannot establish native/Core truth,
audio/media quality or human review. Production still requires normal recording
and Core's independent complete-trace verification. The existing story tests
retain responsibility for the old wire/digest compatibility contract.
"""
from copy import deepcopy
import unittest

from knowledge_story import KnowledgeStoryError, PHASES, compile_presentation
from story_planning import StoryPlan
from test_knowledge_story import fixture


def rebuild_story(plan, change):
    """Reaccept changed author content instead of forging its parent digests."""
    old = StoryPlan.from_dict(plan['story'])
    brief = old.to_dict()['brief']
    stages = {name: old.stage(name) for name in ('cast', 'outline', 'details', 'shots')}
    change(brief, stages)
    story = StoryPlan(brief)
    for name, content in stages.items():
        story = story.accept(name, content, story.fingerprint)
    plan['story'] = story.to_dict()


def delivery_fixture(mode='game', price=3):
    """A literal two-round observation: one delivered good, then buyer pays.

    No fake invoke or Python rule evaluation is supplied. This fixture only
    exercises the adapter against declared observations of the supported shape.
    """
    project, plan, recorded, _ = fixture(mode)
    source = plan['sources'][0]
    source['end_frame'] = 480
    model = source['model']
    model['knowledgeLabel'] = '交货之后付款的有限教学规则'
    for action in model['ruleTable']['actions']:
        action['cost'] = 0
    model['ruleTable']['rules'] = [
        dict(id='delivered', label='交出一件货物',
             conditions=[dict(kind='round', minimum=1, maximum=1)],
             effects=[dict(kind='setState', actorID='weaver', stateID='agreed')]),
        dict(id='sale', label='买家交货后付款',
             conditions=[dict(kind='round', minimum=2, maximum=2),
                         dict(kind='state', actorID='weaver', stateID='agreed')],
             effects=[dict(kind='transfer', sourceActorID='grower',
                           destinationActorID='weaver', amount=price)])]
    plan['sources'] = [source]
    observed = recorded['sources'][0]
    observed.update(model=deepcopy(model), endFrame=480)
    for event in observed['trace']['events']:
        settled = event['round'] == 2 and event['phase'] == PHASES[5]
        delivered = event['round'] == 2 or event['phase'] == PHASES[5]
        for actor in event['actors']:
            actor.update(cost=0, resources=(12 + price if actor['id'] == 'weaver' else 8 - price)
                         if settled else (12 if actor['id'] == 'weaver' else 8),
                         ruleStateID='agreed' if actor['id'] == 'weaver' and delivered else 'open')
        execution = event['ruleExecution']
        execution.update(poolBefore=2, poolAfter=2, deposits=0, matches=[], transfers=[], stateChanges=[])
        if event['round'] == 1 and event['phase'] == PHASES[5]:
            execution['stateChanges'] = [dict(ruleID='delivered', actorID='weaver',
                beforeStateID='open', afterStateID='agreed')]
        if settled:
            execution['transfers'] = [dict(ruleID='sale', sourceActorID='grower',
                destinationActorID='weaver', amount=price)]
    observed['trace']['finalResources'] = [dict(id=a['id'], resources=a['resources'])
                                          for a in observed['trace']['events'][-1]['actors']]
    recorded['sources'] = [observed]
    scene = project['revisions'][-1]['scenes'][0]
    subjects = [('person-weaver', 'weaver'), ('person-grower', 'grower'),
                ('good-weaver', 'weaver'), ('coin-grower', 'grower'),
                ('result-weaver', 'weaver'), ('pool', None)]
    if mode == 'game':
        scene['gameWorld']['entities'] = [dict(id=key, name=key, role='hero', x=1, y=1,
            scale=1, visible=True, renderPlane='ground' if key == 'pool' else 'world')
            for key, _ in subjects]
    else:
        scene['layers'] = [dict(id=key, kind='rectangle', locked=False,
            startFrame=0, endFrame=480) for key, _ in subjects]
    plan['actors'] = [dict(actor_id=actor, subject_id=key) for key, actor in subjects if actor]
    texts = ['卖家想卖货，买家需要货。', '先把货交到买家手里。', '买家收到货后再付钱。', '交货与收钱是两个过程。']
    scene['narration'] = ''.join(texts)
    brief = dict(version=1, title='先交货，再付款', knowledge_goal='看清交货和付款的顺序与不同方向',
        viewer_question='钱为什么要在交货之后给？', context='两名参与者按明确的教学规则交易',
        boundary='一次一件货物，价格仅为教学设定；合成测试观察不是原生录制', source_ids=['exchange'])
    cast = dict(actors=[dict(id=key, name=name, role=role, motive=motive, goal=goal,
        expected_benefit=benefit, stake='实际交接前仍持有自己的物件')
        for key, name, role, motive, goal, benefit in [
            ('weaver', '织工', '卖家', '有一件可交付货物', '交货后取得货款', '实际规则结算的货款'),
            ('grower', '菜农', '买家', '需要卖家的货物', '收到货物后付款', '取得一件货物')]],
        objects=[dict(id='good', name='一件货物', description='卖家持有的一件独立货物', purpose='表现完整交货'),
                 dict(id='coin', name='货款', description='买家持有的独立钱币', purpose='表现实际结算金额')])
    outline = dict(beats=[dict(id=key, purpose=purpose, question=brief['viewer_question'], change=text,
        actor_ids=['weaver', 'grower'], depends_on=[] if i == 0 else [previous], source_ids=['exchange'])
        for i, (key, purpose, previous, text) in enumerate([
            ('setup', 'setup', '', texts[0]), ('choice', 'choice', 'setup', texts[1]),
            ('result', 'consequence', 'choice', texts[2]), ('end', 'conclusion', 'result', texts[3])])])
    rows = [('inspect', 'setup', 'weaver', 'react', None, 4, 'offer', []),
            ('delivered', 'choice', 'weaver', 'deliver', 'grower', 7, 'delivered', ['inspect']),
            ('paid', 'result', 'grower', 'pay', 'weaver', 16, 'sale', ['delivered']),
            ('end', 'end', 'grower', 'react', None, 16, 'outcome', ['paid'])]
    details = dict(actions=[dict(id=key, beat_id=beat, actor_id=actor, verb=verb,
        object_ids=['good' if key == 'delivered' else 'coin'],
        visible_start='各自仍持有自己负责的物件', visible_process='物件沿明确路线递到另一角色处',
        visible_end='接收角色取得该次真实交付的物件', depends_on=dependencies,
        event_refs=[dict(source_id='exchange', tick=tick, rule_id=rule)],
        **(dict(recipient_id=recipient) if recipient else {}))
        for key, beat, actor, verb, recipient, tick, rule, dependencies in rows])
    shots = dict(shots=[dict(id='shot-' + beat['id'], beat_id=beat['id'], start_frame=i*120,
        duration_frames=120, visual_goal=beat['change'], narration=texts[i],
        action_ids=[row['id'] for row in details['actions'] if row['beat_id'] == beat['id']],
        asset_names=['独立人物货物与货款']) for i, beat in enumerate(outline['beats'])],
        asset_requirements=[dict(name='独立人物货物与货款', description='分别可编辑的买卖双方、一件货物与钱币',
            style='采用当前已有真实风格素材', transparent=True)])
    story = StoryPlan(brief)
    for stage, content in zip(('cast', 'outline', 'details', 'shots'), (cast, outline, details, shots)):
        story = story.accept(stage, content, story.fingerprint)
    plan['story'] = story.to_dict()
    plan['beats'] = [
        dict(id='inspect', detail_id='inspect', shot_id='shot-setup', source_id='exchange',
             event=dict(round=1, phase=PHASES[2]), effect=dict(kind='performedAction', actor_id='weaver', action_key='offer'),
             subject_id='person-weaver', start_frame=10, end_frame=40, requires=[], visual=dict(kind='show')),
        dict(id='delivered', detail_id='delivered', shot_id='shot-choice', source_id='exchange',
             event=dict(round=1, phase=PHASES[5]), effect=dict(kind='delivery', actor_id='weaver', to_actor_id='grower',
                 rule_id='delivered', from_state_id='open', to_state_id='agreed'),
             subject_id='good-weaver', start_frame=130, end_frame=160, requires=['inspect'],
             visual=dict(kind='transfer', target_subject_id='person-grower', from_anchor='left', to_anchor='right', via_anchors=['upper'])),
        dict(id='paid', detail_id='paid', shot_id='shot-result', source_id='exchange',
             event=dict(round=2, phase=PHASES[5]), effect=dict(kind='payment', rule_id='sale', from_actor_id='grower', to_actor_id='weaver'),
             subject_id='coin-grower', start_frame=250, end_frame=280, requires=['delivered'],
             visual=dict(kind='transfer', target_subject_id='person-weaver', from_anchor='right', to_anchor='left')),
        dict(id='end', detail_id='end', shot_id='shot-end', source_id='exchange',
             event=dict(round=2, phase=PHASES[5]), effect=dict(kind='outcome', outcome=False),
             subject_id='result-weaver', start_frame=375, end_frame=410, requires=['paid'], visual=dict(kind='show'))]
    return project, plan, recorded


class KnowledgeDeliveryTests(unittest.TestCase):
    def test_game_and_pencil_compile_one_good_and_observed_price_without_mutation(self):
        for mode in ('game', 'pencil'):
            with self.subTest(mode=mode):
                project, plan, recorded = delivery_fixture(mode, price=7)
                before = deepcopy((project, plan, recorded))
                compiled = compile_presentation(project, plan, recorded)
                entry = compiled['story_spec']['scenes'][0]
                actions = {row['id']: row for row in entry['actions']}
                bindings = {row['actionID']: row for row in entry['causality']['bindings']}
                self.assertEqual(actions['delivered']['quantity'], 1)
                self.assertEqual(actions['delivered']['targetID'], 'person-grower')
                self.assertEqual(actions['paid']['quantity'], 7)
                self.assertEqual(bindings['paid']['amount'], 7)
                self.assertEqual(bindings['paid']['requires'], ['delivered'])
                self.assertNotIn('amount', bindings['delivered'])
                self.assertEqual(entry['causality']['sources'], recorded['sources'])
                self.assertEqual((project, plan, recorded), before)
                if mode == 'game':
                    self.assertEqual(entry['world']['entities'], project['revisions'][-1]['scenes'][0]['gameWorld']['entities'])

    def test_author_cannot_supply_delivery_quantity_or_payment_amount(self):
        for index, field in ((1, 'quantity'), (2, 'amount')):
            with self.subTest(field=field):
                project, plan, recorded = delivery_fixture()
                plan['beats'][index]['effect'][field] = 9
                with self.assertRaisesRegex(KnowledgeStoryError, 'unsupported knowledge-story fields'):
                    compile_presentation(project, plan, recorded)

    def test_matched_rules_and_final_state_cannot_replace_applied_delivery(self):
        project, plan, recorded = delivery_fixture()
        event = recorded['sources'][0]['trace']['events'][5]
        event['ruleExecution']['stateChanges'] = []
        event['ruleExecution']['matches'] = [dict(ruleID='delivered')]
        with self.assertRaisesRegex(KnowledgeStoryError, 'unique applied native transition'):
            compile_presentation(project, plan, recorded)

    def test_matched_but_unapplied_or_ambiguous_payment_cannot_move_money(self):
        for issue in ('absent', 'duplicate', 'zero'):
            with self.subTest(issue=issue):
                project, plan, recorded = delivery_fixture()
                execution = recorded['sources'][0]['trace']['events'][-1]['ruleExecution']
                execution['matches'] = [dict(ruleID='sale')]
                if issue == 'absent':
                    execution['transfers'] = []
                elif issue == 'duplicate':
                    execution['transfers'] *= 2
                else:
                    execution['transfers'][0]['amount'] = 0
                with self.assertRaisesRegex(KnowledgeStoryError, 'unique applied positive native route'):
                    compile_presentation(project, plan, recorded)

    def test_visual_order_does_not_authorize_payment_in_the_same_source_tick(self):
        project, plan, recorded = delivery_fixture()
        plan['beats'][2]['event']['round'] = 1
        first = recorded['sources'][0]['trace']['events'][5]['ruleExecution']
        first['transfers'] = deepcopy(recorded['sources'][0]['trace']['events'][-1]['ruleExecution']['transfers'])
        def change(_brief, stages):
            stages['details']['actions'][2]['event_refs'][0]['tick'] = 7
        rebuild_story(plan, change)
        with self.assertRaisesRegex(KnowledgeStoryError, 'earlier actual source event'):
            compile_presentation(project, plan, recorded)

    def test_payment_cannot_drop_delivery_or_its_evaluated_story_prerequisite(self):
        for issue in ('action', 'story', 'both'):
            with self.subTest(issue=issue):
                project, plan, recorded = delivery_fixture()
                if issue in ('action', 'both'):
                    plan['beats'][2]['requires'] = []
                if issue in ('story', 'both'):
                    rebuild_story(plan, lambda _brief, stages: stages['details']['actions'][2].update(depends_on=[]))
                expected = 'absent from the evaluated story detail' if issue == 'story' else 'payment must depend'
                with self.assertRaisesRegex(KnowledgeStoryError, expected):
                    compile_presentation(project, plan, recorded)

    def test_payment_cannot_depend_on_another_branch_delivery(self):
        project, plan, recorded = delivery_fixture()
        child = deepcopy(plan['sources'][0])
        child.update(id='other', scene_id='other-source', parent_id='exchange', start_frame=240)
        child['model']['ruleTable']['plans'][1]['defaultActionID'] = 'wait'
        child['intervention'] = dict(actorID='grower', plan=deepcopy(child['model']['ruleTable']['plans'][1]))
        plan['sources'][0]['end_frame'] = 240
        plan['sources'].append(child)
        recorded['sources'][0]['endFrame'] = 240
        observed = deepcopy(recorded['sources'][0])
        observed.update(id='other', model=deepcopy(child['model']), startFrame=240, endFrame=480,
            parentID='exchange', intervention=deepcopy(child['intervention']))
        recorded['sources'].append(observed)
        for beat in plan['beats'][2:]:
            beat['source_id'] = 'other'
        def change(brief, stages):
            brief['source_ids'].append('other')
            for beat in stages['outline']['beats'][2:]:
                beat['source_ids'] = ['other']
            for detail in stages['details']['actions'][2:]:
                detail['event_refs'][0]['source_id'] = 'other'
        rebuild_story(plan, change)
        with self.assertRaisesRegex(KnowledgeStoryError, 'another branch'):
            compile_presentation(project, plan, recorded)

    def test_reverse_money_route_cannot_be_called_payment_for_this_delivery(self):
        project, plan, recorded = delivery_fixture()
        payment = plan['beats'][2]
        payment['effect'].update(from_actor_id='weaver', to_actor_id='grower')
        payment.update(subject_id='good-weaver')
        payment['visual'].update(target_subject_id='person-grower', from_anchor='right', to_anchor='left')
        recorded['sources'][0]['trace']['events'][-1]['ruleExecution']['transfers'][0].update(
            sourceActorID='weaver', destinationActorID='grower')
        rebuild_story(plan, lambda _brief, stages: stages['details']['actions'][2].update(actor_id='weaver', recipient_id='grower'))
        with self.assertRaisesRegex(KnowledgeStoryError, 'this payee to this payer'):
            compile_presentation(project, plan, recorded)

    def test_delivery_requires_owned_good_and_matching_distinct_story_recipient(self):
        for issue in ('owner', 'recipient', 'same-actor', 'pool'):
            with self.subTest(issue=issue):
                project, plan, recorded = delivery_fixture()
                beat = plan['beats'][1]
                if issue == 'owner':
                    beat['subject_id'] = 'coin-grower'
                elif issue == 'recipient':
                    rebuild_story(plan, lambda _brief, stages: stages['details']['actions'][1].pop('recipient_id'))
                elif issue == 'same-actor':
                    beat['effect']['to_actor_id'] = 'weaver'
                else:
                    beat['visual']['target_subject_id'] = 'pool'
                with self.assertRaises(KnowledgeStoryError):
                    compile_presentation(project, plan, recorded)

    def test_payment_story_recipient_must_be_the_actual_payee(self):
        project, plan, recorded = delivery_fixture()
        def change(_brief, stages):
            observer = deepcopy(stages['cast']['actors'][0])
            observer.update(id='observer', name='旁观者', role='不参与结算的旁观者')
            stages['cast']['actors'].append(observer)
            stages['details']['actions'][2]['recipient_id'] = 'observer'
        rebuild_story(plan, change)
        with self.assertRaisesRegex(KnowledgeStoryError, 'actual payee'):
            compile_presentation(project, plan, recorded)

    def test_one_native_delivery_transition_cannot_create_two_goods(self):
        project, plan, recorded = delivery_fixture()
        duplicate = deepcopy(plan['beats'][1])
        duplicate.update(id='second-good', start_frame=170, end_frame=200)
        plan['beats'].insert(2, duplicate)
        with self.assertRaisesRegex(KnowledgeStoryError, 'multiple goods'):
            compile_presentation(project, plan, recorded)

    def test_same_delivery_transition_cannot_be_claimed_for_different_recipients(self):
        project, plan, recorded = delivery_fixture()
        source = plan['sources'][0]
        model = source['model']
        model['participants'].append(dict(id='potter', name='陶工', strategy='每轮出力', initialResources=5))
        third_plan = deepcopy(model['ruleTable']['plans'][1])
        third_plan.update(actorID='potter')
        third_plan['decisions'][0]['id'] = 'later-wait-potter'
        model['ruleTable']['plans'].append(third_plan)
        observed = recorded['sources'][0]
        observed['model'] = deepcopy(model)
        for event in observed['trace']['events']:
            third_actor = deepcopy(event['actors'][1])
            third_actor.update(id='potter', resources=5, ruleStateID='open')
            event['actors'].append(third_actor)
        observed['trace']['finalResources'].append(dict(id='potter', resources=5))
        scene = project['revisions'][-1]['scenes'][0]
        for identity, owner in [('person-potter', 'potter'), ('second-good-weaver', 'weaver')]:
            entity = deepcopy(scene['gameWorld']['entities'][0])
            entity.update(id=identity, name=identity)
            scene['gameWorld']['entities'].append(entity)
            plan['actors'].append(dict(actor_id=owner, subject_id=identity))
        def change(_brief, stages):
            third_actor = deepcopy(stages['cast']['actors'][1])
            third_actor.update(id='potter', name='陶工')
            stages['cast']['actors'].append(third_actor)
            second_delivery = deepcopy(stages['details']['actions'][1])
            second_delivery.update(id='second-delivered', recipient_id='potter')
            stages['details']['actions'].insert(2, second_delivery)
            stages['shots']['shots'][1]['action_ids'].append('second-delivered')
        rebuild_story(plan, change)
        duplicate = deepcopy(plan['beats'][1])
        duplicate.update(id='second-delivered', detail_id='second-delivered',
            subject_id='second-good-weaver', start_frame=170, end_frame=200)
        duplicate['effect']['to_actor_id'] = 'potter'
        duplicate['visual']['target_subject_id'] = 'person-potter'
        plan['beats'].insert(2, duplicate)
        with self.assertRaisesRegex(KnowledgeStoryError, 'one actual delivery transition'):
            compile_presentation(project, plan, recorded)

    def test_generic_transfer_and_payment_share_one_actual_money_claim(self):
        for order in ('payment-first', 'transfer-first'):
            with self.subTest(order=order):
                project, plan, recorded = delivery_fixture()
                duplicate = deepcopy(plan['beats'][2])
                duplicate.update(id='generic-money', start_frame=285, end_frame=310)
                duplicate['effect']['kind'] = 'transfer'
                if order == 'payment-first':
                    plan['beats'].insert(3, duplicate)
                else:
                    duplicate.update(start_frame=245, end_frame=249)
                    plan['beats'].insert(2, duplicate)
                with self.assertRaisesRegex(KnowledgeStoryError, 'claimed twice'):
                    compile_presentation(project, plan, recorded)


if __name__ == '__main__':
    unittest.main()
