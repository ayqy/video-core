"""Declarative delivery-before-payment plan for the normal knowledge-story API.

Core alone evaluates this finite two-round teaching agreement. The seller's
first-round delivery changes an owned parcel's state; only a later settlement
can pay the agreed three coins. The counterfactual changes one seller plan.
The caller supplies the actual stage, source scenes and normal CLI runtime.
No goods inventory, real-world value, trace or outcome is computed here.
"""
from copy import deepcopy

from story_planning import StoryPlan


PHASES = ('本轮开始', '同时选择', '实际出力与扣费', '清障判定', '通行或受阻', '收益结算')
FRAMES = 600
SUBJECTS = dict(seller='delivery-seller', buyer='delivery-buyer',
                cargo='delivery-cargo', buyer_coin='delivery-buyer-coin',
                retained_cargo='delivery-retained-cargo',
                retained_coin='delivery-retained-coin', pool='delivery-pool')


def delivery_models():
    """Declare the agreement and an otherwise identical refusal branch."""
    model = dict(version=3, knowledgeLabel='先交货后付款：同一对买卖双方的有限约定', resourceLabel='硬币',
        participants=[dict(id='seller', name='阿青', strategy='每轮出力', initialResources=0),
                      dict(id='buyer', name='阿蓝', strategy='每轮出力', initialResources=6)],
        rounds=2, roundTicks=6, startTick=0, contributionCost=0, contributionUnits=1,
        threshold=1, benefit=0,
        ruleTable=dict(version=1,
            actions=[dict(id='deliver', label='交出约定的一箱货', cost=0, pose='act'),
                     dict(id='wait', label='按约等待', cost=0, pose='idle')],
            states=[dict(id='owned', label='货物还在卖家手中', pose='idle'),
                    dict(id='delivered', label='一箱货已经送到买家', pose='act'),
                    dict(id='sold', label='卖家已经收到约定货款', pose='celebrate'),
                    dict(id='ready', label='买家等候交货', pose='idle'),
                    dict(id='paid', label='买家已经支付约定货款', pose='celebrate')],
            plans=[dict(actorID='seller', initialStateID='owned', defaultActionID='deliver',
                        cycleActionIDs=[], decisions=[dict(id='after-delivery', priority=0,
                            conditions=[dict(kind='state', actorID='seller', stateID='delivered')],
                            actionID='wait')]),
                   dict(actorID='buyer', initialStateID='ready', defaultActionID='wait',
                        cycleActionIDs=[], decisions=[])],
            initialPool=0, externalBudgetPerRound=0,
            rules=[dict(id='deliver-parcel', label='第一轮实际交出一箱货',
                conditions=[dict(kind='round', minimum=1, maximum=1),
                            dict(kind='action', actorID='seller', actionID='deliver'),
                            dict(kind='state', actorID='seller', stateID='owned')],
                effects=[dict(kind='setState', actorID='seller', stateID='delivered')]),
                   dict(id='pay-after-delivery', label='第二轮只为已交给本买家的货付款',
                conditions=[dict(kind='round', minimum=2, maximum=2),
                            dict(kind='state', actorID='seller', stateID='delivered'),
                            dict(kind='state', actorID='buyer', stateID='ready'),
                            dict(kind='resources', actorID='buyer', minimum=3, maximum=1000000)],
                effects=[dict(kind='transfer', sourceActorID='buyer', destinationActorID='seller', amount=3),
                         dict(kind='setState', actorID='seller', stateID='sold'),
                         dict(kind='setState', actorID='buyer', stateID='paid')])]))
    alternative = deepcopy(model)
    alternative['ruleTable']['plans'][0]['defaultActionID'] = 'wait'
    return dict(delivered=model, withheld=alternative)


def definitions():
    """Explicit observations, props, routes and causal prerequisites."""
    def performed(actor, action):
        return dict(kind='performedAction', actor_id=actor, action_key=action)
    def state(actor, before, after):
        return dict(kind='stateChange', actor_id=actor, rule_id='pay-after-delivery',
                    from_state_id=before, to_state_id=after)
    rows = []
    def add(identity, shot, actor, verb, source, tick, effect, subject, start, end, visual,
            process, result, requires=(), recipient=None):
        rows.append(dict(id=identity, shot=shot, actor=actor, verb=verb, source=source, tick=tick,
            effect=effect, subject=SUBJECTS[subject], start=start, end=end, visual=visual,
            process=process, result=result, requires=list(requires), recipient=recipient))
    add('ready-parcel', 'agreement', 'seller', 'take', 'delivered', 2,
        performed('seller', 'deliver'), 'cargo', 12, 36, dict(kind='show'),
        '阿青把自己的一箱货拿到交接位置', '货物仍由阿青持有，阿蓝在对面等待')
    add('deliver-parcel', 'delivery', 'seller', 'deliver', 'delivered', 5,
        dict(kind='delivery', actor_id='seller', rule_id='deliver-parcel',
             from_state_id='owned', to_state_id='delivered', to_actor_id='buyer'),
        'cargo', 96, 156,
        dict(kind='transfer', from_anchor='seller-hand', to_anchor='buyer-hand',
             via_anchors=['counter'], target_subject_id=SUBJECTS['buyer']),
        '看清一箱货从阿青手中沿交接台送到阿蓝面前', '阿蓝已经收货，阿青尚未收到货款',
        ['ready-parcel'], 'buyer')
    add('pay-for-parcel', 'payment', 'buyer', 'pay', 'delivered', 11,
        dict(kind='payment', rule_id='pay-after-delivery', from_actor_id='buyer', to_actor_id='seller'),
        'buyer_coin', 192, 234,
        dict(kind='transfer', from_anchor='buyer-hand', to_anchor='seller-hand',
             via_anchors=['payment-route'], target_subject_id=SUBJECTS['seller']),
        '交货完成后，阿蓝取出约定货款递给阿青', '钱到阿青手中，货物已经归阿蓝',
        ['deliver-parcel'], 'seller')
    # Clear only the sold-branch props using real resulting states. The other
    # branch has distinct cargo/money subjects, never a cross-source teleport.
    add('finish-cargo', 'payment', 'seller', 'react', 'delivered', 11,
        state('seller', 'delivered', 'sold'), 'cargo', 240, 250, dict(kind='hide'),
        '阿青收到货款后结束本分支货物的交接表现', '本次交货过程已经结束', ['pay-for-parcel'])
    add('finish-money', 'payment', 'buyer', 'react', 'delivered', 11,
        state('buyer', 'ready', 'paid'), 'buyer_coin', 254, 264, dict(kind='hide'),
        '阿蓝完成付款后结束本分支货款的递交表现', '保留双方实际结算余额', ['pay-for-parcel'])
    add('keep-parcel', 'contrast', 'seller', 'react', 'withheld', 2,
        performed('seller', 'wait'), 'retained_cargo', 318, 348, dict(kind='show'),
        '切到独立分支，阿青把货留在自己身边', '没有交货过程，货物仍在阿青手中')
    add('keep-money', 'contrast', 'buyer', 'react', 'withheld', 2,
        performed('buyer', 'wait'), 'retained_coin', 354, 384, dict(kind='show'),
        '阿蓝继续持有自己的硬币，等候约定的货物', '本分支没有交货，第二轮也没有付款', ['keep-parcel'])
    return rows


def story_plan():
    brief = dict(version=1, title='没交货，钱会付出去吗？',
        knowledge_goal='用真实交货状态与较晚资金流说明先交货后付款这一约定',
        viewer_question='只改卖家的选择，买家还会付款吗？',
        context='阿青带来一箱货，阿蓝愿意在收到后付三枚硬币，两人先约好交接顺序',
        boundary='有限教学协议；交货用卖家状态转换表示一件货物，不计算真实商品价值或通用库存，不授声音或整片审核',
        source_ids=['delivered', 'withheld'])
    cast = dict(actors=[
        dict(id='seller', name='阿青', role='送货的卖家', motive='想把自己的一箱货换成约定的三枚硬币',
             goal='把货交到阿蓝手中后收款', expected_benefit='收到约定的货款', stake='必须先交出自己的一箱货'),
        dict(id='buyer', name='阿蓝', role='收货的买家', motive='需要这箱货，愿意按事先约定付款',
             goal='收到这箱货后再付三枚', expected_benefit='拿到约定的一箱货', stake='付款会减少自己持有的硬币')],
        objects=[dict(id='parcel', name='阿青的一箱货', description='按分支使用不同货物道具，持有人和接收人明确', purpose='观察货物是否真正送到'),
                 dict(id='money', name='阿蓝自己的硬币', description='货款与货物独立，拒绝分支保留自己的资金道具', purpose='观察实际付款与未付款')])
    shots = [
        ('agreement', 'setup', 0, 90, '阿青送一箱货，阿蓝收货后付三枚。', '先说明双方需要什么和交接顺序', 'delivered'),
        ('delivery', 'choice', 90, 90, '阿青把货递过去，阿蓝接到了。', '看清货物从谁手里交给谁', 'delivered'),
        ('payment', 'consequence', 180, 120, '下一轮，阿蓝才把三枚货款递给阿青。', '交货完成之后才表现真实的反向资金流', 'delivered'),
        ('contrast', 'conclusion', 300, 300, '只改阿青的选择：不交货，阿蓝就不付款。', '切到独立分支，看清货和钱各自保留', 'withheld')]
    rows = definitions()
    outline = dict(beats=[dict(id=identity, purpose=purpose, question=brief['viewer_question'],
        change=goal, actor_ids=['seller', 'buyer'], depends_on=[] if index == 0 else [shots[index-1][0]],
        source_ids=[source]) for index, (identity, purpose, at, length, narration, goal, source) in enumerate(shots)])
    details = dict(actions=[dict(id=row['id'], beat_id=row['shot'], actor_id=row['actor'], verb=row['verb'],
        object_ids=['money' if row['subject'] in (SUBJECTS['buyer_coin'], SUBJECTS['retained_coin']) else 'parcel'],
        visible_start='看清当前分支、道具原持有人和约定接收人', visible_process=row['process'], visible_end=row['result'],
        depends_on=row['requires'], event_refs=[dict(source_id=row['source'], tick=row['tick'],
            rule_id=row['effect'].get('rule_id', row['effect'].get('action_key', row['effect']['kind'])))],
        **({'recipient_id': row['recipient']} if row['recipient'] else {})) for row in rows])
    content = dict(shots=[dict(id='shot-'+identity, beat_id=identity, start_frame=at, duration_frames=length,
        visual_goal=goal, narration=narration, action_ids=[row['id'] for row in rows if row['shot'] == identity],
        asset_names=['现有魔塔双方人物、独立货箱和硬币']) for identity, purpose, at, length, narration, goal, source in shots],
        asset_requirements=[dict(name='现有魔塔双方人物、独立货箱和硬币',
            description='大尺寸卖家、买家、分支独立货物与钱道具及明确交接位置', style='原魔塔素材一致的像素风格', transparent=True)])
    plan = StoryPlan(brief)
    for stage, value in zip(('cast', 'outline', 'details', 'shots'), (cast, outline, details, content)):
        plan = plan.accept(stage, value, plan.fingerprint)
    return plan


def presentation(project, source_scene_ids):
    """Bind a complete 600-frame story to an actual existing game stage."""
    revision = project['revisions'][-1]
    models = delivery_models()
    sources = [dict(id=key, scene_id=source_scene_ids[key], model=models[key], seed=19,
                    start_frame=start, end_frame=end)
               for key, start, end in [('delivered', 0, 300), ('withheld', 300, FRAMES)]]
    sources[1].update(parent_id='delivered', intervention=dict(actorID='seller',
        plan=deepcopy(models['withheld']['ruleTable']['plans'][0])))
    def point(x, y):
        side = max(1280/13, 720/7)
        return dict(x=((1280-13*side)/2+(x+.5)*side)/1280,
                    y=((720-7*side)/2+(y+.5)*side)/720)
    rows = definitions()
    beats = [dict(id=row['id'], detail_id=row['id'], shot_id='shot-'+row['shot'],
        source_id=row['source'], event=dict(round=row['tick']//6+1, phase=PHASES[row['tick']%6]),
        effect=deepcopy(row['effect']), subject_id=row['subject'], start_frame=row['start'], end_frame=row['end'],
        requires=deepcopy(row['requires']), visual=deepcopy(row['visual'])) for row in rows]
    moments = [('delivered', 1, 0, 0), ('delivered', 1, 5, 168), ('delivered', 2, 5, 280),
               ('withheld', 1, 0, 300), ('withheld', 2, 5, 570)]
    return dict(version=1, story=story_plan().to_dict(),
        target=dict(workspace_id=project['workspaceID'], project_id=project['id'], base_revision=revision['id'],
                    scene_id=revision['scenes'][0]['id'], fps=30, mode='game'),
        sources=sources,
        actors=[dict(actor_id=actor, subject_id=SUBJECTS[key]) for actor, keys in [
            ('seller', ('seller', 'cargo', 'retained_cargo')),
            ('buyer', ('buyer', 'buyer_coin', 'retained_coin'))] for key in keys],
        pool_subject_id=SUBJECTS['pool'],
        anchors={key: point(x, y) for key, x, y in [('seller-hand', 3, 3.5), ('buyer-hand', 9, 3.5),
            ('counter', 6, 3.5), ('payment-route', 6, 4.5)]},
        beats=beats, balances=[dict(source_id=source, event=dict(round=round_, phase=PHASES[phase]),
            actor_id=actor, entity_id=SUBJECTS[actor], frame=frame)
            for source, round_, phase, frame in moments for actor in ('seller', 'buyer')])
