#!/usr/bin/env python3
"""Bounded Codex event evidence. Summaries never contain transcript/error text.

This module observes events; it does not approve or prevent a command. Use the
dynamic-tool broker for execution-before-permission, not an item.started check.
"""
from __future__ import annotations

from collections import Counter
import hashlib
import json
import math
import re


class ProtocolError(ValueError):
    """A safe, locally generated protocol diagnostic, never a server message."""


# Codex rust-v0.159.2: app-server-protocol v2/account.rs AccountUpdatedNotification,
# common.rs AuthMode, and protocol/account.rs PlanType. This is a status shape,
# not an authentication result or an authorization grant. Never retain its values.
_ACCOUNT_AUTH_MODES = frozenset((
    "apikey", "chatgpt", "chatgptAuthTokens", "headers", "agentIdentity",
    "personalAccessToken", "bedrockApiKey", "bedrockAccessKeys",
))
_ACCOUNT_PLAN_TYPES = frozenset((
    "free", "go", "plus", "pro", "prolite", "promax", "team",
    "self_serve_business_prolite", "self_serve_business_usage_based", "business",
    "ent26", "enterprise_cbp_automation", "enterprise_cbp_usage_based",
    "enterprise", "edu", "edu_plus", "edu_pro", "unknown",
))


def is_account_status_notification(params) -> bool:
    """Recognize only the pinned two-field status; do not return account data."""
    if not isinstance(params, dict) or set(params) != {"authMode", "planType"}:
        return False
    for key, values in (("authMode", _ACCOUNT_AUTH_MODES), ("planType", _ACCOUNT_PLAN_TYPES)):
        value = params[key]
        if value is not None and (not isinstance(value, str) or value not in values):
            return False
    return True


def is_turn_moderation_status(params, *, thread_id, turn_id) -> bool:
    """Validate pinned identity-bound JsonValue status without retaining contents."""
    # rust-v0.159.2 app-server-protocol v2/model.rs:193. The nested metadata is
    # opaque JsonValue, not a permission, execution request, or settings update.
    if (not isinstance(params, dict) or set(params) != {"threadId", "turnId", "metadata"} or
            not isinstance(thread_id, str) or not 0 < len(thread_id) <= 128 or
            not isinstance(turn_id, str) or not 0 < len(turn_id) <= 128 or
            params["threadId"] != thread_id or params["turnId"] != turn_id):
        return False
    nodes = [0]

    def bounded_json(value, depth=0):
        nodes[0] += 1
        if depth > 16 or nodes[0] > 1024:
            return False
        if value is None or type(value) in (bool, int):
            return True
        if type(value) is float:
            return math.isfinite(value)
        if isinstance(value, str):
            return len(value.encode("utf-8")) <= 65536
        if isinstance(value, list):
            return len(value) <= 256 and all(bounded_json(item, depth+1) for item in value)
        if isinstance(value, dict):
            return len(value) <= 256 and all(isinstance(key, str) and
                bounded_json(key, depth+1) and bounded_json(item, depth+1) for key, item in value.items())
        return False

    try:
        return bounded_json(params["metadata"]) and len(json.dumps(
            params["metadata"], ensure_ascii=False, allow_nan=False).encode("utf-8")) <= 65536
    except (ValueError, UnicodeError, RecursionError):
        return False


def _object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ProtocolError("duplicate_json_key")
        result[key] = value
    return result


def parse_object(data: bytes) -> dict:
    try:
        value = json.loads(data.decode("utf-8"), object_pairs_hook=_object,
                           parse_constant=lambda _: (_ for _ in ()).throw(ProtocolError("nonfinite_json")))
    except (UnicodeError, ValueError, RecursionError) as error:
        raise ProtocolError("invalid_json_object") from error
    if not isinstance(value, dict):
        raise ProtocolError("invalid_json_object")
    return value


class JsonLines:
    """Incrementally bound bytes, line size and event count, including final EOF."""

    def __init__(self, *, max_bytes=8 * 1024 * 1024, max_line=1024 * 1024, max_events=1000):
        self.max_bytes, self.max_line, self.max_events = max_bytes, max_line, max_events
        self.buffer = b""
        self.bytes = self.events = 0
        self.digest = hashlib.sha256()
        self.closed = False

    def feed(self, data: bytes, *, eof=False) -> list[dict]:
        if self.closed:
            raise ProtocolError("stream_already_closed")
        self.bytes += len(data)
        self.digest.update(data)
        if self.bytes > self.max_bytes:
            raise ProtocolError("stream_byte_bound")
        self.buffer += data
        lines = self.buffer.split(b"\n")
        self.buffer = lines.pop()
        if eof:
            lines.append(self.buffer)
            self.buffer = b""
            self.closed = True
        if len(self.buffer) > self.max_line or any(len(line) > self.max_line for line in lines):
            raise ProtocolError("stream_line_bound")
        result = []
        for line in lines:
            if not line.strip():
                continue
            self.events += 1
            if self.events > self.max_events:
                raise ProtocolError("stream_event_bound")
            result.append(parse_object(line))
        return result


# Only a finite local signature, not arbitrary remotely supplied text, is exposed.
# A matching message is labelled as a pattern inference. App-server's typed
# codexErrorInfo, when present, is separately retained as direct protocol data.
_PATTERNS = (
    ("sandbox", r"sandbox[_ -](?:apply|error)|sandbox-exec|operation not permitted"),
    ("usage_limit", r"usage limit|quota exceeded|insufficient_quota"),
    ("rate_limit", r"rate.limit|too many requests|\b429\b"),
    ("context_window", r"context.window|maximum context|context length"),
    ("auth_rejected", r"unauthorized|unauthenticated|not signed in|\b401\b"),
    ("transport", r"stream (?:disconnected|connection)|connection (?:failed|reset|closed)|timed? out"),
    ("configuration", r"unknown (?:field|option)|unsupported (?:option|config)|invalid config"),
)
_DIRECT_CODES = frozenset((
    "contextWindowExceeded", "sessionBudgetExceeded", "usageLimitExceeded", "rateLimitExceeded",
    "flexUnavailable", "serverOverloaded", "cyberPolicy", "misalignmentPolicyViolation",
    "tooManyDenials", "internalServerError", "unauthorized", "badRequest", "sandboxError", "other",
))
_HTTP_CODES = frozenset(("httpConnectionFailed", "responseStreamConnectionFailed",
                         "responseStreamDisconnected", "responseTooManyFailedAttempts"))


def safe_error(value, *, source: str) -> dict:
    """Preserve a diagnostic's identity and known shape, never its text or secrets."""
    message = value.get("message", "") if isinstance(value, dict) else ""
    message = message if isinstance(message, str) else ""
    encoded = message.encode("utf-8")
    result = {"source": source, "message_bytes": len(encoded),
              "message_sha256": hashlib.sha256(encoded).hexdigest(),
              "message_pattern_inference": "unknown"}
    for name, pattern in _PATTERNS:
        if re.search(pattern, message[:32768], flags=re.I):
            result["message_pattern_inference"] = name
            break
    code = value.get("codexErrorInfo") if isinstance(value, dict) else None
    if isinstance(code, str) and code in _DIRECT_CODES:
        result["protocol_code"] = code
    elif isinstance(code, dict) and len(code) == 1:
        name, details = next(iter(code.items()))
        if name in _HTTP_CODES and isinstance(details, dict):
            result["protocol_code"] = name
            status = details.get("httpStatusCode")
            if type(status) is int and 100 <= status <= 599:
                result["http_status"] = status
    return result


class ExecAudit:
    """Truthful exec --json lifecycle accounting; not an execution allowlist."""

    def __init__(self, expected_commands: tuple[str, ...]):
        if not expected_commands or len(expected_commands) > 8:
            raise ValueError("one_to_eight_expected_commands_required")
        self.expected = expected_commands
        self.types = Counter()
        self.started = {}
        self.completed = []
        self.errors = []
        self.violations = []
        self.terminal = None
        self.last_message = None

    def add(self, event: dict) -> None:
        kind = event.get("type")
        if kind not in {"thread.started", "turn.started", "turn.completed", "turn.failed", "error",
                        "item.started", "item.updated", "item.completed"}:
            raise ProtocolError("event_type_missing")
        self.types[kind] += 1
        if kind == "thread.started" and (self.types[kind] != 1 or self.types["turn.started"]):
            self.violations.append("thread_start_out_of_order")
        if kind == "turn.started" and (self.types[kind] != 1 or self.types["thread.started"] != 1):
            self.violations.append("turn_start_out_of_order")
        if self.terminal:
            self.violations.append("event_after_terminal")
        if kind in ("turn.completed", "turn.failed"):
            if self.terminal:
                self.violations.append("duplicate_turn_terminal")
            self.terminal = kind
        if kind == "error":
            self.errors.append(safe_error(event, source="error"))
        elif kind == "turn.failed":
            self.errors.append(safe_error(event.get("error"), source="turn.failed"))
        if kind not in ("item.started", "item.updated", "item.completed"):
            return
        item = event.get("item")
        if not isinstance(item, dict):
            raise ProtocolError("item_missing")
        item_type, identity = item.get("type"), item.get("id")
        if item_type == "agent_message" and kind == "item.completed":
            text = item.get("text", "")
            if isinstance(text, str):
                raw = text.encode()
                self.last_message = {"bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest()}
        elif item_type == "error":
            self.errors.append(safe_error(item, source="item.error"))
        elif item_type == "command_execution":
            if self.types["thread.started"] != 1 or self.types["turn.started"] != 1:
                self.violations.append("command_outside_turn")
            if not isinstance(identity, str) or not isinstance(item.get("command"), str):
                raise ProtocolError("command_identity_missing")
            if kind == "item.started":
                if identity in self.started:
                    self.violations.append("duplicate_command_start")
                self.started[identity] = item["command"]
            elif kind == "item.completed":
                if identity not in self.started or any(i[0] == identity for i in self.completed):
                    self.violations.append("unmatched_command_completion")
                if self.started.get(identity) != item["command"]:
                    self.violations.append("command_identity_changed")
                ok = item.get("status") == "completed" and type(item.get("exit_code")) is int and item["exit_code"] == 0
                self.completed.append((identity, item["command"], ok))
        elif item_type not in ("agent_message", "reasoning", "todo_list"):
            self.violations.append("unexpected_execution_item")

    def finish(self, exit_code: int) -> dict:
        actual = tuple(item[1] for item in self.completed)
        passed = (type(exit_code) is int and exit_code == 0 and self.terminal == "turn.completed"
                  and self.types["thread.started"] == self.types["turn.started"] == 1
                  and not self.errors and not self.violations and actual == self.expected
                  and len(self.started) == len(self.completed) and all(i[2] for i in self.completed))
        return {"passed": passed, "terminal": self.terminal or "ended_without_turn", "exit_code": exit_code,
                "event_types": dict(self.types), "commands_started": len(self.started),
                "commands_completed": len(self.completed), "expected_commands_match": actual == self.expected,
                "errors": self.errors, "violations": self.violations, "last_agent_message": self.last_message,
                "execution_control": "observation_only"}
