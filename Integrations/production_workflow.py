#!/usr/bin/env python3
"""Reusable full original-speech production through the ordinary free CLI.

Author hooks supply an explicit story and native source models. The engine owns
normal imports/evidence, source recording and presentation CAS, frozen inputs,
original quote/job recovery, complete media verification and independent backup
restoration. Pure orchestration tests are never product or listening evidence.
"""
from copy import deepcopy
from datetime import datetime, timezone
from decimal import Decimal
import array
import hashlib
import inspect
import json
import math
from pathlib import Path
import plistlib
import re
import shutil
import sqlite3
import subprocess
import uuid

from knowledge_story import record_sources,apply_presentation,_last_tick,_trace
from readaloud_tts import inspect_mp3,read_word_boundaries
from story_speech import retime_presentation

ROOT=Path(__file__).resolve().parents[1]


def need(ok,message):
    if not ok:raise ValueError(message)
def sha(raw):return hashlib.sha256(raw).hexdigest()
def data(value):return json.dumps(value,sort_keys=True,ensure_ascii=False,separators=(',',':'),allow_nan=False).encode()
def unpack(value):return json.loads(value['result']) if isinstance(value.get('result'),str) else value.get('result')
def save(path,value):
    raw=plistlib.dumps(value,fmt=plistlib.FMT_BINARY,sort_keys=True)
    if path.exists():need(path.read_bytes()==raw,'preserve frozen '+path.name)
    else:path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(raw)
def read(path):return plistlib.loads(path.read_bytes())


def preserve_artifacts(artifacts,output,*,revision_id,source_root):
    """Preserve four native originals, changing only copied receipt paths.

    All source identities, bytes and existing destination conflicts are checked
    before creating the output directory or writing a file. Equal existing
    files are reused; different bytes are never overwritten. This is not a
    filesystem transaction across I/O failures and does not inspect media.
    """
    identity=lambda value:isinstance(value,str) and re.fullmatch(r'[A-Za-z0-9._-]{1,128}',value) is not None
    def canonical(value,label):
        need(isinstance(value,(str,Path)) and '\x00' not in str(value),label+' must be an ordinary absolute path')
        path=Path(value)
        need(path.is_absolute() and not path.is_symlink() and path.resolve()==path,
             label+' must be canonical and contain no symlink')
        return path
    need(identity(revision_id),'the exact native revision identity is required')
    root=canonical(source_root,'artifact source root');out=canonical(output,'artifact output')
    need(root.is_dir(),'the actual artifact source root must be an existing ordinary directory')
    need(not out.exists() or out.is_dir(),'artifact output must be an ordinary directory')
    required={'id','path','mime','bytes','sha256','revision'}
    mimes={'video/mp4','image/png','application/x-subrip','text/plain'}
    need(isinstance(artifacts,list) and len(artifacts)==4
         and all(isinstance(a,dict) and required<=set(a) and identity(a['id'])
                 and isinstance(a['mime'],str) and type(a['bytes']) is int and a['bytes']>0
                 and isinstance(a['sha256'],str) and re.fullmatch(r'[0-9a-f]{64}',a['sha256'])
                 and a['revision']==revision_id for a in artifacts),
         'four complete native artifact identities must bind the same revision')
    need({a['mime'] for a in artifacts}==mimes and len({a['id'] for a in artifacts})==4,
         'the four native artifact MIME types and identities must be unique')
    prepared=[];sources=set();targets=set()
    for artifact in artifacts:
        source=canonical(artifact['path'],'artifact original')
        need(source.is_relative_to(root) and source.is_file() and source not in sources,
             'every artifact must be a unique ordinary original inside the actual source root')
        sources.add(source)
        raw=source.read_bytes()
        need(len(raw)==artifact['bytes'] and sha(raw)==artifact['sha256'],'real artifact original bytes differ')
        target=out/source.name
        need(target not in targets and not target.is_symlink(),
             'artifact output names must be unique ordinary files')
        targets.add(target)
        if target.exists():
            need(target.is_file() and target.read_bytes()==raw,'preserve existing artifact output; different bytes cannot be overwritten')
        prepared.append((target,raw))
    # Validation is complete for all four originals and all existing targets.
    out.mkdir(parents=True,exist_ok=True)
    for target,raw in prepared:
        if target.exists():
            need(not target.is_symlink() and target.is_file() and target.read_bytes()==raw,
                 'preserve existing artifact output; different bytes cannot be overwritten')
            continue
        try:
            with target.open('xb') as handle:handle.write(raw)
        except FileExistsError:
            need(not target.is_symlink() and target.is_file() and target.read_bytes()==raw,
                 'preserve concurrently created artifact output; different bytes cannot be overwritten')
    result=deepcopy(artifacts)
    for artifact,(target,_) in zip(result,prepared):artifact['path']=str(target)
    return result


class ProductionWorkflow:
    """Ordinary CLI orchestration; authors supply content, never observed results.

    Each subclass declares its author, original speech identity, source namespace
    and output axis. Pure adapter hooks do not replace native recording or real
    media verification. Existing homes retain exact frozen input sets.
    """
    AUTHOR=None
    VOICE_IDENTIFIER=None
    SOURCE_NAMESPACE=None
    ASPECT=None
    FPS=None
    VIEWPORT=None
    LOG_PREFIX='voiced_production'
    EXTRA_INPUTS=()
    MOTION_FIELDS=frozenset(('layers','storyActions'))

    def speech_inputs(self,args):
        self.boundaries=args.boundaries.resolve(strict=True)
        return [self.boundaries]

    def source_speech_inputs(self):
        return (self.voice,self.voice.with_suffix('.source.md'),self.boundaries)

    def word_boundary_sha256(self):
        return sha(self.boundaries.read_bytes())

    def speech_provenance_kind(self):
        return 'observed-sdk-words'

    def speech_receipt_fields(self):
        rows=re.findall(r'(?m)^\|([^|\n]+)\|([^|\n]*)\|$',self.voice.with_suffix('.source.md').read_text())
        fields={k:v for k,v in rows}
        need(len(fields)==len(rows),'the original voice receipt repeats a field')
        return fields

    def load_speech_axis(self,fields,axis):
        if not axis.exists():
            inspection=inspect_mp3(self.voice,self.ffmpeg,self.ffprobe)
            need(str(inspection['container_duration'])==fields['inspection.container_duration'],'original source duration differs')
        inspection={key:float(fields['inspection.'+key]) for key in ('decoded_duration','container_duration')}
        boundaries=read_word_boundaries(self.boundaries,self.narration(),inspection)
        dummy=dict(id='target',workspaceID='workspace',revisions=[dict(id='initial',fps=self.FPS,
            aspect=self.ASPECT,scenes=[dict(id='stage')])])
        plan=self.presentation_for(dummy,{k:self.uid('source-'+k) for k in self.model_sources()})
        duration=fields['inspection.container_duration']
        if axis.exists():
            observed=read(axis)['axis']['duration_seconds']
            need(Decimal(observed)==Decimal(duration),'retained measured voice duration changed')
            duration=observed
        return retime_presentation(plan,boundaries,duration,fps=self.FPS)

    def production_name(self):
        raise NotImplementedError('declare a production name')

    def production_description(self):
        raise NotImplementedError('describe the authored production and its limits')

    def narration(self):
        raise NotImplementedError('supply the complete original narration')

    def model_sources(self):
        raise NotImplementedError('supply explicitly identified source models')

    def presentation_for(self,project,scene_ids):
        raise NotImplementedError('supply the source-backed presentation')

    def source_scene(self,identity,model,seed):
        return self.author.source_scene(identity,deepcopy(model),seed)

    def implementation_inputs(self):
        """Additional author/model manifests or helper code to freeze by bytes."""
        return ()

    def controller_input(self):
        return Path(inspect.getfile(type(self))).resolve()

    def implementation_paths(self):
        # Pin the actual caller and its adapter ancestry as well as the engine.
        paths=[Path(__file__).resolve()]
        paths += [Path(inspect.getfile(cls)).resolve() for cls in type(self).__mro__
                  if isinstance(cls,type) and issubclass(cls,ProductionWorkflow)]
        owner=self.author if inspect.ismodule(self.author) or inspect.isclass(self.author) else type(self.author)
        paths.append(Path(inspect.getfile(owner)).resolve())
        paths += [ROOT/'Integrations'/name for name in
                  ('knowledge_story.py','story_speech.py','story_action.py','story_planning.py','readaloud_tts.py')]
        paths += [Path(p).resolve() for p in self.implementation_inputs()]
        paths += [Path(p).resolve() for p in self.EXTRA_INPUTS]
        return paths

    def workspace_name(self):return self.production_name()+'·独立本地教学'
    def source_project_name(self):return self.production_name()+'·完整原生来源'
    def target_project_name(self):return self.production_name()
    def voice_material_name(self):return self.production_name()+'·完整原音'
    def motion_edit_description(self):return '为真实来源动作添加独立人物表现；保原音与原因果'

    def import_materials(self,source_project):
        """Ordinary originals; specialized SDK batches override only this step.

        The actual source project already exists, so a batch importer can bind
        authorization to its current identity without making a dummy project.
        """
        assets={}
        for key,row in self.author.requirements().items():
            assets[key],_=self.imported(key,row['path'],row['sha256'])
        return assets

    def __init__(self,args):
        self.author=self.AUTHOR
        need(self.author is not None and isinstance(self.VOICE_IDENTIFIER,str) and self.VOICE_IDENTIFIER
            and isinstance(self.SOURCE_NAMESPACE,str) and self.SOURCE_NAMESPACE,
            'declare the author, original voice identifier and source namespace')
        need(self.ASPECT in ('16:9','9:16','1:1') and type(self.FPS) is int and 1<=self.FPS<=120
            and isinstance(self.VIEWPORT,tuple) and len(self.VIEWPORT)==2
            and all(type(n) is int and n>0 for n in self.VIEWPORT),
            'declare the supported aspect, finite frame rate and output viewport')
        self.args=args;self.home=args.home.resolve();self.out=args.output.resolve()
        need(not args.home.is_symlink() and not args.output.is_symlink(),'ordinary dedicated home/output required')
        self.home.mkdir(parents=True,exist_ok=True);self.out.mkdir(parents=True,exist_ok=True)
        self.binary=args.binary.resolve(strict=True);self.voice=args.voice.resolve(strict=True)
        self.workspace=self.home/'workspace'
        speech_paths=self.speech_inputs(args)
        self.ffmpeg=Path(shutil.which('ffmpeg')).resolve();self.ffprobe=Path(shutil.which('ffprobe')).resolve()
        need(sha(self.binary.read_bytes())==args.binary_sha256,'current normal Release binary differs')
        paths=[*self.implementation_paths(),self.binary,self.voice,self.voice.with_suffix('.source.md'),
               *speech_paths,self.ffmpeg,self.ffprobe]
        paths += [Path(v['path']).resolve() for v in self.author.requirements().values()]
        self.pins={str(p):sha(p.read_bytes()) for p in paths}
        inputs=self.home/'inputs.plist'
        upgraded_inputs=None
        if inputs.exists() and read(inputs)!=self.pins:
            # An explicit, hash-bound controller upgrade retains the original
            # workspace, quote/job and every media/source input. Other changes
            # need a separately authored production; they cannot be waved away.
            original=read(inputs);old_hash=sha(inputs.read_bytes());own=str(Path(self.controller_input()).resolve())
            need(getattr(args,'previous_inputs_sha256',None)==old_hash and set(original)==set(self.pins)
                and {p for p in original if original[p]!=self.pins[p]}=={own}
                and any(p.is_file() and sha(p.read_bytes())==original[own] for p in
                    (self.home/'original-controller.py',self.home/'controller-history'/(original[own]+'.py'))),
                'only an explicit retained-controller upgrade may continue these exact inputs')
            upgraded_inputs=old_hash
            save(self.home/'input-history'/(old_hash+'.plist'),original)
            pending=self.home/'inputs.upgrade.plist';save(pending,self.pins);pending.replace(inputs)
        save(inputs,self.pins)
        self.state=sqlite3.connect(self.home/'requests.sqlite')
        self.state.execute('CREATE TABLE IF NOT EXISTS requests (key TEXT PRIMARY KEY, response BLOB NOT NULL)')
        self.calls=[]
        fields=self.speech_receipt_fields()
        need(fields.get('audio_sha256')==sha(self.voice.read_bytes())
            and fields.get('word_boundaries.sha256')==self.word_boundary_sha256()
            and fields.get('request.text')==self.narration()
            and fields.get('request.voice')==self.VOICE_IDENTIFIER
            and fields.get('request.configuration.boundary')=='WordBoundary',
            'the original receipt must bind this exact full text, voice and same-request word metadata')
        axis=self.home/'speech-axis.plist'
        self.timed=self.load_speech_axis(fields,axis)
        need(self.timed['axis']['fps']==self.FPS and type(self.timed['frames']) is int
            and 1<=self.timed['frames']<=54000,'the complete speech axis must retain the declared finite frame rate')
        save(axis,self.timed)
        self.pins[str(axis)]=sha(axis.read_bytes())
        kind=self.speech_provenance_kind()
        need(kind in ('observed-sdk-words','retained-complete-axis'),'declare the actual speech-axis construction mode')
        provenance=self.home/'speech-provenance.plist'
        speech_proof=dict(version=1,axis_sha256=sha(axis.read_bytes()),inputs_sha256=sha(inputs.read_bytes()),
            voice_sha256=sha(self.voice.read_bytes()),source_receipt_sha256=sha(self.voice.with_suffix('.source.md').read_bytes()),
            word_boundaries_sha256=self.word_boundary_sha256(),kind=kind)
        if provenance.exists() and read(provenance)!=speech_proof:
            original_proof=read(provenance)
            need(upgraded_inputs is not None and original_proof==dict(speech_proof,inputs_sha256=upgraded_inputs),
                'only the authorized controller input identity may advance the same frozen speech provenance')
            save(self.home/'speech-provenance-history'/(sha(provenance.read_bytes())+'.plist'),original_proof)
            pending=self.home/'speech-provenance.upgrade.plist';save(pending,speech_proof);pending.replace(provenance)
        save(provenance,speech_proof)
        self.pins[str(inputs)]=sha(inputs.read_bytes())
        self.pins[str(provenance)]=sha(provenance.read_bytes())

    def uid(self,name):return str(uuid.uuid5(uuid.NAMESPACE_URL,'video/'+self.SOURCE_NAMESPACE+'/'+str(self.home)+'/'+name))
    def check(self):need(all(sha(Path(p).read_bytes())==h for p,h in self.pins.items()),'frozen source, voice or runtime changed')
    def invoke(self,command,body=None,dry=False,*,directory=None):
        self.check();body=deepcopy(body or {});directory=directory or self.workspace
        key=sha(data(dict(command=command,body=body,dry=dry,directory=str(directory))))
        body.setdefault('request_id',self.uid(key))
        reading=command in {'projects list','assets list','doctor','jobs status','knowledge compare','render estimate','speech normalize','jobs run','jobs resume','worker run'}
        cached=self.state.execute('SELECT response FROM requests WHERE key=?',(key,)).fetchone()
        if cached and not reading:return json.loads(cached[0])
        argv=[str(self.binary),*command.split(),'--workspace',str(directory),'--input','-']+(['--dry-run'] if dry else [])
        r=subprocess.run(['rtk','proxy',*argv],input=data(body),stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=660 if command=='jobs run' else 120)
        need(len(r.stdout)<=32*1024*1024 and not r.stderr,'bounded normal envelope required')
        v=json.loads(r.stdout)
        need(r.returncode==0 and v.get('ok') is True and v.get('request_id')==body['request_id'],command+' rejected: '+str(v.get('error')))
        self.calls.append(dict(command=command,dry=dry,state=v.get('state','')))
        if not reading:self.state.execute('INSERT OR REPLACE INTO requests VALUES (?,?)',(key,data(v)));self.state.commit()
        return v
    def write(self,command,body):self.invoke(command,body,True);return self.invoke(command,body)
    def project(self,identity):return next(p for p in unpack(self.invoke('projects list',dict(workspace_id=self.ws))) if p['id']==identity)
    def probe(self,path):
        r=subprocess.run(['rtk','proxy',str(self.ffprobe),'-v','error','-show_streams','-show_format','-of','json',str(path)],capture_output=True,timeout=30)
        need(r.returncode==0 and not r.stderr,'actual media probe failed');return json.loads(r.stdout)
    def imported(self,key,path,digest):
        need(sha(path.read_bytes())==digest,'actual source material differs')
        asset=unpack(self.write('assets import',dict(workspace_id=self.ws,path=str(path))))
        need(asset['hash']==digest,'normal importer changed original bytes')
        proof=self.material_evidence(key,path,digest,asset['id'])
        self.write('evidence add',dict(workspace_id=self.ws,evidence=proof))
        return dict(asset_id=asset['id'],evidence_id=proof['id']),asset

    def material_evidence(self,key,path,digest,asset_id):
        return dict(id=self.uid('evidence-'+digest),workspaceID=self.ws,assetID=asset_id,title=key,
            source='local-generated:video/'+path.name+'/'+digest,owner='方方生成原件；详情见旁置来源与素材清单',
            claim='原件字节与本地生成来源核对；仅本地教学及管理员效果审核，不授商用、上传或人工看听审核。',
            commercialAllowed=False,uploadConsent=False,verified=True,checkedAt=self.started)

    def animate_scene(self,scene,assets):
        """Add authored motion without changing a business fact or audio take."""
        original=deepcopy(scene)
        animated=self.author.animate(deepcopy(scene),self.timed,deepcopy(assets))
        need(isinstance(animated,dict) and {k:v for k,v in animated.items() if k not in self.MOTION_FIELDS}==
            {k:v for k,v in original.items() if k not in self.MOTION_FIELDS},
            'actor motion may only replace ordinary layers and story actions')
        before={a['id']:a for a in original.get('storyActions',[])}
        after={a['id']:a for a in animated.get('storyActions',[])}
        need(len(after)==len(animated.get('storyActions',[])) and before.keys()<=after.keys(),
            'actor motion must preserve every original action exactly once')
        for identity,action in before.items():
            need({k:v for k,v in action.items() if k not in ('from','to','waypoints')}==
                {k:v for k,v in after[identity].items() if k not in ('from','to','waypoints')},
                'actor motion cannot change business action identity, kind, subject, time, recipient or quantity')
        if original.get('storyCausality') is not None:
            from story_action import actions_for_scene
            subjects={layer['id'] for layer in animated.get('layers',[])}
            subjects.update(entity['id'] for entity in (animated.get('gameWorld') or {}).get('entities',[]))
            subjects.update(actor['id'] for actor in (animated.get('cartoonRig') or {}).get('actors',[]))
            if animated.get('cartoonPresenter'):
                subjects.add(animated['cartoonPresenter']['id'])
            actions_for_scene(animated.get('storyActions',[]),subjects,animated['durationFrames'],
                              causality=original['storyCausality'])
        return animated

    def prepare(self):
        saved=self.home/'prepared.plist'
        if saved.exists():
            state=read(saved);self.ws=state['workspace_id']
            need(self.project(state['project_id'])['revisions'][-1]['id']==state['revision_id'],'preserve prepared revision and original job')
            print(self.LOG_PREFIX+'_prepare_reused');return
        clock=self.home/'started.plist'
        if not clock.exists():save(clock,dict(at=datetime.now(timezone.utc).isoformat(timespec='seconds').replace('+00:00','Z')))
        self.started=read(clock)['at']
        workspace=unpack(self.write('workspaces create',dict(name=self.workspace_name())));self.ws=workspace['id']
        source_scenes={}
        declarations=self.timed['presentation']['sources']
        need(len({s['id'] for s in declarations})==len(declarations) and
            {s['id']:s['model'] for s in declarations}==self.model_sources(),
            'the timed presentation must preserve every explicitly declared source model')
        for spec in declarations:
            identity=self.uid('source-'+spec['id'])
            need(spec['scene_id']==identity,'the presentation must bind the explicit source scene identity')
            scene=self.source_scene(identity,spec['model'],spec['seed'])
            need(scene['id']==identity and scene['simulation']['knowledge']==spec['model']
                and scene['simulation']['seed']==spec['seed']
                and scene['durationFrames']==(_last_tick(spec['model'])+1)*self.FPS,
                'the source author must retain the complete model, seed and native frame axis')
            source_scenes[spec['id']]=scene
        source=self.write('projects create',dict(workspace_id=self.ws,name=self.source_project_name(),aspect=self.ASPECT,scenes=list(source_scenes.values())))
        assets=self.import_materials(self.project(source['project_id']))
        need(set(assets)==set(self.author.requirements()),'material importer must return every declared original exactly once')
        voice_binding,voice_asset=self.imported(self.voice_material_name(),self.voice,sha(self.voice.read_bytes()))
        assets['voice']=voice_binding
        need(voice_asset['durationFrames']==self.timed['frames'],'normal importer and complete measured voice axis differ')
        target=self.write('projects create',dict(workspace_id=self.ws,name=self.target_project_name(),aspect=self.ASPECT,scenes=[self.author.stage(self.uid('presentation'),self.timed,assets)]))
        pid=target['project_id'];current=self.project(pid)
        need(current['revisions'][-1]['fps']==self.FPS and self.project(source['project_id'])['revisions'][-1]['fps']==self.FPS,
            'the normal CLI must support the explicitly declared source and target frame rate')
        attached=self.home/'voice-attached.plist'
        if not attached.exists():
            normalized=unpack(self.invoke('speech normalize',dict(text=self.narration(),dictionary=[])))
            normalized.update(voiceIdentifier=self.VOICE_IDENTIFIER,confirmed=True)
            response=self.write('speech attach',dict(workspace_id=self.ws,project_id=pid,scene_id=self.uid('presentation'),
                base_revision=current['revisions'][-1]['id'],asset_id=voice_binding['asset_id'],speech_plan=normalized,extend_scene=False,timeout_seconds=90))
            save(attached,response)
        current=self.project(pid)
        scene=deepcopy(current['revisions'][-1]['scenes'][0])
        if scene['captions'] != self.timed['captions']:
            scene['captions']=deepcopy(self.timed['captions'])
            self.write('edit apply',dict(workspace_id=self.ws,project_id=pid,base_revision=current['revisions'][-1]['id'],
                edits=[dict(replaceScene={'_0':scene['id'],'_1':scene})],text='按完整新原音同流逐词边界绑定字幕；保持未听审'))
            current=self.project(pid)
        plan=deepcopy(self.timed['presentation']);plan['target'].update(workspace_id=self.ws,project_id=pid,
            base_revision=current['revisions'][-1]['id'],scene_id=self.uid('presentation'))
        recorded=record_sources(self.project(source['project_id']),plan,self.invoke)
        applied=apply_presentation(current,plan,recorded,self.invoke)
        current=self.project(pid);scene=current['revisions'][-1]['scenes'][0]
        animated=self.animate_scene(scene,assets)
        if animated!=scene:
            self.write('edit apply',dict(workspace_id=self.ws,project_id=pid,base_revision=current['revisions'][-1]['id'],
                edits=[dict(replaceScene={'_0':scene['id'],'_1':animated})],
                text=self.motion_edit_description()))
            current=self.project(pid);scene=current['revisions'][-1]['scenes'][0]
        need(scene['voice']['assetID']==voice_binding['asset_id'] and scene['voice']['durationFrames']==self.timed['frames']
            and not scene['voice']['listened'] and scene['captions']==self.timed['captions']
            and not any(current['revisions'][-1]['review'].values()),'keep the complete unapproved original voice and captions')
        save(saved,dict(workspace_id=self.ws,project_id=pid,source_project_id=source['project_id'],revision_id=current['revisions'][-1]['id'],
            recorded=recorded,plan=plan,applied=applied,voice_asset_id=voice_binding['asset_id'],frames=self.timed['frames']))
        print(self.LOG_PREFIX+'_prepared frames='+str(self.timed['frames'])+' sources='+str(len(declarations))+' actual_actions='+str(len(scene['storyActions']))+' review=false')

    def render(self):
        state=read(self.home/'prepared.plist');self.ws=state['workspace_id'];current=self.project(state['project_id'])
        need(current['revisions'][-1]['id']==state['revision_id'],'preserve original production revision')
        qpath=self.home/'quote.plist'
        if not qpath.exists():
            quote=unpack(self.invoke('render estimate',dict(workspace_id=self.ws,project_id=current['id'])))
            need(quote['provider']=='native' and quote['upper']==dict(currency='CNY',amount=0),'normal local zero-fee quote required')
            quote['confirmed']=True;save(qpath,quote)
        submitted=self.invoke('render submit',dict(workspace_id=self.ws,project_id=current['id'],quote=read(qpath)))
        jid=submitted['job_id'];status=self.invoke('jobs status',dict(workspace_id=self.ws,job_id=jid))
        status=self.execute_job(status)
        if status is None:return
        need(status['job_id']==jid and status['state']=='needs_review' and len(status['artifacts'])==4,
            'original normal job must produce four unapproved deliverables')
        save(self.home/'produced.plist',status)
        print(self.LOG_PREFIX+'_rendered original_job='+jid+' deliverables=4 review=false')

    def execute_job(self,status):
        """Continue only the submitted job; a live lease leaves it untouched."""
        status=self.recover_job(status)
        if status is None:return None
        if status['state']=='queued':
            jid=status['job_id']
            self.invoke('jobs run',dict(workspace_id=self.ws,job_id=jid))
            status=self.invoke('jobs status',dict(workspace_id=self.ws,job_id=jid))
        return status

    def recover_job(self,status):
        """Recover a finite original lease before selecting its normal executor."""
        jid=status['job_id']
        if status['state']=='running':
            lease=(unpack(status).get('lease') or {}).get('expiresAt')
            need(lease,'running original job requires its actual finite lease')
            if datetime.fromisoformat(lease.replace('Z','+00:00'))>datetime.now(timezone.utc):
                print(self.LOG_PREFIX+'_original_job_active original_job='+jid);return None
            self.invoke('worker run',dict(workspace_id=self.ws,job_ids=[jid],max_jobs=1,timeout_seconds=60,
                resume_interrupted=True,query_remote=False))
            status=self.invoke('jobs status',dict(workspace_id=self.ws,job_id=jid))
        if status['state'] in ('interrupted','failed'):
            self.invoke('jobs resume',dict(workspace_id=self.ws,job_id=jid))
            status=self.invoke('jobs status',dict(workspace_id=self.ws,job_id=jid))
        return status

    def verify_recorded_sources(self,state):
        """Match every complete observation to its frozen persistent Core source.

        This checks models, seeds, native time axes and complete traces. It does
        not execute a rule table in Python or derive a participant's resources.
        """
        recorded=state['recorded'];plan=state['plan']
        need(recorded['project_id']==state['source_project_id'] and recorded['version']==plan['version'],
            'the recorded source project or plan version differs')
        source=self.project(state['source_project_id'])
        need(source['workspaceID']==state['workspace_id'],'the recorded source workspace differs')
        revisions=[r for r in source['revisions'] if r['id']==recorded['revision']]
        need(len(revisions)==1 and revisions[0]['fps']==plan['target']['fps']==self.FPS
            and source['revisions'][-1]['id']==recorded['revision'],
            'the exact recorded source revision and frame rate must remain current')
        scenes={s['id']:s for s in revisions[0]['scenes']}
        need(len(scenes)==len(revisions[0]['scenes']) and len({s['id'] for s in plan['sources']})==len(plan['sources']),
            'source scene and declaration identities must be unique')
        expected=[]
        for declared in plan['sources']:
            need(declared['scene_id'] in scenes,'the declared persistent source scene is absent')
            trace=_trace(declared,scenes[declared['scene_id']],self.FPS)
            row=dict(id=declared['id'],model=deepcopy(declared['model']),seed=declared['seed'],trace=trace,
                startFrame=declared['start_frame'],endFrame=declared['end_frame'])
            for original,stored in (('parent_id','parentID'),('intervention','intervention'),('action_cost','actionCost'),
                                    ('rule_change','ruleChange')):
                if original in declared:row[stored]=deepcopy(declared[original])
            expected.append(row)
        need(expected==recorded['sources'],'recorded source rows must equal the complete persistent Core observations')

    def verify(self):
        state=read(self.home/'prepared.plist');self.ws=state['workspace_id'];status=read(self.home/'produced.plist')
        current=self.project(state['project_id']);need(current['revisions'][-1]['id']==state['revision_id'],'produced revision differs')
        live=self.invoke('jobs status',dict(workspace_id=self.ws,job_id=status['job_id']));job=unpack(live)
        need(job['projectID']==current['id'] and job['revisionID']==state['revision_id']
            and job['quote']==read(self.home/'quote.plist')
            and live['state']==status['state']=='needs_review' and live['artifacts']==status['artifacts']
            and len(status['artifacts'])==4 and len({a['path'] for a in status['artifacts']})==4
            and all(a['revision']==state['revision_id'] for a in status['artifacts']),
            'the original quote, job and four artifacts must bind the same current revision')
        self.verify_recorded_sources(state)
        preserved=preserve_artifacts(status['artifacts'],self.out,
            revision_id=state['revision_id'],source_root=self.workspace)
        video=next(Path(a['path']) for a in preserved if a['mime']=='video/mp4')
        r=subprocess.run(['rtk','proxy',str(self.ffmpeg),'-nostdin','-v','error','-i',str(video),'-f','null','-'],capture_output=True,timeout=180)
        need(r.returncode==0 and not r.stderr,'complete audiovisual decode failed')
        media=self.probe(video);v=next(s for s in media['streams'] if s['codec_type']=='video')
        need((v['width'],v['height'])==self.VIEWPORT and int(v['nb_frames'])==state['frames'],'complete output frame axis differs')
        def pcm(path):
            r=subprocess.run(['rtk','proxy',str(self.ffmpeg),'-nostdin','-v','error','-i',str(path),'-map','0:a:0','-vn','-ac','1','-ar','48000','-f','f32le','pipe:1'],capture_output=True,timeout=120)
            need(r.returncode==0 and not r.stderr and 0<len(r.stdout)<=(math.ceil(48000*54000/self.FPS)+4800)*4,'bounded original/output audio decode required')
            a=array.array('f');a.frombytes(r.stdout);return a
        original,actual=pcm(self.voice),pcm(video)
        def similarity(start):
            # The established whole-film check allows one lossy-codec frame of
            # alignment. This compares decoded copies; it never edits either.
            count=min(48000,len(original)-start)
            best=-1
            for offset in range(-2400,2401,8):
                first=max(start,-offset);last=min(start+count,len(actual)-offset)
                if last-first<count-2400:continue
                # A codec-time-origin difference may omit digital leading
                # silence only. Never obtain a match by skipping spoken audio.
                if any(x!=0 for x in original[start:first]) or any(x!=0 for x in original[last:start+count]):continue
                reference=original[first:last:8];power=math.fsum(x*x for x in reference)
                if power<=1e-8:continue
                candidate=actual[first+offset:last+offset:8];other=math.fsum(x*x for x in candidate)
                if other>1e-8:best=max(best,math.fsum(x*y for x,y in zip(reference,candidate))/math.sqrt(power*other))
            return best
        need(len(actual)+1600>=len(original),'complete original audio tail is absent')
        head=similarity(0);tail=similarity(max(0,len(original)-48000))
        need(head>.90 and tail>.90 and sum(x*x for x in actual[:48000])>1,'first-second sound and complete original head/tail differ')
        save(self.home/'media-verified.plist',dict(voice_sha256=sha(self.voice.read_bytes()),
            video_sha256=sha(video.read_bytes()),source_head_correlation=head,source_tail_correlation=tail,
            full_av_decode=True,frames=state['frames']))
        backup=self.invoke('backup create');a=backup['artifacts'][0];raw=Path(a['path']).read_bytes()
        need(sha(raw)==a['sha256'],'normal complete backup bytes differ');(self.out/'complete.videobackup').write_bytes(raw)
        self.invoke('backup restore',dict(path=str(self.out/'complete.videobackup')),directory=self.home/'restored')
        need(self.invoke('doctor',directory=self.home/'restored')['state']=='succeeded','independent restore doctor failed')
        restored=unpack(self.invoke('projects list',dict(workspace_id=self.ws),directory=self.home/'restored'))
        original_archive=plistlib.loads(raw);original_snapshot=json.loads(original_archive['snapshot'])
        need(sha(original_archive['snapshot'])==original_archive['digest']
            and restored==original_snapshot['projects'],'independent restoration changed complete source/target histories')
        restored_backup=self.invoke('backup create',directory=self.home/'restored')['artifacts'][0]
        restored_archive=plistlib.loads(Path(restored_backup['path']).read_bytes())
        restored_snapshot=json.loads(restored_archive['snapshot'])
        # Restoring is one normal database transaction. Its generation advances
        # exactly once; every business row and original asset remains identical.
        need(sha(restored_archive['snapshot'])==restored_archive['digest']
            and restored_snapshot.get('generation')==original_snapshot.get('generation',0)+1
            and {k:v for k,v in restored_snapshot.items() if k!='generation'}==
                {k:v for k,v in original_snapshot.items() if k!='generation'}
            and restored_archive['assets']==original_archive['assets'],
            'independent restoration changed an asset, source recording, original voice, quote or job')
        evidence=dict(frames=state['frames'],voice_sha256=sha(self.voice.read_bytes()),video_sha256=sha(video.read_bytes()),
            job_id=status['job_id'],revision_id=state['revision_id'],source_head_correlation=head,source_tail_correlation=tail,
            source_axis_kind=read(self.home/'speech-provenance.plist')['kind'],
            source_axis_provenance_sha256=sha((self.home/'speech-provenance.plist').read_bytes()),
            complete_av_decode=True,independent_restore=True,voice_listened=False,review=False)
        save(self.out/'technical-verification.plist',evidence)
        (self.out/'production.md').write_text('# 方方｜'+self.production_name()+'\n\n'
            +self.production_description()+'\n\n'
            +'一次本地零费报价和原任务生成四件，完整声画解码、首秒声音、原音首尾相关及独立完整备份恢复通过。'
            +'未授听审、字幕确认、整片视觉批准或商用上传。\n\n'
            +'原音SHA256 '+evidence['voice_sha256']+'；视频SHA256 '+evidence['video_sha256']+'；帧数 '+str(state['frames'])+'。\n')
        print(self.LOG_PREFIX+'_verified full_av_decode=true first_second_audio=true original_head_tail=true complete_backup_restore=true review=false')
