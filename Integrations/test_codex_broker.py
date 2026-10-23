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
                          _project_mcp, _mcp_projection, isolate_mcp, probe_mcp_isolation)
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

    def command(self):
        return Command("discover", (str(self.python), str(self.discover), "--binary", str(self.binary)), self.root,
                       tuple(self.pin(p) for p in (self.python, self.discover, self.binary)), "discovery")

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
        with patch("codex_broker.os.killpg", side_effect=[None, PermissionError()]) as kill, \
                patch("codex_broker.time.sleep"):
            cleanup = _stop(process)
        self.assertEqual(kill.call_args_list, [unittest.mock.call(123, signal.SIGTERM), unittest.mock.call(123, signal.SIGKILL)])
        process.wait.assert_called_once_with(timeout=1)
        self.assertFalse(cleanup["passed"])
        self.assertEqual(cleanup["kill"], "permission_denied")

    def test_offline_peer_end_to_end_dynamic_execution(self):
        p = Policy((self.command(),))
        r = _consume([str(self.python), str(self.peer), "pass", json.dumps(p.commands[0].arguments())],
                     "Use the explicit operation", p, seconds=5)
        self.assertTrue(r["passed"], r)
        self.assertEqual(len(r["executions"]), 1)
        self.assertEqual(r["native_approvals_accepted"], 0)

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
