"""Declarative author for the shared native knowledge-production workflow.

Content and native stage design are independent explicit inputs. The document
contains no Python, command, model evaluator, paid action or approval override.
Core validates its real scenes, source recordings and causal actions normally.
"""
from copy import deepcopy
import inspect
import json
from pathlib import Path
import plistlib
import re
import subprocess

from frozen_speech import FrozenSpeech
from knowledge_story import _plan, _last_tick
from production_workflow import ProductionWorkflow, data, need, read, save, sha, unpack
from story_planning import StoryPlan


def object_keys(value, required, optional=()):
    need(isinstance(value, dict) and set(required) <= set(value)
         and set(value) <= set(required) | set(optional), 'unknown or missing production document field')


def regular(path, base):
    path = Path(path)
    path = path if path.is_absolute() else base / path
    need(path.is_file() and not path.is_symlink(), 'declared source must be an ordinary existing file')
    return path.resolve()


class ProductionDocument:
    def __init__(self, path):
        self.path = Path(path).resolve(strict=True)
        need(not Path(path).is_symlink() and self.path.stat().st_size <= 8 * 1024 * 1024,
             'bounded ordinary production document required')
        self.value = read(self.path)
        value = self.value
        object_keys(value, ('version', 'name', 'voice_identifier', 'aspect', 'fps', 'viewport',
                           'presentation', 'scene', 'materials'), ('motion_actions', 'retained_speech'))
        need(type(value['version']) is int and value['version'] == 1
             and isinstance(value['name'], str) and 1 <= len(value['name']) <= 200
             and isinstance(value['voice_identifier'], str) and 1 <= len(value['voice_identifier']) <= 200,
             'explicit production name and source voice identifier required')
        need(value['aspect'] in ('16:9', '9:16') and value['fps'] == 30
             and value['viewport'] == ([1280, 720] if value['aspect'] == '16:9' else [720, 1280]),
             'use a declared supported normal project format')
        _plan(value['presentation'])
        need(value['presentation']['target']['fps'] == value['fps'], 'declared frame rates differ')
        story = StoryPlan.from_dict(value['presentation']['story'])
        self.narration = ''.join(s['narration'] for s in story.stage('shots')['shots'])
        self.frames = story.stage('shots')['shots'][-1]['start_frame'] + story.stage('shots')['shots'][-1]['duration_frames']
        scene = value['scene']
        need(isinstance(scene, dict) and scene.get('durationFrames') == self.frames
             and scene.get('narration') == self.narration and scene.get('sourceStartFrame') == 0
             and scene.get('speed') == 1 and scene.get('pauseFrames', 0) == 0 and not scene.get('locked')
             and not any(scene.get(k) for k in ('voice', 'speechPlan', 'storyCausality', 'storyActions')),
             'supply an unapproved explicit stage without injected voice or causal claims')
        need(scene.get('captions', []) == [] and scene.get('evidenceIDs', []) == [],
             'captions and actual evidence bindings are attached by the normal workflow')
        self.rows = {}
        materials = value['materials']
        need(isinstance(materials, dict) and 1 <= len(materials) <= 128, 'bounded nonempty material declaration required')
        for key, row in materials.items():
            need(isinstance(key, str) and re.fullmatch(r'[A-Za-z0-9_-]{1,80}', key), 'stable material key required')
            need(key != 'voice', 'voice is reserved for the complete imported narration')
            object_keys(row, ('path', 'sha256', 'source', 'owner', 'claim', 'license'))
            path = regular(row['path'], self.path.parent)
            need(re.fullmatch('[0-9a-f]{64}', row['sha256']) and sha(path.read_bytes()) == row['sha256']
                 and all(isinstance(row[k], str) and 1 <= len(row[k]) <= 4000
                         for k in ('source', 'owner', 'claim', 'license')), 'original material bytes/provenance differ')
            self.rows[key] = dict(deepcopy(row), path=path)
        # Resolve all symbols before a workspace or input directory is written.
        self.bind(value['scene'], {key: dict(asset_id='asset-' + key, evidence_id='evidence-' + key)
                                  for key in self.rows})
        actions = value.get('motion_actions', [])
        need(isinstance(actions, list) and len(actions) <= 256
             and len({a.get('id') for a in actions}) == len(actions), 'bounded unique authored motion required')

    def bind(self, value, assets):
        if isinstance(value, dict):
            if set(value) in ({'$asset'}, {'$source'}):
                marker = next(iter(value)); key = value[marker]
                need(isinstance(key, str) and key in self.rows and key in assets,
                     'scene references an undeclared material')
                if marker == '$asset':
                    return assets[key]['asset_id']
                row = self.rows[key]
                return dict(assetID=assets[key]['asset_id'], evidenceID=assets[key]['evidence_id'],
                            hash=row['sha256'], source=row['source'], owner=row['owner'], license=row['license'])
            need(not any(str(k).startswith('$') for k in value), 'unknown production material symbol')
            return {k: self.bind(v, assets) for k, v in value.items()}
        if isinstance(value, list):
            return [self.bind(v, assets) for v in value]
        return deepcopy(value)

    def presentation_for(self, project, scene_ids):
        result = deepcopy(self.value['presentation'])
        current = project['revisions'][-1]
        result['target'].update(workspace_id=project['workspaceID'], project_id=project['id'],
                                base_revision=current['id'], scene_id=current['scenes'][0]['id'])
        need(set(scene_ids) == {s['id'] for s in result['sources']}, 'explicit source identities differ')
        for source in result['sources']:
            source['scene_id'] = scene_ids[source['id']]
        return result

    def requirements(self):
        return {key: dict(path=row['path'], sha256=row['sha256']) for key, row in self.rows.items()}

    def stage(self, identity, timed, assets):
        need(timed['frames'] == self.frames and timed['axis']['fps'] == self.value['fps'],
             'author this stage on the actual full voice axis; do not silently stretch scene motion')
        scene = self.bind(self.value['scene'], assets)
        scene['id'] = identity
        scene['captions'] = deepcopy(timed['captions'])
        scene['evidenceIDs'] = list(dict.fromkeys(item['evidence_id'] for item in assets.values()))
        return scene

    def animate(self, scene, timed, assets):
        result = deepcopy(scene)
        if 'motion_actions' in self.value:
            result['storyActions'] = deepcopy(self.value['motion_actions'])
        return result


class DocumentProduction(ProductionWorkflow):
    """Normal API caller: one declaration, one frozen source set, one job.

    Optional executor/catalog use the installed Host's ordinary CLI. Its own
    signature, trust, compatibility and entitlement gates remain authoritative.
    """
    SOURCE_NAMESPACE = 'video/knowledge-document/v1/'

    def __init__(self, args):
        self.document = ProductionDocument(args.document)
        value = self.document.value
        self.AUTHOR = self.document
        self.VOICE_IDENTIFIER = value['voice_identifier']
        self.ASPECT, self.FPS, self.VIEWPORT = value['aspect'], value['fps'], tuple(value['viewport'])
        self.executor = getattr(args, 'executor', None)
        self.catalog = getattr(args, 'catalog', None)
        need((self.executor is None) == (self.catalog is None), 'supply both installed advanced Host and catalog')
        self.runtime_inputs = []
        if self.executor is not None:
            self.executor = regular(self.executor, self.document.path.parent)
            self.catalog = Path(self.catalog).resolve(strict=True)
            need(self.catalog.is_dir() and not Path(args.catalog).is_symlink(), 'ordinary installed catalog required')
            self.runtime_inputs.append(self.executor)
            for path in sorted(self.catalog.rglob('*')):
                need(not path.is_symlink(), 'catalog must not contain symlinks')
                if path.is_file():
                    self.runtime_inputs.append(path)
            need(1 < len(self.runtime_inputs) <= 1024, 'bounded installed catalog required')
        self.retained = None
        self.voice = args.voice.resolve(strict=True)
        witness = value.get('retained_speech')
        if witness is not None:
            need(args.boundaries is None, 'choose retained exact speech or actual SDK words, never both')
            self.retained = FrozenSpeech(witness, self.voice, self.speech_receipt_fields(), value['presentation'])
        super().__init__(args)

    def implementation_inputs(self):
        return [Path(__file__), Path(inspect.getfile(FrozenSpeech)), self.document.path, *self.runtime_inputs]

    def narration(self):
        return self.document.narration

    def model_sources(self):
        return {s['id']: deepcopy(s['model']) for s in self.document.value['presentation']['sources']}

    def presentation_for(self, project, scene_ids):
        return self.document.presentation_for(project, scene_ids)

    def source_scene(self, identity, model, seed):
        return dict(id=identity, kind='规则模拟', title=self.production_name() + '·原生来源', body='', narration='',
            durationFrames=(_last_tick(model) + 1) * self.FPS, sourceStartFrame=0, speed=1,
            preservePitch=True, locked=False, x=.5, y=.5, scale=1, voiceGain=1, sourceGain=0,
            musicGain=0, muted=False, pauseFrames=0, captions=[], evidenceIDs=[], keyframes=[], layers=[],
            simulation=dict(seed=seed, initial=0, capacity=1, unit=model['resourceLabel'], events=[], knowledge=deepcopy(model)),
            character='', emotion='', color='FFFFFF', showPrice=False, classicArtworkRequired=False)

    def speech_inputs(self, args):
        witness = self.document.value.get('retained_speech')
        if witness is None:
            need(args.boundaries is not None, 'the same-request SDK WordBoundary input is required')
            return super().speech_inputs(args)
        need(args.boundaries is None, 'choose retained exact speech or actual SDK words, never both')
        need(self.retained is not None, 'retained speech must be validated before creating the production home')
        self.boundaries = None
        return self.retained.paths

    def source_speech_inputs(self):
        return (self.voice, self.voice.with_suffix('.source.md')) if self.retained else super().source_speech_inputs()

    def speech_provenance_kind(self):
        return 'retained-complete-axis' if self.retained else 'observed-sdk-words'

    def word_boundary_sha256(self):
        return self.retained.boundaries_sha256 if self.retained else super().word_boundary_sha256()

    def load_speech_axis(self, fields, axis):
        if self.retained is None:
            return super().load_speech_axis(fields, axis)
        result = deepcopy(self.retained.timed)
        dummy = dict(id='target', workspaceID='workspace', revisions=[dict(id='initial',
            scenes=[dict(id='stage')])])
        result['presentation'] = self.presentation_for(dummy, {k: self.uid('source-' + k) for k in self.model_sources()})
        return result

    def production_name(self):
        return self.document.value['name']

    def production_description(self):
        timing = '复用原工程已冻结完整声轴；历史词界身份与计数保留，本次未重验SDK词界文件。' if self.retained else '完整原音与同请求SDK词界绑定。'
        return timing + '知识、人物、源规则、布局与动作由声明输入；Core实际录制、因果重算与正常制作，不授完整看听或上传权。'

    def material_evidence(self, key, path, digest, asset_id):
        result = super().material_evidence(key, path, digest, asset_id)
        if key in self.document.rows:
            row = self.document.rows[key]
            result.update(source=row['source'], owner=row['owner'], claim=row['claim'])
        return result

    def execute_job(self, status):
        if self.executor is None:
            return super().execute_job(status)
        status = self.recover_job(status)
        if status is None or status['state'] != 'queued':
            return status
        body = dict(workspace_id=self.ws, job_id=status['job_id'])
        key = sha(data(dict(command='jobs run', body=body, dry=False, directory=str(self.workspace))))
        body['request_id'] = self.uid(key)
        argv = [str(self.executor), 'jobs', 'run', '--catalog', str(self.catalog),
                '--workspace', str(self.workspace), '--input', '-']
        for dry in (True, False):
            self.check()
            result = subprocess.run(['rtk', 'proxy', *argv, *(['--dry-run'] if dry else [])],
                                    input=data(body), capture_output=True, timeout=660)
            need(not result.stderr and len(result.stdout) <= 32 * 1024 * 1024, 'bounded normal Host response required')
            value = json.loads(result.stdout)
            need(result.returncode == 0 and value.get('ok') is True and value.get('request_id') == body['request_id'],
                 'normal Host rejected: ' + str(value.get('error')))
            self.calls.append(dict(command='jobs run', dry=dry, state=value['state']))
            if not dry:
                save(self.home/'executor-receipt.plist', value)
        return self.invoke('jobs status', dict(workspace_id=self.ws, job_id=status['job_id']))
