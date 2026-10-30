"""Planning contract tests; these authored inputs are not rendered evidence."""
from copy import deepcopy
import unittest

from story_planning import StoryPlan, StoryPlanningError, generate_story
from pencil_production import ContentDesign


def content():
    brief = dict(version=1, title='共同修桥', knowledge_goal='理解公共通路为何容易出现等待别人付费的选择',
                 viewer_question='谁需要桥，为什么有人不愿出钱？', context='菜农和商人都要把货运进集市',
                 boundary='给定三币门槛的教学假设，不保证现实收益', source_ids=['base', 'refund'])
    actors = [dict(id=k, name=n, role=r, motive=m, goal='把自己的货运进集市',
                   expected_benefit='交付后取得实际买家货款', stake='桥断就不能运到市场')
              for k,n,r,m in [('a','小林','菜农','收成不能一直堆在村口'),('b','小周','商人','铺子缺货无法开张')]]
    cast = dict(actors=actors, objects=[dict(id='bridge', name='石桥', description='村口通往集市的石桥', purpose='共同通行'),
                                       dict(id='coin', name='金币', description='明确持有人和接收人的修桥款', purpose='支付工队')])
    outline = dict(beats=[dict(id=k, purpose=p, question=q, change=c, actor_ids=['a','b'], depends_on=d, source_ids=s)
                          for k,p,q,c,d,s in [('setup','setup','为什么过桥？','看见村口积货和空店',[],[]),
                                              ('choice','choice','谁愿意出钱？','菜农把一枚交给商人',['setup'],['base']),
                                              ('result','consequence','货还能卖吗？','道路未通便不能交货',['choice'],['refund']),
                                              ('end','conclusion','为何等别人？','回看共同受益和个人付费的区别',['result'],['base','refund'])]])
    details = dict(actions=[dict(id=k, beat_id=b, actor_id='a', verb=v, object_ids=o,
                                 visible_start='角色走到村口', visible_process=process, visible_end=end,
                                 depends_on=deps, event_refs=refs, **extra)
                            for k,b,v,o,process,end,deps,refs,extra in [
                                ('look','setup','react',['bridge'],'看向堆积的货物','指向无法通行的断口',[],[],{}),
                                ('pay','choice','pay',['coin'],'伸手取出一枚并递给对方','对方接住同一枚币',['look'],[dict(source_id='base',tick=2,rule_id='pay')],dict(recipient_id='b')),
                                ('stopped','result','react',['bridge'],'推车走到断口停住','货物仍在车上',['pay'],[],{}),
                                ('recall','end','react',['bridge'],'看向已通和未通两个结果','把视线转回共同通路',['stopped'],[],{})]])
    shots = dict(shots=[dict(id='shot-'+row['id'], beat_id=row['beat_id'], start_frame=i*60, duration_frames=60,
                             visual_goal=outline['beats'][i]['change'], narration='桥通了，大家都能走。',
                             action_ids=[row['id']], asset_names=['石桥原图']) for i,row in enumerate(details['actions'])],
                 asset_requirements=[dict(name='石桥原图', description='连贯可拼接的石块和手绘纹理', style='彩铅插画', transparent=True)])
    return brief, [cast, outline, details, shots]


def complete():
    brief, stages = content()
    plan = StoryPlan(brief)
    for name,value in zip(('cast','outline','details','shots'),stages):
        plan=plan.accept(name,value,plan.fingerprint)
    return plan


class StoryPlanningTests(unittest.TestCase):
    def test_finite_author_calls_advance_one_layer_and_material_stage_reuses_existing_contract(self):
        brief, stages = content(); calls=[]
        def author(request):
            calls.append(request)
            self.assertEqual(len(request['parents']),len(calls)-1)
            return stages[len(calls)-1]
        plan=generate_story(brief,author)
        self.assertEqual([v['stage'] for v in calls],['cast','outline','details','shots'])
        self.assertEqual(ContentDesign.from_dict(plan.drawing_design()).drawings[0].name,'石桥原图')
        self.assertEqual(StoryPlan.from_dict(plan.to_dict()).fingerprint,plan.fingerprint)

    def test_early_material_resolution_and_out_of_order_layer_are_rejected(self):
        brief,stages=content();plan=StoryPlan(brief)
        with self.assertRaises(StoryPlanningError):plan.drawing_design()
        with self.assertRaises(StoryPlanningError):plan.accept('shots',stages[-1],plan.fingerprint)

    def test_parent_change_invalidates_dependent_details_and_shots(self):
        plan=complete(); cast=plan.stage('cast');cast['actors'][0]['motive']='收成已经成熟，必须赶在坏掉前送到集市'
        edited=plan.rewrite('cast',cast,'先让付费动机具体可见')
        self.assertFalse(edited.complete)
        self.assertEqual(edited.prompt()['stage'],'outline')
        self.assertTrue(plan.complete)
        with self.assertRaises(StoryPlanningError):edited.accept('outline',plan.stage('outline'),plan.to_dict()['stages'][1]['parent_digest'])

    def test_unmotivated_choice_is_repaired_at_outline_instead_of_renderer(self):
        brief,stages=content();plan=StoryPlan(brief).accept('cast',stages[0],StoryPlan(brief).fingerprint)
        changed=deepcopy(stages[1]);changed['beats'][0]['actor_ids']=['a']
        with self.assertRaises(StoryPlanningError) as error:plan.accept('outline',changed,plan.fingerprint)
        self.assertEqual(error.exception.layer,'outline')

    def test_handover_requires_recipient_process_and_native_event_requirement(self):
        brief,stages=content();plan=StoryPlan(brief)
        for stage,value in zip(('cast','outline'),stages):plan=plan.accept(stage,value,plan.fingerprint)
        for mutate in (lambda a:a.pop('recipient_id'),lambda a:a.update(event_refs=[]),
                       lambda a:a.update(visible_process=a['visible_start'])):
            changed=deepcopy(stages[2]);mutate(changed['actions'][1])
            with self.assertRaises(StoryPlanningError):plan.accept('details',changed,plan.fingerprint)

    def test_content_does_not_receive_inventory_or_silent_cache_fields(self):
        brief,_=content();brief['available_assets']=['arbitrary inventory sentinel']
        with self.assertRaises(StoryPlanningError):StoryPlan(brief)
        plan=complete()
        self.assertNotIn('inventory',str(plan.to_dict()))
        changed=plan.to_dict();changed['stages'][0]['content']['cache_hits']=3
        with self.assertRaises(StoryPlanningError):StoryPlan.from_dict(changed)

    def test_shots_cannot_skip_cause_or_borrow_another_beat_action(self):
        plan=complete();parent=StoryPlan(plan.to_dict()['brief'],plan.to_dict()['stages'][:3])
        for mutate in (lambda s:s['shots'][1].update(start_frame=61),
                       lambda s:s['shots'][1].update(action_ids=['look']),
                       lambda s:s['shots'].pop()):
            changed=plan.stage('shots');mutate(changed)
            with self.assertRaises(StoryPlanningError):parent.accept('shots',changed,parent.fingerprint)


if __name__=='__main__':unittest.main()
