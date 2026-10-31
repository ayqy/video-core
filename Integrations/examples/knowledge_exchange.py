"""An explicit non-road knowledge plan for the normal knowledge-story adapter.

This finite protocol exchanges existing money only when both actors consent.
It does not model goods, value, delivery-before-payment, or real trade. The
caller supplies real scene identities and existing stage subjects; native Core
records the inputs. This author module never computes an outcome or a trace.
"""
from copy import deepcopy

from story_planning import StoryPlan


SUBJECTS = dict(qing='exchange-qing', lan='exchange-lan',
                qing_coin='exchange-qing-coin', lan_coin='exchange-lan-coin',
                agreed='exchange-agreed', pool='exchange-pool')


def protocol_models():
    actions = [dict(id='consent', label='同意这次互换', cost=0, pose='act'),
               dict(id='decline', label='保留自己的钱', cost=0, pose='idle')]
    states = [dict(id='unsettled', label='尚未互换', pose='idle'),
              dict(id='agreed', label='协议已结算', pose='celebrate')]
    plans = [dict(actorID=actor, initialStateID='unsettled', defaultActionID='consent',
                  cycleActionIDs=[], decisions=[dict(id='after-'+actor, priority=0,
                      conditions=[dict(kind='state', actorID=actor, stateID='agreed')],
                      actionID='decline')]) for actor in ('qing', 'lan')]
    model = dict(version=3, knowledgeLabel='双边合意：两条资金互换都以双方同意为条件', resourceLabel='硬币',
        participants=[dict(id='qing', name='阿青', initialResources=5, strategy='每轮出力'),
                      dict(id='lan', name='阿蓝', initialResources=2, strategy='每轮出力')],
        rounds=2, roundTicks=6, startTick=0, contributionCost=0, contributionUnits=1,
        threshold=1, benefit=0,
        ruleTable=dict(version=1, actions=actions, states=states, plans=plans, initialPool=0,
            externalBudgetPerRound=0, rules=[dict(id='mutual-consent', label='双方都同意才执行两条资金流',
                conditions=[dict(kind='actionCount', actionID='consent', minimum=2, maximum=2),
                            dict(kind='state', actorID='qing', stateID='unsettled'),
                            dict(kind='resources', actorID='qing', minimum=3, maximum=1000000),
                            dict(kind='resources', actorID='lan', minimum=1, maximum=1000000)],
                effects=[dict(kind='transfer', sourceActorID='qing', destinationActorID='lan', amount=3),
                         dict(kind='transfer', sourceActorID='lan', destinationActorID='qing', amount=1),
                         dict(kind='setState', actorID='qing', stateID='agreed'),
                         dict(kind='setState', actorID='lan', stateID='agreed')])]))
    alternative = deepcopy(model)
    alternative['ruleTable']['plans'][0]['defaultActionID'] = 'decline'
    return dict(consent=model, decline=alternative)


def story_plan():
    brief = dict(version=1, title='两个人都点头，钱才交换',
        knowledge_goal='通过真实的双向资金流观察双方同意这一协议条件',
        viewer_question='只改一人的选择，两条资金流还会发生吗？',
        context='阿青和阿蓝在魔塔大厅尝试一个事先约定的资金互换协议',
        boundary='有限教学协议；仅交换既有硬币，不计算商品价值，不模拟交货或买卖付款',
        source_ids=['consent', 'decline'])
    cast = dict(actors=[
        dict(id='qing', name='阿青', role='协议参与人', motive='愿意尝试事先约好的互换', goal='双方确认后再行动',
             expected_benefit='看到协议是否按双方选择执行', stake='本例互换后净少两枚硬币，不能推断经济上获利'),
        dict(id='lan', name='阿蓝', role='另一位协议参与人', motive='只在对方也同意时交换', goal='守住双方共同确认的条件',
             expected_benefit='实际收到对方约定的硬币', stake='对方拒绝就不能拿走对方的硬币')],
        objects=[dict(id='money', name='双方各自持有的硬币', description='两条分别核对出方与收方的资金流', purpose='展示实际互换'),
                 dict(id='agreement', name='同意标记', description='只表示阿青协议状态改变的游戏图块', purpose='展示实际状态后果')])
    rows = [
        ('setup', 'setup', '为什么要两人确认？', '阿青走到交接点，阿蓝在对面等候', [], ['consent']),
        ('choice', 'choice', '两人同意后发生了什么？', '先后看清阿青三枚和阿蓝一枚的不同资金流', ['setup'], ['consent']),
        ('result', 'consequence', '钱去了哪里？', '同意标记出现，实际余额变为三枚和四枚', ['choice'], ['consent']),
        ('contrast', 'choice', '只改阿青的选择呢？', '明确切换到独立拒绝分支，硬币仍各自保留', ['result'], ['decline']),
        ('end', 'conclusion', '为什么没有互换？', '回看双方同意是这份协议执行的前提', ['contrast'], ['decline'])]
    outline = dict(beats=[dict(id=i, purpose=p, question=q, change=c, actor_ids=['qing', 'lan'],
                              depends_on=d, source_ids=s) for i,p,q,c,d,s in rows])
    # All details have an explicit native event reference and a real shot. The
    # adapter still selects the *actual* effect, amount and owner from Core.
    definitions = [
        ('arrive','setup','qing','walk',['money'],[], 'consent',2,'consent',None),
        ('qing-gives','choice','qing','hand_over',['money'],['arrive'],'consent',5,'mutual-consent','lan'),
        ('lan-gives','choice','lan','hand_over',['money'],['qing-gives'],'consent',5,'mutual-consent','qing'),
        ('settled','result','qing','react',['agreement'],['qing-gives','lan-gives'],'consent',5,'mutual-consent',None),
        ('clear-qing-token','result','qing','react',['money'],['settled'],'consent',8,'decline',None),
        ('clear-lan-token','result','lan','react',['money'],['settled'],'consent',8,'decline',None),
        ('clear-agreement','contrast','qing','react',['agreement'],['settled'],'decline',2,'decline',None),
        ('refuse','contrast','qing','react',['money'],['clear-agreement'],'decline',2,'decline',None),
        ('recall','end','qing','react',['money'],['refuse'],'decline',8,'decline',None)]
    details = dict(actions=[dict(id=i, beat_id=b, actor_id=a, verb=v, object_ids=o,
        visible_start='看清实际持有人和当前协议分支', visible_process='按镜头展示角色动作或相应资金的逐步变化',
        visible_end='角色停在明确位置，实际状态与余额保留', depends_on=deps,
        event_refs=[dict(source_id=s,tick=t,rule_id=r)], **({'recipient_id':recipient} if recipient else {}))
        for i,b,a,v,o,deps,s,t,r,recipient in definitions])
    narrations = ['阿青和阿蓝，约好互换硬币。', '两人都同意，阿青交三枚，阿蓝交一枚。',
                  '互换后，阿青剩三枚，阿蓝有四枚。', '把阿青的选择改为拒绝，钱就各自保留。', '这份协议，要两人同意才执行。']
    windows = [(0,90),(90,90),(180,60),(240,120),(360,120)]
    shots = dict(shots=[dict(id='shot-'+row[0], beat_id=row[0], start_frame=at, duration_frames=length,
        visual_goal=row[3], narration=text, action_ids=[a['id'] for a in details['actions'] if a['beat_id']==row[0]],
        asset_names=['熟悉的魔塔人物与大厅图块']) for row,(at,length),text in zip(rows,windows,narrations)],
        asset_requirements=[dict(name='熟悉的魔塔人物与大厅图块', description='大尺寸双方人物、独立金币和同意状态标记',
                                 style='原魔塔素材一致的像素风格', transparent=True)])
    plan = StoryPlan(brief)
    for stage, content in zip(('cast','outline','details','shots'), (cast,outline,details,shots)):
        plan = plan.accept(stage, content, plan.fingerprint)
    return plan


def presentation(project, source_scene_ids):
    """Bind this explicit example to an existing 480-frame stage and sources."""
    revision = project['revisions'][-1]
    models = protocol_models()
    source_ids = ('consent','decline')
    sources = [dict(id=key, scene_id=source_scene_ids[key], model=models[key], seed=19,
                    start_frame=i*240, end_frame=(i+1)*240) for i,key in enumerate(source_ids)]
    sources[1].update(parent_id='consent', intervention=dict(actorID='qing', plan=deepcopy(models['decline']['ruleTable']['plans'][0])))
    def point(x,y):
        # Actual 13x7 stage centers in the example's 1280x720 viewport.
        side=max(1280/13,720/7);ox=(1280-13*side)/2;oy=(720-7*side)/2
        return dict(x=(ox+(x+.5)*side)/1280, y=(oy+(y+.5)*side)/720)
    anchors = {name:point(x,y) for name,x,y in [('home',3,4),('junction',4.5,4),('counter',6.5,4),
        ('qing-hand',6.5,3.5),('lan-hand',9,3.5),('upper-route',7.7,3.1),('lower-route',7.7,4.2)]}
    def beat(identity, detail, shot, source, tick, effect, subject, start, end, visual, requires=()):
        return dict(id=identity, detail_id=detail, shot_id='shot-'+shot, source_id=source,
            event=dict(round=tick//6+1,phase=('本轮开始','同时选择','实际出力与扣费','清障判定','通行或受阻','收益结算')[tick%6]),
            effect=effect, subject_id=subject, start_frame=start, end_frame=end, requires=list(requires), visual=visual)
    performed=lambda actor,action:dict(kind='performedAction',actor_id=actor,action_key=action)
    moves=lambda a,b,via:dict(kind='move',from_anchor=a,to_anchor=b,via_anchors=via)
    beats=[beat('arrive','arrive','setup','consent',2,performed('qing','consent'),SUBJECTS['qing'],1,60,moves('home','counter',['junction'])),
        beat('qing-gives','qing-gives','choice','consent',5,dict(kind='transfer',rule_id='mutual-consent',from_actor_id='qing',to_actor_id='lan'),
             SUBJECTS['qing_coin'],90,122,dict(kind='transfer',from_anchor='qing-hand',to_anchor='lan-hand',via_anchors=['upper-route'],target_subject_id=SUBJECTS['lan']),['arrive']),
        beat('lan-gives','lan-gives','choice','consent',5,dict(kind='transfer',rule_id='mutual-consent',from_actor_id='lan',to_actor_id='qing'),
             SUBJECTS['lan_coin'],130,162,dict(kind='transfer',from_anchor='lan-hand',to_anchor='qing-hand',via_anchors=['lower-route'],target_subject_id=SUBJECTS['qing']),['qing-gives']),
        beat('settled','settled','result','consent',5,dict(kind='stateChange',actor_id='qing',rule_id='mutual-consent',from_state_id='unsettled',to_state_id='agreed'),
             SUBJECTS['agreed'],182,200,dict(kind='show'),['qing-gives','lan-gives']),
        beat('clear-qing-token','clear-qing-token','result','consent',8,performed('qing','decline'),SUBJECTS['qing_coin'],208,220,dict(kind='hide'),['settled']),
        beat('clear-lan-token','clear-lan-token','result','consent',8,performed('lan','decline'),SUBJECTS['lan_coin'],208,220,dict(kind='hide'),['settled']),
        beat('clear-agreement','clear-agreement','contrast','decline',2,performed('qing','decline'),SUBJECTS['agreed'],241,252,dict(kind='hide')),
        beat('refuse','refuse','contrast','decline',2,performed('qing','decline'),SUBJECTS['qing'],254,285,dict(kind='hide'),['clear-agreement']),
        beat('recall','recall','end','decline',8,performed('qing','decline'),SUBJECTS['qing'],390,420,dict(kind='show'),['refuse'])]
    balances=[dict(source_id=key,event=dict(round=1,phase=phase),actor_id=actor,entity_id=SUBJECTS[actor],frame=frame)
              for key,phase,frame in [('consent','本轮开始',0),('consent','收益结算',202),('decline','本轮开始',240),('decline','收益结算',330)]
              for actor in ('qing','lan')]
    return dict(version=1,story=story_plan().to_dict(),target=dict(workspace_id=project['workspaceID'],project_id=project['id'],
        base_revision=revision['id'],scene_id=revision['scenes'][0]['id'],fps=30,mode='game'),sources=sources,
        actors=[dict(actor_id=actor,subject_id=SUBJECTS[key]) for actor,keys in [('qing',('qing','qing_coin','agreed')),('lan',('lan','lan_coin'))] for key in keys],
        pool_subject_id=SUBJECTS['pool'],anchors=anchors,beats=beats,balances=balances)
