from copy import deepcopy
import hashlib
import json
import os
import selectors
import signal
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

from codex_broker import (Broker, Command, FilePin, Policy, TOOL, _consume, _stop, execute, run_codex,
                          server_arguments, thread_parameters, _OFFICIAL_NOTIFICATIONS, _NOTIFICATION_ENUM_SHA256,
                          _project_mcp, _mcp_projection, isolate_mcp, probe_mcp_isolation,
                          _verified_model_catalog, PinnedSkill)
from codex_events import ProtocolError


PEER = r'''
import json,signal,sys,time
def get(): return json.loads(sys.stdin.readline())
def send(value): print(json.dumps(value),flush=True)
mode=sys.argv[1]
if mode=='pass': signal.signal(signal.SIGTERM,signal.SIG_IGN)
first=get();assert first['method']=='initialize'
send({'method':'remoteControl/status/changed','params':{'status':'disabled','installationId':'test-only-installation','serverName':'test-only-server','environmentId':None}})
send({'id':1,'result':{'userAgent':'offline-test-peer'}})
assert get()['method']=='initialized'
request=get();assert request['method']=='mcpServerStatus/list' and request['id']==4
assert request['params']=={'limit':32,'detail':'toolsAndAuthOnly'}
send({'id':4,'result':{'data':[],'nextCursor':None}})
if mode=='initialize-only':
 assert sys.stdin.readline()==''
 raise SystemExit(0)
request=get();assert request['method']=='thread/start'
p=request['params'];assert p['environments']==[] and p['runtimeWorkspaceRoots']==[] and p['sandbox']=='read-only'
send({'id':2,'result':{'thread':{'id':'thread-one'},'cwd':p['cwd'],'approvalPolicy':'on-request','sandbox':{'type':'readOnly'},'runtimeWorkspaceRoots':[]}})
request=get();assert request['method']=='turn/start' and request['params']['environments']==[]
send({'method':'turn/started','params':{'threadId':'thread-one','turn':{'id':'turn-one','status':'inProgress'}}})
send({'id':3,'result':{'turn':{'id':'turn-one','status':'inProgress'}}})
if mode=='timeout': time.sleep(30);raise SystemExit(0)
if mode=='failure':
 send({'method':'error','params':{'threadId':'thread-one','turnId':'turn-one','willRetry':False,'error':{'message':' '.join(('Unauthorized', 'Bearer', 'secret-never-leave-memory')),'codexErrorInfo':'unauthorized'}}})
 raise SystemExit(0)
if mode!='zero':
 arguments=json.loads(sys.argv[2])
 if mode=='denied':arguments['argv'].append('--extra')
 item={'id':'call-one','type':'dynamicToolCall','tool':p['dynamicTools'][0]['name'],'arguments':arguments,'status':'inProgress'}
 send({'method':'item/started','params':{'threadId':'thread-one','turnId':'turn-one','item':item}})
 send({'id':100,'method':'item/tool/call','params':{'threadId':'thread-one','turnId':'turn-one','callId':'call-one','tool':item['tool'],'arguments':arguments}})
 reply=get();assert reply['id']==100
 if mode=='denied':
  assert reply['result']['success'] is False;raise SystemExit(0)
 assert reply['result']['success'] is True
 item.update(status='completed',success=True)
 send({'method':'item/completed','params':{'threadId':'thread-one','turnId':'turn-one','item':item}})
send({'method':'turn/completed','params':{'threadId':'thread-one','turn':{'id':'turn-one','status':'completed','error':None}}})
if mode.startswith('tail-') or mode=='normal':
 assert sys.stdin.readline()==''
 if mode=='tail-info': send({'method':'thread/status/changed','params':{'threadId':'thread-one','status':{'type':'idle'}}})
 if mode=='tail-partial': sys.stdout.write('{"broken":');sys.stdout.flush()
 if mode=='tail-invalid': send({'method':'item/tool/call','id':101,'params':{'secret':'never-execute'}})
 if mode=='tail-timeout': time.sleep(30)
if mode=='pass': time.sleep(30)  # Persistent server, stopped only by the owned-group cleanup.
'''


class BrokerTests(unittest.TestCase):
    def setUp(self):
        cache = Path.cwd() / ".cache" / "codex-broker-tests"
        cache.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=cache)
        self.root = Path(self.temp.name).resolve()
        self.python = Path(sys.executable).resolve()
        self.discover = self.root / "discover.py"
        self.binary = self.root / "video"
        self.discover.write_text("print('video schema_version=1.0 commands=40 schema_sha256=' + 'a'*64)\n")
        self.binary.write_text("test-only pinned CLI, not a production runtime\n")
        self.peer = self.root / "peer.py"
        self.peer.write_text(PEER)

    def tearDown(self):
        self.temp.cleanup()

    def pin(self, path):
        return FilePin(path, hashlib.sha256(path.read_bytes()).hexdigest())

    def catalog(self, **changes):
        value = {"models": [{"slug": "test-model", "display_name": "Test model",
                 "supported_reasoning_levels": [], "shell_type": "disabled", "visibility": "list",
                 "supported_in_api": True, "priority": 1, "tool_mode": "direct", **changes}]}
        path = self.root / "reviewed-model-catalog.json"
        path.write_text(json.dumps(value))
        return self.pin(path)

    def test_pinned_catalog_adds_only_dedicated_process_startup_override(self):
        pin = self.catalog()
        args = server_arguments(model_catalog=pin)
        base = server_arguments()
        flag = "model_catalog_json=" + json.dumps(str(pin.path))
        self.assertEqual(args.count(flag), 1)
        copy = args.copy()
        index = copy.index(flag)
        self.assertEqual(copy[index-1], "-c")
        del copy[index-1:index+1]
        self.assertEqual(copy, base)
        self.assertEqual(_verified_model_catalog(pin), "test-model")
        self.assertIn("features.code_mode_host=false", args)

    def test_model_catalog_requires_pin_and_refuses_changed_symlink_or_oversize_file(self):
        pin = self.catalog()
        with self.assertRaises(ProtocolError):
            server_arguments(model_catalog=pin.path)
        pin.path.write_text(pin.path.read_text()+" ")
        with self.assertRaises(ValueError):
            server_arguments(model_catalog=pin)
        pin.path.write_bytes(b"x"*(512*1024+1))
        oversized_pin = self.pin(pin.path)
        with patch.object(FilePin, "verify") as verify:
            with self.assertRaises(ProtocolError):
                server_arguments(model_catalog=oversized_pin)
            verify.assert_not_called()
        target = self.root / "catalog-link.json"
        target.symlink_to(pin.path)
        with self.assertRaises(ValueError):
            server_arguments(model_catalog=FilePin(target, self.pin(pin.path).sha256))

    def test_model_catalog_refuses_multiple_models_wrong_metadata_and_extra_envelope(self):
        for change in ({"tool_mode": "code_mode_only"}, {"slug": "other/tool"}, {"priority": True},
                       {"supported_in_api": "true"}, {"supported_reasoning_levels": {}}, {"shell_type": "shell"}):
            with self.assertRaises(ProtocolError):
                _verified_model_catalog(self.catalog(**change))
        for value in ({"models": []}, {"models": [{}, {}]}, {"models": [{}], "extra": True},
                      {"models": [{"slug": "only-partial"}]}):
            pin = self.catalog()
            pin.path.write_text(json.dumps(value))
            with self.assertRaises(ProtocolError):
                _verified_model_catalog(self.pin(pin.path))

    def test_model_catalog_changed_during_call_is_refused_before_any_execution(self):
        pin = self.catalog()
        broker = Broker(Policy((self.command(),)), "bounded task", deadline=time.monotonic()+5, model_catalog=pin)
        pin.path.write_text(pin.path.read_text()+" ")
        with patch("codex_broker.execute") as run:
            with self.assertRaises(ValueError):
                broker.receive({"id": 1, "result": {}})
            run.assert_not_called()
        self.assertEqual(broker.policy.used, 0)

    def test_catalog_model_must_be_acknowledged_before_turn_starts(self):
        for model in (None, "other-model", "test-model"):
            broker = Broker(Policy((self.command(),)), "bounded task", deadline=time.monotonic()+5,
                            model_catalog=self.catalog())
            broker.receive({"id": 1, "result": {}})
            broker.receive({"id": 4, "result": {"data": [], "nextCursor": None}})
            result = {"thread": {"id": "thread-one"}, "cwd": str(self.root), "approvalPolicy": "on-request",
                      "sandbox": {"type": "readOnly"}, "runtimeWorkspaceRoots": [], "model": model}
            if model != "test-model":
                with self.assertRaises(ProtocolError):
                    broker.receive({"id": 2, "result": result})
                self.assertEqual(broker.policy.used, 0)
                self.assertFalse(broker.summary()["catalog_model_acknowledged"])
                self.assertEqual(broker.summary()["catalog_model_receipt"]["received"], model)
            else:
                response = broker.receive({"id": 2, "result": result})
                self.assertEqual(response[0]["method"], "turn/start")
                self.assertTrue(broker.summary()["catalog_model_acknowledged"])

    def test_catalog_selects_only_its_reviewed_model_in_thread_with_or_without_skill(self):
        catalog = self.catalog()
        self.assertNotIn("model", thread_parameters(Policy((self.command(),))))
        self.assertEqual(thread_parameters(Policy((self.command(),)), model_catalog=catalog)["model"], "test-model")
        for skill in (None, self.skill()):
            broker = Broker(Policy((self.command(),)), "bounded task", deadline=time.monotonic()+5,
                            model_catalog=catalog, skill=skill)
            broker.receive({"id": 1, "result": {}})
            requests = broker.receive({"id": 4, "result": {"data": [], "nextCursor": None}})
            if skill is not None:
                requests = broker.receive({"id": 5, "result": {"data": [{"cwd": str(self.root), "errors": [], "skills": [
                    {"path": str(skill.directory/"SKILL.md"), "name": "video", "enabled": True}]}]}})
            self.assertEqual(requests[0]["method"], "thread/start")
            self.assertEqual(requests[0]["params"]["model"], "test-model")
            self.assertEqual(requests[0]["params"]["runtimeWorkspaceRoots"], [])
        with self.assertRaises(ProtocolError):
            thread_parameters(Policy((self.command(),)), model_catalog="unreviewed-model")

    def test_pinned_catalog_is_preserved_through_both_mcp_inventory_projections(self):
        pin = self.catalog()
        with patch("codex_broker._mcp_projection", side_effect=[{}, {}]) as probe:
            args, names = isolate_mcp("official-codex", self.root, deadline=time.monotonic()+5, model_catalog=pin)
        self.assertEqual(names, frozenset())
        expected = "model_catalog_json=" + json.dumps(str(pin.path))
        self.assertIn(expected, args)
        self.assertTrue(all(expected in call.args[0] for call in probe.call_args_list))

    def command(self):
        return Command("discover", (str(self.python), str(self.discover), "--binary", str(self.binary)), self.root,
                       tuple(self.pin(p) for p in (self.python, self.discover, self.binary)), "discovery")

    def skill(self):
        root = self.root / "skill"
        values = {"SKILL.md": "---\nname: video\n---\nPublic test-only instructions.\n",
                  "LICENSE": "Test license", "NOTICE": "Test notice", "agents/openai.yaml": "name: video\n",
                  "references/protocol.md": "Test protocol\n",
                  "references/narration-writing.md": "Test narration guidance\n"}
        for name, text in values.items():
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        return PinnedSkill(root, tuple(self.pin(root/name) for name in values))

    def test_current_complete_repository_skill_is_accepted_with_all_six_pins(self):
        root = Path(__file__).resolve().parent / "skills/video"
        files = tuple(sorted(path for path in root.rglob("*") if path.is_file()))
        expected = {"SKILL.md", "LICENSE", "NOTICE", "agents/openai.yaml", "references/protocol.md",
                    "references/narration-writing.md"}
        self.assertEqual({path.relative_to(root).as_posix() for path in files}, expected)
        skill = PinnedSkill(root, tuple(self.pin(path) for path in files))
        value = skill.verify()
        self.assertEqual(value["name"], "video")
        self.assertEqual(value["path"], str(root/"SKILL.md"))
        self.assertEqual(value["sha256"], self.pin(root/"SKILL.md").sha256)
        self.assertEqual(skill.input(), {"type": "skill", "name": "video", "path": str(root/"SKILL.md")})
        changed_pin = FilePin(root/"references/narration-writing.md", "0"*64)
        changed = tuple(changed_pin if pin.path == changed_pin.path else pin for pin in skill.pins)
        with self.assertRaisesRegex(ValueError, "file_pin_mismatch"):
            PinnedSkill(root, changed).verify()

    def test_legacy_five_file_skill_is_incomplete_before_any_business(self):
        skill = self.skill()
        reference = skill.directory/"references/narration-writing.md"
        reference.unlink()
        legacy = PinnedSkill(skill.directory, tuple(pin for pin in skill.pins if pin.path != reference))
        policy = Policy((self.command(),))
        with self.assertRaisesRegex(ProtocolError, "video_skill_complete_pins_required"):
            Broker(policy, "bounded task", deadline=time.monotonic()+5, skill=legacy)
        self.assertEqual(policy.used, 0)

    def test_complete_skill_requires_unique_pins_for_the_narration_reference(self):
        skill = self.skill()
        reference = skill.directory/"references/narration-writing.md"
        without_reference = tuple(pin for pin in skill.pins if pin.path != reference)
        for pins in (without_reference, without_reference + (without_reference[0],)):
            with self.subTest(pin_count=len(pins)):
                policy = Policy((self.command(),))
                with self.assertRaisesRegex(ProtocolError, "video_skill_complete_pins_required"):
                    Broker(policy, "bounded task", deadline=time.monotonic()+5,
                           skill=PinnedSkill(skill.directory, pins))
                self.assertEqual(policy.used, 0)

    def test_narration_reference_mutation_before_turn_is_refused(self):
        skill = self.skill()
        policy = Policy((self.command(),))
        broker = Broker(policy, "bounded task", deadline=time.monotonic()+5, skill=skill)
        broker.receive({"id": 1, "result": {}})
        (skill.directory/"references/narration-writing.md").write_text("changed guidance")
        with self.assertRaisesRegex(ValueError, "file_pin_mismatch"):
            broker.receive({"id": 4, "result": {"data": [], "nextCursor": None}})
        self.assertFalse(broker.skill_submitted)
        self.assertEqual(policy.used, 0)

    def test_unknown_reference_is_rejected_even_when_caller_pins_it(self):
        skill = self.skill()
        unknown = skill.directory/"references/unknown.md"
        unknown.write_text("unknown instructions")
        complete_with_extra = PinnedSkill(skill.directory, skill.pins + (self.pin(unknown),))
        for candidate in (skill, complete_with_extra):
            with self.subTest(pin_count=len(candidate.pins)):
                policy = Policy((self.command(),))
                with self.assertRaises(ProtocolError):
                    Broker(policy, "bounded task", deadline=time.monotonic()+5, skill=candidate)
                self.assertEqual(policy.used, 0)

    def test_narration_reference_hardlink_is_refused(self):
        skill = self.skill()
        reference = skill.directory/"references/narration-writing.md"
        os.link(reference, self.root/"linked-narration.md")
        policy = Policy((self.command(),))
        with self.assertRaisesRegex(ProtocolError, "video_skill_layout_refused"):
            Broker(policy, "bounded task", deadline=time.monotonic()+5, skill=skill)
        self.assertEqual(policy.used, 0)

    def test_complete_skill_retains_per_file_and_total_byte_bounds(self):
        skill = self.skill()
        reference = skill.directory/"references/narration-writing.md"
        reference.write_bytes(b"")
        with self.assertRaisesRegex(ProtocolError, "video_skill_byte_bound"):
            skill.verify()
        reference.write_bytes(b"x"*(256*1024+1))
        with self.assertRaisesRegex(ProtocolError, "video_skill_byte_bound"):
            skill.verify()
        for pin in skill.pins:
            pin.path.write_bytes(b"x"*(200*1024))
        bounded_pins = tuple(self.pin(pin.path) for pin in skill.pins)
        with self.assertRaisesRegex(ProtocolError, "video_skill_byte_bound"):
            PinnedSkill(skill.directory, bounded_pins).verify()

    def test_explicit_skill_input_is_fixed_and_does_not_change_tool_or_permission_contract(self):
        skill = self.skill()
        broker = Broker(Policy((self.command(),)), "bounded task", deadline=time.monotonic()+5, skill=skill)
        broker.receive({"id": 1, "result": {}})
        requests = broker.receive({"id": 4, "result": {"data": [], "nextCursor": None}})
        self.assertEqual(requests[0]["method"], "skills/list")
        self.assertEqual(requests[0]["params"], {"cwds": [str(self.root)], "forceReload": True})
        broker.receive({"id": 5, "result": {"data": [{"cwd": str(self.root), "errors": [], "skills": [
            {"path": str(skill.directory/"SKILL.md"), "name": "video", "enabled": True}]}]}})
        replies = broker.receive({"id": 2, "result": {"thread": {"id": "thread-one"}, "cwd": str(self.root),
            "approvalPolicy": "on-request", "sandbox": {"type": "readOnly"}, "runtimeWorkspaceRoots": []}})
        inputs = replies[0]["params"]["input"]
        self.assertEqual(inputs, [{"type": "text", "text": "bounded task"},
            {"type": "skill", "name": "video", "path": str(skill.directory/"SKILL.md")}])
        self.assertTrue(broker.summary()["skill_input"]["submitted"])
        self.assertTrue(broker.summary()["skill_input"]["catalog_verified"])
        self.assertEqual(broker.summary()["native_approvals_accepted"], 0)
        self.assertFalse(broker.summary()["passed"])
        self.assertEqual(broker.policy.used, 0)

    def test_explicit_skill_inventory_must_match_pinned_path_and_be_enabled(self):
        skill = self.skill()
        valid = {"data": [{"cwd": str(self.root), "errors": [], "skills": [
            {"path": str(skill.directory/"SKILL.md"), "name": "video", "enabled": True}]}]}
        for change in ("path", "disabled", "errors", "cwd", "duplicate"):
            with self.subTest(change=change):
                broker = Broker(Policy((self.command(),)), "bounded task", deadline=time.monotonic()+5, skill=skill)
                broker.receive({"id": 1, "result": {}})
                broker.receive({"id": 4, "result": {"data": [], "nextCursor": None}})
                result = deepcopy(valid)
                entry = result["data"][0]
                if change == "path": entry["skills"][0]["path"] = str(self.root/"foreign"/"SKILL.md")
                if change == "disabled": entry["skills"][0]["enabled"] = False
                if change == "errors": entry["errors"] = [{}]
                if change == "cwd": entry["cwd"] = str(self.root.parent)
                if change == "duplicate": entry["skills"].append(deepcopy(entry["skills"][0]))
                with self.assertRaises(ProtocolError):
                    broker.receive({"id": 5, "result": result})
                self.assertFalse(broker.skill_submitted)
                self.assertEqual(broker.policy.used, 0)

    def test_agent_message_receipt_keeps_only_bounded_length_and_hash(self):
        broker = self.active()
        text = "Private words never returned."
        broker.receive({"method": "item/completed", "params": {"threadId": "thread-one", "turnId": "turn-one",
            "item": {"id": "message-one", "type": "agentMessage", "text": text}}})
        self.assertEqual(broker.summary()["agent_messages"], [{"bytes": len(text.encode()),
            "sha256": hashlib.sha256(text.encode()).hexdigest()}])
        self.assertNotIn(text, json.dumps(broker.summary()))
        with self.assertRaises(ProtocolError):
            broker.receive({"method": "item/completed", "params": {"threadId": "thread-one", "turnId": "turn-one",
                "item": {"id": "message-two", "type": "agentMessage", "text": "x"*65537}}})

    def test_skill_rejects_changed_incomplete_extra_link_or_identity_before_any_business(self):
        skill = self.skill()
        skill.verify()
        for mutation in ("changed", "incomplete", "extra", "directory", "link", "identity"):
            with self.subTest(mutation=mutation):
                if mutation == "changed":
                    (skill.directory/"NOTICE").write_text("changed")
                elif mutation == "incomplete":
                    skill = PinnedSkill(skill.directory, skill.pins[:-1])
                elif mutation == "extra":
                    (skill.directory/"extra.txt").write_text("unknown")
                elif mutation == "directory":
                    (skill.directory/"unknown").mkdir()
                elif mutation == "link":
                    path = skill.directory/"NOTICE"
                    path.unlink();path.symlink_to(self.binary)
                else:
                    path = skill.directory/"SKILL.md"
                    path.write_text("---\nname: other\n---\n")
                    skill = PinnedSkill(skill.directory, tuple(self.pin(pin.path) for pin in skill.pins))
                with self.assertRaises((ValueError, ProtocolError)):
                    Broker(Policy((self.command(),)), "bounded task", deadline=time.monotonic()+5, skill=skill)
                import shutil
                shutil.rmtree(skill.directory)
                skill = self.skill()

    def test_skill_mutation_before_turn_is_refused_without_tool_execution(self):
        skill = self.skill()
        broker = Broker(Policy((self.command(),)), "bounded task", deadline=time.monotonic()+5, skill=skill)
        broker.receive({"id": 1, "result": {}})
        (skill.directory/"references/protocol.md").write_text("changed")
        with self.assertRaises(ValueError):
            broker.receive({"id": 4, "result": {"data": [], "nextCursor": None}})
        self.assertFalse(broker.skill_submitted)
        self.assertEqual(broker.policy.used, 0)

    def active(self):
        policy = Policy((self.command(),))
        broker = Broker(policy, "Use the exact authorized dynamic operation.", deadline=time.monotonic()+5)
        broker.receive({"id": 1, "result": {}})
        broker.receive({"id": 4, "result": {"data": [], "nextCursor": None}})
        broker.receive({"id": 2, "result": {"thread": {"id": "thread-one"}, "cwd": str(self.root),
                        "approvalPolicy": "on-request", "sandbox": {"type": "readOnly"}, "runtimeWorkspaceRoots": []}})
        broker.receive({"method": "turn/started", "params": {"threadId": "thread-one", "turn": {"id": "turn-one"}}})
        broker.receive({"id": 3, "result": {"turn": {"id": "turn-one"}}})
        return broker

    def start(self, broker, *, arguments=None, call="call-one"):
        arguments = broker.policy.commands[0].arguments() if arguments is None else arguments
        broker.receive({"method": "item/started", "params": {"threadId": "thread-one", "turnId": "turn-one",
            "item": {"id": call, "type": "dynamicToolCall", "tool": TOOL, "arguments": arguments}}})
        return {"id": 100, "method": "item/tool/call", "params": {"threadId": "thread-one", "turnId": "turn-one",
                "callId": call, "tool": TOOL, "arguments": arguments}}

    def test_spec_and_thread_have_no_host_environment(self):
        p = Policy((self.command(),))
        params = thread_parameters(p)
        self.assertEqual(params["environments"], [])
        self.assertEqual(params["runtimeWorkspaceRoots"], [])
        self.assertEqual(params["sandbox"], "read-only")
        self.assertEqual(params["approvalPolicy"], "on-request")
        self.assertFalse(params["dynamicTools"][0]["inputSchema"]["additionalProperties"])

    def test_diagnostic_names_match_pinned_official_01592_notification_enum(self):
        self.assertEqual(len(_OFFICIAL_NOTIFICATIONS), 83)
        raw = json.dumps(sorted(_OFFICIAL_NOTIFICATIONS), separators=(",", ":")).encode()
        self.assertEqual(hashlib.sha256(raw).hexdigest(), _NOTIFICATION_ENUM_SHA256)

    def test_disabled_remote_status_and_deprecation_are_passive_before_initialize(self):
        broker = Broker(Policy((self.command(),)), "bounded task", deadline=time.monotonic()+5)
        with patch("codex_broker.execute") as run:
            for method, params in (("remoteControl/status/changed", {"status": "disabled", "environmentId": None,
                    "installationId": "private-install-id", "serverName": "private-server"}),
                    ("deprecationNotice", {"summary": "private arbitrary text"})):
                self.assertEqual(broker.receive({"method": method, "params": params}), [])
            run.assert_not_called()
        self.assertEqual(broker.phase, "initialize")
        self.assertEqual(broker.policy.used, 0)
        self.assertFalse(broker.summary()["passed"])
        self.assertEqual(broker.summary()["event_types"]["remoteControl/status/changed"], 1)
        self.assertNotIn("private-", json.dumps(broker.summary()))

    def test_remote_control_enabled_errored_unknown_or_environment_are_refused(self):
        for status, environment in (("connecting", None), ("connected", None), ("errored", None),
                                    ("unknown-private-value", None), ({"private": True}, None), ("disabled", "private-env")):
            broker = self.active()
            with self.assertRaises(ProtocolError):
                broker.receive({"method": "remoteControl/status/changed", "params": {"status": status,
                    "environmentId": environment, "installationId": "private-id", "serverName": "private-name"}})
            summary = broker.summary()
            self.assertFalse(summary["passed"])
            self.assertEqual(summary["unsupported_notifications"][0]["official_method"], "remoteControl/status/changed")
            self.assertNotIn("private", json.dumps(summary))

    def test_account_status_notification_is_passive_not_authentication_or_execution(self):
        broker = self.active()
        before = (broker.phase, broker.policy.used, broker.turn_id, tuple(broker.calls))
        with patch("codex_broker.execute") as run:
            for params in ({"authMode": "chatgpt", "planType": "plus"},
                           {"authMode": None, "planType": None}):
                self.assertEqual(broker.receive({"method": "account/updated", "params": params}), [])
            run.assert_not_called()
        self.assertEqual(before, (broker.phase, broker.policy.used, broker.turn_id, tuple(broker.calls)))
        summary = broker.summary()
        self.assertFalse(summary["passed"])
        self.assertEqual(summary["native_approvals_accepted"], 0)
        self.assertEqual(summary["event_types"]["account/updated"], 2)
        self.assertNotIn("chatgpt", json.dumps(summary))
        self.assertNotIn("plus", json.dumps(summary))

    def test_invalid_account_status_remains_rejected_without_retaining_account_data(self):
        for params in ({}, {"authMode": "chatgpt", "planType": "plus", "email": "private-value"},
                       {"authMode": "private-value", "planType": None},
                       {"authMode": None, "planType": {"private-value": True}}):
            broker = self.active()
            with patch("codex_broker.execute") as run:
                with self.assertRaises(ProtocolError):
                    broker.receive({"method": "account/updated", "params": params})
                run.assert_not_called()
            summary = broker.summary()
            self.assertEqual(summary["unsupported_notifications"], [{"official_method": "account/updated"}])
            self.assertNotIn("private-value", json.dumps(summary))

    def test_account_status_request_is_never_an_authorization_grant(self):
        broker = self.active()
        with patch("codex_broker.execute") as run:
            reply = broker.receive({"id": 19, "method": "account/updated",
                                    "params": {"authMode": "chatgpt", "planType": "plus"}})
            run.assert_not_called()
        self.assertEqual(reply[0]["error"]["code"], -32601)
        self.assertEqual(broker.terminal, "denied")
        self.assertFalse(broker.summary()["passed"])

    def test_current_turn_moderation_status_is_opaque_and_does_not_execute(self):
        broker = self.active()
        before = (broker.phase, broker.policy.used, broker.turn_id, tuple(broker.calls))
        with patch("codex_broker.execute") as run:
            self.assertEqual(broker.receive({"method": "turn/moderationMetadata", "params": {
                "threadId": "thread-one", "turnId": "turn-one", "metadata": {"private-value": "opaque"}}}), [])
            run.assert_not_called()
        self.assertEqual(before, (broker.phase, broker.policy.used, broker.turn_id, tuple(broker.calls)))
        summary = broker.summary()
        self.assertFalse(summary["passed"])
        self.assertEqual(summary["event_types"]["turn/moderationMetadata"], 1)
        self.assertEqual(summary["native_approvals_accepted"], 0)
        self.assertNotIn("private-value", json.dumps(summary))

    def test_foreign_incomplete_extra_and_out_of_turn_moderation_are_refused(self):
        valid = {"threadId": "thread-one", "turnId": "turn-one", "metadata": {}}
        for params in ({}, dict(valid, threadId="other"), dict(valid, turnId="other"),
                       dict(valid, unexpected="private-value"), dict(valid, metadata=float("nan"))):
            broker = self.active()
            with self.assertRaises(ProtocolError):
                broker.receive({"method": "turn/moderationMetadata", "params": params})
            self.assertFalse(broker.summary()["passed"])
            self.assertNotIn("private-value", json.dumps(broker.summary()))
        broker = Broker(Policy((self.command(),)), "bounded task", deadline=time.monotonic()+5)
        with self.assertRaises(ProtocolError):
            broker.receive({"method": "turn/moderationMetadata", "params": valid})
        broker = self.active()
        broker.terminal = "completed"
        with self.assertRaises(ProtocolError):
            broker.receive({"method": "turn/moderationMetadata", "params": valid})

    def test_moderation_notification_with_request_id_is_still_denied(self):
        broker = self.active()
        reply = broker.receive({"id": 20, "method": "turn/moderationMetadata", "params": {
            "threadId": "thread-one", "turnId": "turn-one", "metadata": {"authorized": True}}})
        self.assertEqual(reply[0]["error"]["code"], -32601)
        self.assertEqual(broker.terminal, "denied")
        self.assertEqual(broker.policy.used, 0)

    def test_configuration_and_security_warnings_are_not_blindly_ignored(self):
        for method in ("warning", "configWarning", "guardianWarning"):
            broker = self.active()
            with self.assertRaises(ProtocolError):
                broker.receive({"method": method, "params": {"summary": "Unauthorized Bearer private-string",
                    "message": "Unauthorized Bearer private-string", "details": "private-extra", "path": "/private/config"}})
            summary = broker.summary()
            entry = summary["unsupported_notifications"][0]
            self.assertEqual(entry["official_method"], method)
            self.assertEqual(entry["reason"]["message_pattern_inference"], "auth_rejected")
            self.assertNotIn("private", json.dumps(summary))

    def test_official_execution_notifications_still_refused_without_recording_params(self):
        for method in ("mcpServer/startupStatus/updated", "process/outputDelta", "thread/environment/connected"):
            broker = self.active()
            with patch("codex_broker.execute") as run:
                with self.assertRaises(ProtocolError):
                    broker.receive({"method": method, "params": {"secret": "private-value"}})
                run.assert_not_called()
            summary = broker.summary()
            self.assertEqual(summary["unsupported_notifications"], [{"official_method": method}])
            self.assertNotIn("private-value", json.dumps(summary))

    def test_nonofficial_names_are_opaque_and_rejection_details_are_bounded(self):
        broker = self.active()
        for i in range(10):
            method = "private-secret/" + str(i) + "x"*150
            with self.assertRaises(ProtocolError):
                broker.receive({"method": method, "params": {"private": "data"}})
        summary = broker.summary()
        self.assertEqual(summary["unsupported_notification_count"], 10)
        self.assertEqual(len(summary["unsupported_notifications"]), 8)
        for entry in summary["unsupported_notifications"]:
            self.assertEqual(set(entry), {"method_bytes", "method_sha256"})
        self.assertNotIn("private", json.dumps(summary))
        self.assertFalse(any("private" in key for key in summary["event_types"]))

    def test_nonstring_notification_name_is_safe_protocol_failure(self):
        broker = self.active()
        with self.assertRaises(ProtocolError):
            broker.receive({"method": {"private": "name"}, "params": {}})
        self.assertEqual(broker.summary()["unsupported_notifications"], [{"method_type": "non_string"}])

    def test_only_explicit_discovery_and_fixed_dry_run_are_constructible(self):
        self.command().verify()
        input_path = self.root / "input.json"
        input_path.write_text('{}')
        command = Command("preflight", (str(self.binary), "--workspace", str(self.root / "workspace"),
                          "workspaces", "create", "--input", str(input_path), "--dry-run"), self.root,
                          (self.pin(self.binary), self.pin(input_path)), "preflight")
        command.verify()
        for values in (("--dry-run", "--extra"), ("--force",), ()):
            argv = command.argv[:-1] + values
            with self.assertRaises(ValueError):
                Command(command.name, argv, command.cwd, command.pins, "preflight").verify()
        for words in (("review", "record"), ("products", "import"), ("baidu", "submit"), ("worker", "run")):
            argv = command.argv[:3] + words + command.argv[5:]
            with self.assertRaises(ValueError):
                Command(command.name, argv, command.cwd, command.pins, "preflight").verify()

    def test_missing_or_modified_pin_refused(self):
        command = self.command()
        self.discover.write_text("raise RuntimeError('changed')\n")
        with self.assertRaises(ValueError):
            Policy((command,))

    def test_symlink_and_hardlink_refused(self):
        link = self.root / "link"
        link.symlink_to(self.binary)
        with self.assertRaises(ValueError):
            self.pin(link).verify()
        hardlink = self.root / "hardlink"
        os.link(self.binary, hardlink)
        with self.assertRaises(ValueError):
            self.pin(self.binary).verify()

    def test_wrong_cwd_argv_extra_fields_and_order_denied_before_execute(self):
        for change in ("cwd", "argv", "extra", "operation"):
            broker = self.active()
            arguments = broker.policy.commands[0].arguments()
            if change == "cwd": arguments["cwd"] += "/."
            if change == "argv": arguments["argv"].append("; printenv")
            if change == "extra": arguments["background"] = True
            if change == "operation": arguments["operation"] = "another_operation"
            request = self.start(broker, arguments=arguments)
            with patch("codex_broker.execute") as run:
                response = broker.receive(request)
                self.assertFalse(response[0]["result"]["success"])
                run.assert_not_called()
            self.assertEqual(broker.policy.used, 0)

    def test_changed_file_denied_at_call_time(self):
        broker = self.active()
        request = self.start(broker)
        self.binary.write_text("changed after policy construction")
        with patch("codex_broker.execute") as run:
            response = broker.receive(request)
            run.assert_not_called()
        self.assertFalse(response[0]["result"]["success"])

    def test_wrong_thread_turn_tool_or_unknown_extra_top_level_denied(self):
        for field, value in (("threadId", "other"), ("turnId", "other"), ("tool", "run_shell"),
                             ("namespace", "functions"), ("extra", True), ("callId", "missing")):
            broker = self.active()
            request = self.start(broker)
            request["params"][field] = value
            with patch("codex_broker.execute") as run:
                self.assertFalse(broker.receive(request)[0]["result"]["success"])
                run.assert_not_called()

    def test_dynamic_command_is_single_use(self):
        broker = self.active()
        request = self.start(broker)
        with patch("codex_broker.execute", return_value={"passed": True}) as run:
            self.assertTrue(broker.receive(request)[0]["result"]["success"])
            self.assertFalse(broker.receive(request)[0]["result"]["success"])
            self.assertEqual(run.call_count, 1)

    def test_native_command_file_network_and_unknown_requests_never_execute(self):
        for method in ("item/commandExecution/requestApproval", "item/fileChange/requestApproval",
                       "item/permissions/requestApproval", "tool/requestUserInput", "unknown/request"):
            broker = self.active()
            with patch("codex_broker.execute") as run:
                reply = broker.receive({"id": 99, "method": method, "params": {"command": "printenv"}})[0]
                run.assert_not_called()
            self.assertTrue(reply.get("result", {}).get("decision") == "decline" or "error" in reply)
            self.assertFalse(broker.summary()["passed"])

    def test_native_execution_item_refused(self):
        broker = self.active()
        for kind in ("commandExecution", "fileChange", "mcpToolCall", "webSearch", "collabAgentToolCall"):
            with self.assertRaises(ProtocolError):
                broker.receive({"method": "item/started", "params": {"threadId": "thread-one", "turnId": "turn-one",
                               "item": {"id": "x", "type": kind}}})

    def test_thread_boundary_must_be_acknowledged_before_start_turn(self):
        for field, bad in (("cwd", "/tmp"), ("approvalPolicy", "never"),
                           ("sandbox", {"type": "dangerFullAccess"}), ("runtimeWorkspaceRoots", ["/tmp"])):
            broker = Broker(Policy((self.command(),)), "bounded task", deadline=time.monotonic()+5)
            broker.receive({"id": 1, "result": {}})
            broker.receive({"id": 4, "result": {"data": []}})
            result = {"thread": {"id": "thread-one"}, "cwd": str(self.root), "approvalPolicy": "on-request",
                      "sandbox": {"type": "readOnly"}, "runtimeWorkspaceRoots": []}
            result[field] = bad
            with self.assertRaises(ProtocolError):
                broker.receive({"id": 2, "result": result})

    def test_only_typed_error_and_message_digest_leave_broker(self):
        broker = self.active()
        broker.receive({"method": "error", "params": {"threadId": "thread-one", "turnId": "turn-one",
            "willRetry": True, "error": {"message": "Unauthorized Bearer private-string", "codexErrorInfo": "unauthorized"}}})
        summary = broker.summary()
        self.assertFalse(summary["passed"])
        self.assertNotIn("private-string", json.dumps(summary))
        self.assertEqual(summary["errors"][0]["protocol_code"], "unauthorized")

    def test_zero_tools_and_orphan_completions_cannot_pass(self):
        broker = self.active()
        broker.receive({"method": "turn/completed", "params": {"threadId": "thread-one", "turn": {"id": "turn-one", "status": "completed"}}})
        self.assertFalse(broker.summary()["passed"])
        broker = self.active()
        with self.assertRaises(ProtocolError):
            broker.receive({"method": "item/completed", "params": {"threadId": "thread-one", "turnId": "turn-one",
                "item": {"id": "call-one", "type": "dynamicToolCall", "tool": TOOL, "status": "completed", "success": True}}})

    def test_actual_client_owned_argv_output_is_bounded_and_summarized(self):
        receipt = execute(self.command(), deadline=time.monotonic()+5)
        self.assertTrue(receipt["passed"])
        self.assertEqual(receipt["commands"], 40)
        self.assertEqual(receipt["schema_sha256"], "a"*64)

    def test_actual_child_receives_no_inherited_secret(self):
        self.discover.write_text("import os\nassert 'TEST_PRIVATE_VALUE' not in os.environ\nprint('video schema_version=1.0 commands=40 schema_sha256='+'a'*64)\n")
        with patch.dict("os.environ", {"TEST_PRIVATE_VALUE": "private-string"}):
            self.assertTrue(execute(self.command(), deadline=time.monotonic()+5)["passed"])

    def test_child_deadline_and_output_limit(self):
        self.discover.write_text("import time\ntime.sleep(20)\n")
        with self.assertRaises(ProtocolError):
            execute(self.command(), deadline=time.monotonic()+.1)
        self.discover.write_text("print('x'*(2*1024*1024))\n")
        with self.assertRaises(ProtocolError):
            execute(self.command(), deadline=time.monotonic()+5)

    def test_exited_leader_with_term_ignoring_descendant_is_cleaned(self):
        # Both the command and transport finally paths must clean their own group
        # after the leader exits. The descendant deliberately retains both pipes.
        for kind in ("command", "transport"):
            with self.subTest(kind=kind):
                pid_file = self.root / (kind + "-descendant.pid")
                descendant = ("import os,signal,time\n"
                              "signal.signal(signal.SIGTERM,signal.SIG_IGN)\n"
                              "p=open(" + repr(str(pid_file)) + ", 'w');p.write(str(os.getpid())+' '+str(os.getpgrp()));p.close()\n"
                              "time.sleep(30)\n")
                leader = ("import pathlib,subprocess,time\n"
                          "p=subprocess.Popen([" + repr(str(self.python)) + ",'-c'," + repr(descendant) + "])\n"
                          "deadline=time.monotonic()+2\n"
                          "while not pathlib.Path(" + repr(str(pid_file)) + ").exists() and time.monotonic()<deadline: time.sleep(.01)\n")
                self.discover.write_text(leader)
                started = time.monotonic()
                captured = []
                original_popen = subprocess.Popen

                def capture_popen(*args, **kwargs):
                    process = original_popen(*args, **kwargs)
                    # Keep our own read descriptor after the broker closes its
                    # stream. EOF proves that the pipe-holding descendant died;
                    # the fixture never closes/replaces its inherited stdout.
                    captured.append((process, os.dup(process.stdout.fileno())))
                    # Explicit readiness replaces a short cold-start assumption:
                    # the child has installed its TERM handler and owns pipes,
                    # and the leader has exited before the consumer starts.
                    process.wait(timeout=3)
                    self.assertTrue(pid_file.exists())
                    return process

                try:
                    with patch("codex_broker.subprocess.Popen", side_effect=capture_popen):
                        if kind == "command":
                            with self.assertRaises(ProtocolError) as failure:
                                execute(self.command(), deadline=time.monotonic()+1)
                            cleanup = failure.exception.cleanup
                        else:
                            result = _consume([str(self.python), str(self.discover)], "bounded task",
                                              Policy((self.command(),)), seconds=1)
                            self.assertEqual(result["status"], "hard_deadline")
                            cleanup = result["cleanup"]
                    self.assertLess(time.monotonic()-started, 5)
                    self.assertTrue(cleanup["passed"], cleanup)
                    self.assertTrue(pid_file.exists())
                    self.assertEqual(len(captured), 1)
                    process, descriptor = captured[0]
                    self.assertEqual(process.returncode, 0, "leader must have exited before timeout cleanup")
                    watcher = selectors.DefaultSelector()
                    try:
                        watcher.register(descriptor, selectors.EVENT_READ)
                        self.assertTrue(watcher.select(2), "pipe-holding descendant survived cleanup")
                        self.assertEqual(os.read(descriptor, 1), b"", "owned descendant still holds pipe")
                    finally:
                        watcher.close()
                finally:
                    for process, descriptor in captured:
                        os.close(descriptor)
                    # Only this fixture's recorded owned group, never global cleanup.
                    if pid_file.exists():
                        try:
                            os.killpg(int(pid_file.read_text().split()[1]), signal.SIGKILL)
                        except (ProcessLookupError, PermissionError):
                            pass

        # Deterministically verify refusal reporting and independent leader reap.
        # This branch is a protocol/unit substitute, not a live strong-kill claim.
        process = unittest.mock.Mock(pid=123)
        with patch("codex_broker.os.killpg", side_effect=[None, PermissionError(), PermissionError()]) as kill, \
                patch("codex_broker.time.sleep"):
            cleanup = _stop(process)
        self.assertEqual(kill.call_args_list, [unittest.mock.call(123, signal.SIGTERM),
                        unittest.mock.call(123, signal.SIGKILL), unittest.mock.call(123, 0)])
        process.wait.assert_called_once_with(timeout=1)
        self.assertFalse(cleanup["passed"])
        self.assertEqual(cleanup["kill"], "permission_denied")
        self.assertEqual(cleanup["post_reap_group"], "permission_denied")

    def test_owned_group_absence_after_reap_preserves_initial_refusal(self):
        process = unittest.mock.Mock(pid=123)
        with patch("codex_broker.os.killpg", side_effect=[None, PermissionError(), ProcessLookupError()]) as kill, \
                patch("codex_broker.time.sleep"):
            cleanup = _stop(process)
        self.assertTrue(cleanup["passed"])
        self.assertEqual(cleanup["kill"], "permission_denied")
        self.assertEqual(cleanup["post_reap_group"], "absent")
        self.assertEqual(kill.call_args_list, [unittest.mock.call(123, signal.SIGTERM),
                        unittest.mock.call(123, signal.SIGKILL), unittest.mock.call(123, 0)])
        process.wait.assert_called_once_with(timeout=1)

    def test_reaped_leader_does_not_make_existing_unknown_or_denied_group_pass(self):
        for probe, status in ((None, "present"), (PermissionError(), "permission_denied"),
                              (OSError(), "probe_failed")):
            process = unittest.mock.Mock(pid=123)
            with patch("codex_broker.os.killpg", side_effect=[None, PermissionError(), probe]), \
                    patch("codex_broker.time.sleep"):
                cleanup = _stop(process)
            self.assertFalse(cleanup["passed"])
            self.assertTrue(cleanup["leader_reaped"])
            self.assertEqual(cleanup["post_reap_group"], status)

    def test_absence_probe_requires_owned_term_and_actual_leader_reap(self):
        for term, wait_error in ((PermissionError(), None),
                                 (None, subprocess.TimeoutExpired("owned", 1)), (None, OSError())):
            process = unittest.mock.Mock(pid=123)
            process.wait.side_effect = wait_error
            with patch("codex_broker.os.killpg", side_effect=[term, PermissionError()]) as kill, \
                    patch("codex_broker.time.sleep"):
                cleanup = _stop(process)
            self.assertFalse(cleanup["passed"])
            self.assertNotIn("post_reap_group", cleanup)
            self.assertEqual(kill.call_count, 2)

    def test_actual_owned_group_termination_is_independently_absent_after_reap(self):
        process = subprocess.Popen([str(self.python), "-c", "import time;time.sleep(30)"],
                                   start_new_session=True, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cleanup = _stop(process)
        self.assertTrue(cleanup["leader_reaped"])
        self.assertTrue(cleanup["passed"], cleanup)
        if cleanup["kill"] == "permission_denied":
            self.assertEqual(cleanup["post_reap_group"], "absent")

    def test_offline_peer_end_to_end_dynamic_execution(self):
        p = Policy((self.command(),))
        r = _consume([str(self.python), str(self.peer), "pass", json.dumps(p.commands[0].arguments())],
                     "Use the explicit operation", p, seconds=5)
        self.assertTrue(r["passed"], r)
        self.assertEqual(len(r["executions"]), 1)
        self.assertEqual(r["native_approvals_accepted"], 0)
        self.assertFalse(r["native_exit"]["normal"])

    def test_terminal_eof_normal_exit_and_valid_tail_are_drained(self):
        for mode in ("normal", "tail-info"):
            with self.subTest(mode=mode):
                policy = Policy((self.command(),))
                result = _consume([str(self.python), str(self.peer), mode, json.dumps(policy.commands[0].arguments())],
                                  "Use the exact operation", policy, seconds=5)
                self.assertTrue(result["passed"], result)
                self.assertTrue(result["native_exit"]["normal"], result)
                self.assertEqual(result["native_exit"]["exit_code"], 0)
                self.assertEqual(result["cleanup"]["term"], "not_attempted")
                self.assertEqual(result["cleanup"]["kill"], "not_attempted")

    def test_invalid_or_partial_tail_after_terminal_is_not_discarded(self):
        for mode in ("tail-invalid", "tail-partial"):
            with self.subTest(mode=mode):
                policy = Policy((self.command(),))
                result = _consume([str(self.python), str(self.peer), mode, json.dumps(policy.commands[0].arguments())],
                                  "Use the exact operation", policy, seconds=5)
                self.assertFalse(result["passed"], result)
                self.assertEqual(result["status"], "client_failed")
                self.assertTrue(result["cleanup"]["passed"])
                self.assertNotIn("never-execute", json.dumps(result))

    def test_terminal_server_without_exit_keeps_business_and_owned_cleanup_separate(self):
        policy = Policy((self.command(),))
        result = _consume([str(self.python), str(self.peer), "tail-timeout", json.dumps(policy.commands[0].arguments())],
                          "Use the exact operation", policy, seconds=.8)
        self.assertTrue(result["passed"], result)
        self.assertFalse(result["native_exit"]["normal"])
        self.assertTrue(result["cleanup"]["passed"])
        self.assertLess(result["seconds"], 3)

    def test_offline_peer_zero_tool_failure_denial_timeout(self):
        for mode in ("zero", "failure", "denied", "timeout"):
            with self.subTest(mode=mode):
                p = Policy((self.command(),))
                r = _consume([str(self.python), str(self.peer), mode, json.dumps(p.commands[0].arguments())],
                             "Use the explicit operation", p, seconds=.3 if mode == "timeout" else 5)
                self.assertFalse(r["passed"], r)
                self.assertEqual(r["executions"], [])
                self.assertNotIn("secret-never-leave-memory", json.dumps(r))
                if mode == "timeout": self.assertEqual(r["status"], "hard_deadline")

    def test_server_launch_flags_do_not_override_auth_model_or_provider(self):
        argv = server_arguments()
        self.assertNotIn("mcp_servers={}", argv)
        self.assertIn("features.shell_tool=false", argv)
        self.assertIn('web_search="disabled"', argv)
        self.assertTrue(argv[-2:] == ["app-server", "--stdio"])
        for forbidden in ("--model", "--profile", "--dangerously-bypass-approvals-and-sandbox", "--ignore-rules"):
            self.assertNotIn(forbidden, argv)

    def test_mcp_configuration_projection_discards_transport_auth_and_environment(self):
        raw = json.dumps([{"name": "docs-server_1", "enabled": True, "transport": {"private": "unused"},
                           "env": {"private": "unused"}, "auth": "private"}]).encode()
        result = _project_mcp(raw)
        self.assertEqual(result, {"docs-server_1": True})
        self.assertNotIn("private", json.dumps(result))
        self.assertEqual(_project_mcp(b'[]'), {})

    def test_mcp_configuration_unsafe_names_duplicates_nonboolean_and_invalid_json_refused(self):
        for name in ("has.dot", "quoted\"name", "line\nbreak", "", "x"*129, 1, None, []):
            with self.subTest(name_type=type(name).__name__):
                with self.assertRaises(ProtocolError):
                    _project_mcp(json.dumps([{"name": name, "enabled": True}]).encode())
        for value in (None, 0, 1, "true", [], {}):
            with self.assertRaises(ProtocolError):
                _project_mcp(json.dumps([{"name": "docs", "enabled": value}]).encode())
        for raw in (b'{"data":[]}', b'not-json', b'[],"extra":1', b'[{"name":"a","name":"b","enabled":false}]',
                    b'[{"name":"a","enabled":true},{"name":"a","enabled":false}]',
                    json.dumps([{"name": "server"+str(i), "enabled": False} for i in range(33)]).encode(),
                    b' '*(1024*1024+1)):
            with self.assertRaises(ProtocolError):
                _project_mcp(raw)

    def test_mcp_isolation_disables_all_actual_keys_and_checks_same_cwd_readback(self):
        for before in ({}, {"docs": True}, {"docs": True, "other-server": False}):
            with patch("codex_broker._mcp_projection", side_effect=[before, dict.fromkeys(before, False)]) as read:
                arguments, names = isolate_mcp("official-codex", self.root, deadline=time.monotonic()+5)
            self.assertEqual(names, frozenset(before))
            self.assertEqual(read.call_count, 2)
            for call in read.call_args_list:
                self.assertEqual(call.args[1], self.root)
                self.assertEqual(call.args[0][-3:], ["mcp", "list", "--json"])
            for name in before:
                self.assertIn("mcp_servers."+name+".enabled=false", arguments)
                self.assertIn("mcp_servers."+name+".enabled=false", read.call_args_list[1].args[0])
            self.assertNotIn("mcp_servers={}", arguments)

    def test_mcp_configuration_changed_set_or_enabled_readback_stops_before_server(self):
        for after in ({}, {"other": False}, {"docs": True}, {"docs": False, "other": False}):
            with patch("codex_broker._verify_version"), \
                    patch("codex_broker._mcp_projection", side_effect=[{"docs": True}, after]), \
                    patch("codex_broker._consume") as consume:
                with self.assertRaises(ProtocolError):
                    run_codex("bounded task", Policy((self.command(),)))
                consume.assert_not_called()

    def test_mcp_projection_child_is_bounded_and_has_minimal_environment(self):
        self.discover.write_text("import json,os\nassert 'TEST_PRIVATE_VALUE' not in os.environ\n"
                                 "print(json.dumps([{'name':'docs','enabled':False,'private':'discarded'}]))\n")
        argv = [str(self.python), str(self.discover)]
        with patch.dict("os.environ", {"TEST_PRIVATE_VALUE": "private-string"}), \
                patch("codex_broker.subprocess.Popen", wraps=subprocess.Popen) as spawn:
            self.assertEqual(_mcp_projection(argv, self.root, deadline=time.monotonic()+5), {"docs": False})
            self.assertEqual(set(spawn.call_args.kwargs["env"]), {"PATH", "LANG"})
        for source, seconds in (("import time\ntime.sleep(20)\n", .1),
                                ("print('x'*(2*1024*1024))\n", 5),
                                ("import sys\nsys.stderr.write('private-output')\nprint('[]')\n", 5),
                                ("raise SystemExit(1)\n", 5)):
            self.discover.write_text(source)
            with self.assertRaises(ProtocolError) as caught:
                _mcp_projection(argv, self.root, deadline=time.monotonic()+seconds)
            self.assertNotIn("private", str(caught.exception))

    def isolated_inventory(self, name="docs"):
        return {"name": name, "authStatus": "unsupported", "tools": {}, "resources": [], "resourceTemplates": [],
                "runtimeStatus": None, "serverCapabilities": None, "serverInfo": None, "toolsError": None}

    def inventory_broker(self, *, initialize_only=False):
        broker = Broker(Policy((self.command(),)), "bounded task", deadline=time.monotonic()+5,
                        disabled_mcp_names=("docs",), initialize_only=initialize_only)
        replies = broker.receive({"id": 1, "result": {}})
        self.assertEqual([item["method"] for item in replies], ["initialized", "mcpServerStatus/list"])
        self.assertEqual(replies[1]["params"], {"limit": 32, "detail": "toolsAndAuthOnly"})
        return broker

    def test_inventory_must_be_verified_before_any_thread_request(self):
        broker = self.inventory_broker()
        self.assertEqual(broker.phase, "mcp_inventory")
        self.assertFalse(broker.summary()["mcp_inventory_verified"])
        with self.assertRaises(ProtocolError):
            broker.receive({"id": 2, "result": {}})
        self.assertEqual(broker.policy.used, 0)
        for state in (None, "disabled", "notStarted"):
            broker = self.inventory_broker()
            entry = self.isolated_inventory()
            entry["runtimeStatus"] = state
            replies = broker.receive({"id": 4, "result": {"data": [entry], "nextCursor": None}})
            self.assertEqual([item["method"] for item in replies], ["thread/start"])
            self.assertTrue(broker.summary()["mcp_inventory_verified"])
            self.assertEqual(broker.summary()["mcp_disabled_count"], 1)
            self.assertNotIn("docs", json.dumps(broker.summary()))

    def test_inventory_names_pagination_missing_and_unknown_security_fields_refused(self):
        entries = self.isolated_inventory()
        invalid = ({"data": []}, {"data": [self.isolated_inventory("other")]}, {"data": [entries, entries]},
                   {"data": [entries], "nextCursor": "private-cursor"}, {"data": [entries], "extra": True},
                   {"data": "private"}, {"data": [dict(entries, futureCapability=True)]})
        for result in invalid:
            broker = self.inventory_broker()
            with self.assertRaises(ProtocolError):
                broker.receive({"id": 4, "result": result})
            self.assertFalse(broker.summary()["mcp_inventory_verified"])
            self.assertEqual(broker.phase, "mcp_inventory")
            self.assertEqual(broker.policy.used, 0)

    def test_inventory_tools_resources_handshake_error_and_active_states_refused(self):
        for field, bad in (("tools", {"tool": {}}), ("resources", [{}]), ("resourceTemplates", [{}]),
                           ("serverInfo", {}), ("serverCapabilities", {}), ("toolsError", "private-error"),
                           ("runtimeStatus", "starting"), ("runtimeStatus", "connected"),
                           ("runtimeStatus", "authenticationRequired"), ("runtimeStatus", "failed"),
                           ("runtimeStatus", "cancelled"), ("runtimeStatus", "unknown"), ("authStatus", "future")):
            broker = self.inventory_broker()
            entry = self.isolated_inventory()
            entry[field] = bad
            with self.assertRaises(ProtocolError):
                broker.receive({"id": 4, "result": {"data": [entry]}})
            self.assertFalse(broker.summary()["mcp_inventory_verified"])
            self.assertEqual(broker.policy.used, 0)

    def test_mcp_startup_notification_still_fails_before_inventory(self):
        for method in ("mcpServer/startupStatus/updated", "mcpServer/event/stream/notification", "thread/started"):
            broker = self.inventory_broker()
            with self.assertRaises(ProtocolError):
                broker.receive({"method": method, "params": {"private": "unused"}})
            self.assertFalse(broker.summary()["mcp_inventory_verified"])
            self.assertEqual(broker.policy.used, 0)
            self.assertNotIn("private", json.dumps(broker.summary()))

    def test_initialize_only_verifies_inventory_and_never_requests_thread_or_model(self):
        broker = self.inventory_broker(initialize_only=True)
        replies = broker.receive({"id": 4, "result": {"data": [self.isolated_inventory()]}})
        self.assertEqual(replies, [])
        self.assertEqual(broker.terminal, "mcp_isolation_verified")
        self.assertTrue(broker.summary()["mcp_inventory_verified"])
        self.assertFalse(broker.summary()["passed"])
        self.assertIsNone(broker.thread_id)
        self.assertIsNone(broker.turn_id)
        self.assertEqual(broker.policy.used, 0)
        for method in ("thread/start", "turn/start"):
            with self.assertRaises(ProtocolError):
                broker.receive({"id": 99, "method": method, "params": {}})
        with patch("codex_broker._verify_version"), \
                patch("codex_broker.isolate_mcp", return_value=(["local-official-server"], frozenset())), \
                patch("codex_broker._consume", return_value={"passed": False}) as consume:
            probe_mcp_isolation(Policy((self.command(),)))
            self.assertTrue(consume.call_args.kwargs["initialize_only"])
            self.assertEqual(consume.call_args.kwargs["disabled_mcp_names"], frozenset())
        result = _consume([str(self.python), str(self.peer), "initialize-only"], "Inventory only.",
                          Policy((self.command(),)), seconds=5, initialize_only=True)
        self.assertEqual(result["status"], "mcp_isolation_verified")
        self.assertTrue(result["mcp_inventory_verified"])
        self.assertFalse(result["passed"])
        self.assertEqual(result["executions"], [])
        self.assertFalse(any(name.startswith(("thread/", "turn/", "item/")) for name in result["event_types"]))

    def test_version_probe_uses_minimal_env_and_stops_before_online_on_mismatch(self):
        with patch("codex_broker.subprocess.run", return_value=subprocess.CompletedProcess([], 0, b"other-version", b"")) as probe, \
                patch("codex_broker._consume") as online:
            with patch.dict("os.environ", {"TEST_PRIVATE_VALUE": "private-string"}):
                with self.assertRaises(ValueError):
                    run_codex("bounded task", Policy((self.command(),)))
            self.assertEqual(set(probe.call_args.kwargs["env"]), {"PATH", "LANG"})
            online.assert_not_called()


if __name__ == "__main__":
    unittest.main()
