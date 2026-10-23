#!/usr/bin/env python3
"""Bounded Qwen stream-json consumer; credentials remain with the native host.

SDK initialize must be the first message. Direct/user-first mode has no control
service and cannot deliver permission requests for tools configured to ask.
No transcript, prompt, tool output or credential is written by this module.
"""
from __future__ import annotations

from dataclasses import dataclass, field
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import signal
import stat
import subprocess
import time
import uuid


@dataclass(frozen=True)
class ExactPolicy:
    directory: Path
    commands: frozenset[str]
    input_files: frozenset[Path] = frozenset()

    def allows(self, request: dict) -> bool:
        if request.get("subtype") != "can_use_tool":
            return False
        tool = request.get("tool_name")
        values = request.get("input")
        if not isinstance(values, dict):
            return False
        directory = self.directory.resolve()
        if tool == "run_shell_command":
            supplied_directory = values.get("directory")
            if supplied_directory is not None:
                if not isinstance(supplied_directory, str):
                    return False
                supplied_path = Path(supplied_directory)
                if (supplied_path if supplied_path.is_absolute() else directory / supplied_path).resolve() != directory:
                    return False
            return values.get("command") in self.commands and not any(
                values.get(name) for name in ("is_background", "background", "async")
            )
        if tool == "write_file":
            name, content = values.get("file_path"), values.get("content")
            if not isinstance(name, str) or not isinstance(content, str) or len(content.encode()) > 1024 * 1024:
                return False
            path = Path(name)
            path = path if path.is_absolute() else directory / path
            # Do not silently resolve an installed symlink into a permitted input.
            if any(candidate.is_symlink() for candidate in (path, *path.parents)):
                return False
            if path.resolve() not in self.input_files or not path.resolve().is_relative_to(directory):
                return False
            try:
                return isinstance(json.loads(content), dict)
            except ValueError:
                return False
        return tool == "skill" and values.get("skill") == "video"


@dataclass(frozen=True)
class FilePin:
    path: Path
    sha256: str
    _identity: tuple | None = field(default=None, init=False, repr=False, compare=False)

    def verify(self) -> None:
        path = Path(self.path)
        if (not path.is_absolute() or path != path.resolve(strict=True) or
                any(p.is_symlink() for p in (path, *path.parents)) or
                not re.fullmatch(r"[a-f0-9]{64}", self.sha256)):
            raise ValueError("invalid_file_pin")
        before = path.stat()
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise ValueError("single_regular_pinned_file_required")
        identity = lambda value: (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns)
        if self._identity is not None and identity(before) != self._identity:
            raise ValueError("file_pin_identity_changed")
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            opened = os.fstat(stream.fileno())
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
            after = os.fstat(stream.fileno())
        if (identity(before) != identity(opened) or identity(opened) != identity(after) or
                identity(after) != identity(path.stat()) or digest.hexdigest() != self.sha256):
            raise ValueError("file_pin_mismatch")
        if self._identity is None:
            object.__setattr__(self, "_identity", identity(after))


class _PolicyRefused(ValueError):
    pass


class PinnedPolicy:
    """One ordered, single-use shell chain; ExactPolicy remains membership-only.

    Pins must cover every reviewed interpreter, executable, script, Skill and
    fixed input used by the commands. They are verified before permission and
    at completion; this does not eliminate the native host's check/start race.
    File-tool writes are always denied, including writes to a pinned input.
    Optional shell timeout is a positive integer capped at the native 120000ms
    foreground default; it never extends consume's separate whole-run deadline.
    Completion describes authorization/lifecycle only, never business success.
    """
    def __init__(self, directory: Path, commands: tuple[str, ...], pins: tuple[FilePin, ...], *, allow_skill: bool = False):
        self.directory = Path(directory)
        if (not self.directory.is_absolute() or not self.directory.is_dir() or
                self.directory != self.directory.resolve() or
                any(p.is_symlink() for p in (self.directory, *self.directory.parents)) or
                not isinstance(commands, tuple) or not 1 <= len(commands) <= 8 or
                any(not isinstance(c, str) or not c for c in commands) or len(set(commands)) != len(commands) or
                not isinstance(pins, tuple) or not 1 <= len(pins) <= 64 or
                any(not isinstance(p, FilePin) for p in pins) or len({p.path for p in pins}) != len(pins) or
                not isinstance(allow_skill, bool)):
            raise ValueError("invalid_pinned_policy")
        self.commands, self.pins, self.allow_skill = commands, pins, allow_skill
        self._exact = ExactPolicy(self.directory, frozenset(commands))
        self._position = 0
        self._pending = None
        self._reserved = {}
        self._observed = {}
        self._completed = set()
        self._skill_used = False
        self._started = False
        self.failed = False
        self._verify_pins()

    def _verify_pins(self) -> None:
        if (not self.directory.is_dir() or self.directory != self.directory.resolve() or
                any(p.is_symlink() for p in (self.directory, *self.directory.parents))):
            raise ValueError("pinned_directory_changed")
        for pin in self.pins:
            pin.verify()

    def begin(self) -> None:
        if self._started or self.failed or self._reserved or self._observed:
            raise ValueError("pinned_policy_already_used")
        self._verify_pins()
        self._started = True

    def _matches_next(self, tool, values) -> bool:
        if not isinstance(values, dict):
            return False
        if tool == "skill":
            return (self.allow_skill and not self._skill_used and self._position == 0 and
                    values == {"skill": "video"})
        return (tool == "run_shell_command" and self._position < len(self.commands) and
                set(values) <= {"command", "directory", "description", "is_background", "timeout"} and
                ("timeout" not in values or
                 (type(values["timeout"]) is int and 0 < values["timeout"] <= 120000)) and
                values.get("directory") in (None, ".", str(self.directory)) and
                ("is_background" not in values or values["is_background"] is False) and
                ("description" not in values or isinstance(values["description"], str)) and
                values.get("command") == self.commands[self._position] and
                self._exact.allows({"subtype": "can_use_tool", "tool_name": tool, "input": values}))

    def allows(self, request: dict) -> bool:
        try:
            self._verify_pins()
            if not isinstance(request, dict):
                raise ValueError("invalid_tool_request")
            tool_id, tool, values = request.get("tool_use_id"), request.get("tool_name"), request.get("input")
            if (self.failed or request.get("subtype") != "can_use_tool" or not isinstance(tool_id, str) or not tool_id or
                    self._pending is not None or tool_id in self._reserved or
                    not self._matches_next(tool, values) or
                    any(key != tool_id for key in self._observed if key not in self._completed) or
                    (tool_id in self._observed and self._observed[tool_id] != (tool, values))):
                raise ValueError("tool_not_authorized")
            self._reserved[tool_id] = (tool, dict(values))
            self._pending = tool_id
            return True
        except (OSError, ValueError, TypeError):
            self.failed = True
            return False

    @property
    def complete(self) -> bool:
        return (not self.failed and self._position == len(self.commands) and self._pending is None and
                set(self._observed) == set(self._reserved) == self._completed)

    def observe(self, event: dict, *, initialized: bool = True) -> None:
        """Called by consume itself for native tool-use/result lifecycle events."""
        try:
            if self.failed:
                raise ValueError("policy_already_refused")
            message = event.get("message", {})
            blocks = message.get("content", []) if isinstance(message, dict) else []
            if isinstance(blocks, list):
                for block in blocks:
                    if not isinstance(block, dict):
                        continue
                    if block.get("type") == "tool_use":
                        tool_id, tool, values = block.get("id"), block.get("name"), block.get("input")
                        if (not initialized or event.get("type") != "assistant" or message.get("role") != "assistant" or
                                not isinstance(tool_id, str) or not tool_id or tool_id in self._observed or
                                not self._matches_next(tool, values) or
                                (self._pending is not None and self._pending != tool_id) or
                                any(key not in self._completed for key in self._observed) or
                                (tool_id in self._reserved and self._reserved[tool_id] != (tool, values))):
                            raise ValueError("unexpected_native_tool_use")
                        self._verify_pins()
                        self._observed[tool_id] = (tool, dict(values))
                    elif block.get("type") == "tool_result":
                        tool_id = block.get("tool_use_id")
                        if (not initialized or event.get("type") != "user" or message.get("role") != "user" or
                                not isinstance(tool_id, str) or tool_id != self._pending or
                                tool_id not in self._observed or tool_id not in self._reserved or
                                tool_id in self._completed or (block.get("is_error") is not None and block.get("is_error") is not False)):
                            raise ValueError("unexpected_native_tool_result")
                        self._verify_pins()
                        self._completed.add(tool_id)
                        self._pending = None
                        if self._reserved[tool_id][0] == "skill":
                            self._skill_used = True
                        else:
                            self._position += 1
            if event.get("type") == "result":
                self._verify_pins()
                if (not initialized or not self.complete or event.get("subtype") != "success" or
                        (event.get("is_error") is not None and event.get("is_error") is not False)):
                    raise ValueError("incomplete_native_tool_chain")
        except (OSError, ValueError, TypeError):
            self.failed = True
            raise _PolicyRefused("固定许可链未完成或文件身份已变化") from None


def _strict_tools(policy: PinnedPolicy) -> list[str]:
    return ["run_shell_command"] + (["skill"] if policy.allow_skill else [])


def _strict_permissions(policy: PinnedPolicy) -> dict:
    return {"ask": ["Bash", "Edit"] + (["Skill"] if policy.allow_skill else []), "allow": []}


def create_isolated_settings(directory: Path, home: Path, runtime: Path, *, model: str = "deepseek-flash", env_key: str = "DEEPSEEK_API_KEY", strict_policy: PinnedPolicy | None = None) -> None:
    """Create only public configuration in fresh directories; never read a key."""
    root = directory.resolve()
    if strict_policy is not None and strict_policy.directory != root:
        raise ValueError("严格许可与宿主配置须使用同一目录")
    for path in (home, runtime):
        if path.is_symlink() or not path.resolve().is_relative_to(root) or path.resolve() == root:
            raise ValueError("宿主配置和运行目录必须位于本次工作区内")
        if path.exists():
            raise ValueError("请使用新的独立宿主目录，不读取或覆盖现有设置")
    if not re.fullmatch(r"[A-Z][A-Z0-9_]{1,63}", env_key):
        raise ValueError("只接受环境变量名称，不接受凭据内容")
    home.mkdir(parents=True)
    runtime.mkdir(parents=True)
    settings = {
        # Qwen Code 0.17.0 otherwise adds this metadata on first load, which
        # correctly invalidates a caller's pin of the unversioned input file.
        "$version": 4,
        "model": {"name": model},
        "modelProviders": {"openai": [{"id": model, "baseUrl": "https://api.deepseek.com", "envKey": env_key}]},
        "security": {"auth": {"selectedType": "openai"}},
        "permissions": {"ask": ["Bash", "Edit"], "allow": ["Skill(video)"]},
        "tools": {"core": ["run_shell_command", "write_file", "skill"]},
        "telemetry": {"enabled": False},
    }
    if strict_policy is not None:
        settings["permissions"] = _strict_permissions(strict_policy)
        settings["tools"] = {"core": _strict_tools(strict_policy)}
    (home / "settings.json").write_text(json.dumps(settings, ensure_ascii=False), encoding="utf-8")


def _terminate_group(process: subprocess.Popen) -> None:
    """Only the new process group owned by this invocation is ever signalled."""
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=0.5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=1)


def consume(arguments: list[str], prompt: str, policy: ExactPolicy | PinnedPolicy, *, seconds: float, on_event=None) -> dict:
    """Return in-memory evidence. Native max-wall-time is not a timeout guarantee."""
    if not 0 < seconds <= 300:
        raise ValueError("必须提供至多300秒的独立硬预算")
    if isinstance(policy, PinnedPolicy):
        policy.begin()
    started = time.monotonic()
    deadline = started + seconds
    process = subprocess.Popen(arguments, cwd=policy.directory, stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ, "out")
    selector.register(process.stderr, selectors.EVENT_READ, "err")
    initialize_id = uuid.uuid4().hex
    events, decisions = [], []
    buffer = b""
    stderr_digest = hashlib.sha256()
    stderr_bytes = 0
    stdout_bytes = 0
    initialized = False
    native_result = None
    status = "ended_without_result"

    def send(value):
        process.stdin.write((json.dumps(value, ensure_ascii=False) + "\n").encode())
        process.stdin.flush()

    try:
        send({"type": "control_request", "request_id": initialize_id,
              "request": {"subtype": "initialize", "timeout": {"canUseTool": 10000}}})
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                status = "hard_deadline"
                break
            for key, _ in selector.select(timeout=min(remaining, 0.2)):
                data = os.read(key.fileobj.fileno(), 65536)
                if not data:
                    selector.unregister(key.fileobj)
                    continue
                if key.data == "err":
                    stderr_bytes += len(data)
                    stderr_digest.update(data)
                    continue
                stdout_bytes += len(data)
                if stdout_bytes > 8 * 1024 * 1024:
                    raise ValueError("宿主事件流超过有限内存上限")
                buffer += data
                if len(buffer) > 4 * 1024 * 1024:
                    raise ValueError("宿主事件超过有限消息上限")
                while b"\n" in buffer:
                    line, buffer = buffer.split(b"\n", 1)
                    if not line.strip():
                        continue
                    event = json.loads(line)
                    if not isinstance(event, dict):
                        raise ValueError("宿主事件不是对象")
                    events.append(event)
                    if len(events) > 1000:
                        raise ValueError("宿主事件超过有限数量上限")
                    kind = event.get("type")
                    if kind == "control_response":
                        response = event.get("response", {})
                        if response.get("request_id") == initialize_id:
                            payload = response.get("response", {})
                            capabilities = payload.get("capabilities", {})
                            if response.get("subtype") != "success" or payload.get("subtype") != "initialize" or capabilities.get("can_handle_can_use_tool") is not True:
                                raise ValueError("宿主未确认原生SDK许可通道，未发送用户任务")
                            if initialized:
                                raise ValueError("重复宿主初始化回执")
                            initialized = True
                            send({"type": "user", "message": {"role": "user", "content": prompt}})
                    elif kind == "control_request":
                        request = event.get("request", {})
                        allowed = initialized and policy.allows(request)
                        decisions.append({"tool_use_id": request.get("tool_use_id"), "allowed": allowed})
                        send({"type": "control_response", "response": {"subtype": "success", "request_id": event["request_id"],
                              "response": {"behavior": "allow" if allowed else "deny", "message": "Only the exact authorized local action is permitted."}}})
                    elif kind == "result":
                        native_result = event
                        status = "native_result"
                        process.stdin.close()
                    if isinstance(policy, PinnedPolicy):
                        policy.observe(event, initialized=initialized)
                    if on_event:
                        on_event(event)
        if process.poll() is None and status != "hard_deadline":
            try:
                process.wait(timeout=max(0.01, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                status = "hard_deadline"
    except _PolicyRefused:
        status = "policy_refused"
    finally:
        _terminate_group(process)
        selector.close()
        for stream in (process.stdin, process.stdout, process.stderr):
            if not stream.closed:
                stream.close()
    if isinstance(policy, PinnedPolicy):
        try:
            policy._verify_pins()
        except (OSError, ValueError):
            policy.failed = True
            status = "policy_refused"
    result = {"status": status, "exit_code": process.returncode, "seconds": round(time.monotonic() - started, 3),
            "initialized": initialized, "events": events, "decisions": decisions, "result": native_result,
            "stderr_bytes": stderr_bytes, "stderr_sha256": stderr_digest.hexdigest()}
    if isinstance(policy, PinnedPolicy):
        result["policy_complete"] = policy.complete and native_result is not None and process.returncode == 0
    return result


def run_qwen(prompt: str, policy: ExactPolicy | PinnedPolicy, home: Path, runtime: Path, *, seconds: float = 60, model: str = "deepseek-flash", on_event=None) -> dict:
    """Use native Qwen with per-invocation directories and ask-before-execute tools."""
    root = policy.directory.resolve()
    if any(not path.resolve().is_relative_to(root) or path.resolve() == root for path in (home, runtime)):
        raise ValueError("宿主目录不属于本次工作区")
    core_tools = ["run_shell_command", "write_file", "skill"]
    max_calls = 30
    if isinstance(policy, PinnedPolicy):
        for path in (home, runtime, home / "settings.json"):
            if any(p.is_symlink() for p in (path, *path.parents)):
                raise ValueError("严格宿主配置不能使用符号链接")
        config_path = home / "settings.json"
        if not config_path.is_file() or config_path.stat().st_size > 1024 * 1024:
            raise ValueError("缺少有限的严格宿主配置")
        settings = json.loads(config_path.read_text(encoding="utf-8"))
        if (not isinstance(settings, dict) or
                set(settings) != {"$version", "model", "modelProviders", "security", "permissions", "tools", "telemetry"} or
                type(settings.get("$version")) is not int or settings["$version"] != 4 or
                settings.get("permissions") != _strict_permissions(policy) or
                settings.get("tools") != {"core": _strict_tools(policy)} or
                (root / ".qwen" / "settings.json").exists()):
            raise ValueError("严格宿主的实际工具和许可配置不匹配")
        core_tools = _strict_tools(policy)
        max_calls = len(policy.commands) + int(policy.allow_skill)
    arguments = ["env", f"QWEN_HOME={home}", f"QWEN_RUNTIME_DIR={runtime}", "qwen",
                 "--auth-type", "openai", "--model", model, "--input-format", "stream-json", "--output-format", "stream-json",
                 "--approval-mode", "default", "--no-chat-recording", "--max-tool-calls", str(max_calls), "--max-session-turns", "36",
                 "--core-tools", *core_tools]
    return consume(arguments, prompt, policy, seconds=seconds, on_event=on_event)
