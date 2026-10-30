"""Purpose-based before/after observations, independent of rendering success.

This module validates provenance and comparable questions. It never converts a
schema check, a frame count or a model opinion into a human review approval.
"""
from __future__ import annotations

from copy import deepcopy
from dataclasses import dataclass
import hashlib
from pathlib import Path
import re

CRITERIA = {
    'motivation': ('plot', '选择前是否看懂各角色为什么行动、付出什么、期待什么？'),
    'causality': ('details', '谁对谁做了什么、过程和结果能否连续看懂？'),
    'consequence': ('details', '道路通断是否真实改变运货、售卖和收益，而非只换字幕？'),
    'readability': ('shots', '关键角色、物体和动作是否突出，字幕是否避开关键画面？'),
    'scene': ('materials', '场景、职业、建筑、道路和车辆能否一眼辨认并支持情节？'),
    'identity': ('materials', '图帧间是否保持同一人物的脸、体型、服装和标志？'),
    'performance': ('performance', '表情与口型持续变化，少量手势有过程且随情节发生吗？'),
    'timing': ('timing', '实际旁白、字幕、动作和理解画面的留白是否同步？'),
}
STATUSES = {'observed', 'rejected', 'needs_review', 'not_applicable'}


class EvaluationError(ValueError): pass


@dataclass(frozen=True)
class Observation:
    criterion: str
    status: str
    scope: str
    finding: str
    artifact: str = ''
    sha256: str = ''
    start_frame: int = 0
    end_frame: int = 0
    basis: str = 'unverified'

    def validate(self):
        if (self.criterion not in CRITERIA or self.status not in STATUSES
                or self.scope not in {'plan', 'asset', 'frame', 'sequence', 'full_movie'}
                or not isinstance(self.finding, str) or not self.finding.strip()
                or len(self.finding.encode()) > 8000
                or type(self.start_frame) is not int or type(self.end_frame) is not int
                or not 0 <= self.start_frame <= self.end_frame <= 54000
                or self.basis not in {'direct', 'inference', 'unverified'}):
            raise EvaluationError('bounded criterion, observation scope and honest evidence basis required')
        if self.status in {'observed', 'rejected'}:
            if self.basis == 'unverified' or not re.fullmatch('[0-9a-f]{64}', self.sha256):
                raise EvaluationError('an observation needs its original artifact identity')
            path = Path(self.artifact)
            if not path.is_file() or path.is_symlink() or hashlib.sha256(path.read_bytes()).hexdigest() != self.sha256:
                raise EvaluationError('observed original is absent or changed')
            if self.scope in {'frame', 'sequence', 'full_movie'} and self.end_frame <= self.start_frame:
                raise EvaluationError('visual observation needs its actual nonempty frame window')
        elif self.basis != 'unverified' or self.artifact or self.sha256:
            raise EvaluationError('pending and inapplicable items cannot carry a false observed grant')
        return self


def compare(purpose, before, after):
    """Same criteria and evidence scopes; pending whole-film review stays pending."""
    if not isinstance(purpose, str) or not purpose.strip() or len(purpose.encode()) > 4000:
        raise EvaluationError('retain the concrete knowledge-comprehension purpose')
    if not isinstance(before, list) or not isinstance(after, list) or not before or len(before) > len(CRITERIA):
        raise EvaluationError('bounded paired observations required')
    for row in before + after:
        if not isinstance(row, Observation): raise EvaluationError('typed observation required')
        row.validate()
    left = {row.criterion: row for row in before}; right = {row.criterion: row for row in after}
    if len(left) != len(before) or len(right) != len(after) or left.keys() != right.keys():
        raise EvaluationError('use the same distinct questions before and after')
    changes = []
    for key, previous in left.items():
        current = right[key]
        if previous.scope != current.scope:
            raise EvaluationError('a frame sample cannot replace a sequence or whole-film observation')
        changes.append(dict(criterion=key, layer=CRITERIA[key][0], question=CRITERIA[key][1],
                            before=deepcopy(previous.__dict__), after=deepcopy(current.__dict__)))
    return dict(purpose=purpose, comparisons=changes, automatic_quality_approval=False,
                needs_review=[r.criterion for r in after if r.status == 'needs_review'],
                repair_layers=sorted({CRITERIA[r.criterion][0] for r in after if r.status == 'rejected'}))
