#!/usr/bin/env python3
"""Bounded native Claude SDK stdio consumer; no credential/config-file reader.

Claude Code 2.1.3's createCanUseTool/gC1 protocol requires updatedInput on allow.
Native Bash/Skill requests are translated only after exact input validation,
then use the existing ordered PinnedPolicy. Initialization metadata is neither
authentication evidence nor a permission and is never returned to the caller.
"""
from __future__ import annotations

import hashlib
import json
import math
import os
from pathlib import Path
import selectors
import shutil
import subprocess
import time
import uuid

from codex_events import JsonLines, ProtocolError, parse_object
from install import host_manifests, complete_host_package_fingerprints
from qwen_stream import PinnedPolicy, _PolicyRefused, _terminate_group


def _text(value, limit=16384):
    return isinstance(value, str) and 0 < len(value.encode("utf-8")) <= limit


def _bounded(value):
    nodes = [0]
    def visit(item, depth=0):
        nodes[0] += 1
        if depth > 16 or nodes[0] > 16384:
            return False
        if item is None or type(item) in (bool, int):
            return True
        if type(item) is float:
            return math.isfinite(item)
        if isinstance(item, str):
            return len(item.encode("utf-8")) <= 1024 * 1024
        if isinstance(item, list):
            return len(item) <= 2048 and all(visit(x, depth+1) for x in item)
        if isinstance(item, dict):
            return len(item) <= 256 and all(isinstance(k, str) and visit(k, depth+1) and
                                            visit(v, depth+1) for k, v in item.items())
        return False
    return visit(value)


def _optional_betas_valid(event):
    # Claude Code 2.1.3 omits this JSON property when no SDK betas are set.
    # Metadata cannot grant tools/permissions; present values still have bounds.
    if "betas" not in event:
        return True
    values = event["betas"]
    if not isinstance(values, list) or len(values) > 32:
        return False
    try:
        return all(_text(value, 128) for value in values)
    except UnicodeError:
        return False


# Diagnostic data is a separate bounded projection, never an exception/transcript
# serializer. These names/codes are authored locally; unknown strings leave only
# a digest. In particular, initialization identity/source values are not copied.
_DIAGNOSTIC_REASONS = frozenset((
    "invalid_native_tool_input", "unreviewed_native_tool_input",
    "invalid_native_permission_envelope", "unexpected_native_permission_request",
    "native_event_after_result", "unreviewed_native_session_configuration",
    "unexpected_native_status", "unexpected_native_system_event", "unexpected_native_event",
    "native_session_changed", "invalid_native_result", "invalid_native_message",
    "invalid_native_content_block", "invalid_native_tool_use", "invalid_native_tool_result",
    "unexpected_native_user_text", "unexpected_native_content_block",
    "invalid_native_initialize_envelope", "native_initialize_not_confirmed",
    "native_outbound_byte_bound", "native_pending_input_at_result",
    "native_stderr_byte_bound", "native_json_structure_bound",
    "unexpected_native_control_response", "native_permission_before_session",
    "native_event_before_initialize", "invalid_json_object", "stream_already_closed",
    "stream_byte_bound", "stream_line_bound", "stream_event_bound",
    "reviewed_regular_file_required", "native_dependency_pin_required",
    "native_configuration_byte_bound", "native_settings_mismatch", "unexpected_skill_plugin",
    "reviewed_local_skill_plugin_required", "native_plugin_layout_bound",
    "unexpected_native_plugin_file_type", "unexpected_local_plugin_contents",
    "unreviewed_plugin_manifest", "plugin_license_or_notice_not_same_source",
    "invalid_file_pin", "single_regular_pinned_file_required", "file_pin_identity_changed",
    "file_pin_mismatch", "pinned_directory_changed",
))
_DIAGNOSTIC_FIELDS = frozenset((
    "type", "subtype", "cwd", "session_id", "tools", "mcp_servers", "model",
    "permissionMode", "slash_commands", "betas", "claude_code_version", "output_style",
    "agents", "skills", "plugins", "uuid", "status", "message", "parent_tool_use_id",
    "error", "isSynthetic", "tool_use_result", "response", "request", "request_id",
    "is_error", "duration_ms", "duration_api_ms", "num_turns", "result", "total_cost_usd",
    "usage", "modelUsage", "permission_denials", "errors",
))


def _diagnostic_type(value):
    return {type(None): "null", bool: "boolean", int: "integer", float: "number",
            str: "string", list: "array", dict: "object"}.get(type(value), "other")


def _diagnostic_name(value, allowed):
    if type(value) is str and value in allowed:
        return {"name": value}
    result = {"name": "other", "type": _diagnostic_type(value)}
    if type(value) is str:
        result["sha256"] = hashlib.sha256(value.encode("utf-8", errors="surrogatepass")).hexdigest()
    return result


def _diagnostic_fields(value):
    if not isinstance(value, dict):
        return {"type": _diagnostic_type(value)}
    known, unknown, unknown_count = set(), [], 0
    for index, name in enumerate(value):
        if index >= 256:
            break
        if name in _DIAGNOSTIC_FIELDS:
            known.add(name)
        elif name in ("apiKeySource", "tokenSource", "account"):
            known.add("private_metadata")
        else:
            unknown_count += 1
            if len(unknown) < 16:
                unknown.append(_diagnostic_name(name, ()))
    return {"type": "object", "count": min(len(value), 257), "known": sorted(known),
            "unknown": unknown, "truncated": len(value) > 256 or unknown_count > 16}


def _diagnostic_init(event, native):
    required = {
        "type", "subtype", "cwd", "session_id", "tools", "mcp_servers", "model",
        "permissionMode", "slash_commands", "claude_code_version", "output_style",
        "agents", "skills", "plugins", "uuid", "apiKeySource"}
    def strings_match(value, expected):
        return isinstance(value, list) and all(type(x) is str for x in value) and set(value) == expected
    checks = {
        "fields_exact": set(event) - {"betas"} == required,
        "betas_valid": _optional_betas_valid(event), "first_session": native.session is None,
        "cwd_match": event.get("cwd") == str(native.policy.directory),
        "session_id_valid": type(event.get("session_id")) is str and
            0 < len(event["session_id"].encode("utf-8", errors="surrogatepass")) <= 128 and
            not any(0xD800 <= ord(c) <= 0xDFFF for c in event["session_id"]),
        "tools_match": strings_match(event.get("tools"), {"Bash"} | ({"Skill"} if native.policy.allow_skill else set())),
        "mcp_empty": event.get("mcp_servers") == [],
        "permission_default": event.get("permissionMode") == "default",
        "agents_strings": isinstance(event.get("agents"), list) and all(isinstance(x, str) for x in event["agents"]),
        "skills_match": strings_match(event.get("skills"), {"video:video"} if native.policy.allow_skill else set()),
        "plugins_match": event.get("plugins") == ([{"name": "video", "path": str(native.skill_plugin)}]
                                                   if native.policy.allow_skill else []),
    }
    shapes = {}
    for name in ("cwd", "session_id", "tools", "mcp_servers", "permissionMode", "agents", "skills", "plugins", "betas"):
        value = event.get(name)
        shapes[name] = {"type": _diagnostic_type(value)}
        if isinstance(value, (list, dict)):
            shapes[name].update(count=min(len(value), 2049), truncated=len(value) > 2048)
    return {"checks": checks, "shapes": shapes}


def _diagnostic_event(event, native):
    if not isinstance(event, dict):
        return None
    result = {"type": _diagnostic_name(event.get("type"),
        ("system", "assistant", "user", "result", "control_request", "control_response")),
        "fields": _diagnostic_fields(event)}
    request = event.get("request")
    response = event.get("response")
    subtype = (request.get("subtype") if isinstance(request, dict) else
               response.get("subtype") if isinstance(response, dict) else event.get("subtype"))
    result["subtype"] = _diagnostic_name(subtype, ("init", "status", "success", "error", "can_use_tool"))
    if event.get("type") == "system" and event.get("subtype") == "init":
        result["init"] = _diagnostic_init(event, native)
    message = event.get("message")
    blocks = message.get("content") if isinstance(message, dict) else None
    candidates = [request] if isinstance(request, dict) else (
        blocks[:8] if isinstance(blocks, list) else [])
    tools = []
    for block in candidates:
        if not isinstance(block, dict) or (block is not request and block.get("type") not in ("tool_use", "tool_result")):
            continue
        item = {"name": _diagnostic_name(block.get("tool_name", block.get("name")), ("Bash", "Skill"))}
        for source, target in ((block.get("tool_use_id", block.get("id")), "id"),
                               ((block.get("input") or {}).get("command")
                                if isinstance(block.get("input"), dict) else None, "command")):
            item[target] = _diagnostic_name(source, ())
        tools.append(item)
    if tools:
        result["tools"] = tools
    return result


def _diagnostic_failure(error, stage, event, native):
    category = next((name for kind, name in ((ProtocolError, "ProtocolError"),
        (_PolicyRefused, "_PolicyRefused"), (OSError, "OSError"), (ValueError, "ValueError"),
        (TypeError, "TypeError"), (RuntimeError, "RuntimeError")) if isinstance(error, kind)), "other")
    reason = "pinned_policy_refused" if isinstance(error, _PolicyRefused) else "other"
    if type(error) in (ProtocolError, ValueError) and len(error.args) == 1 and type(error.args[0]) is str:
        code = error.args[0]
        if len(code) <= 96 and code in _DIAGNOSTIC_REASONS:
            reason = code
    return {"category": category, "reason": reason, "stage": stage,
            "event": _diagnostic_event(event, native)}


def _input(tool, values):
    if not isinstance(values, dict):
        raise ProtocolError("invalid_native_tool_input")
    if tool == "Skill" and values == {"skill": "video:video"}:
        return "skill", {"skill": "video"}
    if (tool != "Bash" or set(values) - {"command", "description", "timeout", "run_in_background"} or
            not _text(values.get("command")) or
            ("description" in values and not isinstance(values["description"], str)) or
            ("description" in values and len(values["description"].encode()) > 4096) or
            ("timeout" in values and (type(values["timeout"]) is not int or not 0 < values["timeout"] <= 120000)) or
            ("run_in_background" in values and values["run_in_background"] is not False)):
        raise ProtocolError("unreviewed_native_tool_input")
    translated = {key: value for key, value in values.items() if key != "run_in_background"}
    if "run_in_background" in values:
        translated["is_background"] = False
    return "run_shell_command", translated


class _NativePolicy:
    def __init__(self, policy, skill_plugin=None):
        self.policy = policy
        self.skill_plugin = skill_plugin
        self.requests = set()
        self.session = None
        self.result_seen = False

    def permission(self, event):
        if (set(event) != {"type", "request_id", "request"} or
                not _text(event.get("request_id"), 128) or event["request_id"] in self.requests):
            raise ProtocolError("invalid_native_permission_envelope")
        self.requests.add(event["request_id"])
        value = event["request"]
        if (not isinstance(value, dict) or set(value) - {"subtype", "tool_name", "input", "tool_use_id",
                "permission_suggestions", "blocked_path", "decision_reason", "agent_id"} or
                value.get("subtype") != "can_use_tool" or not _text(value.get("tool_use_id"), 128) or
                value.get("agent_id") is not None or
                any(value.get(k) is not None and not isinstance(value[k], str)
                    for k in ("blocked_path", "decision_reason")) or
                (value.get("permission_suggestions") is not None and
                 not isinstance(value["permission_suggestions"], list))):
            raise ProtocolError("unexpected_native_permission_request")
        tool, values = _input(value.get("tool_name"), value.get("input"))
        allowed = self.policy.allows({"subtype": "can_use_tool", "tool_name": tool,
            "tool_use_id": value["tool_use_id"], "input": values})
        # Return exactly the original validated native input; never apply any
        # suggested permissions, session updates, directory grants or auth data.
        reply = ({"behavior": "allow", "updatedInput": value["input"]} if allowed else
                 {"behavior": "deny", "message": "Only the exact reviewed local action is permitted."})
        return allowed, value["tool_use_id"], reply

    def observe(self, event):
        kind = event.get("type")
        if self.result_seen:
            raise ProtocolError("native_event_after_result")
        if kind == "system":
            subtype = event.get("subtype")
            if subtype == "init":
                required = {"type", "subtype", "cwd", "session_id", "tools", "mcp_servers", "model",
                    "permissionMode", "slash_commands", "apiKeySource", "claude_code_version",
                    "output_style", "agents", "skills", "plugins", "uuid"}
                expected_tools = {"Bash"} | ({"Skill"} if self.policy.allow_skill else set())
                if (set(event) - {"betas"} != required or not _optional_betas_valid(event) or self.session is not None or
                        event["cwd"] != str(self.policy.directory) or not _text(event["session_id"], 128) or
                        not isinstance(event["tools"], list) or set(event["tools"]) != expected_tools or
                        event["mcp_servers"] != [] or event["permissionMode"] != "default" or
                        not isinstance(event["agents"], list) or
                        any(not isinstance(item, str) for item in event["agents"]) or
                        not isinstance(event["skills"], list) or
                        set(event["skills"]) != ({"video:video"} if self.policy.allow_skill else set()) or
                        event["plugins"] != ([{"name": "video", "path": str(self.skill_plugin)}]
                                             if self.policy.allow_skill else [])):
                    raise ProtocolError("unreviewed_native_session_configuration")
                self.session = event["session_id"]
            elif subtype == "status":
                if (set(event) != {"type", "subtype", "status", "session_id", "uuid"} or
                        event["status"] not in (None, "compacting") or self.session is None or
                        event["session_id"] != self.session):
                    raise ProtocolError("unexpected_native_status")
            else:
                raise ProtocolError("unexpected_native_system_event")
            # apiKeySource and other configuration metadata are not exported.
            return {"type": "system", "subtype": subtype}
        if kind not in ("assistant", "user", "result") or self.session is None:
            raise ProtocolError("unexpected_native_event")
        if event.get("session_id") != self.session:
            raise ProtocolError("native_session_changed")
        if kind == "result":
            allowed = {"type", "subtype", "is_error", "duration_ms", "duration_api_ms", "num_turns", "result",
                "session_id", "total_cost_usd", "usage", "modelUsage", "permission_denials", "uuid", "errors"}
            if (set(event) - allowed or event.get("permission_denials") != [] or
                    type(event.get("is_error")) is not bool):
                raise ProtocolError("invalid_native_result")
            self.policy.observe(event)
            self.result_seen = True
            return event
        allowed = {"type", "message", "session_id", "parent_tool_use_id", "uuid"}
        allowed |= {"error"} if kind == "assistant" else {"isSynthetic", "tool_use_result"}
        message = event.get("message")
        if (set(event) - allowed or event.get("parent_tool_use_id") is not None or
                (kind == "assistant" and event.get("error") is not None) or
                not isinstance(message, dict) or message.get("role") != kind or
                not isinstance(message.get("content"), list)):
            raise ProtocolError("invalid_native_message")
        translated = []
        for block in message["content"]:
            if not isinstance(block, dict):
                raise ProtocolError("invalid_native_content_block")
            tag = block.get("type")
            if tag == "tool_use":
                if kind != "assistant" or set(block) != {"type", "id", "name", "input"}:
                    raise ProtocolError("invalid_native_tool_use")
                name, values = _input(block.get("name"), block.get("input"))
                translated.append(dict(block, name=name, input=values))
            elif tag == "tool_result":
                if kind != "user" or set(block) - {"type", "tool_use_id", "content", "is_error"}:
                    raise ProtocolError("invalid_native_tool_result")
                translated.append(block)
            elif tag in ("text", "thinking", "redacted_thinking") and kind == "assistant":
                translated.append(block)
            elif tag == "text" and kind == "user":
                # Skill expansion is a native synthetic user message; it does
                # not authorize another action or advance the ordered policy.
                if event.get("isSynthetic") is not True:
                    raise ProtocolError("unexpected_native_user_text")
                translated.append(block)
            else:
                raise ProtocolError("unexpected_native_content_block")
        normalized = dict(event, message=dict(message, content=translated))
        self.policy.observe(normalized)
        return event


def _initialized(event, identifier):
    if (set(event) != {"type", "response"} or not isinstance(event.get("response"), dict)):
        raise ProtocolError("invalid_native_initialize_envelope")
    response = event["response"]
    payload = response.get("response")
    if (set(response) != {"subtype", "request_id", "response"} or response["request_id"] != identifier or
            response["subtype"] != "success" or not isinstance(payload, dict) or
            set(payload) != {"commands", "output_style", "available_output_styles", "models", "account"} or
            not isinstance(payload["commands"], list) or not isinstance(payload["models"], list) or
            not isinstance(payload["available_output_styles"], list) or not isinstance(payload["output_style"], str) or
            not isinstance(payload["account"], dict) or set(payload["account"]) -
            {"email", "organization", "subscriptionType", "tokenSource", "apiKeySource"}):
        raise ProtocolError("native_initialize_not_confirmed")


def consume(arguments, prompt, policy: PinnedPolicy, *, seconds, on_event=None, skill_plugin=None,
            _verify_configuration=None):
    """One initialized native user turn; strict pins and owned-group cleanup.

    The caller must build arguments with run_claude for a real host. Direct
    consume is exposed to local protocol peers for meaningful security tests.
    """
    if (not isinstance(policy, PinnedPolicy) or type(seconds) not in (int, float) or
            not 0 < seconds <= 180 or not _text(prompt, 65536)):
        raise ValueError("invalid_bounded_native_invocation")
    policy.begin()
    started = time.monotonic()
    deadline = started + seconds
    process = subprocess.Popen(arguments, cwd=policy.directory, stdin=subprocess.PIPE,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ, "out")
    selector.register(process.stderr, selectors.EVENT_READ, "err")
    os.set_blocking(process.stdin.fileno(), False)
    outgoing = bytearray()
    stream = JsonLines(max_bytes=8*1024*1024, max_line=1024*1024, max_events=1000)
    stderr = hashlib.sha256()
    stderr_bytes = 0
    identifier = uuid.uuid4().hex
    native = _NativePolicy(policy, skill_plugin)
    initialized = False
    events, decisions = [], []
    result = None
    status = "ended_without_result"
    failure = None
    diagnostics = {"version": 1, "refusal": None}
    diagnostic_event = None
    diagnostic_stage = "initialize_send"

    def send(value):
        encoded = (json.dumps(value, ensure_ascii=False) + "\n").encode()
        if len(outgoing) + len(encoded) > 256 * 1024:
            raise ProtocolError("native_outbound_byte_bound")
        outgoing.extend(encoded)
        if process.stdin not in [key.fileobj for key in selector.get_map().values()]:
            selector.register(process.stdin, selectors.EVENT_WRITE, "in")

    try:
        send({"type": "control_request", "request_id": identifier, "request": {"subtype": "initialize"}})
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                status = "hard_deadline"
                break
            for key, _ in selector.select(min(.2, remaining)):
                if key.data == "in":
                    diagnostic_stage = "stdin_write"
                    diagnostic_event = None
                    try:
                        written = os.write(process.stdin.fileno(), outgoing[:4096])
                    except BlockingIOError:
                        continue
                    del outgoing[:written]
                    if not outgoing:
                        selector.unregister(process.stdin)
                    continue
                data = os.read(key.fileobj.fileno(), 65536)
                if not data:
                    selector.unregister(key.fileobj)
                if key.data == "err":
                    stderr.update(data)
                    stderr_bytes += len(data)
                    if stderr_bytes > 1024*1024:
                        raise ProtocolError("native_stderr_byte_bound")
                    continue
                diagnostic_event = None
                diagnostic_stage = "event_decode"
                for event in stream.feed(data, eof=not data):
                    diagnostic_event = event
                    diagnostic_stage = "event_bounds"
                    if not _bounded(event):
                        raise ProtocolError("native_json_structure_bound")
                    diagnostic_stage = "configuration_verify"
                    if _verify_configuration is not None:
                        _verify_configuration()
                    diagnostic_stage = "event_admission"
                    kind = event.get("type")
                    if kind == "control_response":
                        if initialized:
                            raise ProtocolError("unexpected_native_control_response")
                        _initialized(event, identifier)
                        initialized = True
                        # Do not export the native account/configuration values.
                        events.append({"type": "control_response", "initialized": True})
                        send({"type": "user", "message": {"role": "user", "content": prompt}})
                    elif kind == "control_request":
                        if not initialized or native.session is None or native.result_seen:
                            raise ProtocolError("native_permission_before_session")
                        allowed, tool_id, reply = native.permission(event)
                        decisions.append({"tool_use_id": tool_id, "allowed": allowed})
                        send({"type": "control_response", "response": {"subtype": "success",
                            "request_id": event["request_id"], "response": reply}})
                        if not allowed:
                            raise _PolicyRefused("固定许可拒绝")
                    else:
                        if not initialized:
                            raise ProtocolError("native_event_before_initialize")
                        if kind == "result" and outgoing:
                            raise ProtocolError("native_pending_input_at_result")
                        safe = native.observe(event)
                        events.append(safe)
                        if kind == "result":
                            result = event
                            status = "native_result"
                            process.stdin.close()
                        if on_event:
                            on_event(safe)
        if process.poll() is None and status != "hard_deadline":
            try:
                process.wait(timeout=max(.01, deadline-time.monotonic()))
            except subprocess.TimeoutExpired:
                status = "hard_deadline"
    except (ProtocolError, _PolicyRefused, OSError, ValueError, TypeError, RuntimeError) as error:
        diagnostics["refusal"] = _diagnostic_failure(error, diagnostic_stage, diagnostic_event, native)
        failure = diagnostics["refusal"]["category"]
        policy.failed = True
        status = "policy_refused" if isinstance(error, _PolicyRefused) else "protocol_refused"
    finally:
        try:
            cleanup = _terminate_group(process)
        finally:
            selector.close()
            for item in (process.stdin, process.stdout, process.stderr):
                if not item.closed:
                    item.close()
    try:
        diagnostic_stage = "completion_verify"
        if _verify_configuration is not None:
            _verify_configuration()
        policy._verify_pins()
    except (ValueError, OSError) as error:
        diagnostics["completion_refusal"] = _diagnostic_failure(error, diagnostic_stage, None, native)
        policy.failed = True
        status = "policy_refused"
    complete = (status == "native_result" and initialized and process.returncode == 0 and
        isinstance(result, dict) and result.get("subtype") == "success" and result.get("is_error") is False and
        policy.complete and all(item["allowed"] for item in decisions) and cleanup["passed"])
    return {"status": status, "initialized": initialized, "exit_code": process.returncode,
        "seconds": round(time.monotonic()-started, 3), "events": events, "decisions": decisions,
        "result": result, "failure_type": failure, "diagnostics": diagnostics,
        "cleanup": cleanup, "execution_complete": complete,
        "policy_complete": complete, "event_bytes": stream.bytes, "event_sha256": stream.digest.hexdigest(),
        "stderr_bytes": stderr_bytes, "stderr_sha256": stderr.hexdigest()}


def create_isolated_settings(policy: PinnedPolicy, path: Path):
    path = Path(path)
    if (path.exists() or path.is_symlink() or path.parent != policy.directory or
            path != path.resolve() or any(p.is_symlink() for p in path.parents)):
        raise ValueError("fresh_invocation_settings_required")
    settings = {"disableAllHooks": True, "permissions": {"allow": [],
        "ask": ["Bash"] + (["Skill"] if policy.allow_skill else [])}}
    path.write_text(json.dumps(settings, sort_keys=True) + "\n", encoding="utf-8")


def _pinned_regular(policy, path, limit=None):
    path = Path(path)
    if (not path.is_absolute() or path != path.resolve(strict=True) or path.is_symlink() or
            any(p.is_symlink() for p in path.parents) or not path.is_file() or
            (limit is not None and path.stat().st_size > limit)):
        raise ValueError("reviewed_regular_file_required")
    match = [pin for pin in policy.pins if pin.path == path]
    if len(match) != 1:
        raise ValueError("native_dependency_pin_required")
    match[0].verify()
    return path


def _pinned_json(policy, path, limit):
    path = _pinned_regular(policy, path, limit)
    with path.open("rb") as stream:
        data = stream.read(limit+1)
    if len(data) > limit:
        raise ValueError("native_configuration_byte_bound")
    value = parse_object(data)
    _pinned_regular(policy, path, limit)
    return value


def _configuration(policy, settings, skill_plugin):
    expected = {"disableAllHooks": True, "permissions": {"allow": [],
        "ask": ["Bash"] + (["Skill"] if policy.allow_skill else [])}}
    if settings.parent != policy.directory or _pinned_json(policy, settings, 65536) != expected:
        raise ValueError("native_settings_mismatch")
    if not policy.allow_skill:
        if skill_plugin is not None:
            raise ValueError("unexpected_skill_plugin")
        return
    if (not isinstance(skill_plugin, Path) or not skill_plugin.is_absolute() or
            skill_plugin != skill_plugin.resolve(strict=True) or
            not skill_plugin.is_relative_to(policy.directory) or
            any(p.is_symlink() for p in (skill_plugin, *skill_plugin.parents))):
        raise ValueError("reviewed_local_skill_plugin_required")
    if policy.skill_directory != skill_plugin / "skills/video":
        raise ValueError("native_skill_directory_mismatch")
    policy._verify_pins()
    files = []
    for index, path in enumerate(skill_plugin.rglob("*")):
        if index >= 128 or path.is_symlink():
            raise ValueError("native_plugin_layout_bound")
        if path.is_file():
            files.append(path)
        elif not path.is_dir():
            raise ValueError("unexpected_native_plugin_file_type")
    manifest = skill_plugin / ".claude-plugin/plugin.json"
    if (not 4 <= len(files) <= 32 or manifest not in files or
            skill_plugin / "skills/video/SKILL.md" not in files or
            any(p not in (manifest, skill_plugin/"LICENSE", skill_plugin/"NOTICE") and
                not p.is_relative_to(skill_plugin / "skills/video") for p in files)):
        raise ValueError("unexpected_local_plugin_contents")
    for path in files:
        _pinned_regular(policy, path, 1024*1024)
    metadata = _pinned_json(policy, manifest, 65536)
    version = metadata.get("version")
    if (not isinstance(version, str) or
            metadata != host_manifests("claude", version)[".claude-plugin/plugin.json"]):
        raise ValueError("unreviewed_plugin_manifest")
    digests = {pin.path: pin.sha256 for pin in policy.pins}
    for name in ("LICENSE", "NOTICE"):
        outer, inner = skill_plugin/name, skill_plugin/"skills/video"/name
        if outer not in files or inner not in files or digests[outer] != digests[inner]:
            raise ValueError("plugin_license_or_notice_not_same_source")
    complete_host_package_fingerprints(skill_plugin, "claude")


def run_claude(prompt, policy: PinnedPolicy, settings: Path, *, seconds=110,
               max_turns=4, max_budget_usd=.10, skill_plugin: Path | None = None, on_event=None):
    """Native installed CLI only; no arbitrary argv, HOME or authentication edit.

    Explicit local plugins keep user/project settings disabled while loading
    the one reviewed namespaced Skill. Callers pin interpreter, CLI, settings,
    plugin manifest and every Skill file, in addition to their business inputs.
    """
    if (not isinstance(policy, PinnedPolicy) or type(max_turns) is not int or not 1 <= max_turns <= 8 or
            type(max_budget_usd) not in (int, float) or not 0 < max_budget_usd <= .10):
        raise ValueError("invalid_native_limits")
    node = _pinned_regular(policy, Path(shutil.which("node")).resolve(strict=True))
    cli = _pinned_regular(policy, Path(shutil.which("claude")).resolve(strict=True))
    _pinned_regular(policy, Path(__file__).with_name("install.py").resolve(strict=True))
    settings = Path(settings)
    _configuration(policy, settings, skill_plugin)
    arguments = [str(node), str(cli), "--print", "--verbose", "--input-format", "stream-json",
        "--output-format", "stream-json", "--permission-mode", "default", "--permission-prompt-tool", "stdio",
        "--tools", "Bash,Skill" if policy.allow_skill else "Bash", "--strict-mcp-config", "--mcp-config",
        '{"mcpServers":{}}', "--setting-sources", "", "--settings", str(settings), "--no-session-persistence",
        "--max-turns", str(max_turns), "--max-budget-usd", str(max_budget_usd)]
    if policy.allow_skill:
        arguments += ["--plugin-dir", str(skill_plugin)]
    policy._verify_pins()
    return consume(arguments, prompt, policy, seconds=seconds, on_event=on_event, skill_plugin=skill_plugin,
                   _verify_configuration=lambda: _configuration(policy, settings, skill_plugin))
