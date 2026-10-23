import hashlib
import json
import unittest

from codex_events import ExecAudit, JsonLines, ProtocolError, safe_error


def event(kind, **values):
    return {"type": kind, **values}


def command(kind, *, identity="c1", text="video schema", status="completed", exit_code=0):
    return event(kind, item={"id": identity, "type": "command_execution", "command": text,
                             "status": status, "exit_code": exit_code})


class EventTests(unittest.TestCase):
    def audit(self, commands=("video schema",)):
        a = ExecAudit(commands)
        a.add(event("thread.started", thread_id="thread"))
        a.add(event("turn.started"))
        return a

    def test_chunked_utf8_and_final_line_without_newline(self):
        data = json.dumps(event("error", message="中文"), ensure_ascii=False).encode()
        lines = JsonLines()
        self.assertEqual(lines.feed(data[:31]), [])
        self.assertEqual(lines.feed(data[31:], eof=True), [event("error", message="中文")])
        self.assertEqual(lines.digest.hexdigest(), hashlib.sha256(data).hexdigest())
        with self.assertRaises(ProtocolError):
            lines.feed(b"")

    def test_duplicate_keys_scalar_nonfinite_and_invalid_utf8_refused(self):
        for data in (b'{"type":"error","type":"turn.completed"}', b'[]', b'{"n":NaN}', b'{"x":"\xff"}'):
            with self.subTest(data=data), self.assertRaises(ProtocolError):
                JsonLines().feed(data, eof=True)

    def test_byte_line_and_event_bounds(self):
        for stream, data in ((JsonLines(max_bytes=3), b"1234"), (JsonLines(max_line=2), b"123"),
                             (JsonLines(max_line=2), b"123\n"), (JsonLines(max_events=1), b"{}\n{}\n")):
            with self.assertRaises(ProtocolError):
                stream.feed(data)

    def test_error_diagnostics_never_echo_secrets_or_remote_fields(self):
        secret = "".join(("sk-", "example-private-value-", "abcdefghijklmnop"))
        text = "Unauthorized 401; Authorization: Bearer " + secret
        value = safe_error({"message": text, "codexErrorInfo": "unauthorized", "secret": secret}, source="error")
        self.assertEqual(value["protocol_code"], "unauthorized")
        self.assertEqual(value["message_pattern_inference"], "auth_rejected")
        self.assertEqual(value["message_sha256"], hashlib.sha256(text.encode()).hexdigest())
        self.assertNotIn(secret, json.dumps(value))
        self.assertNotIn("Bearer", json.dumps(value))

    def test_typed_http_diagnostic_and_unrecognized_code(self):
        value = safe_error({"message": "opaque", "codexErrorInfo": {"responseStreamDisconnected": {"httpStatusCode": 502}}}, source="error")
        self.assertEqual(value["protocol_code"], "responseStreamDisconnected")
        self.assertEqual(value["http_status"], 502)
        self.assertNotIn("protocol_code", safe_error({"codexErrorInfo": "secret-value"}, source="error"))

    def test_zero_tools_exit_zero_does_not_pass(self):
        a = self.audit()
        a.add(event("turn.completed"))
        self.assertFalse(a.finish(0)["passed"])

    def test_real_command_lifecycle_required(self):
        a = self.audit()
        a.add(command("item.started", status="in_progress", exit_code=None))
        a.add(command("item.completed"))
        a.add(event("turn.completed"))
        summary = a.finish(0)
        self.assertTrue(summary["passed"])
        self.assertEqual(summary["execution_control"], "observation_only")
        self.assertNotIn("video schema", json.dumps(summary))

    def test_turn_failed_preserved_and_message_not_lost(self):
        a = self.audit()
        a.add(event("error", message="sandbox-exec: sandbox_apply: Operation not permitted"))
        a.add(event("turn.failed", error={"message": "sandbox-exec failed"}))
        r = a.finish(1)
        self.assertEqual(r["terminal"], "turn.failed")
        self.assertEqual(len(r["errors"]), 2)
        self.assertTrue(all(e["message_pattern_inference"] == "sandbox" for e in r["errors"]))
        self.assertFalse(r["passed"])

    def test_incomplete_started_command_fails(self):
        a = self.audit()
        a.add(command("item.started"))
        a.add(event("turn.completed"))
        self.assertFalse(a.finish(0)["passed"])

    def test_orphan_changed_and_duplicate_completions_fail(self):
        for mode in ("orphan", "changed", "duplicate"):
            with self.subTest(mode=mode):
                a = self.audit()
                if mode != "orphan":
                    a.add(command("item.started"))
                a.add(command("item.completed", text="unexpected" if mode == "changed" else "video schema"))
                if mode == "duplicate":
                    a.add(command("item.completed"))
                a.add(event("turn.completed"))
                self.assertFalse(a.finish(0)["passed"])

    def test_wrong_order_and_command_failure_fail(self):
        a = ExecAudit(("video schema",))
        a.add(event("turn.started"))
        a.add(event("thread.started"))
        a.add(command("item.started"))
        a.add(command("item.completed"))
        a.add(event("turn.completed"))
        self.assertFalse(a.finish(0)["passed"])
        for status, exit_code in (("failed", 0), ("completed", 2), ("completed", True)):
            b = self.audit()
            b.add(command("item.started"))
            b.add(command("item.completed", status=status, exit_code=exit_code))
            b.add(event("turn.completed"))
            self.assertFalse(b.finish(0)["passed"])

    def test_unexpected_execution_not_ignored(self):
        for kind in ("file_change", "mcp_tool_call", "web_search", "future_execution"):
            a = self.audit()
            a.add(event("item.completed", item={"id": "x", "type": kind}))
            a.add(event("turn.completed"))
            self.assertFalse(a.finish(0)["passed"])

    def test_duplicate_terminal_and_later_item_fail(self):
        a = self.audit()
        a.add(command("item.started"))
        a.add(command("item.completed"))
        a.add(event("turn.completed"))
        a.add(event("turn.completed"))
        self.assertFalse(a.finish(0)["passed"])

    def test_agent_message_only_hash_and_unknown_event_refused(self):
        a = self.audit()
        a.add(event("item.completed", item={"id": "msg", "type": "agent_message", "text": "private text"}))
        self.assertNotIn("private text", json.dumps(a.finish(0)))
        with self.assertRaises(ProtocolError):
            a.add(event("arbitrary-secret-string"))


if __name__ == "__main__":
    unittest.main()
