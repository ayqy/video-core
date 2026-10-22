"""Transport/security rules use a local protocol peer, never a model account."""
from pathlib import Path
import json
import sys
import tempfile
import unittest

from qwen_stream import ExactPolicy, consume, create_isolated_settings


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
        base = Path.cwd() / ".qwen-check" / "test-temp"
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

    def testFullCommandEqualityRejectsAdditionalArgumentAtNativeGate(self):
        result = consume(self.peer("deny"), "bounded input", self.policy, seconds=3)
        self.assertEqual(result["decisions"], [{"tool_use_id": "call-one", "allowed": False}])
        self.assertEqual(result["exit_code"], 0)

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
        self.assertEqual(settings["permissions"], {"ask": ["Bash", "Edit"], "allow": ["Skill(video)"]})
        self.assertEqual(settings["modelProviders"]["openai"][0]["envKey"], "DEEPSEEK_API_KEY")
        with self.assertRaises(ValueError):
            create_isolated_settings(self.root, home, runtime)


if __name__ == "__main__":
    unittest.main()
