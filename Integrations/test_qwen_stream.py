"""Transport/security rules use a local protocol peer, never a model account."""
from pathlib import Path
import hashlib
import json
import os
import selectors
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

from qwen_stream import ExactPolicy, FilePin, PinnedPolicy, _PolicyRefused, _policy_rejection, _terminate_group, consume, create_isolated_settings, run_qwen


PEER = '''import json,sys,time
mode=sys.argv[1]
first=json.loads(sys.stdin.readline())
assert first['type']=='control_request' and first['request']['subtype']=='initialize'
ack={'type':'control_response','response':{'subtype':'success','request_id':first['request_id'],'response':{'subtype':'initialize','capabilities':{'can_handle_can_use_tool':mode!='bad-init'}}}}
print(json.dumps(ack),flush=True)
if mode=='bad-init':time.sleep(20)
user=json.loads(sys.stdin.readline());assert user['type']=='user'
if mode=='stall':time.sleep(20)
command='rtk proxy video schema'+(' --extra' if mode=='deny' else '')
request={'type':'control_request','request_id':'permission-one','request':{'subtype':'can_use_tool','tool_name':'run_shell_command','tool_use_id':'call-one','input':{'command':command}}}
print(json.dumps(request),flush=True)
reply=json.loads(sys.stdin.readline());assert reply['response']['request_id']=='permission-one'
assert reply['response']['response']['behavior']==('deny' if mode=='deny' else 'allow')
print(json.dumps({'type':'result','subtype':'success','is_error':False}),flush=True)
assert sys.stdin.readline()==''
'''


class QwenStreamTests(unittest.TestCase):
    def setUp(self):
        base = Path.cwd() / ".cache" / "qwen-check" / "test-temp"
        base.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=base)
        self.root = Path(self.temporary.name)
        self.policy = ExactPolicy(self.root, frozenset({"rtk proxy video schema"}))

    def tearDown(self):
        self.temporary.cleanup()

    def peer(self, mode):
        script = self.root / "peer.py"
        script.write_text(PEER)
        return [sys.executable, str(script), mode]

    def testFirstMessageInitializesSdkBeforeUserAndPermissionReply(self):
        result = consume(self.peer("allow"), "bounded input", self.policy, seconds=3)
        self.assertTrue(result["initialized"])
        self.assertEqual(result["status"], "native_result")
        self.assertEqual(result["exit_code"], 0)
        self.assertEqual(result["decisions"], [{"tool_use_id": "call-one", "allowed": True}])
        self.assertTrue(result["cleanup"]["passed"])
        self.assertTrue(result["execution_complete"])

    def testUnreadingNativeStdinCannotBlockParentDeadline(self):
        script=self.root/'unreading-peer.py'
        script.write_text("""import json,sys,time
first=json.loads(sys.stdin.readline())
print(json.dumps({'type':'control_response','response':{'subtype':'success','request_id':first['request_id'],'response':{'subtype':'initialize','capabilities':{'can_handle_can_use_tool':True}}}}),flush=True)
time.sleep(3)
""")
        entered=[]
        started=time.monotonic()
        def stop(process):
            entered.append(time.monotonic()-started)
            return _terminate_group(process)
        with patch('qwen_stream._terminate_group',side_effect=stop):
            result=consume([sys.executable,str(script),'allow'],'x'*65536,self.policy,seconds=2)
        self.assertEqual(result['status'],'hard_deadline')
        self.assertTrue(result['initialized'])
        self.assertEqual(len(entered),1)
        self.assertLess(entered[0],2.5)
        self.assertEqual(result['decisions'],[])
        self.assertFalse(result['execution_complete'])
        self.assertIn('passed',result['cleanup'])

    def testPartialAndTemporarilyBlockedStdinWritesKeepWholeMessageOrder(self):
        original=os.write
        writes=[0]
        def partial(descriptor,data):
            writes[0]+=1
            if writes[0]==2:
                raise BlockingIOError()
            return original(descriptor,data[:97])
        script=self.root/'partial-peer.py'
        script.write_text(PEER.replace(
            "user=json.loads(sys.stdin.readline());assert user['type']=='user'",
            "user=json.loads(sys.stdin.readline());assert user['type']=='user' and user['message']['content']=='x'*65536"))
        with patch('qwen_stream.os.write',side_effect=partial):
            result=consume([sys.executable,str(script),'allow'],'x'*65536,self.policy,seconds=3)
        self.assertEqual(result['status'],'native_result')
        self.assertTrue(result['execution_complete'])
        self.assertGreater(writes[0],600)
        self.assertEqual(result['decisions'],[{'tool_use_id':'call-one','allowed':True}])

    def testClosedNativeStdinReturnsBoundedFailureAndActualCleanup(self):
        script=self.root/'closed-peer.py'
        script.write_text("""import json,os,sys,time
first=json.loads(sys.stdin.readline())
os.close(0)
print(json.dumps({'type':'control_response','response':{'subtype':'success','request_id':first['request_id'],'response':{'subtype':'initialize','capabilities':{'can_handle_can_use_tool':True}}}}),flush=True)
time.sleep(.05)
""")
        result=consume([sys.executable,str(script)],'bounded',self.policy,seconds=1)
        self.assertEqual(result['status'],'protocol_refused')
        self.assertFalse(result['execution_complete'])
        self.assertEqual(result['decisions'],[])
        self.assertIn('passed',result['cleanup'])

    def testNativeResultCannotDiscardPendingUserMessage(self):
        script=self.root/'premature-result-peer.py'
        script.write_text("""import json,os,sys,time
first=json.loads(sys.stdin.readline())
ack={'type':'control_response','response':{'subtype':'success','request_id':first['request_id'],'response':{'subtype':'initialize','capabilities':{'can_handle_can_use_tool':True}}}}
result={'type':'result','subtype':'success','is_error':False}
os.write(1,('\\n'.join(json.dumps(x) for x in (ack,result))+'\\n').encode())
time.sleep(.1)
""")
        result=consume([sys.executable,str(script)],'x'*65536,self.policy,seconds=1)
        self.assertEqual(result['status'],'protocol_refused')
        self.assertFalse(result['execution_complete'])
        self.assertEqual(result['decisions'],[])

    def testOutboundQueueBoundRefusesBeforeUserOrPermission(self):
        result=consume(self.peer('allow'),'x'*(256*1024),self.policy,seconds=1)
        self.assertEqual(result['status'],'protocol_refused')
        self.assertTrue(result['initialized'])
        self.assertFalse(result['execution_complete'])
        self.assertEqual(result['decisions'],[])

    def testFullCommandEqualityRejectsAdditionalArgumentAtNativeGate(self):
        result = consume(self.peer("deny"), "bounded input", self.policy, seconds=3)
        self.assertEqual(result["decisions"], [{"tool_use_id": "call-one", "allowed": False}])
        self.assertEqual(result["exit_code"], 0)
        self.assertFalse(result["execution_complete"])

    def testCleanupFailureNeverBecomesSuccessfulExecution(self):
        failed = {"term": "requested", "kill": "permission_denied", "leader_reaped": True,
                  "post_reap_group": "permission_denied", "passed": False}
        with patch("qwen_stream._terminate_group", return_value=failed):
            result = consume(self.peer("allow"), "bounded input", self.policy, seconds=3)
        self.assertEqual(result["status"], "native_result")
        self.assertEqual(result["exit_code"], 0)
        self.assertFalse(result["cleanup"]["passed"])
        self.assertFalse(result["execution_complete"])

    def testCleanupUsesExistingOwnedGroupProofWithoutInventingAnotherPolicy(self):
        from qwen_stream import _terminate_group
        process = unittest.mock.Mock(pid=123)
        expected = {"term": "requested", "kill": "permission_denied", "leader_reaped": True,
                    "post_reap_group": "absent", "passed": True}
        with patch("codex_broker._stop", return_value=expected) as stop:
            self.assertEqual(_terminate_group(process), expected)
        stop.assert_called_once_with(process)

    def testExitedLeaderWithTermIgnoringDescendantDoesNotEscapeOwnedGroupCleanup(self):
        child = self.root / "descendant.py"
        ready = self.root / "ready"
        child.write_text("import signal,time,pathlib\nsignal.signal(signal.SIGTERM,signal.SIG_IGN)\n"
                         "pathlib.Path("+repr(str(ready))+").write_text('ready')\ntime.sleep(30)\n")
        leader = self.root / "leader.py"
        leader.write_text("import subprocess,sys,time,pathlib\nsubprocess.Popen([sys.executable,"
                          +repr(str(child))+"])\nend=time.monotonic()+2\n"
                          "while not pathlib.Path("+repr(str(ready))+").exists() and time.monotonic()<end:time.sleep(.01)\n")
        captured = []
        real_popen = subprocess.Popen

        def owned(*args, **kwargs):
            process = real_popen(*args, **kwargs)
            captured.append((process, os.dup(process.stdout.fileno())))
            process.wait(timeout=3)
            self.assertTrue(ready.exists())
            return process

        try:
            with patch("qwen_stream.subprocess.Popen", side_effect=owned):
                result = consume([sys.executable, str(leader)], "no host init", self.policy, seconds=.5)
            self.assertEqual(result["status"], "hard_deadline")
            self.assertFalse(result["execution_complete"])
            self.assertTrue(result["cleanup"]["passed"])
            process, descriptor = captured[0]
            self.assertEqual(process.returncode, 0)
            watcher = selectors.DefaultSelector()
            try:
                watcher.register(descriptor, selectors.EVENT_READ)
                self.assertTrue(watcher.select(2), "owned descendant still holds the pipe")
                self.assertEqual(os.read(descriptor, 1), b"")
            finally:
                watcher.close()
        finally:
            for process, descriptor in captured:
                os.close(descriptor)
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except (ProcessLookupError, PermissionError):
                    pass

    def testMissingPermissionCapabilityRefusesToSendUserTask(self):
        with self.assertRaisesRegex(ValueError, "SDK许可通道"):
            consume(self.peer("bad-init"), "must not run", self.policy, seconds=3)

    def testHardDeadlineEndsStalledOwnedProcessWithoutNativeResult(self):
        result = consume(self.peer("stall"), "bounded input", self.policy, seconds=0.3)
        self.assertEqual(result["status"], "hard_deadline")
        self.assertLess(result["seconds"], 1.5)
        self.assertNotEqual(result["exit_code"], 0)
        self.assertIsNone(result["result"])

    def testRejectsDifferentDirectoryAndBackgroundExecution(self):
        self.assertTrue(self.policy.allows({"subtype": "can_use_tool", "tool_name": "run_shell_command", "input": {"command": "rtk proxy video schema", "directory": "."}}))
        for values in [{"command": "rtk proxy video schema", "directory": str(self.root.parent)},
                       {"command": "rtk proxy video schema", "is_background": True},
                       {"command": "rtk proxy video schema; echo other"}]:
            self.assertFalse(self.policy.allows({"subtype": "can_use_tool", "tool_name": "run_shell_command", "input": values}))

    def testOnlyExactJsonInputPathCanBeWritten(self):
        target = self.root / "input.json"
        policy = ExactPolicy(self.root, self.policy.commands, frozenset({target.resolve()}))
        request = {"subtype": "can_use_tool", "tool_name": "write_file", "input": {"file_path": str(target), "content": "{}"}}
        self.assertTrue(policy.allows(request))
        request["input"]["file_path"] = str(self.root / "other.json")
        self.assertFalse(policy.allows(request))
        request["input"] = {"file_path": str(target), "content": "[]"}
        self.assertFalse(policy.allows(request))
        target.symlink_to(self.root / "other.json")
        request["input"]["content"] = "{}"
        self.assertFalse(policy.allows(request))

    def testFreshSettingsUseEnvNameAndMandatoryAskRules(self):
        home, runtime = self.root / "qwen-home", self.root / "runtime"
        create_isolated_settings(self.root, home, runtime)
        settings = json.loads((home / "settings.json").read_text())
        self.assertIs(type(settings["$version"]), int)
        self.assertEqual(settings["$version"], 4)
        self.assertEqual(settings["permissions"], {"ask": ["Bash", "Edit"], "allow": ["Skill(video)"]})
        self.assertEqual(settings["modelProviders"]["openai"][0]["envKey"], "DEEPSEEK_API_KEY")
        with self.assertRaises(ValueError):
            create_isolated_settings(self.root, home, runtime)


PINNED_PEER = '''import json,sys
mode=sys.argv[1]
first=json.loads(sys.stdin.readline())
print(json.dumps({'type':'control_response','response':{'subtype':'success','request_id':first['request_id'],'response':{'subtype':'initialize','capabilities':{'can_handle_can_use_tool':True}}}}),flush=True)
assert json.loads(sys.stdin.readline())['type']=='user'
if mode=='empty':
 print(json.dumps({'type':'result','subtype':'success','is_error':False}),flush=True)
 sys.exit(0)
commands=['rtk proxy video schema','rtk proxy video doctor']
if mode=='reverse':commands.reverse()
if mode=='repeat':commands[1]=commands[0]
for i,command in enumerate(commands):
 identifier='call-'+str(i)
 values={'command':command}
 if mode.startswith('timeout-'):
  values.update(timeout=json.loads(sys.argv[3]),directory='.',is_background=False)
 if mode=='timeout-shell-wrapper':values['command']='/bin/sh -c '+repr(command)
 if mode=='timeout-unknown':values['unreviewed']=False
 observed_values,permission_values=dict(values),dict(values)
 if mode=='timeout-change-after-use':permission_values['timeout']=119999
 if mode=='timeout-change-after-permission':observed_values['timeout']=119999
 use={'type':'assistant','message':{'role':'assistant','content':[{'type':'tool_use','id':identifier,'name':'run_shell_command','input':observed_values}]}}
 permission_first=mode in ('permission-first','timeout-permission-first','timeout-change-after-permission')
 if not permission_first:print(json.dumps(use),flush=True)
 print(json.dumps({'type':'control_request','request_id':'permission-'+str(i),'request':{'subtype':'can_use_tool','tool_name':'run_shell_command','tool_use_id':identifier,'input':permission_values}}),flush=True)
 reply=json.loads(sys.stdin.readline())
 if reply['response']['response']['behavior']!='allow':sys.exit(0)
 if permission_first:print(json.dumps(use),flush=True)
 if mode=='timeout-stall':
  import time
  time.sleep(20)
 if mode in ('mutated','timeout-mutated'):
  from pathlib import Path
  Path(sys.argv[2]).write_text('changed after permission')
 result={'type':'tool_result','tool_use_id':identifier if mode!='unknown-result' else 'unknown','is_error':mode=='error'}
 print(json.dumps({'type':'user','message':{'role':'user','content':[result]}}),flush=True)
print(json.dumps({'type':'result','subtype':'success','is_error':False}),flush=True)
assert sys.stdin.readline()==''
'''


class PinnedQwenPolicyTests(unittest.TestCase):
    """Only a local protocol peer is used; it never executes a tool or model."""
    def setUp(self):
        base = Path.cwd() / ".cache" / "qwen-check" / "test-temp"
        base.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=base)
        self.root = Path(self.temporary.name).resolve()
        self.fixed = self.root / "fixed-input.txt"
        self.fixed.write_text("fixed reviewed input")
        self.digest = hashlib.sha256(self.fixed.read_bytes()).hexdigest()
        self.commands = ("rtk proxy video schema", "rtk proxy video doctor")

    def tearDown(self):
        self.temporary.cleanup()

    def policy(self, **kwargs):
        return PinnedPolicy(self.root, self.commands, (FilePin(self.fixed, self.digest),), **kwargs)

    def request(self, command=None, identifier="one", **values):
        return {"subtype": "can_use_tool", "tool_name": "run_shell_command", "tool_use_id": identifier,
                "input": {"command": command or self.commands[0], **values}}

    def use(self, request):
        return {"type": "assistant", "message": {"role": "assistant", "content": [
            {"type": "tool_use", "id": request["tool_use_id"], "name": request["tool_name"], "input": request["input"]}]}}

    def result(self, identifier="one", **extra):
        return {"type": "user", "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": identifier, "is_error": False, **extra}]}}

    def complete_one(self, policy, request):
        policy.observe(self.use(request))
        self.assertTrue(policy.allows(request))
        policy.observe(self.result(request["tool_use_id"]))

    def peer(self, mode, timeout=None):
        script = self.root / "peer.py"
        script.write_text(PINNED_PEER)
        return [sys.executable, str(script), mode, str(self.fixed), json.dumps(timeout)]

    def testPinnedSequenceHasNativeLifecycleWithoutCallerCallback(self):
        for mode in ("ordered", "permission-first"):
            with self.subTest(mode=mode):
                result = consume(self.peer(mode), "test protocol only", self.policy(), seconds=3)
                self.assertEqual(result["status"], "native_result")
                self.assertEqual(result["exit_code"], 0)
                self.assertTrue(result["policy_complete"])
                self.assertEqual([d["allowed"] for d in result["decisions"]], [True, True])
                self.assertIsNone(result["policy_rejection"])

    def tail_peer(self, tail, *, final=None):
        script = self.root / "tail-peer.py"
        source = PINNED_PEER.replace("assert sys.stdin.readline()==''", tail)
        if final is not None:
            source = source.replace(
                "print(json.dumps({'type':'result','subtype':'success','is_error':False}),flush=True)", final)
        script.write_text(source)
        return [sys.executable, "-B", str(script), "ordered", str(self.fixed)]

    def assert_refused_stream_cleanup(self, result):
        # A natural EOF can leave an unreaped Darwin leader for which both
        # signals are denied. Preserve that conservative cleanup failure;
        # refusal must still reap the leader and never become success.
        self.assertTrue(result["cleanup"]["leader_reaped"])
        for name in ("term", "kill"):
            self.assertIn(result["cleanup"][name],
                          ("requested", "group_absent", "permission_denied", "signal_failed"))
        self.assertFalse(result["execution_complete"])
        self.assertFalse(result["policy_complete"])

    def testTruncatedJsonAtEofNeverCompletesAnOtherwiseFinishedChain(self):
        result = consume(self.tail_peer("sys.stdout.write('{\"type\":');sys.stdout.flush()"),
                         "local protocol only", self.policy(), seconds=3)
        self.assertEqual(result["status"], "protocol_refused")
        self.assertFalse(result["execution_complete"])
        self.assertFalse(result["policy_complete"])
        self.assertEqual(result["policy_rejection"]["reason"], "native_protocol_refused")
        self.assert_refused_stream_cleanup(result)

    def testSecondResultCannotReplaceTheFirstNativeResult(self):
        first = "print(json.dumps({'type':'result','subtype':'success','is_error':False,'result':'first'}),flush=True)"
        for subtype in ("success", "error_during_execution"):
            with self.subTest(subtype=subtype):
                tail = "print(json.dumps({'type':'result','subtype':"+repr(subtype)+",'result':'replacement'}),flush=True)"
                result = consume(self.tail_peer(tail, final=first), "local only", self.policy(), seconds=3)
                self.assertEqual(result["status"], "protocol_refused")
                self.assertEqual(result["result"]["result"], "first")
                self.assertFalse(result["execution_complete"])
                self.assertFalse(result["policy_complete"])
                self.assert_refused_stream_cleanup(result)

    def testUnknownOrExecutableEventsAfterResultNeverReachAnotherPermission(self):
        tails = [
            {"type": "unexpected_native_event"},
            {"type": "assistant", "message": {"role": "assistant", "content": [{
                "type": "tool_use", "id": "late", "name": "run_shell_command",
                "input": {"command": self.commands[0]}}]}},
            {"type": "control_request", "request_id": "late", "request": {
                "subtype": "can_use_tool", "tool_name": "run_shell_command", "tool_use_id": "late",
                "input": {"command": self.commands[0]}}},
            {"type": "system", "subtype": "init"},
            {"type": "usage", "usage": {}, "request": {"subtype": "can_use_tool"}},
            {"type": "system", "subtype": "summary", "parent_tool_use_id": "late", "data": {}},
        ]
        for event in tails:
            with self.subTest(event=event):
                result = consume(self.tail_peer("print("+repr(json.dumps(event))+",flush=True)"),
                                 "local only", self.policy(), seconds=3)
                self.assertEqual(result["status"], "protocol_refused")
                self.assertFalse(result["execution_complete"])
                self.assertFalse(result["policy_complete"])
                self.assertEqual(len(result["decisions"]), 2)
                self.assert_refused_stream_cleanup(result)

    def testFinalUsageAndSystemSummariesAreInertAndDoNotReplaceResult(self):
        first = "print(json.dumps({'type':'result','subtype':'success','is_error':False,'session_id':'session-one','usage':{'input_tokens':1}}),flush=True)"
        tail = """for event in [
 {'type':'usage','session_id':'session-one','usage':{'input_tokens':2,'output_tokens':3}},
 {'type':'system','subtype':'summary','session_id':'session-one','parent_tool_use_id':None,'data':{'summary':'finished'}},
 {'type':'system','subtype':'usage','session_id':'session-one','usage':{'output_tokens':3}},
 {'type':'system','subtype':'session_end','session_id':'session-one','data':{'session_id':'session-one'}}]:
 print(json.dumps(event),flush=True)
"""
        result = consume(self.tail_peer(tail, final=first), "local only", self.policy(), seconds=3)
        self.assertTrue(result["execution_complete"])
        self.assertTrue(result["policy_complete"])
        self.assertEqual(result["result"]["usage"], {"input_tokens": 1})
        self.assertEqual(len(result["decisions"]), 2)
        self.assertEqual([e["type"] for e in result["events"][-4:]], ["usage", "system", "system", "system"])
        self.assertTrue(result["cleanup"]["passed"])

    def testTailAccountingFromAnotherSessionIsRefused(self):
        first = "print(json.dumps({'type':'result','subtype':'success','is_error':False,'session_id':'one'}),flush=True)"
        tail = "print(json.dumps({'type':'usage','session_id':'other','usage':{}}),flush=True)"
        result = consume(self.tail_peer(tail, final=first), "local only", self.policy(), seconds=3)
        self.assertEqual(result["status"], "protocol_refused")
        self.assertFalse(result["execution_complete"])
        self.assertFalse(result["policy_complete"])

    def testCompleteResultWithoutFinalNewlineIsConsumedAtEof(self):
        final = "sys.stdout.write(json.dumps({'type':'result','subtype':'success','is_error':False}));sys.stdout.flush()"
        result = consume(self.tail_peer("pass", final=final), "local only", self.policy(), seconds=3)
        self.assertEqual(result["status"], "native_result")
        self.assertTrue(result["execution_complete"])
        self.assertTrue(result["policy_complete"])
        self.assertTrue(result["cleanup"]["passed"])

    def testFragmentedFinalAccountingWithoutNewlineIsConsumedAtEof(self):
        tail = """import time
sys.stdout.write('{"type":"usage","usage":');sys.stdout.flush()
time.sleep(.03)
sys.stdout.write('{"output_tokens":1}}');sys.stdout.flush()
"""
        result = consume(self.tail_peer(tail), "local only", self.policy(), seconds=3)
        self.assertTrue(result["execution_complete"])
        self.assertTrue(result["policy_complete"])
        self.assertEqual(result["events"][-1], {"type": "usage", "usage": {"output_tokens": 1}})

    def testDuplicateKeysNonfiniteValuesAndNonobjectsRefuseAtTheSharedDecoder(self):
        for raw in ('{"type":"usage","usage":{},"usage":{}}',
                    '{"type":"usage","usage":{"output_tokens":NaN}}',
                    '{"type":"usage","usage":{"output_tokens":Infinity}}', '[]'):
            with self.subTest(raw=raw):
                result = consume(self.tail_peer("sys.stdout.write("+repr(raw)+");sys.stdout.flush()"),
                                 "local only", self.policy(), seconds=3)
                self.assertEqual(result["status"], "protocol_refused")
                self.assertFalse(result["execution_complete"])
                self.assertFalse(result["policy_complete"])
                self.assert_refused_stream_cleanup(result)

    def testOversizedFrameAndTooManyEventsCannotFinishSuccessfully(self):
        tails = ["sys.stdout.write('x'*(4*1024*1024+1));sys.stdout.flush()",
                 "for _ in range(1001):print(json.dumps({'type':'usage','usage':{}}),flush=True)"]
        for tail in tails:
            with self.subTest(tail=tail):
                result = consume(self.tail_peer(tail), "local only", self.policy(), seconds=3)
                self.assertEqual(result["status"], "protocol_refused")
                self.assertFalse(result["execution_complete"])
                self.assertFalse(result["policy_complete"])
                self.assert_refused_stream_cleanup(result)

    def testRejectedNativeObservationReturnsOnlyShapeAndExpectedCommandFingerprint(self):
        result = consume(self.peer("reverse"), "not retained in diagnostic", self.policy(), seconds=3)
        value = result["policy_rejection"]
        self.assertEqual(value["reason"], "pinned_observer_refused")
        self.assertEqual(value["phase"], "observation")
        self.assertEqual(value["event_type"], {"kind": "assistant"})
        tool = value["content_blocks"][0]["tool"]
        self.assertEqual(tool["tool"], {"kind": "run_shell_command"})
        self.assertEqual(tool["command_sha256"], hashlib.sha256(self.commands[1].encode()).hexdigest())
        self.assertEqual(tool["expected_command_sha256"], hashlib.sha256(self.commands[0].encode()).hexdigest())
        self.assertFalse(tool["command_matches_expected"])
        self.assertFalse(result["execution_complete"])
        self.assertFalse(result["policy_complete"])
        self.assertTrue(result["cleanup"]["passed"])
        self.assertNotIn(self.commands[0], json.dumps(value))
        self.assertNotIn(self.commands[1], json.dumps(value))

    def testNativePermissionRefusalIsDistinctAndContainsNoTimeoutValue(self):
        result = consume(self.peer("timeout-permission-first", 0), "local only", self.policy(), seconds=3)
        value = result["policy_rejection"]
        self.assertEqual(value["reason"], "native_permission_refused")
        self.assertEqual(value["phase"], "permission")
        self.assertTrue(value["requested_tool"]["command_matches_expected"])
        fields = value["requested_tool"]["input"]["fields"]
        self.assertIn({"key": {"kind": "timeout"}, "value_type": "number"}, fields)
        self.assertFalse(any(item["allowed"] for item in result["decisions"]))
        self.assertFalse(result["policy_complete"])

    def testCompletionPinFailureIsDistinctWithoutReusingNativeEventAsExplanation(self):
        from qwen_stream import _terminate_group
        def stop_and_mutate(process):
            result = _terminate_group(process)
            self.fixed.write_text("changed after real process cleanup")
            return result
        with patch("qwen_stream._terminate_group", side_effect=stop_and_mutate):
            result = consume(self.peer("ordered"), "local only", self.policy(), seconds=3)
        self.assertEqual(result["policy_rejection"]["phase"], "completion_pin")
        self.assertEqual(result["policy_rejection"]["event"], {"value_type": "null"})
        self.assertFalse(result["execution_complete"])
        self.assertTrue(result["cleanup"]["passed"])

    def testObserverExceptionTextIsNeverIncludedInTheReceipt(self):
        sentinel = "private-observer-exception-content-do-not-render"
        with patch.object(PinnedPolicy, "observe", side_effect=_PolicyRefused(sentinel)):
            result = consume(self.peer("ordered"), "local only", self.policy(), seconds=3)
        self.assertEqual(result["status"], "policy_refused")
        self.assertEqual(result["policy_rejection"]["phase"], "observation")
        self.assertNotIn(sentinel, json.dumps(result))

    def testDiagnosticUnknownNamesKeysIdsValuesAndBodyAreHashedOrOmitted(self):
        sentinels = ["unknown-event-private-marker", "unknown-tool-private-marker", "opaque-tool-id-private-marker",
                     "unknown-key-private-marker", "command-value-private-marker", "directory-value-private-marker",
                     "description-value-private-marker", "body-private-marker"]
        event = {"type": sentinels[0], "request": {"subtype": sentinels[7], "tool_name": sentinels[1],
            "tool_use_id": sentinels[2], "input": {sentinels[3]: sentinels[7], "command": sentinels[4],
                "directory": sentinels[5], "description": sentinels[6]}},
            "message": {"role": sentinels[7], "content": [{"type": "text", "text": sentinels[7]}]}}
        value = _policy_rejection(event, self.policy(), phase="permission", initialized=True)
        encoded = json.dumps(value, sort_keys=True)
        for sentinel in sentinels:
            self.assertNotIn(sentinel, encoded)
        self.assertEqual(value["event_type"]["kind"], "other")
        self.assertEqual(value["event_type"]["sha256"], hashlib.sha256(sentinels[0].encode()).hexdigest())
        self.assertEqual(value["requested_tool"]["tool"]["kind"], "other")
        self.assertEqual(value["requested_tool"]["tool_id_sha256"], hashlib.sha256(sentinels[2].encode()).hexdigest())
        self.assertEqual(value["requested_tool"]["command_sha256"], hashlib.sha256(sentinels[4].encode()).hexdigest())

    def testDiagnosticBoundsFieldAndContentProjectionWithoutCopyingValues(self):
        values = {"unreviewed-field-"+str(i): {"private": "body"*500} for i in range(100)}
        event = {"type": "assistant", "message": {"role": "assistant", "content": [
            {"type": "tool_use", "name": "run_shell_command", "id": "opaque", "input": values}
            for _ in range(100)]}}
        value = _policy_rejection(event, self.policy(), phase="observation", initialized=True)
        self.assertEqual(value["content_block_count"], 100)
        self.assertEqual(value["omitted_content_blocks"], 96)
        self.assertEqual(len(value["content_blocks"]), 4)
        for block in value["content_blocks"]:
            self.assertEqual(block["tool"]["input"]["field_count"], 100)
            self.assertEqual(len(block["tool"]["input"]["fields"]), 16)
            self.assertEqual(block["tool"]["input"]["omitted_fields"], 84)
        self.assertLess(len(json.dumps(value)), 16000)
        self.assertNotIn("body", json.dumps(value))

    def testDiagnosticDoesNotCallStringOrReprAndHandlesEscapedSurrogates(self):
        class Opaque:
            def __str__(self):
                raise AssertionError("must not render")
            def __repr__(self):
                raise AssertionError("must not render")
        opaque = Opaque()
        event = {"type": "assistant", "message": {"role": "assistant", "content": [
            {"type": "tool_use", "name": "\ud800", "id": opaque, "input": {"description": opaque, "\ud800": opaque}}]}}
        value = _policy_rejection(event, self.policy(), phase="observation", initialized=True)
        tool = value["content_blocks"][0]["tool"]
        self.assertEqual(tool["tool"]["kind"], "other")
        self.assertEqual(len(tool["tool"]["sha256"]), 64)
        self.assertEqual(tool["tool_id_type"], "other")
        self.assertNotIn("\\ud800", json.dumps(value))

    def testCompletePinnedToolLifecycleStillRequiresActualGroupCleanup(self):
        failed = {"term": "requested", "kill": "permission_denied", "leader_reaped": True,
                  "post_reap_group": "permission_denied", "passed": False}
        with patch("qwen_stream._terminate_group", return_value=failed):
            result = consume(self.peer("ordered"), "test protocol only", self.policy(), seconds=3)
        self.assertEqual(result["status"], "native_result")
        self.assertEqual(result["exit_code"], 0)
        self.assertFalse(result["policy_complete"])
        self.assertFalse(result["execution_complete"])

    def testReverseRepeatedUnknownAndErrorResultsCannotReportPolicyComplete(self):
        for mode in ("reverse", "repeat", "unknown-result", "error", "empty"):
            with self.subTest(mode=mode):
                result = consume(self.peer(mode), "test protocol only", self.policy(), seconds=3)
                self.assertEqual(result["status"], "policy_refused")
                self.assertFalse(result["policy_complete"])

    def testCompletionRechecksPinnedBytesAfterPermission(self):
        result = consume(self.peer("mutated"), "test protocol only", self.policy(), seconds=3)
        self.assertEqual(result["status"], "policy_refused")
        self.assertFalse(result["policy_complete"])

    def testPermissionRechecksPinsAndDoesNotGrantAfterFailure(self):
        policy = self.policy()
        self.fixed.write_text("changed before permission")
        self.assertFalse(policy.allows(self.request()))
        self.assertTrue(policy.failed)
        self.assertFalse(policy.allows(self.request(identifier="another")))

    def testDirectoryReplacementAndNoncanonicalAliasAreRefused(self):
        directory = self.root / "workdir"
        directory.mkdir()
        policy = PinnedPolicy(directory, self.commands, (FilePin(self.fixed, self.digest),))
        replacement = self.root / "moved-workdir"
        directory.rename(replacement)
        directory.symlink_to(replacement, target_is_directory=True)
        self.assertFalse(policy.allows(self.request()))
        self.assertFalse(self.policy().allows(self.request(directory=str(self.root / ".." / self.root.name))))

    def testPinRejectsSymlinkHardlinkWrongHashAndSameByteReplacement(self):
        link = self.root / "link"
        link.symlink_to(self.fixed)
        for pin in (FilePin(link, self.digest), FilePin(self.fixed, "0" * 64)):
            with self.assertRaises(ValueError):
                pin.verify()
        link.unlink()
        os.link(self.fixed, link)
        with self.assertRaises(ValueError):
            FilePin(self.fixed, self.digest).verify()
        link.unlink()
        pin = FilePin(self.fixed, self.digest)
        pin.verify()
        replacement = self.root / "replacement"
        replacement.write_bytes(self.fixed.read_bytes())
        replacement.replace(self.fixed)
        with self.assertRaisesRegex(ValueError, "identity_changed"):
            pin.verify()

    def testPendingDuplicateAndReorderedCommandsAreFailClosed(self):
        for scenario in ("pending", "same-id", "same-command", "reverse", "extra"):
            with self.subTest(scenario=scenario):
                policy = self.policy()
                if scenario == "reverse":
                    self.assertFalse(policy.allows(self.request(self.commands[1])))
                else:
                    first = self.request()
                    if scenario == "pending":
                        self.assertTrue(policy.allows(first))
                    else:
                        self.complete_one(policy, first)
                    if scenario == "extra":
                        self.complete_one(policy, self.request(self.commands[1], "two"))
                    request = self.request(self.commands[1] if scenario in ("pending", "same-id") else self.commands[0],
                                           "one" if scenario == "same-id" else "extra")
                    self.assertFalse(policy.allows(request))
                self.assertTrue(policy.failed)

    def testStrictRequestsRejectUnknownFieldsDirectoryBackgroundAndWrites(self):
        variants = [{"env": {"UNREVIEWED": "value"}}, {"timeout": 0}, {"async": False},
                    {"directory": str(self.root.parent)}, {"is_background": True}, {"is_background": 0},
                    {"command": self.commands[0] + " --extra"}]
        for values in variants:
            with self.subTest(values=values):
                self.assertFalse(self.policy().allows(self.request(**values)))
        for path in (self.fixed, self.root / "other.json"):
            self.assertFalse(self.policy().allows({"subtype": "can_use_tool", "tool_use_id": "edit", "tool_name": "write_file",
                                                   "input": {"file_path": str(path), "content": "{}"}}))

    def testTimeoutOnlyAcceptsExactPositiveIntegersWithinNativeDefault(self):
        for timeout in (1, 120000):
            with self.subTest(timeout=timeout):
                policy = self.policy()
                self.complete_one(policy, self.request(timeout=timeout, directory=".", is_background=False))
                self.complete_one(policy, self.request(self.commands[1], "two", timeout=timeout))
                self.assertTrue(policy.complete)
        for timeout in (None, True, False, 0, -1, 120001, 600000, 2**100,
                        1.0, 1.5, float("inf"), float("nan"), "120000", [], {}):
            with self.subTest(timeout=timeout):
                policy = self.policy()
                self.assertFalse(policy.allows(self.request(timeout=timeout)))
                self.assertTrue(policy.failed)

    def testValidTimeoutCannotAuthorizeUnknownFieldsCommandDirectoryOrBackground(self):
        variants = ({"env": {}}, {"async": False}, {"unreviewed": 1},
                    {"command": self.commands[0] + " --extra"},
                    {"directory": str(self.root.parent)}, {"is_background": True},
                    {"is_background": 0})
        for values in variants:
            with self.subTest(values=values):
                self.assertFalse(self.policy().allows(self.request(timeout=120000, **values)))

    def testTimeoutMustStayIdenticalBetweenObservedUseAndPermission(self):
        for permission_first in (False, True):
            for changed in (self.request(timeout=119999), self.request()):
                with self.subTest(permission_first=permission_first, changed=changed):
                    policy = self.policy()
                    original = self.request(timeout=120000)
                    if permission_first:
                        self.assertTrue(policy.allows(original))
                        with self.assertRaises(ValueError):
                            policy.observe(self.use(changed))
                    else:
                        policy.observe(self.use(original))
                        self.assertFalse(policy.allows(changed))
                    self.assertTrue(policy.failed)
                    self.assertFalse(policy.complete)

    def testConsumeAcceptsBoundedTimeoutLifecycleInBothNativeEventOrders(self):
        for mode, timeout in (("timeout-ordered", 1), ("timeout-ordered", 120000),
                              ("timeout-permission-first", 120000)):
            with self.subTest(mode=mode, timeout=timeout):
                result = consume(self.peer(mode, timeout), "test protocol only", self.policy(), seconds=3)
                self.assertEqual(result["status"], "native_result")
                self.assertEqual(result["exit_code"], 0)
                self.assertTrue(result["policy_complete"])
                self.assertEqual([d["allowed"] for d in result["decisions"]], [True, True])

    def testConsumeRefusesInvalidTimeoutBeforeAuthorizingAnyTool(self):
        for timeout in (None, True, 0, -1, 120001, 1.5, "120000"):
            with self.subTest(timeout=timeout):
                result = consume(self.peer("timeout-ordered", timeout), "test protocol only", self.policy(), seconds=3)
                self.assertEqual(result["status"], "policy_refused")
                self.assertFalse(result["policy_complete"])
                self.assertFalse(any(d["allowed"] for d in result["decisions"]))

    def testConsumeTimeoutStillRejectsChangedInputShellWrapperAndUnknownFields(self):
        expected = (("timeout-change-after-use", [False]), ("timeout-change-after-permission", [True]),
                    ("timeout-shell-wrapper", []), ("timeout-unknown", []))
        for mode, decisions in expected:
            with self.subTest(mode=mode):
                result = consume(self.peer(mode, 120000), "test protocol only", self.policy(), seconds=3)
                self.assertEqual(result["status"], "policy_refused")
                self.assertFalse(result["policy_complete"])
                self.assertEqual([d["allowed"] for d in result["decisions"]], decisions)

    def testTimeoutDoesNotExtendParentHardDeadline(self):
        # Allow this real interpreter to initialize before testing a tool's
        # 120000ms timeout; startup must still count against the parent budget.
        result = consume(self.peer("timeout-stall", 120000), "test protocol only", self.policy(), seconds=0.8)
        self.assertEqual(result["status"], "hard_deadline")
        self.assertLess(result["seconds"], 1.5)
        self.assertNotEqual(result["exit_code"], 0)
        self.assertIsNone(result["result"])
        self.assertFalse(result["policy_complete"])
        self.assertEqual(result["decisions"], [{"tool_use_id": "call-0", "allowed": True}])

    def testTimeoutLifecycleStillRechecksPinnedBytesAfterPermission(self):
        result = consume(self.peer("timeout-mutated", 120000), "test protocol only", self.policy(), seconds=3)
        self.assertEqual(result["status"], "policy_refused")
        self.assertFalse(result["policy_complete"])

    def testUnknownDuplicateChangedAndUninitializedUsesAreRefused(self):
        for scenario in ("duplicate", "changed", "uninitialized", "unknown-result", "result-without-use"):
            with self.subTest(scenario=scenario):
                policy = self.policy()
                request = self.request()
                if scenario == "duplicate":
                    policy.observe(self.use(request))
                    event = self.use(request)
                elif scenario == "changed":
                    self.assertTrue(policy.allows(request))
                    event = self.use(self.request(description="changed input"))
                elif scenario in ("unknown-result", "result-without-use"):
                    self.assertTrue(policy.allows(request))
                    event = self.result("unknown" if scenario == "unknown-result" else "one")
                else:
                    event = self.use(request)
                with self.assertRaises(ValueError):
                    policy.observe(event, initialized=scenario != "uninitialized")
                self.assertTrue(policy.failed)

    def testSkillIsOptionalSingleUseBeforeShellAndNoOtherSkillIsGranted(self):
        request = {"subtype": "can_use_tool", "tool_name": "skill", "tool_use_id": "skill-one", "input": {"skill": "video"}}
        self.assertFalse(self.policy().allows(request))
        policy = self.policy(allow_skill=True)
        self.complete_one(policy, request)
        self.complete_one(policy, self.request())
        self.assertFalse(policy.allows({**request, "tool_use_id": "skill-two"}))
        other = {**request, "input": {"skill": "other"}}
        self.assertFalse(self.policy(allow_skill=True).allows(other))

    def testPolicyIsSingleInvocationAndRequiresDistinctFiniteCommandsAndPins(self):
        policy = self.policy()
        policy.begin()
        with self.assertRaises(ValueError):
            policy.begin()
        for commands, pins in (((), (FilePin(self.fixed, self.digest),)), ((self.commands[0],) * 2, (FilePin(self.fixed, self.digest),)),
                               (self.commands, ()), (self.commands, (FilePin(self.fixed, self.digest),) * 2)):
            with self.assertRaises(ValueError):
                PinnedPolicy(self.root, commands, pins)

    def testStrictSettingsAndRunToolArgumentsHaveNoWriteOrAutomaticSkill(self):
        for allow_skill in (False, True):
            with self.subTest(allow_skill=allow_skill):
                policy = self.policy(allow_skill=allow_skill)
                home, runtime = self.root / ("home-" + str(allow_skill)), self.root / ("runtime-" + str(allow_skill))
                create_isolated_settings(self.root, home, runtime, strict_policy=policy)
                settings = json.loads((home / "settings.json").read_text())
                expected_tools = ["run_shell_command"] + (["skill"] if allow_skill else [])
                self.assertEqual(settings["permissions"], {"ask": ["Bash", "Edit"] + (["Skill"] if allow_skill else []), "allow": []})
                self.assertEqual(settings["tools"], {"core": expected_tools})
                with patch("qwen_stream.consume", return_value={"test_only": True}) as local_contract:
                    run_qwen("not sent to a host", policy, home, runtime)
                    arguments = local_contract.call_args.args[0]
                self.assertEqual(arguments[arguments.index("--core-tools") + 1:], expected_tools)
                self.assertEqual(arguments[arguments.index("--max-tool-calls") + 1], str(2 + int(allow_skill)))

    def testStrictRunRejectsActualWeakenedSettingsBeforeAnyProcess(self):
        for variant in ("allow", "ask", "tools", "hooks", "project"):
            with self.subTest(variant=variant):
                policy = self.policy(allow_skill=True)
                home, runtime = self.root / ("home-" + variant), self.root / ("runtime-" + variant)
                create_isolated_settings(self.root, home, runtime, strict_policy=policy)
                config = home / "settings.json"
                settings = json.loads(config.read_text())
                if variant == "allow":settings["permissions"]["allow"] = ["Bash"]
                elif variant == "ask":settings["permissions"]["ask"].remove("Skill")
                elif variant == "tools":settings["tools"]["core"].append("write_file")
                elif variant == "hooks":settings["hooks"] = {"unreviewed": "not executed"}
                else:
                    (self.root / ".qwen").mkdir()
                    (self.root / ".qwen" / "settings.json").write_text("{}")
                config.write_text(json.dumps(settings))
                with patch("qwen_stream.consume") as local_contract:
                    with self.assertRaises(ValueError):
                        run_qwen("must not start", policy, home, runtime)
                    local_contract.assert_not_called()

    def testStrictRunRejectsMissingWrongVersionAndUnknownMetadataBeforeAnyProcess(self):
        variants = (("missing", None), ("null", None), ("old", 3), ("future", 5),
                    ("boolean", True), ("floating", 4.0), ("string", "4"), ("unknown", 4))
        for variant, version in variants:
            with self.subTest(variant=variant):
                policy = self.policy(allow_skill=True)
                home, runtime = self.root / ("home-version-" + variant), self.root / ("runtime-version-" + variant)
                create_isolated_settings(self.root, home, runtime, strict_policy=policy)
                config = home / "settings.json"
                settings = json.loads(config.read_text())
                if variant == "missing":
                    del settings["$version"]
                else:
                    settings["$version"] = version
                if variant == "unknown":
                    settings["unreviewed"] = True
                config.write_text(json.dumps(settings))
                with patch("qwen_stream.consume") as local_contract:
                    with self.assertRaises(ValueError):
                        run_qwen("must not start", policy, home, runtime)
                    local_contract.assert_not_called()


if __name__ == "__main__":
    unittest.main()
