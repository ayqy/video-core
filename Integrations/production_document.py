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
from production_runtime import checked_runtime, checked_importer
from presenter_composition import compose as compose_presenter, validate_profile
from speech_energy import analyze_take
from sdk_material_import import invoke_import, validate_receipt, validate_spec
from scene_layout import present


def project_presentation(value, projection):
    """Change only explicit display coordinates; source semantics stay exact."""
    result=deepcopy(value)
    if projection is None:return result
    object_keys(projection,('mode','anchors'),('balance_subjects',))
    need(projection['mode'] in ('pencil','game'),'explicit supported presentation mode required')
    result['target']['mode']=projection['mode']
    result['anchors']=deepcopy(projection['anchors'])
    subjects=projection.get('balance_subjects',{})
    need(isinstance(subjects,dict),'explicit balance subject mapping required')
    for balance in result.get('balances',[]):
        if balance['actor_id'] in subjects:
            balance['entity_id']=subjects[balance['actor_id']]
    need(set(subjects)<={b['actor_id'] for b in result.get('balances',[])},'cannot invent balance observations')
    _plan(result)
    return result


def object_keys(value, required, optional=()):
    need(isinstance(value, dict) and set(required) <= set(value)
         and set(value) <= set(required) | set(optional), 'unknown or missing production document field')


def regular(path, base):
    path = Path(path)
    path = path if path.is_absolute() else base / path
    need(path.is_file() and not path.is_symlink(), 'declared source must be an ordinary existing file')
    return path.resolve()


def validate_source_revision(receipt, project, reused):
    """Permit interrupted normal recording, preserving the exact source design."""
    need(receipt['workspaceID']==project['workspaceID'] and receipt['projectID']==project['id'],
         'the SDK receipt belongs to another source project')
    revisions=project['revisions']; ids=[r['id'] for r in revisions]
    need(len(ids)==len(set(ids)) and ids.count(receipt['baseRevision'])==1,
         'the SDK source revision is absent or ambiguous')
    index=ids.index(receipt['baseRevision'])
    need(reused or index==len(revisions)-1,'a new SDK import must bind the actual current source revision')
    def design(revision):
        value=deepcopy(revision)
        for key in ('id','parentID','number','createdAt','change','invalidated'):value.pop(key,None)
        if isinstance(value.get('dependencies'),dict):value['dependencies'].pop('capturedAt',None)
        for scene in value['scenes']:
            confirmation=scene.pop('simulationRecordingConfirmed',None)
            need(confirmation is None or (type(confirmation) is bool and not confirmation),
                 'normal recording recovery cannot grant or inherit a confirmation')
            scene.pop('simulationRecording',None)
        return value
    original=design(revisions[index])
    for previous,current in zip(revisions[index:],revisions[index+1:]):
        need(current.get('parentID')==previous['id'] and design(current)==original,
             'retained SDK sources must remain on the unchanged normal recording ancestry')
        scenes={s['id']:s for s in current['scenes']}
        need(all(not s.get('simulationRecording') or
                 scenes[s['id']].get('simulationRecording')==s['simulationRecording']
                 for s in previous['scenes']), 'a retained source recording was replaced or removed')


class ProductionDocument:
    def __init__(self, path):
        self.path = Path(path).resolve(strict=True)
        need(not Path(path).is_symlink() and self.path.stat().st_size <= 8 * 1024 * 1024,
             'bounded ordinary production document required')
        self.value = read(self.path)
        value = self.value
        object_keys(value, ('version', 'name', 'voice_identifier', 'aspect', 'fps', 'viewport',
                           'presentation', 'scene', 'materials'),
                    ('motion_actions','retained_speech','projection','presenter','sdk_import','supporting_files',
                     'story_layout'))
        need(type(value['version']) is int and value['version'] == 1
             and isinstance(value['name'], str) and 1 <= len(value['name']) <= 200
             and isinstance(value['voice_identifier'], str) and 1 <= len(value['voice_identifier']) <= 200,
             'explicit production name and source voice identifier required')
        need(value['aspect'] in ('16:9', '9:16') and value['fps'] == 30
             and value['viewport'] == ([1280, 720] if value['aspect'] == '16:9' else [720, 1280]),
             'use a declared supported normal project format')
        _plan(value['presentation'])
        projected=project_presentation(value['presentation'],value.get('projection'))
        need(not (value.get('presenter') and projected['target']['mode']=='game'),
             'keep the independent narrator and game presentation explicit and separate')
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
        need(len({r['sha256'] for r in self.rows.values()})==len(self.rows),
             'one material declaration per original hash; reuse its symbol instead of conflicting aliases')
        self.supporting=[]
        support=value.get('supporting_files',[])
        need(isinstance(support,list) and len(support)<=64,'bounded supporting provenance files required')
        for row in support:
            object_keys(row,('path','sha256'))
            path=regular(row['path'],self.path.parent)
            need(sha(path.read_bytes())==row['sha256'],'supporting source or metadata changed')
            self.supporting.append(path)
        sdk=value.get('sdk_import')
        if sdk is not None:
            object_keys(sdk,('version','kind','resources','materials'))
            need(type(sdk['version']) is int and sdk['version']==1 and sdk['kind']=='mota-world'
                 and isinstance(sdk['materials'],dict) and len(sdk['materials'])==15
                 and set(sdk['materials'])<=set(self.rows),'declare the complete supported SDK pack explicitly')
            resource=Path(sdk['resources'])
            need(resource.is_absolute() and resource.is_dir() and not resource.is_symlink(),
                 'the actual complete SDK resource directory is required')
            validate_spec(sdk,{k:self.rows[k] for k in sdk['materials']})
        profile=value.get('presenter')
        if profile is not None:
            need(self.frames<=60*value['fps'], 'the current actual RMS analyzer supports at most sixty seconds')
            validate_profile(profile,self.frames,viewport=value['viewport'])
            need(profile['material_key'] in self.rows,'the presenter needs its explicitly declared actual original')
            need(scene.get('kind')=='图文讲解' and not any(scene.get(k) for k in
                 ('gameWorld','cartoonRig','cartoonPerformance','cartoonPresenter','classicArtwork')),
                 'the narrator needs a complete independent pencil stage')
            need(profile['id'] not in {v.get('id') for v in scene.get('layers',[])},
                 'the narrator cannot own or replace a business layer')
        self.energy=None
        self.voice_sha256=None
        # Resolve all symbols before a workspace or input directory is written.
        self.bind(value['scene'], {key: dict(asset_id='asset-' + key, evidence_id='evidence-' + key)
                                  for key in self.rows})
        actions = value.get('motion_actions', [])
        need(isinstance(actions, list) and len(actions) <= 256
             and len({a.get('id') for a in actions}) == len(actions), 'bounded unique authored motion required')
        if profile is not None:
            draft = deepcopy(scene)
            draft['storyActions'] = deepcopy(actions)
            validate_profile(profile, self.frames, viewport=value['viewport'], scene=draft)
        layout = value.get('story_layout')
        if layout is not None:
            object_keys(layout, ('mode',), ('bounds',))
            need(layout['mode'] == 'plain' and profile is None and projected['target']['mode'] == 'pencil',
                 'an explicit plain story layout is separate from game and presenter composition')
            draft = deepcopy(scene)
            draft['storyActions'] = deepcopy(actions)
            present(draft, 'plain', viewport=value['viewport'], target_bounds=layout.get('bounds'))

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
        result = project_presentation(result,self.value.get('projection'))
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
        layout = self.value.get('story_layout')
        if layout is not None:
            result = present(result, layout['mode'], viewport=self.value['viewport'],
                             target_bounds=layout.get('bounds'))
            result.pop('layout_projection', None)
            result.pop('layout_profile', None)
        if self.value.get('presenter') is not None:
            actual={}
            for key,row in self.rows.items():
                binding=assets[key]
                actual[key]=dict(binding,path=str(row['path']),sha256=row['sha256'],
                    source=dict(assetID=binding['asset_id'],evidenceID=binding['evidence_id'],
                        hash=row['sha256'],source=row['source'],owner=row['owner'],license=row['license']))
            measured=deepcopy(timed)
            measured['voice_sha256']=self.voice_sha256
            result=compose_presenter(result,measured,self.value['presenter'],actual,self.energy,
                                    viewport=self.value['viewport'])
        return result


class DocumentProduction(ProductionWorkflow):
    """Normal API caller: one declaration, one frozen source set, one job.

    Optional executor/catalog use the installed Host's ordinary CLI. Its own
    signature, trust, compatibility and entitlement gates remain authoritative.
    """
    SOURCE_NAMESPACE = 'video/knowledge-document/v1/'
    MOTION_FIELDS=ProductionWorkflow.MOTION_FIELDS|frozenset(('kind','body','paperPresentation',
        'classicArtworkRequired','classicArtwork','cartoonPresenter'))

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
        self.runtime=getattr(args,'runtime',None)
        advanced=value.get('presenter') is not None or project_presentation(value['presentation'],value.get('projection'))['target']['mode']=='game'
        if advanced:
            need(self.runtime is not None,'advanced presentation requires its actual complete verified runtime group')
        if self.runtime is not None:
            self.runtime=Path(self.runtime).resolve(strict=True)
            self.runtime_inputs += list(map(Path,checked_runtime(self.runtime)))
            need(self.executor is not None and Path(self.executor).resolve()==self.runtime/'native/video-advanced'
                 and Path(self.catalog).resolve()==self.runtime/'catalog',
                 'the executor and catalog must belong to this exact verified runtime')
            need(args.binary.resolve()==self.runtime/'native/video','the Core CLI must belong to this same normal runtime')
        self.world_importer=getattr(args,'world_importer',None)
        if value.get('sdk_import') is not None:
            need(self.world_importer is not None,'the SDK pack needs its actual authorized importer')
            self.world_importer=regular(self.world_importer,self.document.path.parent)
            receipt=getattr(args,'world_importer_receipt',None)
            need(self.runtime is not None and receipt is not None,
                 'the SDK importer needs its current link receipt and complete normal runtime')
            receipt=regular(receipt,self.document.path.parent)
            self.runtime_inputs+=list(map(Path,checked_importer(self.world_importer,
                getattr(args,'world_importer_sha256',None),receipt,self.runtime)))
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
        paths=[Path(__file__),Path(inspect.getfile(FrozenSpeech)),self.document.path,
               Path(inspect.getfile(checked_runtime)),*self.document.supporting,*self.runtime_inputs]
        if self.document.value.get('presenter') is not None:
            paths += [Path(inspect.getfile(compose_presenter)),Path(inspect.getfile(analyze_take)),
                      Path(__file__).with_name('scene_layout.py')]
        elif self.document.value.get('story_layout') is not None:
            paths.append(Path(inspect.getfile(present)))
        if self.document.value.get('sdk_import') is not None:
            paths.append(Path(inspect.getfile(invoke_import)))
        return paths

    def material_snapshot(self,label):
        response=self.invoke('backup create',dict(request_id=self.uid('material-snapshot-'+label)))
        artifact=response['artifacts'][0];raw=Path(artifact['path']).read_bytes()
        need(sha(raw)==artifact['sha256'],'normal material snapshot artifact differs')
        archive=plistlib.loads(raw)
        need(sha(archive['snapshot'])==archive['digest'],'normal material snapshot digest differs')
        return json.loads(archive['snapshot'])

    def import_materials(self,source_project):
        spec=self.document.value.get('sdk_import')
        if spec is None:return super().import_materials(source_project)
        declared={key:self.document.rows[key] for key in spec['materials']}
        proof=self.home/'sdk-material-import.plist'
        reused=proof.exists()
        if reused:
            receipt=read(proof);after=self.material_snapshot('retained-sdk')
        else:
            before=self.material_snapshot('before-sdk')
            self.check()
            receipt=invoke_import(self.world_importer,self.workspace,self.ws,source_project['id'],Path(spec['resources']))
            after=self.material_snapshot('after-sdk')
            unchanged=deepcopy(after)
            unchanged.update(generation=before['generation'],assets=before['assets'],evidence=before['evidence'])
            need(unchanged==before,'the normal SDK import changed another business table')
            added_assets=[a for a in after['assets'] if a['id'] not in {v['id'] for v in before['assets']}]
            added_proofs=[a for a in after['evidence'] if a['id'] not in {v['id'] for v in before['evidence']}]
            for table in ('assets','evidence'):
                current={v['id']:v for v in after[table]}
                need(all(current.get(v['id'])==v for v in before[table]),
                     'the SDK importer changed or removed an existing original')
            need({v['id'] for v in added_assets}=={v['assetID'] for v in receipt['assetsByPath'].values()}
                 and {v['id'] for v in added_proofs}=={v['evidenceID'] for v in receipt['assetsByPath'].values()},
                 'new SDK rows must equal exactly the declared normal receipt identities')
            need(len(added_assets)==len(added_proofs)==15
                 and after['generation']==before['generation']+1,
                 'the declared new SDK pack must append exactly fifteen real sources in one transaction')
            save(proof,receipt)
        result=validate_receipt(receipt,spec,declared,self.ws,source_project['id'],
            receipt['baseRevision'],after['assets'],after['evidence'])
        validate_source_revision(receipt,source_project,reused)
        for key,row in self.author.requirements().items():
            if key not in declared:result[key],_=self.imported(key,row['path'],row['sha256'])
        return result

    def animate_scene(self,scene,assets):
        if self.document.value.get('presenter') is not None:
            voice=scene['voice'];profile=self.document.value['presenter'];source_hash=sha(self.voice.read_bytes())
            energy=analyze_take(self.voice,source_sha256=source_hash,voice_asset_id=voice['assetID'],
                text_digest=voice['textDigest'],actor_id=profile['id'],duration_frames=self.timed['frames'],
                fps=self.FPS,decoder=self.ffmpeg)
            save(self.home/'presenter-energy.plist',energy)
            self.document.energy=energy
            self.document.voice_sha256=source_hash
        return super().animate_scene(scene,assets)

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
