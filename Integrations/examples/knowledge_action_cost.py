"""Declarative one-cost counterfactual for the normal knowledge-story API.

The existing two-party protocol is unchanged except for one action's cost.
Native Core alone records actions, transfers, balances and traces. This module
declares the teaching input and presentation, never evaluates either model.
"""
from copy import deepcopy

from examples.knowledge_exchange import SUBJECTS as EXCHANGE_SUBJECTS, protocol_models
from story_planning import StoryPlan

PHASES=('本轮开始','同时选择','实际出力与扣费','清障判定','通行或受阻','收益结算')
FRAMES=600
SUBJECTS=deepcopy(EXCHANGE_SUBJECTS)
SUBJECTS.update(low_qing_fee='cost-low-qing-fee',low_lan_fee='cost-low-lan-fee',
    high_qing_fee='cost-high-qing-fee',high_lan_fee='cost-high-lan-fee',high_second_fee='cost-high-second-fee')


def cost_models():
    low=deepcopy(protocol_models()['consent'])
    next(a for a in low['ruleTable']['actions'] if a['id']=='consent')['cost']=1
    high=deepcopy(low)
    next(a for a in high['ruleTable']['actions'] if a['id']=='consent')['cost']=2
    return dict(low=low,high=high)


def definitions():
    """Identity, shot, actor, event, effect, subject, interval, visual, dependencies."""
    def performed(actor):return dict(kind='performedAction',actor_id=actor,action_key='consent')
    def shown(kind):return dict(kind=kind)
    def deposit(actor):return dict(kind='deposit',from_actor_id=actor)
    def route(target,a,b):return dict(kind='transfer',target_subject_id=SUBJECTS[target],from_anchor=a,to_anchor=b)
    rows=[]
    def add(i,shot,actor,source,tick,effect,subject,a,b,visual,deps=()):
        rows.append(dict(id=i,shot=shot,actor=actor,source=source,tick=tick,effect=effect,subject=SUBJECTS[subject],
                         a=a,b=b,visual=visual,deps=list(deps)))
    for actor,a,b in [('qing',10,34),('lan',38,62)]:
        fee='low_'+actor+'_fee'
        add('low-show-'+actor,'setup',actor,'low',2,performed(actor),fee,a-7,a-1,shown('show'))
        add('low-cost-'+actor,'setup',actor,'low',2,deposit(actor),fee,a,b,
            route('pool',actor+'-hand','pool'),['low-show-'+actor])
    add('low-qing-gives','exchange','qing','low',5,dict(kind='transfer',rule_id='mutual-consent',from_actor_id='qing',to_actor_id='lan'),
        'qing_coin',100,135,route('lan','qing-hand','lan-hand'),['low-cost-qing'])
    add('low-lan-gives','exchange','lan','low',5,dict(kind='transfer',rule_id='mutual-consent',from_actor_id='lan',to_actor_id='qing'),
        'lan_coin',140,175,route('qing','lan-hand','qing-hand'),['low-qing-gives'])
    add('low-agreed','result','qing','low',5,dict(kind='stateChange',actor_id='qing',rule_id='mutual-consent',from_state_id='unsettled',to_state_id='agreed'),
        'agreed',182,198,shown('show'),['low-qing-gives','low-lan-gives'])
    for actor in ('qing','lan'):
        add('low-clear-'+actor,'result',actor,'low',8,dict(kind='performedAction',actor_id=actor,action_key='decline'),
            actor+'_coin',220,230,shown('hide'),['low-agreed'])
    add('high-reset','contrast','qing','high',2,performed('qing'),'agreed',301,307,shown('hide'))
    for actor,a,b in [('qing',318,350),('lan',358,390)]:
        fee='high_'+actor+'_fee'
        add('high-show-'+actor,'contrast',actor,'high',2,performed(actor),fee,a-9,a-2,shown('show'))
        add('high-cost-'+actor,'contrast',actor,'high',2,deposit(actor),fee,a,b,
            route('pool',actor+'-hand','pool'),['high-show-'+actor])
        add('high-clear-'+actor,'contrast',actor,'high',2,performed(actor),fee,400,409,shown('hide'),['high-cost-'+actor])
    add('high-second-show','end','qing','high',8,performed('qing'),'high_second_fee',430,437,shown('show'),['high-clear-qing'])
    add('high-second-cost','end','qing','high',8,deposit('qing'),'high_second_fee',440,475,
        route('pool','qing-hand','pool'),['high-second-show'])
    add('high-second-clear','end','qing','high',8,performed('qing'),'high_second_fee',482,492,shown('hide'),['high-second-cost'])
    return rows


def story_plan():
    brief=dict(version=1,title='只改确认成本，资金流会怎样',knowledge_goal='比较单一行动成本对实际可执行选择和资金流的影响',
        viewer_question='规则和选择不变，扣费不同会改变协议结果吗？',context='两个参与人在同一有限资金协议中作两轮确认',
        boundary='仅此教学模型；成本进入规则池，不计商品价值；本例是内部作者与视觉链验证，不授声音或整片审核',source_ids=['low','high'])
    cast=dict(actors=[dict(id=a,name=n,role='协议参与人',motive='按原先约定尝试资金互换',goal='确认扣费后协议是否还能执行',
        expected_benefit='观察真实资金去向',stake='每次确认先支付规则成本，未必仍够钱互换') for a,n in [('qing','阿青'),('lan','阿蓝')]],
        objects=[dict(id='money',name='参与人的硬币',description='本金、确认成本及实际协议资金流分别核对',purpose='展示真实扣费与资金去向'),
                 dict(id='agreement',name='本分支协议标记',description='只表示实际应用的协议状态',purpose='区别实际完成与未执行的互换')])
    shots=[('setup','setup',0,90,'每次确认先付一枚。','展示两位参与人各自的一枚成本','low'),
           ('exchange','choice',90,90,'扣费后，两人仍够钱，互换完成。','展示三枚与一枚的实际资金流','low'),
           ('result','consequence',180,120,'两轮结束，阿青剩两枚，阿蓝有三枚。','保留实际结算余额','low'),
           ('contrast','choice',300,120,'只把确认成本改成两枚，其他规则和选择保持。','切换独立分支并展示每人两枚扣费','high'),
           ('end','conclusion',420,180,'阿蓝扣费后不够钱，互换没有发生。两轮结束，阿青剩一枚，阿蓝剩零枚。','展示第二轮实际扣费与最终余额','high')]
    rows=definitions()
    outline=dict(beats=[dict(id=i,purpose=p,question=brief['viewer_question'],change=goal,actor_ids=['qing','lan'],
        depends_on=[] if index==0 else [shots[index-1][0]],source_ids=[source]) for index,(i,p,at,length,text,goal,source) in enumerate(shots)])
    details=dict(actions=[dict(id=r['id'],beat_id=r['shot'],actor_id=r['actor'],verb='pay' if r['effect']['kind']=='transfer' else 'take' if r['effect']['kind']=='deposit' else 'react',
        object_ids=['agreement' if r['subject']==SUBJECTS['agreed'] else 'money'],visible_start='看清当前参与人与独立分支',
        visible_process='从自己的本金取出本次确认成本，放入无主规则池' if r['effect']['kind']=='deposit' else '按实际转账或状态事件表现',visible_end='保留真实持有状态，不画未执行的行为',depends_on=r['deps'],
        event_refs=[dict(source_id=r['source'],tick=r['tick'],rule_id=r['effect'].get('rule_id',r['effect'].get('action_key',r['effect']['kind'])))],
        **({'recipient_id':r['effect']['to_actor_id']} if r['effect'].get('to_actor_id') else {})) for r in rows])
    content=dict(shots=[dict(id='shot-'+i,beat_id=i,start_frame=at,duration_frames=length,visual_goal=goal,narration=text,
        action_ids=[r['id'] for r in rows if r['shot']==i],asset_names=['现有魔塔人物、硬币及规则池']) for i,p,at,length,text,goal,source in shots],
        asset_requirements=[dict(name='现有魔塔人物、硬币及规则池',description='独立持有人、资金道具与未拥有规则池',style='原魔塔像素风格',transparent=True)])
    plan=StoryPlan(brief)
    for stage,value in zip(('cast','outline','details','shots'),(cast,outline,details,content)):plan=plan.accept(stage,value,plan.fingerprint)
    return plan


def presentation(project,source_scene_ids):
    revision=project['revisions'][-1];models=cost_models();rows=definitions()
    sources=[dict(id=key,scene_id=source_scene_ids[key],model=models[key],seed=19,start_frame=i*300,end_frame=(i+1)*300) for i,key in enumerate(('low','high'))]
    sources[1].update(parent_id='low',action_cost=dict(actionID='consent',newCost=2))
    def point(x,y):
        side=max(1280/13,720/7);return dict(x=((1280-13*side)/2+(x+.5)*side)/1280,y=((720-7*side)/2+(y+.5)*side)/720)
    beats=[dict(id=r['id'],detail_id=r['id'],shot_id='shot-'+r['shot'],source_id=r['source'],
        event=dict(round=r['tick']//6+1,phase=PHASES[r['tick']%6]),effect=deepcopy(r['effect']),subject_id=r['subject'],
        start_frame=r['a'],end_frame=r['b'],requires=r['deps'],visual=deepcopy(r['visual'])) for r in rows]
    moments=[('low',1,0,0),('low',1,2,66),('low',1,5,202),('low',2,5,280),
             ('high',1,0,300),('high',1,2,412),('high',2,5,570)]
    return dict(version=2,story=story_plan().to_dict(),target=dict(workspace_id=project['workspaceID'],project_id=project['id'],base_revision=revision['id'],
        scene_id=revision['scenes'][0]['id'],fps=30,mode='game'),sources=sources,
        actors=[dict(actor_id=a,subject_id=SUBJECTS[key]) for a,keys in [
            ('qing',('qing','qing_coin','agreed','low_qing_fee','high_qing_fee','high_second_fee')),
            ('lan',('lan','lan_coin','low_lan_fee','high_lan_fee'))] for key in keys],
        pool_subject_id=SUBJECTS['pool'],anchors={key:point(x,y) for key,x,y in [('qing-hand',3,3.5),('lan-hand',9,3.5),('pool',6,5)]},
        beats=beats,balances=[dict(source_id=s,event=dict(round=r,phase=PHASES[phase]),actor_id=a,entity_id=SUBJECTS[a],frame=f)
            for s,r,phase,f in moments for a in ('qing','lan')])
