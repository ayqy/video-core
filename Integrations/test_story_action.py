import copy
import unittest

from story_action import StoryError, actions_for_scene, apply_story, compile_story


def project():
    return dict(id='project', workspaceID='workspace', revisions=[dict(id='revision', fps=30,
        scenes=[dict(id='scene', kind='图文讲解', durationFrames=90, locked=False,
                     narration='路修好了，货物运出去。', captions=[], layers=[dict(id='coin')])])])


def plan():
    return dict(version=1, base_revision='revision', fps=30, scenes=[dict(scene_id='scene', mode='pencil',
        actions=[dict(id='give', kind='transfer', subjectID='coin', targetID='builder',
                      startFrame=10, endFrame=30, **{'from': dict(x=.2, y=.6), 'to': dict(x=.5, y=.6)})],
        layers=[dict(id='coin'), dict(id='builder')])])


def causal_plan(version=1):
    """Synthetic declarations only; these are not Core or media evidence."""
    value=plan()
    value['scenes'][0]['causality']=dict(version=version,poolSubjectID='coin',actors=[],
        sources=[dict(id='UNIT-source')],bindings=[dict(actionID='give',sourceID='UNIT-source')])
    return value


class StoryActionTests(unittest.TestCase):
    def test_pencil_action_edit_retains_the_existing_paper_without_mutating_input(self):
        original=project();paper=dict(version=1,layout='explanation',paperColor='FFFFFF',inkColor='263238')
        original['revisions'][0]['scenes'][0]['paperPresentation']=paper
        snapshot=copy.deepcopy(original)
        scene=compile_story(original,plan())['edits'][0]['replaceScene']['_1']
        self.assertEqual(scene['paperPresentation'],paper)
        self.assertIsNot(scene['paperPresentation'],paper)
        self.assertEqual(original,snapshot)

    def test_switching_to_advanced_cartoon_retires_the_existing_paper(self):
        original=project();original['revisions'][0]['scenes'][0]['paperPresentation']=dict(version=1,layout='explanation',paperColor='FFFFFF',inkColor='263238')
        spec=plan();spec['scenes'][0].update(mode='cartoon',rig=dict(version=1,actors=[dict(id='host')],cues=[]))
        scene=compile_story(original,spec)['edits'][0]['replaceScene']['_1']
        self.assertNotIn('paperPresentation',scene)
        self.assertIn('paperPresentation',original['revisions'][0]['scenes'][0])

    def test_one_transaction_preserves_content_and_causal_inputs(self):
        original = project(); snapshot = copy.deepcopy(original); calls = []
        def invoke(command, body, dry):
            calls.append((command, body, dry))
            return dict(ok=True, state='dry_run' if dry else 'needs_review', project_id='project', revision='new')
        result = apply_story(original, plan(), invoke)
        self.assertEqual(original, snapshot)
        self.assertEqual(result, dict(changed=True, revision='new', scenes=1))
        self.assertEqual([call[2] for call in calls], [True, False])
        self.assertEqual(calls[0][1], calls[1][1])
        scene = calls[1][1]['edits'][0]['replaceScene']['_1']
        self.assertEqual(scene['narration'], original['revisions'][0]['scenes'][0]['narration'])
        self.assertEqual(scene['storyActions'][0]['targetID'], 'builder')

    def test_stale_axis_or_unidentified_handover_is_rejected_before_mutation(self):
        variants = []
        stale = plan(); stale['base_revision'] = 'old'; variants.append(stale)
        target = plan(); del target['scenes'][0]['actions'][0]['targetID']; variants.append(target)
        unknown = plan(); unknown['scenes'][0]['actions'][0]['subjectID'] = 'undeclared'; variants.append(unknown)
        overlap = plan(); duplicate = copy.deepcopy(overlap['scenes'][0]['actions'][0]); duplicate['id'] = 'other'
        overlap['scenes'][0]['actions'].append(duplicate); variants.append(overlap)
        for value in variants:
            with self.subTest(value=value), self.assertRaises(StoryError):
                compile_story(project(), value)

    def test_incomplete_map_and_unrelated_voice_cannot_enter_normal_editor(self):
        value = plan(); entry = value['scenes'][0]
        entry.update(mode='game', world=dict(version=1, width=3, height=2, tiles=['floor'], entities=[], updates=[]))
        with self.assertRaises(StoryError):
            compile_story(project(), value)
        source = project(); source['revisions'][0]['scenes'][0]['voice'] = dict(assetID='take', textDigest='a'*64, durationFrames=60)
        value = plan(); value['scenes'][0].update(mode='cartoon', rig=dict(version=1,
            actors=[dict(id='host')], cues=[], speech=dict(voiceAssetID='other', textDigest='a'*64, durationFrames=60)))
        with self.assertRaises(StoryError):
            compile_story(source, value)

    def test_typed_causality_is_explicitly_preserved_for_host_verification(self):
        value=causal_plan();causal=value['scenes'][0]['causality']
        result=compile_story(project(),value)['edits'][0]['replaceScene']['_1']
        self.assertEqual(result['storyCausality'],causal)
        self.assertIsNot(result['storyCausality'],causal)
        source=project();source['revisions'][0]['scenes'][0]['storyCausality']=causal
        self.assertNotIn('storyCausality',compile_story(source,plan())['edits'][0]['replaceScene']['_1'])
        value['scenes'][0]['causality']['untyped']=True
        with self.assertRaises(StoryError):compile_story(project(),value)

    def test_causality_two_is_host_evidence_without_upgrading_the_story_envelope(self):
        value=causal_plan(2);causal=value['scenes'][0]['causality']
        causal['sources'][0]['actionCost']=dict(actionID='work',newCost=2)
        snapshot=copy.deepcopy(value)
        scene=compile_story(project(),value)['edits'][0]['replaceScene']['_1']
        self.assertEqual(scene['storyCausality'],causal);self.assertEqual(value,snapshot);self.assertEqual(value['version'],1)
        for version in (0,4,True,2.0):
            value=copy.deepcopy(snapshot);value['scenes'][0]['causality']['version']=version
            with self.subTest(version=version),self.assertRaises(StoryError):compile_story(project(),value)

    def test_explicit_causality_three_does_not_change_story_one_or_legacy_causality(self):
        for version in (1,2,3):
            value=causal_plan(version);snapshot=copy.deepcopy(value)
            scene=compile_story(project(),value)['edits'][0]['replaceScene']['_1']
            self.assertEqual(scene['storyCausality'],value['scenes'][0]['causality'])
            self.assertEqual(value,snapshot);self.assertEqual(value['version'],1)

    def test_causal_visual_moves_can_pick_up_hold_and_put_down_without_changing_bound_amount_or_axis(self):
        value=causal_plan();entry=value['scenes'][0]
        entry['actions'][0]['quantity']=3
        entry['actions'].extend([
            dict(id='pickup',kind='move',subjectID='coin',startFrame=0,endFrame=10,
                 **{'from':dict(x=.1,y=.6),'to':dict(x=.2,y=.6)}),
            dict(id='putdown',kind='move',subjectID='coin',startFrame=40,endFrame=60,
                 **{'from':dict(x=.5,y=.6),'to':dict(x=.7,y=.7)})])
        before=copy.deepcopy(value)
        scene=compile_story(project(),value)['edits'][0]['replaceScene']['_1']
        self.assertEqual(scene['storyActions'],entry['actions'])
        self.assertEqual(scene['storyCausality'],entry['causality']);self.assertEqual(value,before)
        self.assertEqual(scene['storyActions'][0]['quantity'],3)
        self.assertEqual((scene['storyActions'][0]['startFrame'],scene['storyActions'][0]['endFrame']),(10,30))

    def test_causal_unbound_transfers_and_any_new_quantity_fail_before_editor_submission(self):
        for extra in (
            dict(id='invented',kind='transfer',subjectID='coin',targetID='builder',startFrame=40,endFrame=60,
                 **{'from':dict(x=.5,y=.6),'to':dict(x=.7,y=.6)}),
            dict(id='invented',kind='show',subjectID='builder',startFrame=40,endFrame=60,quantity=999)):
            value=causal_plan();value['scenes'][0]['actions'].append(extra);calls=[]
            with self.subTest(extra=extra),self.assertRaisesRegex(StoryError,'unbound visual movements'):
                apply_story(project(),value,lambda *args:calls.append(args))
            self.assertEqual(calls,[])

    def test_causal_disconnected_move_cannot_teleport_after_completed_transfer(self):
        value=causal_plan();entry=value['scenes'][0]
        entry['actions'].append(dict(id='putdown',kind='move',subjectID='coin',startFrame=40,endFrame=60,
            **{'from':dict(x=.8,y=.6),'to':dict(x=.9,y=.6)}))
        # A layer keyframe cannot replace the Native action's held .5 endpoint.
        entry['layers'][0]['keyframes']=[dict(frame=40,x=.8,y=.6)]
        with self.assertRaisesRegex(StoryError,'previous actual endpoint'):compile_story(project(),value)

    def test_causal_branches_need_distinct_subjects_even_with_unbound_bridge_between_them(self):
        value=causal_plan();entry=value['scenes'][0];causal=entry['causality']
        causal['sources'].append(dict(id='UNIT-branch'))
        causal['bindings'].append(dict(actionID='branch-give',sourceID='UNIT-branch'))
        entry['actions'].extend([
            dict(id='bridge',kind='move',subjectID='coin',startFrame=30,endFrame=40,
                 **{'from':dict(x=.5,y=.6),'to':dict(x=.6,y=.6)}),
            dict(id='branch-give',kind='transfer',subjectID='coin',targetID='builder',startFrame=40,endFrame=60,
                 **{'from':dict(x=.6,y=.6),'to':dict(x=.7,y=.6)})])
        with self.assertRaisesRegex(StoryError,'distinct movement subjects'):compile_story(project(),value)
        entry['layers'].append(dict(id='branch-coin'))
        entry['actions'][-1]['subjectID']='branch-coin'
        self.assertEqual(len(compile_story(project(),value)['edits']),1)

    def test_no_causality_preserves_legacy_independent_authored_positions(self):
        value=plan();entry=value['scenes'][0]
        entry['actions'].append(dict(id='legacy',kind='move',subjectID='coin',startFrame=40,endFrame=60,
            **{'from':dict(x=.8,y=.6),'to':dict(x=.9,y=.6)}))
        self.assertEqual(len(compile_story(project(),value)['edits']),1)

    def test_causal_binding_identity_cannot_be_missing_duplicated_or_detached_from_source(self):
        for change in (
            lambda cause:cause['bindings'][0].update(actionID='missing'),
            lambda cause:cause['bindings'].append(copy.deepcopy(cause['bindings'][0])),
            lambda cause:cause['bindings'][0].update(sourceID='missing')):
            value=causal_plan();entry=value['scenes'][0];change(entry['causality'])
            with self.subTest(change=change),self.assertRaises(StoryError):
                actions_for_scene(entry['actions'],{'coin','builder'},90,causality=entry['causality'])

    def test_explicit_rig_two_supports_eight_independent_actors_without_widening_rig_one(self):
        value=plan();entry=value['scenes'][0];entry['mode']='cartoon'
        entry['rig']=dict(version=2,actors=[dict(id='actor-'+str(i)) for i in range(8)],cues=[])
        scene=compile_story(project(),value)['edits'][0]['replaceScene']['_1']
        self.assertEqual(scene['cartoonRig']['version'],2);self.assertEqual(len(scene['cartoonRig']['actors']),8)
        for version,count in ((1,5),(2,9),(3,1),(True,1)):
            changed=copy.deepcopy(value);changed['scenes'][0]['rig'].update(version=version,actors=[dict(id='actor-'+str(i)) for i in range(count)])
            with self.subTest(version=version,count=count),self.assertRaises(StoryError):compile_story(project(),changed)
        value['scenes'][0]['rig'].update(version=1,actors=[dict(id='actor-'+str(i)) for i in range(4)])
        self.assertEqual(len(compile_story(project(),value)['edits']),1)

    def test_dry_run_rejection_never_submits_edit(self):
        calls = []
        def invoke(command, body, dry):
            calls.append(dry); return dict(ok=False)
        with self.assertRaises(StoryError):
            apply_story(project(), plan(), invoke)
        self.assertEqual(calls, [True])


if __name__ == '__main__':
    unittest.main()
