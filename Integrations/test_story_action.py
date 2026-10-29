import copy
import unittest

from story_action import StoryError, apply_story, compile_story


def project():
    return dict(id='project', workspaceID='workspace', revisions=[dict(id='revision', fps=30,
        scenes=[dict(id='scene', kind='图文讲解', durationFrames=90, locked=False,
                     narration='路修好了，货物运出去。', captions=[], layers=[dict(id='coin')])])])


def plan():
    return dict(version=1, base_revision='revision', fps=30, scenes=[dict(scene_id='scene', mode='pencil',
        actions=[dict(id='give', kind='transfer', subjectID='coin', targetID='builder',
                      startFrame=10, endFrame=30, **{'from': dict(x=.2, y=.6), 'to': dict(x=.5, y=.6)})],
        layers=[dict(id='coin'), dict(id='builder')])])


class StoryActionTests(unittest.TestCase):
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

    def test_dry_run_rejection_never_submits_edit(self):
        calls = []
        def invoke(command, body, dry):
            calls.append(dry); return dict(ok=False)
        with self.assertRaises(StoryError):
            apply_story(project(), plan(), invoke)
        self.assertEqual(calls, [True])


if __name__ == '__main__':
    unittest.main()
