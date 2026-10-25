"""Actual local child-process fixtures; never launches Codex or any model."""
from copy import deepcopy
import hashlib
import json
from pathlib import Path
import tempfile
import time
import unittest
import sys

from codex_broker import Broker, FilePin, Policy, Command, execute, _consume, TOOL
from codex_production import LocalProductionPolicy, LocalStep, ResultBinding
from codex_events import ProtocolError


# This is an isolated executable protocol fixture, not a shipping video runtime.
# It deliberately stores only test state, and is never shipped or called by production.
CHILD = r'''#!/usr/bin/python3
import hashlib,json,pathlib,sys,time,uuid
MODE=__MODE__
args=sys.argv[1:];root=pathlib.Path(args[1]);index=args.index('--input');command=' '.join(args[2:index]);source=pathlib.Path(args[index+1]);body=json.loads(source.read_text());dry=args[-1]=='--dry-run'
def entity(c):return c*8+'-'+c*4+'-'+c*4+'-'+c*4+'-'+c*12
ids={name:entity(format(i,'x')) for i,name in enumerate(('unused','workspace','asset','project','revision','quote','job','artifact','salt'),1)}
ids['new_revision']=entity('a')
def envelope(result=None,state='succeeded',project_id=None,revision=None,job_id=None,artifacts=None):
 return dict(schema_version='1.0',request_id=body['request_id'],ok=True,state=state,project_id=project_id,revision=revision,job_id=job_id,artifacts=artifacts or [],result=result,error=None,cost=dict(currency='CNY',estimated=None,reserved=None,actual=None,unknown='no external request'))
def write_state(value):
 root.mkdir(exist_ok=True);(root/'fixture-state').write_text(json.dumps(value))
def read_state():return json.loads((root/'fixture-state').read_text())
def quote():return dict(id=ids['quote'],projectID=ids['project'],revisionID=ids['new_revision'],digest='b'*64,upper=dict(amount=0,currency='CNY'),unit='CNY',provider='native',expiresAt=3000000000,attempts=1,confirmed=False,createdAt=1000000000)
def artifact(path,mime,revision=''):
 raw=path.read_bytes();return dict(id=ids['artifact'],path=str(path),mime=mime,bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest(),revision=revision)
if MODE=='deadline':time.sleep(30)
if dry:
 answer=envelope(state='dry_run')
 if MODE=='dry_is_actual':answer['state']='succeeded'
else:
 if command=='workspaces create':
  write_state({'job_state':'queued','revision':ids['revision']})
  answer=envelope(dict(id=ids['workspace'],name=body['name'],owner='local fixture owner',salt=ids['salt'],grants=[]))
 elif command=='assets import':
  path=pathlib.Path(body['path']);answer=envelope(dict(id=ids['asset'],workspaceID=ids['workspace'],name=path.name,hash=hashlib.sha256(path.read_bytes()).hexdigest(),ext=path.suffix[1:],bytes=path.stat().st_size,mediaType='audio',durationFrames=60,pages=[],warnings=[],tags=[]))
  if MODE=='bad_source_hash':answer['result']['hash']='0'*64
 elif command=='projects create':answer=envelope(dict(review_required=True),'needs_review',ids['project'],ids['revision'])
 elif command=='edit apply':
  value=read_state();value['revision']=ids['new_revision'];write_state(value)
  answer=envelope(None,'needs_review',ids['project'],ids['new_revision'])
 elif command=='render estimate':
  answer=envelope(quote())
  if MODE=='paid_quote':answer['result']['provider']='external';answer['result']['upper']['amount']=1
 elif command=='render submit':answer=envelope(None,'queued',job_id=ids['job'])
 elif command=='worker run':
  value=read_state();value['job_state']='needs_review';write_state(value)
  result=dict(id='c'*32,requestID=body['request_id'],principal='local fixture owner',state='completed',plan=dict(workspaceID=body['workspace_id'],jobIDs=body['job_ids'],maximumJobs=body['max_jobs'],timeoutSeconds=body['timeout_seconds'],resumeInterrupted=False,queryRemote=False),outcomes=[dict(jobID=x,state='needs_review',note='not human reviewed') for x in body['job_ids']])
  answer=envelope(result,'completed')
 elif command=='jobs cancel':
  value=read_state();value['job_state']='cancelled';write_state(value)
  answer=envelope(None,'cancelled',job_id=body['job_id'])
 elif command=='jobs status':
  q=quote();q['confirmed']=True
  artifacts=[]
  if read_state()['job_state']=='needs_review':
   exports=root/'exports';exports.mkdir(exist_ok=True)
   for name,mime in (('video.mp4','video/mp4'),('cover.png','image/png'),('captions.srt','application/x-subrip'),('publication.txt','text/plain')):
    path=exports/name;path.write_bytes(b'' if name=='captions.srt' else b'protocol fixture, not real media')
    item=artifact(path,mime,ids['new_revision']);item['id']=str(uuid.UUID(hashlib.md5(mime.encode()).hexdigest()));artifacts.append(item)
  result=dict(id=body['job_id'],workspaceID=body['workspace_id'],projectID=ids['project'],revisionID=ids['new_revision'],digest='b'*64,requestKey='render',quote=q,state=read_state()['job_state'],artifacts=artifacts)
  answer=envelope(result,result['state'],job_id=body['job_id'],artifacts=artifacts)
 elif command=='backup create':
  path=root/'backup-fixture.videobackup';path.write_bytes((root/'fixture-state').read_bytes())
  answer=envelope('local fixture backup',artifacts=[artifact(path,'application/octet-stream')])
  if MODE=='outside_backup':answer['artifacts'][0]['path']=str(root.parent/'outside.videobackup')
 elif command=='backup restore':
  write_state(json.loads(pathlib.Path(body['path']).read_text()));answer=envelope('restored new fixture directory')
 elif command=='doctor':answer=envelope(dict(database=dict(validated=True,read_only=True)))
 else:raise SystemExit(3)
 if MODE=='unknown_response':answer['unexpected']='must remain opaque'
 if MODE=='wrong_request':answer['request_id']='different-request'
 if MODE=='actual_is_dry':answer['state']='dry_run'
 if MODE=='cost_is_boolean':answer['cost']['estimated']=False
 if MODE=='future_schema':answer['schema_version']='2.0'
 if MODE=='not_ok':answer['ok']=False
 if MODE=='malformed_workspace':answer['result']=[]
print(json.dumps(answer))
'''

BROKER_PEER = r'''
import json,sys,signal,time
signal.signal(signal.SIGTERM,signal.SIG_IGN)
def get():return json.loads(sys.stdin.readline())
def send(value):print(json.dumps(value),flush=True)
assert get()['method']=='initialize';send(dict(id=1,result={}))
assert get()['method']=='initialized';assert get()['method']=='mcpServerStatus/list'
send(dict(id=4,result=dict(data=[],nextCursor=None)))
thread=get();assert thread['method']=='thread/start'
p=thread['params'];assert p['environments']==[] and p['runtimeWorkspaceRoots']==[] and p['sandbox']=='read-only'
send(dict(id=2,result=dict(thread=dict(id='thread-local'),cwd=p['cwd'],approvalPolicy='on-request',sandbox=dict(type='readOnly'),runtimeWorkspaceRoots=[])))
assert get()['method']=='turn/start'
send(dict(method='turn/started',params=dict(threadId='thread-local',turn=dict(id='turn-local',status='inProgress'))))
send(dict(id=3,result=dict(turn=dict(id='turn-local',status='inProgress'))))
for n,args in enumerate(json.loads(sys.argv[1])):
 call='call-'+str(n);tool=p['dynamicTools'][0]['name']
 item=dict(id=call,type='dynamicToolCall',tool=tool,arguments=args,status='inProgress')
 send(dict(method='item/started',params=dict(threadId='thread-local',turnId='turn-local',item=item)))
 send(dict(id=100+n,method='item/tool/call',params=dict(threadId='thread-local',turnId='turn-local',callId=call,tool=tool,arguments=args)))
 reply=get();assert reply['result']['success'] is True
 content=json.loads(reply['result']['contentItems'][0]['text']);assert content['passed'] and 'argv' not in content and 'result' not in content
 item.update(status='completed',success=True)
 send(dict(method='item/completed',params=dict(threadId='thread-local',turnId='turn-local',item=item)))
send(dict(method='turn/completed',params=dict(threadId='thread-local',turn=dict(id='turn-local',status='completed',error=None))))
time.sleep(30)  # Keep the owned group alive until the broker's strict cleanup.
'''


class LocalProductionTests(unittest.TestCase):
    def setUp(self):
        cache = Path.cwd() / '.cache' / 'codex-production-tests'
        cache.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=cache)
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.source = self.root / 'approved-sources'
        self.source.mkdir()
        self.audio = self.source / 'source.wav'
        self.audio.write_bytes(b'isolated source fixture, not a sample video')
        self.binary = self.root / 'video'
        self.binary.write_text(CHILD.replace('__MODE__', repr('pass')))
        self.binary.chmod(0o700)
        self.templates = self.root / 'reviewed-inputs'
        self.templates.mkdir()
        self.workspace = self.root / 'workspace'
        self.restored = self.root / 'restored'
        self.pins = [self.pin(self.binary), self.pin(self.audio)]
        self.steps = []

    @staticmethod
    def pin(path):
        return FilePin(path, hashlib.sha256(path.read_bytes()).hexdigest())

    def mode(self, mode):
        self.binary.write_text(CHILD.replace('__MODE__', repr(mode)))
        self.pins[0] = self.pin(self.binary)

    def step(self, name, command, body, bindings=(), **options):
        body = dict(body, request_id=name)
        path = self.templates / (name + '.json')
        path.write_text(json.dumps(body))
        self.pins.append(self.pin(path))
        step = LocalStep(name, command, path, tuple(bindings), **options)
        self.steps.append(step)
        return step

    @staticmethod
    def bind(target, step, field):
        return ResultBinding(tuple(target), step, field)

    def plan(self, **options):
        return LocalProductionPolicy(binary=self.binary, directory=self.root, workspace=self.workspace,
                                     steps=tuple(self.steps), pins=tuple(self.pins), source_roots=(self.source,),
                                     restore_roots={'restored': self.restored}, **options)

    def scope(self):
        return [self.bind(('workspace_id',), 'workspace', 'workspace_id')]

    def flow(self, *, finish=True):
        self.step('workspace', 'workspaces create', {'name': 'reviewed local production'})
        self.step('audio', 'assets import', {'workspace_id': None, 'path': str(self.audio)}, self.scope())
        scene = dict(id='dddddddd-dddd-dddd-dddd-dddddddddddd', kind='图文讲解', title='Fixture', body='One prepared scene', narration='', durationFrames=30,
                     evidenceIDs=[], showPrice=False, captions=[])
        self.step('project', 'projects create', {'workspace_id': None, 'name': 'local', 'scenes': [scene]}, self.scope())
        binding = self.scope()+[self.bind(('project_id',), 'project', 'project_id'), self.bind(('base_revision',), 'project', 'revision'),
                                self.bind(('edits', 0, 'music', '_0'), 'audio', 'asset_id')]
        self.step('edit', 'edit apply', {'workspace_id': None, 'project_id': None, 'base_revision': None, 'edits': [{'music': {'_0': None}}]}, binding)
        self.step('estimate', 'render estimate', {'workspace_id': None, 'project_id': None},
                  self.scope()+[self.bind(('project_id',), 'edit', 'project_id')])
        self.step('render', 'render submit', {'workspace_id': None, 'project_id': None, 'quote': None},
                  self.scope()+[self.bind(('project_id',), 'edit', 'project_id'), self.bind(('quote',), 'estimate', 'quote')], confirm_zero_quote=True)
        if not finish:
            return
        self.step('worker', 'worker run', {'workspace_id': None, 'job_ids': [None], 'max_jobs': 1, 'timeout_seconds': 5, 'query_remote': False},
                  self.scope()+[self.bind(('job_ids', 0), 'render', 'job_id')])
        job_bindings = self.scope()+[self.bind(('job_id',), 'render', 'job_id')]
        self.step('status', 'jobs status', {'workspace_id': None, 'job_id': None}, job_bindings, expected_state='needs_review')
        self.step('backup', 'backup create', {})
        self.step('restore', 'backup restore', {'path': None}, [self.bind(('path',), 'backup', 'backup_path')], workspace='restored')
        self.step('restored_status', 'jobs status', {'workspace_id': None, 'job_id': None}, job_bindings,
                  workspace='restored', expected_state='needs_review')
        self.step('restored_doctor', 'doctor', {}, workspace='restored')

    def run_step(self, policy):
        step = policy.commands[policy.used]
        return execute(policy.claim(policy.arguments(step)), deadline=time.monotonic()+15)

    def test_actual_local_children_bind_ids_produce_and_restore_without_model_or_shell(self):
        self.flow()
        policy = self.plan()
        self.assertFalse(self.workspace.exists())
        summaries = [self.run_step(policy) for _ in policy.commands]
        self.assertTrue(all(x['passed'] for x in summaries))
        self.assertEqual(policy.used, 12)
        self.assertEqual((self.workspace/'fixture-state').read_bytes(), (self.restored/'fixture-state').read_bytes())
        self.assertEqual(policy.templates['render']['quote'], None)
        actual_render = json.loads((policy.input_directory/'05.json').read_text())
        self.assertTrue(actual_render['quote']['confirmed'])
        self.assertFalse(policy.values[('estimate','quote')]['confirmed'])
        self.assertEqual(len([p for x in summaries for p in x['phases'] if p['phase']=='dry_run']), 8)
        self.assertTrue(all(x['human_review_granted'] is False for x in summaries))
        self.assertNotIn('argv', policy.spec()['inputSchema']['properties'])
        self.assertNotIn('quote', json.dumps(summaries))
        with self.assertRaises(ProtocolError):
            policy.claim(policy.arguments(policy.commands[-1]))

    @staticmethod
    def speech_scene():
        return dict(id='dddddddd-dddd-dddd-dddd-dddddddddddd', kind='图文讲解', title='Authored speech',
            body='Unreviewed local material', narration='甲😀乙', durationFrames=287, captions=[],
            speechPlan=dict(source='甲😀乙', normalized='甲笑脸乙', dictionary=[dict(term='😀',pronunciation='笑脸')],
                mappings=[dict(sourceStart=1,sourceLength=2,normalizedStart=1,normalizedLength=2,kind='dictionary')],
                rate=.5,confirmed=False,notes=['Preserve the authored input.']))

    def speech_policy(self):
        self.step('workspace','workspaces create',{'name':'local'})
        return self.plan()

    def test_unreviewed_speech_plan_preserves_utf16_source_and_optional_voice(self):
        policy=self.speech_policy()
        scene=self.speech_scene()
        original=deepcopy(scene)
        policy._scene(scene)
        self.assertEqual(scene,original)
        scene['speechPlan']['voiceIdentifier']='reviewed-local-voice'
        policy._scene(scene)
        scene['speechPlan']['voiceIdentifier']=None
        policy._scene(scene)
        # 乙 starts at UTF-16 offset 3, rather than Python code-point offset 2.
        scene['speechPlan']['mappings'].append(dict(sourceStart=3,sourceLength=1,normalizedStart=3,normalizedLength=1,kind='unchanged'))
        policy._scene(scene)
        del scene['speechPlan']
        policy._scene(scene)  # Existing ordinary callers remain supported.

    def test_speech_plan_cannot_inject_provider_credentials_or_review_confirmation(self):
        policy=self.speech_policy()
        for mutation in ({'provider':'external'},{'api_key':'not-a-real-key'},{'confirmed':True},{'confirmed':0},
                         {'source':'different narration'},{'voiceIdentifier':{}},{'notes':[{}]}):
            with self.subTest(mutation=mutation):
                scene=self.speech_scene();scene['speechPlan'].update(mutation)
                with self.assertRaises(ProtocolError):policy._scene(scene)

    def test_speech_rate_and_utf16_text_have_explicit_finite_bounds(self):
        policy=self.speech_policy()
        for rate in (True,False,'0.5',float('nan'),float('inf'),.199,.651,10**1000):
            scene=self.speech_scene();scene['speechPlan']['rate']=rate
            with self.subTest(rate=rate),self.assertRaises(ProtocolError):policy._scene(scene)
        for value in ('','   ','😀'*2001):
            scene=self.speech_scene();scene['narration']=value;scene['speechPlan']['source']=value
            with self.subTest(source_length=len(value)),self.assertRaises(ProtocolError):policy._scene(scene)
        scene=self.speech_scene();scene['speechPlan']['normalized']='😀'*4001
        with self.assertRaises(ProtocolError):policy._scene(scene)

    def test_speech_dictionary_rejects_duplicate_unknown_empty_or_overlong_terms(self):
        policy=self.speech_policy()
        for entries in ([{'term':'a','pronunciation':'b'},{'term':'a','pronunciation':'c'}],
                        [{'term':'','pronunciation':'b'}],[{'term':'a','pronunciation':''}],
                        [{'term':'a','pronunciation':'b','extra':True}],
                        [{'term':'😀'*51,'pronunciation':'b'}],
                        [{'term':'a','pronunciation':'😀'*101}],
                        [dict(term=str(i),pronunciation='a') for i in range(201)]):
            scene=self.speech_scene();scene['speechPlan']['dictionary']=entries
            with self.subTest(entries=len(entries)),self.assertRaises(ProtocolError):policy._scene(scene)

    def test_speech_mapping_ranges_order_integer_types_and_shapes_are_strict(self):
        policy=self.speech_policy()
        mutations=({'sourceStart':-1},{'sourceStart':5},{'sourceLength':0},{'sourceLength':2**63-1},
                   {'normalizedStart':5},{'normalizedLength':0},{'normalizedLength':2**63-1},
                   {'sourceStart':True},{'sourceLength':'2'},{'kind':''},{'extra':1})
        for mutation in mutations:
            scene=self.speech_scene();scene['speechPlan']['mappings'][0].update(mutation)
            with self.subTest(mutation=mutation),self.assertRaises(ProtocolError):policy._scene(scene)
        scene=self.speech_scene();scene['speechPlan']['mappings'].append(deepcopy(scene['speechPlan']['mappings'][0]))
        with self.assertRaises(ProtocolError):policy._scene(scene)
        scene=self.speech_scene();scene['speechPlan']['mappings']=[scene['speechPlan']['mappings'][0]]*257
        with self.assertRaises(ProtocolError):policy._scene(scene)

    def test_speech_plan_never_grants_voice_or_caption_human_review(self):
        policy=self.speech_policy()
        scene=self.speech_scene();scene['captions']=[dict(confirmed=True)]
        with self.assertRaisesRegex(ProtocolError,'human_review'):policy._scene(scene)
        scene=self.speech_scene();scene['voice']=dict(assetID='eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee',listened=True)
        with self.assertRaisesRegex(ProtocolError,'unreviewed_voice'):policy._scene(scene)

    def test_speech_plan_input_is_still_hash_pinned_before_any_write(self):
        self.step('workspace','workspaces create',{'name':'local'})
        step=self.step('project','projects create',{'workspace_id':None,'name':'local','scenes':[self.speech_scene()]},self.scope())
        policy=self.plan()
        changed=json.loads(step.input_file.read_text());changed['scenes'][0]['speechPlan']['normalized']='different'
        step.input_file.write_text(json.dumps(changed))
        with self.assertRaises(ValueError):policy.claim(policy.arguments(policy.commands[0]))
        self.assertFalse(self.workspace.exists())

    def test_legacy_command_cannot_acquire_writes_by_changing_kind(self):
        self.step('workspace','workspaces create',{'name':'local'})
        with self.assertRaises(ValueError):
            Policy((Command('write',(str(self.binary),'--workspace',str(self.workspace),'workspaces','create','--input',str(self.steps[0].input_file)),self.root,tuple(self.pins),'production'),))

    def test_required_binary_template_and_import_pins_are_not_optional(self):
        self.flow(finish=False)
        original = self.pins[:]
        for omitted in (self.binary, self.audio, self.steps[0].input_file):
            with self.subTest(path=omitted):
                self.pins = [p for p in original if p.path != omitted]
                with self.assertRaises(ValueError):
                    self.plan()
                self.assertFalse(self.workspace.exists())

    def test_pinned_inventory_has_explicit_file_count_and_size_bounds(self):
        self.step('workspace','workspaces create',{'name':'local'})
        original=self.pins[:]
        for index in range(97):
            path=self.source/('pin-'+str(index));path.write_bytes(b'bounded pin')
            self.pins.append(self.pin(path))
        with self.assertRaisesRegex(ProtocolError,'unique_file_pins'):self.plan()
        self.pins=original
        with self.audio.open('r+b') as stream:stream.truncate(128*1024*1024+1)
        with self.assertRaisesRegex(ProtocolError,'inventory_bound'):self.plan()
        self.assertFalse(self.workspace.exists())

    def test_only_new_separate_canonical_output_roots_and_explicit_sources(self):
        self.flow(finish=False)
        self.workspace.mkdir()
        with self.assertRaises(ProtocolError):self.plan()
        self.workspace.rmdir()
        foreign = self.root / 'outside-approved.wav';foreign.write_bytes(b'foreign source')
        self.pins.append(self.pin(foreign))
        path=self.steps[1].input_file
        path.write_text(json.dumps(dict(workspace_id=None,path=str(foreign),request_id='audio')))
        self.pins=[self.pin(path) if p.path==path else p for p in self.pins]
        with self.assertRaises(ProtocolError):self.plan()
        self.assertFalse(self.workspace.exists())

    def test_symlink_hardlink_and_escaping_roots_refused_before_any_write(self):
        self.step('workspace','workspaces create',{'name':'local'})
        original=self.workspace
        for candidate in (self.root.parent/'escaped-output',self.root/'not-canonical'/'..'/'workspace'):
            with self.subTest(candidate=candidate):
                self.workspace=candidate
                with self.assertRaises(ValueError):self.plan()
        self.workspace=original
        linked=self.root/'source-alias';linked.symlink_to(self.source,target_is_directory=True)
        with self.assertRaises(ValueError):
            LocalProductionPolicy(binary=self.binary,directory=self.root,workspace=self.workspace,steps=tuple(self.steps),
                                  pins=tuple(self.pins),source_roots=(linked,))
        import os
        alias=self.root/'hard-linked-video';os.link(self.binary,alias)
        with self.assertRaises(ValueError):self.plan()
        self.assertFalse(self.workspace.exists())

    def test_unknown_remote_background_review_and_transaction_commands_refused(self):
        self.step('workspace','workspaces create',{'name':'local'})
        for command in ('jobs query','jobs remote-cancel','worker launch','review record','products import','sales record','imports rollback','baidu submit'):
            with self.subTest(command=command):
                original=self.steps[:]
                self.step('forbidden','doctor',{})
                self.steps[-1]=LocalStep('forbidden',command,self.steps[-1].input_file)
                with self.assertRaises(ProtocolError):self.plan()
                self.steps=original
                self.pins=[p for p in self.pins if p.path.name!='forbidden.json']

    def test_worker_cannot_query_remote_run_all_or_extend_its_explicit_bound(self):
        self.flow()
        path=self.steps[6].input_file;original=json.loads(path.read_text());old_pins=self.pins[:]
        for mutation in ({'query_remote':True},{'resume_interrupted':True},{'job_ids':[]},{'max_jobs':2},
                         {'timeout_seconds':True},{'timeout_seconds':61},{'timeout_seconds':0}):
            with self.subTest(mutation=mutation):
                path.write_text(json.dumps({**original,**mutation}));self.pins=[self.pin(path) if p.path==path else p for p in old_pins]
                with self.assertRaises(ProtocolError):self.plan()
        self.assertFalse(self.workspace.exists())

    def test_model_cannot_supply_ids_argv_extra_fields_or_reorder_steps(self):
        self.flow(finish=False)
        policy=self.plan();expected=policy.arguments(policy.commands[0])
        for changed in ({**expected,'argv':['/bin/sh']},{**expected,'workspace_id':'f'*32},
                        {**expected,'plan_sha256':'0'*64},policy.arguments(policy.commands[1])):
            with self.subTest(arguments=changed),self.assertRaises(ProtocolError):policy.claim(changed)
        self.assertEqual(policy.used,0)
        self.assertFalse(self.workspace.exists())

    def test_bindings_must_use_prior_typed_exports_into_existing_nulls(self):
        self.flow(finish=False)
        original=self.steps[1]
        for binding in (self.bind(('workspace_id',),'later','workspace_id'),self.bind(('workspace_id',),'workspace','owner'),
                        self.bind(('path',),'workspace','workspace_id'),self.bind(('unknown',),'workspace','workspace_id')):
            with self.subTest(binding=binding):
                self.steps[1]=LocalStep(original.name,original.command,original.input_file,(binding,))
                with self.assertRaises(ProtocolError):self.plan()

    def test_modified_template_binary_or_materialized_input_never_executes(self):
        self.step('workspace','workspaces create',{'name':'local'})
        policy=self.plan()
        invocation=policy.claim(policy.arguments(policy.commands[0]))
        invocation.input_file.write_text('{}')
        with self.assertRaises(ValueError):execute(invocation,deadline=time.monotonic()+5)
        self.assertFalse(self.workspace.exists())
        self.assertTrue(policy.failed)
        with self.assertRaises(ProtocolError):policy.claim(policy.arguments(policy.commands[0]))

    def test_unknown_or_wrong_success_envelopes_fail_and_cannot_be_retried(self):
        self.step('workspace','workspaces create',{'name':'local'})
        for mode in ('unknown_response','wrong_request','actual_is_dry','cost_is_boolean','future_schema','not_ok','dry_is_actual','malformed_workspace'):
            with self.subTest(mode=mode):
                self.mode(mode)
                if self.workspace.exists():
                    (self.workspace/'fixture-state').unlink();self.workspace.rmdir()
                policy=self.plan()
                with self.assertRaises(ProtocolError) as caught:self.run_step(policy)
                self.assertNotIn('must remain opaque',str(caught.exception))
                self.assertTrue(policy.failed)
                with self.assertRaises(ProtocolError):policy.claim(policy.arguments(policy.commands[0]))

    def test_imported_asset_hash_must_match_the_approved_source(self):
        self.flow(finish=False);self.mode('bad_source_hash');policy=self.plan()
        self.run_step(policy)
        with self.assertRaisesRegex(ProtocolError,'source_receipt'):self.run_step(policy)
        self.assertNotIn(('audio','asset_id'),policy.values)

    def test_paid_or_unknown_quote_is_not_exported_or_confirmed(self):
        self.flow(finish=False);self.mode('paid_quote');policy=self.plan()
        for _ in range(4):self.run_step(policy)
        with self.assertRaisesRegex(ProtocolError,'native_zero_quote'):self.run_step(policy)
        self.assertNotIn(('estimate','quote'),policy.values)

    def test_cancel_only_original_native_job_and_report_actual_cancelled_state(self):
        self.flow(finish=False)
        self.step('cancel','jobs cancel',dict(workspace_id=None,job_id=None),
                  self.scope()+[self.bind(('job_id',),'render','job_id')],expected_state='cancelled')
        self.step('cancel_status','jobs status',dict(workspace_id=None,job_id=None),
                  self.scope()+[self.bind(('job_id',),'render','job_id')],expected_state='cancelled')
        policy=self.plan()
        summaries=[self.run_step(policy) for _ in policy.commands]
        self.assertTrue(all(x['passed'] for x in summaries))
        self.assertEqual(summaries[-1]['state'],'cancelled')
        self.assertEqual(len(summaries[-2]['phases']),2)

    def test_parent_deadline_stops_owned_child_and_never_retries_step(self):
        self.mode('deadline');self.step('workspace','workspaces create',{'name':'local'});policy=self.plan()
        invocation=policy.claim(policy.arguments(policy.commands[0]));started=time.monotonic()
        with self.assertRaises(ProtocolError):execute(invocation,deadline=started+.15)
        self.assertLess(time.monotonic()-started,2)
        self.assertFalse(self.workspace.exists())
        self.assertTrue(policy.failed)

    def test_new_policy_runs_through_the_actual_broker_protocol_without_native_permissions(self):
        self.flow();policy=self.plan()
        peer=self.root/'broker-peer.py';peer.write_text(BROKER_PEER)
        result=_consume([str(Path(sys.executable).resolve()),str(peer),json.dumps([policy.arguments(s) for s in policy.commands])],
                        'Execute only the next caller-approved operation.',policy,seconds=60)
        self.assertTrue(result['passed'],result)
        self.assertEqual(len(result['executions']),12)
        self.assertEqual(result['native_approvals_accepted'],0)
        self.assertTrue(result['mcp_inventory_verified'])
        self.assertEqual(result['host_environments'],[])

    def test_new_policy_still_denies_native_command_approval_before_any_local_step(self):
        self.step('workspace','workspaces create',{'name':'local'});policy=self.plan()
        broker=Broker(policy,'Only the explicit local plan.',deadline=time.monotonic()+5)
        result=broker.receive(dict(id=101,method='item/commandExecution/requestApproval',params={}))
        self.assertEqual(result,[dict(id=101,result=dict(decision='decline'))])
        self.assertFalse(broker.summary()['passed'])
        self.assertFalse(self.workspace.exists())


if __name__=='__main__':
    unittest.main()
