import hashlib
from pathlib import Path
import tempfile
import unittest

from story_evaluation import Observation, EvaluationError, compare


class StoryEvaluationTests(unittest.TestCase):
    def test_same_questions_and_scopes_keep_unverified_whole_film_pending(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'actual-observation.txt';path.write_text('bounded unit observation source')
            pin=hashlib.sha256(path.read_bytes()).hexdigest()
            before=[Observation('motivation','rejected','plan','角色先出钱，后面才解释为什么',str(path),pin,basis='direct'),
                    Observation('timing','needs_review','full_movie','尚未完整看听')]
            after=[Observation('motivation','observed','plan','选择前先展示积货和缺货',str(path),pin,basis='direct'),
                   Observation('timing','needs_review','full_movie','完整新片仍待看听')]
            result=compare('看懂共同通路上的个人选择',before,after)
            self.assertFalse(result['automatic_quality_approval'])
            self.assertEqual(result['needs_review'],['timing'])
            self.assertEqual(result['repair_layers'],[])

    def test_frame_cannot_replace_sequence_or_claim_an_unobserved_original(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'source';path.write_bytes(b'unit source')
            pin=hashlib.sha256(path.read_bytes()).hexdigest()
            before=Observation('performance','observed','sequence','原表演窗口',str(path),pin,10,20,'direct')
            after=Observation('performance','observed','frame','只看一个时点',str(path),pin,10,11,'direct')
            with self.assertRaises(EvaluationError):compare('保持同一评估问题',[before],[after])
            path.write_bytes(b'changed')
            with self.assertRaises(EvaluationError):before.validate()

    def test_duplicate_questions_and_invented_approval_are_rejected(self):
        row=Observation('timing','needs_review','full_movie','待完整看听')
        with self.assertRaises(EvaluationError):compare('原问题',[row,row],[row,row])
        with self.assertRaises(EvaluationError):Observation('timing','approved','frame','模型说通过').validate()


if __name__=='__main__':unittest.main()
