"""Local native-protocol peers; no model, account or network is contacted."""
from pathlib import Path
import hashlib
import json
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

from claude_stream import _configuration, _input, _pinned_json, _terminate_group, consume, create_isolated_settings, run_claude
from codex_events import ProtocolError
from qwen_stream import FilePin, PinnedPolicy
from install import host_manifests
import package as native_package


PEER = r'''import json,os,sys,time
mode=sys.argv[1]
def emit(value):print(json.dumps(value),flush=True)
first=json.loads(sys.stdin.readline())
assert first['type']=='control_request' and first['request']=={'subtype':'initialize'}
payload={'commands':[],'output_style':'default','available_output_styles':['default'],'models':[],
 'account':{'tokenSource':'private-source-not-to-export','email':'private-email-not-to-export'}}
ack={'type':'control_response','response':{'subtype':'success','request_id':first['request_id'],'response':payload}}
if mode=='bad-init':ack['response']['subtype']='error'
if mode=='init-extra':payload['capabilities']={'anything':True}
emit(ack)
if mode in ('bad-init','init-extra'):time.sleep(20)
assert json.loads(sys.stdin.readline())['type']=='user'
if mode=='duplicate-init':emit(ack);time.sleep(20)
if mode=='unknown':emit({'type':'unknown_action','request':{}});time.sleep(20)
if mode=='hostile-event':
 emit({'type':'private-event-not-to-export','subtype':'private-subtype-not-to-export',
       'private-field-not-to-export':'private-value-not-to-export'})
 time.sleep(20)
if mode=='stall':time.sleep(20)
skill=mode=='skill'
session={'type':'system','subtype':'init','cwd':os.getcwd(),'session_id':'s-one',
 'tools':['Bash','Skill'] if skill else ['Bash'],'mcp_servers':[],'model':'native-model',
 'permissionMode':'default','slash_commands':[],'apiKeySource':'private-source-not-to-export','betas':[],
 'claude_code_version':'2.1.3','output_style':'default','agents':['general-purpose'],
 'skills':['video:video'] if skill else [],
 'plugins':[{'name':'video','path':os.getcwd()+'/plugin'}] if skill else [],'uuid':'init-one'}
if mode=='wrong-directory':session['cwd']+='-other'
if mode=='extra-tools':session['tools'].append('Read')
if mode=='mcp':session['mcp_servers']=[{'name':'other','status':'connected'}]
if mode=='bypass':session['permissionMode']='bypassPermissions'
if mode=='no-betas':del session['betas']
if mode=='betas-valid':session['betas']=['context-1m-2025-08-07']
invalid_betas={'betas-null':None,'betas-string':'private-beta-not-to-export',
 'betas-object':{'private-beta-not-to-export':True},'betas-bool':True,'betas-number':1,
 'betas-nested':[[]],'betas-nonstring':[1],'betas-empty-string':[''],
 'betas-long-string':['x'*129],'betas-too-many':['beta']*33}
if mode in invalid_betas:session['betas']=invalid_betas[mode]
if mode=='session-extra':session['fast_mode_state']='private-value-not-to-export'
if mode=='session-missing':del session['agents']
if mode=='session-agents':session['agents']={'private-value-not-to-export':True}
if mode=='session-skills':session['skills']=['private-value-not-to-export']
if mode=='session-plugins':session['plugins']=[{'name':'private-value-not-to-export','path':'private-path-not-to-export'}]
if mode=='session-unhashable-tools':session['tools']=[{'private-value-not-to-export':True}]
if mode=='hostile-init':
 session.update(cwd='private-cwd-not-to-export',session_id='private-session-not-to-export',
                model='private-model-output-not-to-export')
 for n in range(200):session['private-field-not-to-export-'+str(n)]='private-value-not-to-export'
if mode!='before-session':emit(session)
tools=[('Skill',{'skill':'video:video'})] if skill else []
tools += [('Bash',{'command':'rtk proxy video schema','timeout':120000,'run_in_background':False})]
for n,(name,values) in enumerate(tools):
 tid='tool-'+str(n)
 if mode=='hostile-tool':
  name='private-tool-not-to-export';tid='private-tool-id-not-to-export'
  values['command']='private-command-not-to-export'
 if mode=='extra-input':values['dangerouslyDisableSandbox']=True
 if mode=='wrong-command':values['command']+=' --unreviewed'
 if mode=='background':values['run_in_background']=True
 use={'type':'assistant','message':{'role':'assistant','content':[{'type':'tool_use','id':tid,'name':name,'input':values}]},
      'session_id':'s-one','parent_tool_use_id':None,'uuid':'use-'+str(n)}
 req={'type':'control_request','request_id':'permission-'+str(n),'request':{'subtype':'can_use_tool',
      'tool_name':name,'input':values,'tool_use_id':tid,'permission_suggestions':[],
      'decision_reason':'exact local test','blocked_path':None}}
 if mode=='unknown-request':req['request']['subtype']='set_permission_mode'
 if mode=='request-extra':req['request']['unreviewed']=True
 if mode=='agent':req['request']['agent_id']='subagent'
 if mode=='mismatch':req['request']['input']=dict(values,timeout=119999)
 if mode not in ('permission-first','before-session'):emit(use)
 if mode!='no-permission':
  emit(req)
  line=sys.stdin.readline()
  if not line:sys.exit(0)
  reply=json.loads(line)
  assert reply['response']['request_id']==req['request_id']
  value=reply['response']['response']
  if value['behavior']=='deny':sys.exit(0)
  assert value=={'behavior':'allow','updatedInput':values}
 if mode=='permission-first':emit(use)
 if mode=='mutate-pin':open(sys.argv[2],'w').write('changed')
 result={'type':'user','message':{'role':'user','content':[{'type':'tool_result','tool_use_id':tid,'content':'finite output'}]},
   'session_id':'s-one','parent_tool_use_id':None,'uuid':'return-'+str(n)}
 if mode=='wrong-result-id':result['message']['content'][0]['tool_use_id']='other'
 if mode=='tool-error':result['message']['content'][0]['is_error']=True
 emit(result)
 if mode=='skill':
  emit({'type':'user','message':{'role':'user','content':[{'type':'text','text':'native Skill expansion'}]},
        'session_id':'s-one','parent_tool_use_id':None,'uuid':'skill-expansion','isSynthetic':True})
native={'type':'result','subtype':'success','is_error':False,'duration_ms':1,'duration_api_ms':1,'num_turns':2,
 'result':'complete','session_id':'s-one','total_cost_usd':0,'usage':{},'modelUsage':{},'permission_denials':[],'uuid':'done'}
if mode=='native-error':native['is_error']=True
if mode=='result-foreign':native['session_id']='other'
if mode=='no-result':sys.exit(0)
emit(native)
if mode=='after-result':emit({'type':'system','subtype':'status','status':None,'session_id':'s-one','uuid':'late'})
assert sys.stdin.readline()==''
'''


class ClaudeStreamTests(unittest.TestCase):
    def setUp(self):
        base = Path.cwd()/'.cache/round60/claude-rules'
        base.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=base)
        self.root = Path(self.temporary.name).resolve()
        self.input = self.root/'input'
        self.input.write_text('reviewed')
        self.script = self.root/'peer.py'
        self.script.write_text(PEER)

    def tearDown(self):
        self.temporary.cleanup()

    def pin(self, path):
        return FilePin(path, hashlib.sha256(path.read_bytes()).hexdigest())

    def policy(self, *, skill=False, pins=()):
        installer=Path(__file__).with_name('install.py').resolve()
        dependencies = (self.pin(self.input), self.pin(installer), *pins)
        if skill:
            plugin, files = self.plugin()
            known = {pin.path for pin in dependencies}
            dependencies += tuple(self.pin(path) for path in files if path not in known)
        return PinnedPolicy(self.root, ('rtk proxy video schema',), dependencies, allow_skill=skill,
                            skill_directory=self.root/'plugin/skills/video' if skill else None)

    def run_peer(self, mode):
        return consume([sys.executable,str(self.script),mode,str(self.input)], 'bounded native user task',
                       self.policy(skill=mode=='skill'), seconds=3, skill_plugin=self.root/'plugin')

    def testInitializedPermissionUsesExactNativeUpdatedInputAndCompletes(self):
        result=self.run_peer('normal')
        self.assertTrue(result['initialized'])
        self.assertEqual(result['status'],'native_result')
        self.assertTrue(result['execution_complete'])
        self.assertTrue(result['policy_complete'])
        self.assertTrue(result['cleanup']['passed'])
        self.assertEqual(result['decisions'],[{'tool_use_id':'tool-0','allowed':True}])

    def testUnreadingNativeStdinCannotBlockParentDeadline(self):
        self.script.write_text("""import json,sys,time
first=json.loads(sys.stdin.readline())
print(json.dumps({'type':'control_response','response':{'subtype':'success','request_id':first['request_id'],'response':{'commands':[],'output_style':'default','available_output_styles':['default'],'models':[],'account':{}}}}),flush=True)
time.sleep(3)
""")
        entered=[]
        started=time.monotonic()
        def stop(process):
            entered.append(time.monotonic()-started)
            return _terminate_group(process)
        with patch('claude_stream._terminate_group',side_effect=stop):
            result=consume([sys.executable,str(self.script),'normal',str(self.input)],
                           'x'*65536,self.policy(),seconds=2)
        self.assertEqual(result['status'],'hard_deadline')
        self.assertTrue(result['initialized'])
        self.assertEqual(len(entered),1)
        self.assertLess(entered[0],2.5)
        self.assertEqual(result['decisions'],[])
        self.assertFalse(result['execution_complete'])
        # The original cleanup's TERM/KILL/leader proof is not replaced by the
        # transport deadline; an OS permission refusal remains a refusal.
        self.assertIn('passed',result['cleanup'])

    def testPartialAndTemporarilyBlockedStdinWritesKeepWholeMessageOrder(self):
        import os
        original=os.write
        writes=[0]
        def partial(descriptor,data):
            writes[0]+=1
            if writes[0]==2:
                raise BlockingIOError()
            return original(descriptor,data[:97])
        self.script.write_text(PEER.replace(
            "assert json.loads(sys.stdin.readline())['type']=='user'",
            "user=json.loads(sys.stdin.readline());assert user['type']=='user' and user['message']['content']=='x'*65536"))
        with patch('claude_stream.os.write',side_effect=partial):
            result=consume([sys.executable,str(self.script),'normal',str(self.input)],
                           'x'*65536,self.policy(),seconds=3)
        self.assertEqual(result['status'],'native_result')
        self.assertTrue(result['policy_complete'])
        self.assertGreater(writes[0],600)
        self.assertEqual(result['decisions'],[{'tool_use_id':'tool-0','allowed':True}])

    def testClosedNativeStdinReturnsBoundedFailureAndActualCleanup(self):
        self.script.write_text("""import json,os,sys,time
first=json.loads(sys.stdin.readline())
os.close(0)
print(json.dumps({'type':'control_response','response':{'subtype':'success','request_id':first['request_id'],'response':{'commands':[],'output_style':'default','available_output_styles':['default'],'models':[],'account':{}}}}),flush=True)
time.sleep(.05)
""")
        result=consume([sys.executable,str(self.script)],'bounded',self.policy(),seconds=1)
        self.assertEqual(result['status'],'protocol_refused')
        self.assertEqual(result['failure_type'],'OSError')
        self.assertFalse(result['execution_complete'])
        self.assertEqual(result['decisions'],[])
        self.assertIn('passed',result['cleanup'])

    def testNativeResultCannotDiscardPendingUserMessage(self):
        script="""import json,os,sys,time
first=json.loads(sys.stdin.readline())
ack={'type':'control_response','response':{'subtype':'success','request_id':first['request_id'],'response':{'commands':[],'output_style':'default','available_output_styles':['default'],'models':[],'account':{}}}}
session={'type':'system','subtype':'init','cwd':os.getcwd(),'session_id':'s','tools':['Bash'],'mcp_servers':[],'model':'native-model','permissionMode':'default','slash_commands':[],'apiKeySource':'not-exported','claude_code_version':'2.1.3','output_style':'default','agents':[],'skills':[],'plugins':[],'uuid':'init'}
final={'type':'result','subtype':'success','is_error':False,'permission_denials':[],'session_id':'s'}
os.write(1,('\\n'.join(json.dumps(x) for x in (ack,session,final))+'\\n').encode())
time.sleep(.1)
"""
        self.script.write_text(script)
        result=consume([sys.executable,str(self.script)],'x'*65536,self.policy(),seconds=1)
        self.assertEqual(result['status'],'protocol_refused')
        self.assertFalse(result['execution_complete'])
        self.assertEqual(result['decisions'],[])

    def testPrivateInitializeAndSystemConfigurationMetadataNeverLeavesConsumer(self):
        result=self.run_peer('normal')
        encoded=json.dumps(result)
        self.assertNotIn('private-source-not-to-export',encoded)
        self.assertNotIn('private-email-not-to-export',encoded)
        self.assertNotIn('account',encoded)

    def testRefusalDiagnosticIdentifiesExactInitCheckWithoutChangingAdmission(self):
        expected = {'wrong-directory':'cwd_match','extra-tools':'tools_match','mcp':'mcp_empty',
                    'bypass':'permission_default','session-agents':'agents_strings',
                    'session-skills':'skills_match','session-plugins':'plugins_match'}
        for mode, check in expected.items():
            with self.subTest(mode=mode):
                result=self.run_peer(mode)
                refusal=result['diagnostics']['refusal']
                self.assertEqual(refusal['reason'],'unreviewed_native_session_configuration')
                self.assertEqual(refusal['stage'],'event_admission')
                self.assertFalse(refusal['event']['init']['checks'][check])
                self.assertEqual(result['decisions'],[])
                self.assertFalse(result['execution_complete'])
                self.assertTrue(result['cleanup']['passed'])
                self.assertNotIn('private-value-not-to-export',json.dumps(result))

    def testExtraOrMissingInitMetadataRemainsRejectedAndFieldNamesAreProjected(self):
        for mode in ('session-extra','session-missing'):
            with self.subTest(mode=mode):
                result=self.run_peer(mode)
                event=result['diagnostics']['refusal']['event']
                self.assertFalse(event['init']['checks']['fields_exact'])
                self.assertFalse(result['execution_complete'])
                self.assertEqual(result['decisions'],[])
                if mode=='session-extra':
                    self.assertTrue(all(value for name,value in event['init']['checks'].items()
                                        if name!='fields_exact'))
                    self.assertEqual(event['fields']['unknown'],[{'name':'other','type':'string',
                        'sha256':hashlib.sha256(b'fast_mode_state').hexdigest()}])
                else:
                    self.assertEqual(event['init']['shapes']['agents'],{'type':'null'})
                self.assertNotIn('private-value-not-to-export',json.dumps(result))

    def testOptionalBetasMissingOrFiniteStringsCompleteButMalformedMetadataCannot(self):
        for mode in ('no-betas','betas-valid'):
            with self.subTest(mode=mode):
                result=self.run_peer(mode)
                self.assertTrue(result['execution_complete'])
                self.assertEqual(result['diagnostics']['refusal'],None)
                self.assertEqual(result['decisions'],[{'tool_use_id':'tool-0','allowed':True}])
        for mode in ('betas-null','betas-string','betas-object','betas-bool','betas-number',
                     'betas-nested','betas-nonstring','betas-empty-string','betas-long-string','betas-too-many'):
            with self.subTest(mode=mode):
                result=self.run_peer(mode)
                refusal=result['diagnostics']['refusal']
                self.assertEqual(refusal['reason'],'unreviewed_native_session_configuration')
                self.assertTrue(refusal['event']['init']['checks']['fields_exact'])
                self.assertFalse(refusal['event']['init']['checks']['betas_valid'])
                self.assertFalse(result['execution_complete'])
                self.assertEqual(result['decisions'],[])
                self.assertTrue(result['cleanup']['passed'])
                self.assertNotIn('private-beta-not-to-export',json.dumps(result))

    def testUnknownEventSubtypeAndFieldExposeOnlyFiniteClassificationAndHashes(self):
        result=self.run_peer('hostile-event')
        refusal=result['diagnostics']['refusal']
        self.assertEqual(refusal['reason'],'unexpected_native_event')
        event=refusal['event']
        for key,value in (('type','private-event-not-to-export'),('subtype','private-subtype-not-to-export')):
            self.assertEqual(event[key],{'name':'other','type':'string',
                'sha256':hashlib.sha256(value.encode()).hexdigest()})
        self.assertEqual(event['fields']['unknown'],[{'name':'other','type':'string',
            'sha256':hashlib.sha256(b'private-field-not-to-export').hexdigest()}])
        self.assertNotIn('private-',json.dumps(result))
        self.assertFalse(result['execution_complete'])

    def testRejectedToolNameIdAndCommandAreDigestsNeverRemoteText(self):
        result=self.run_peer('hostile-tool')
        refusal=result['diagnostics']['refusal']
        self.assertEqual(refusal['reason'],'unreviewed_native_tool_input')
        tool=refusal['event']['tools'][0]
        for key,value in (('name','private-tool-not-to-export'),('id','private-tool-id-not-to-export'),
                          ('command','private-command-not-to-export')):
            self.assertEqual(tool[key],{'name':'other','type':'string',
                'sha256':hashlib.sha256(value.encode()).hexdigest()})
        self.assertNotIn('private-',json.dumps(result))
        self.assertEqual(result['decisions'],[])

    def testDiagnosticHasBoundedFieldsShapesAndNoIdentityOrModelContents(self):
        result=self.run_peer('hostile-init')
        event=result['diagnostics']['refusal']['event']
        self.assertEqual(len(event['fields']['unknown']),16)
        self.assertTrue(event['fields']['truncated'])
        self.assertLess(len(json.dumps(result['diagnostics'])),6000)
        self.assertEqual(event['init']['shapes']['tools'],{'type':'array','count':1,'truncated':False})
        self.assertNotIn('private-',json.dumps(result))
        self.assertNotIn(str(self.root),json.dumps(result['diagnostics']))
        malformed=self.run_peer('session-unhashable-tools')
        self.assertEqual(malformed['failure_type'],'TypeError')
        self.assertEqual(malformed['diagnostics']['refusal']['reason'],'other')
        self.assertFalse(malformed['diagnostics']['refusal']['event']['init']['checks']['tools_match'])

    def testUnreviewedExceptionTextAndRenderingNeverReachDiagnostics(self):
        class UnrenderableProtocolError(ProtocolError):
            def __str__(self):raise AssertionError('exception string must not be read')
            def __repr__(self):raise AssertionError('exception representation must not be read')
        def refuse():raise UnrenderableProtocolError('private-exception-not-to-export')
        result=consume([sys.executable,str(self.script),'normal',str(self.input)],'bounded',self.policy(),
                       seconds=3,_verify_configuration=refuse)
        self.assertEqual(result['failure_type'],'ProtocolError')
        self.assertEqual(result['diagnostics']['refusal']['reason'],'other')
        self.assertEqual(result['diagnostics']['completion_refusal']['reason'],'other')
        self.assertNotIn('private-',json.dumps(result))
        self.assertTrue(result['cleanup']['passed'])

    def testNativePermissionBeforeAssistantUseStillBindsSameInput(self):
        self.assertTrue(self.run_peer('permission-first')['policy_complete'])

    def testNamespacedSkillAndSyntheticExpansionUseExistingOrderedLifecycle(self):
        result=self.run_peer('skill')
        self.assertTrue(result['policy_complete'])
        self.assertEqual(len(result['decisions']),2)
        self.assertTrue(all(x['allowed'] for x in result['decisions']))

    def testInitializationMissingConfirmationOrExtraFieldsNeverSendsTask(self):
        for mode in ('bad-init','init-extra'):
            with self.subTest(mode=mode):
                result=self.run_peer(mode)
                self.assertFalse(result['initialized'])
                self.assertEqual(result['status'],'protocol_refused')
                self.assertTrue(result['cleanup']['passed'])

    def testUnknownEventAndSecondInitializationAreRejected(self):
        for mode in ('unknown','duplicate-init','after-result'):
            with self.subTest(mode=mode):
                self.assertFalse(self.run_peer(mode)['execution_complete'])

    def testActualCwdToolsMcpAndPermissionModeMustMatchReviewedConfiguration(self):
        for mode in ('wrong-directory','extra-tools','mcp','bypass'):
            with self.subTest(mode=mode):
                result=self.run_peer(mode)
                self.assertFalse(result['policy_complete'])
                self.assertEqual(result['decisions'],[])

    def testUnknownPermissionSubtypeFieldAndAgentCannotAuthorizeAnything(self):
        for mode in ('unknown-request','request-extra','agent','before-session'):
            with self.subTest(mode=mode):
                result=self.run_peer(mode)
                self.assertFalse(result['policy_complete'])
                self.assertEqual(result['decisions'],[])

    def testExtraNativeInputBackgroundAndCommandExpansionCannotExecute(self):
        for mode in ('extra-input','background','wrong-command'):
            with self.subTest(mode=mode):
                result=self.run_peer(mode)
                self.assertFalse(result['policy_complete'])
                self.assertFalse(any(item['allowed'] for item in result['decisions']))

    def testApprovalObservedUseInputMismatchCannotAuthorizeAlteredTimeout(self):
        result=self.run_peer('mismatch')
        self.assertFalse(result['policy_complete'])
        self.assertEqual(result['failure_type'],'_PolicyRefused')
        self.assertEqual(result['diagnostics']['refusal']['reason'],'pinned_policy_refused')
        self.assertEqual(result['decisions'],[{'tool_use_id':'tool-0','allowed':False}])

    def testSuccessfulNativeResultWithoutPermissionOrWithWrongResultIdCannotComplete(self):
        for mode in ('no-permission','wrong-result-id','tool-error','native-error','result-foreign','no-result'):
            with self.subTest(mode=mode):
                self.assertFalse(self.run_peer(mode)['policy_complete'])

    def testMidInvocationPinnedInputMutationCannotComplete(self):
        result=self.run_peer('mutate-pin')
        self.assertFalse(result['policy_complete'])
        self.assertEqual(result['status'],'policy_refused')

    def testDeadlineTerminatesOwnedInvocationWithoutNativeResult(self):
        result=consume([sys.executable,str(self.script),'stall',str(self.input)], 'bounded',
                       self.policy(), seconds=.2)
        self.assertEqual(result['status'],'hard_deadline')
        self.assertTrue(result['cleanup']['passed'])
        self.assertLess(result['seconds'],1.5)
        self.assertFalse(result['execution_complete'])

    def testCleanupFailureCannotBeHiddenBySuccessfulNativeResult(self):
        failed={'term':'requested','kill':'permission_denied','leader_reaped':True,
                'post_reap_group':'permission_denied','passed':False}
        with patch('claude_stream._terminate_group',return_value=failed):
            result=self.run_peer('normal')
        self.assertEqual(result['status'],'native_result')
        self.assertFalse(result['execution_complete'])

    def testNativeInputRejectsInvalidTimeoutTypesAndUnreviewedFields(self):
        for timeout in (True,False,0,-1,120001,1.5,'30',None):
            with self.subTest(timeout=timeout),self.assertRaises(ValueError):
                _input('Bash',{'command':'rtk proxy video schema','timeout':timeout})
        for values in ({'skill':'video'},{'skill':'video:video','args':'extra'}):
            with self.assertRaises(ValueError):_input('Skill',values)

    def testFreshSettingsContainOnlyMandatoryAskAndDisabledHooks(self):
        path=self.root/'native-settings.json'
        create_isolated_settings(self.policy(),path)
        self.assertEqual(json.loads(path.read_text()),{'disableAllHooks':True,
            'permissions':{'allow':[],'ask':['Bash']}})
        with self.assertRaises(ValueError):create_isolated_settings(self.policy(),path)

    def native_dependencies(self,skill=False):
        node=self.root/'node';node.write_text('reviewed interpreter')
        cli=self.root/'claude';cli.write_text('reviewed native cli')
        settings=self.root/'settings.json'
        create_isolated_settings(self.policy(skill=skill),settings)
        return node,cli,settings

    def plugin(self):
        plugin=self.root/'plugin'
        if not plugin.exists():
            native_package.package(Path(__file__).parent/'skills/video',plugin,'claude','1.0.0')
        return plugin,tuple(p for p in plugin.rglob('*') if p.is_file())

    def testNormalEntryBuildsOfficialIsolatedArgumentsWithoutChangingHome(self):
        node,cli,settings=self.native_dependencies()
        policy=self.policy(pins=tuple(self.pin(p) for p in (node,cli,settings)))
        with patch('claude_stream.shutil.which',side_effect=lambda name:str(node if name=='node' else cli)),\
             patch('claude_stream.consume',return_value={'prepared':True}) as consumer:
            self.assertEqual(run_claude('bounded',policy,settings),{'prepared':True})
        args=consumer.call_args.args[0]
        for option,value in (('--setting-sources',''),('--permission-prompt-tool','stdio'),
                             ('--tools','Bash'),('--permission-mode','default'),
                             ('--mcp-config','{"mcpServers":{}}')):
            self.assertEqual(args[args.index(option)+1],value)
        self.assertIn('--no-session-persistence',args)
        self.assertNotIn('--allowedTools',args)
        self.assertNotIn('--dangerously-skip-permissions',args)
        self.assertEqual(args[:2],[str(node),str(cli)])

    def testNormalEntryRejectsMissingPinSettingsMutationAndUnreviewedPlugin(self):
        node,cli,settings=self.native_dependencies()
        for dependencies in ((node,settings),(node,cli)):
            with self.subTest(dependencies=dependencies),\
                 patch('claude_stream.shutil.which',side_effect=lambda name:str(node if name=='node' else cli)),\
                 self.assertRaises(ValueError):
                run_claude('bounded',self.policy(pins=tuple(self.pin(p) for p in dependencies)),settings)
        policy=self.policy(pins=tuple(self.pin(p) for p in (node,cli,settings)))
        settings.write_text('{"permissions":{"allow":["Bash"]}}')
        with patch('claude_stream.shutil.which',side_effect=lambda name:str(node if name=='node' else cli)),\
             self.assertRaises(ValueError):run_claude('bounded',policy,settings)

    def testExplicitReviewedPluginLoadsOnlyOneNamespacedSkillWithoutFilesystemSettings(self):
        node,cli,settings=self.native_dependencies(skill=True)
        plugin,files=self.plugin()
        dependencies=(node,cli,settings,*files)
        policy=self.policy(skill=True,pins=tuple(self.pin(p) for p in dependencies))
        with patch('claude_stream.shutil.which',side_effect=lambda name:str(node if name=='node' else cli)),\
             patch('claude_stream.consume',return_value={}) as consumer:
            run_claude('bounded',policy,settings,skill_plugin=plugin)
        args=consumer.call_args.args[0]
        self.assertEqual(args[args.index('--plugin-dir')+1],str(plugin))
        self.assertEqual(args[args.index('--setting-sources')+1],'')
        hook=plugin/'hooks/unreviewed.json';hook.parent.mkdir();hook.write_text('{}')
        with patch('claude_stream.shutil.which',side_effect=lambda name:str(node if name=='node' else cli)),\
             self.assertRaises(ValueError):run_claude('bounded',policy,settings,skill_plugin=plugin)

    def testNewUnpinnedPluginHookDuringInvocationFailsBeforeNextPermission(self):
        settings=self.root/'settings.json'
        create_isolated_settings(self.policy(skill=True),settings)
        plugin,files=self.plugin()
        policy=self.policy(skill=True,pins=tuple(self.pin(p) for p in (settings,*files)))
        def observe(event):
            if event.get('type')=='system':
                hook=plugin/'hooks/new-hook.json';hook.parent.mkdir();hook.write_text('{}')
        result=consume([sys.executable,str(self.script),'skill',str(self.input)],'bounded',policy,seconds=3,
            skill_plugin=plugin,on_event=observe,_verify_configuration=lambda:_configuration(policy,settings,plugin))
        self.assertFalse(result['execution_complete'])
        self.assertEqual(result['decisions'],[])
        self.assertTrue(result['cleanup']['passed'])

    def testEveryMissingFormalSkillFileRefusesBeforeNextNativePermission(self):
        settings=self.root/'settings.json'
        create_isolated_settings(self.policy(skill=True),settings)
        plugin,files=self.plugin()
        skill=plugin/'skills/video'
        for reference in tuple(p for p in skill.rglob('*') if p.is_file()):
            policy=self.policy(skill=True,pins=(self.pin(settings),))
            original=reference.read_bytes()
            with self.subTest(missing=reference.relative_to(skill)):
                reference.unlink()
                with self.assertRaises((OSError,ValueError)):_configuration(policy,settings,plugin)
            reference.write_bytes(original)

    def testCompletePluginStillRejectsUnreviewedEmptyDirectoryAndAnotherSkillPath(self):
        settings=self.root/'settings.json'
        create_isolated_settings(self.policy(skill=True),settings)
        plugin,_=self.plugin()
        policy=self.policy(skill=True,pins=(self.pin(settings),))
        extra=plugin/'unreviewed';extra.mkdir()
        with self.assertRaises(ValueError):_configuration(policy,settings,plugin)
        extra.rmdir()
        other=self.root/'other/skills/video'
        import shutil
        shutil.copytree(plugin/'skills/video',other)
        pins=tuple(self.pin(p) for p in other.rglob('*') if p.is_file())+(self.pin(settings),)
        wrong=PinnedPolicy(self.root,('rtk proxy video schema',),pins,allow_skill=True,skill_directory=other)
        with self.assertRaisesRegex(ValueError,'native_skill_directory_mismatch'):_configuration(wrong,settings,plugin)

    def testConfigurationSizeIsCheckedBeforeHashAndDuplicateJsonKeysAreRejected(self):
        path=self.root/'settings.json';path.write_bytes(b'x'*65537)
        pin=self.pin(path);policy=self.policy(pins=(pin,))
        with patch.object(FilePin,'verify') as verify,self.assertRaises(ValueError):
            _pinned_json(policy,path,65536)
        verify.assert_not_called()
        path.write_text('{"permissions":{},"permissions":{}}')
        with self.assertRaises(ValueError):_pinned_json(self.policy(pins=(self.pin(path),)),path,65536)

    def testExistingOfficialPackageBuilderOutputWorksWithoutInventedWrapper(self):
        source=Path(__file__).parent/'skills/video'
        plugin=self.root/'plugin'
        native_package.package(source,plugin,'claude','1.0.0')
        settings=self.root/'settings.json';create_isolated_settings(self.policy(skill=True),settings)
        files=tuple(p for p in plugin.rglob('*') if p.is_file())
        policy=self.policy(skill=True,pins=tuple(self.pin(p) for p in (settings,*files)))
        _configuration(policy,settings,plugin)
        (plugin/'LICENSE').write_text('different source')
        changed=self.policy(skill=True,pins=tuple(self.pin(p) for p in (settings,*files)))
        with self.assertRaisesRegex(ValueError,'not_same_source'):_configuration(changed,settings,plugin)


if __name__=='__main__':unittest.main()
