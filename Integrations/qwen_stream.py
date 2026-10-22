#!/usr/bin/env python3
"""Bounded Qwen stream-json consumer; credentials remain with the native host.

SDK initialize must be the first message. Direct/user-first mode has no control
service and cannot deliver permission requests for tools configured to ask.
No transcript, prompt, tool output or credential is written by this module.
"""
from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import signal
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


def create_isolated_settings(directory: Path, home: Path, runtime: Path, *, model: str = "deepseek-flash", env_key: str = "DEEPSEEK_API_KEY") -> None:
    """Create only public configuration in fresh directories; never read a key."""
    root = directory.resolve()
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
        "model": {"name": model},
        "modelProviders": {"openai": [{"id": model, "baseUrl": "https://api.deepseek.com", "envKey": env_key}]},
        "security": {"auth": {"selectedType": "openai"}},
        "permissions": {"ask": ["Bash", "Edit"], "allow": ["Skill(video)"]},
        "tools": {"core": ["run_shell_command", "write_file", "skill"]},
        "telemetry": {"enabled": False},
    }
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


def consume(arguments: list[str], prompt: str, policy: ExactPolicy, *, seconds: float, on_event=None) -> dict:
    """Return in-memory evidence. Native max-wall-time is not a timeout guarantee."""
    if not 0 < seconds <= 300:
        raise ValueError("必须提供至多300秒的独立硬预算")
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
                    if on_event:
                        on_event(event)
        if process.poll() is None and status != "hard_deadline":
            try:
                process.wait(timeout=max(0.01, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                status = "hard_deadline"
    finally:
        _terminate_group(process)
        selector.close()
        for stream in (process.stdin, process.stdout, process.stderr):
            if not stream.closed:
                stream.close()
    return {"status": status, "exit_code": process.returncode, "seconds": round(time.monotonic() - started, 3),
            "initialized": initialized, "events": events, "decisions": decisions, "result": native_result,
            "stderr_bytes": stderr_bytes, "stderr_sha256": stderr_digest.hexdigest()}


def run_qwen(prompt: str, policy: ExactPolicy, home: Path, runtime: Path, *, seconds: float = 60, model: str = "deepseek-flash", on_event=None) -> dict:
    """Use native Qwen with per-invocation directories and ask-before-execute tools."""
    root = policy.directory.resolve()
    if any(not path.resolve().is_relative_to(root) or path.resolve() == root for path in (home, runtime)):
        raise ValueError("宿主目录不属于本次工作区")
    arguments = ["env", f"QWEN_HOME={home}", f"QWEN_RUNTIME_DIR={runtime}", "qwen",
                 "--auth-type", "openai", "--model", model, "--input-format", "stream-json", "--output-format", "stream-json",
                 "--approval-mode", "default", "--no-chat-recording", "--max-tool-calls", "30", "--max-session-turns", "36",
                 "--core-tools", "run_shell_command", "write_file", "skill"]
    return consume(arguments, prompt, policy, seconds=seconds, on_event=on_event)
