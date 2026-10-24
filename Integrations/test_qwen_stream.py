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
import unittest
from unittest.mock import patch

from qwen_stream import ExactPolicy, FilePin, PinnedPolicy, consume, create_isolated_settings, run_qwen


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
        result = consume(self.peer("timeout-stall", 120000), "test protocol only", self.policy(), seconds=0.3)
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
