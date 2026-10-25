#!/usr/bin/env python3
"""Finite Codex 0.159.2 app-server client with client-owned dynamic-tool execution.

The model has no registered environment. Native command/file/network approvals
are always denied. Only this client's exact, hash-bound operations can spawn;
LocalProductionPolicy adds an explicit fresh-workspace local-only plan. This is
not an item.started observer pretending to be approval.
No function is called on import. run_codex explicitly starts a model session.
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
import sys
import time

from codex_events import (JsonLines, ProtocolError, is_account_status_notification,
                          is_turn_moderation_status, parse_object, safe_error)


VERSION = "codex-cli 0.159.2"
TOOL = "video_local_preflight"
_MCP_LIMIT = 32
_PROBE_ENV = {"PATH": "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"}
_PREVIEWS = frozenset(("workspaces create", "assets import", "evidence add", "projects create",
                       "script create", "edit apply", "render estimate", "render submit",
                       "backup create", "backup restore"))
_DISABLED_FEATURES = ("shell_tool", "unified_exec", "apply_patch_freeform", "js_repl", "code_mode",
                      "code_mode_host", "code_mode_only", "multi_agent", "collab", "apps", "plugins",
                      "hooks", "codex_hooks", "plugin_hooks", "browser_use", "computer_use", "view_image",
                      "image_generation", "memory_tool", "request_permissions", "request_permissions_tool")

# Generated offline by the installed 0.159.2 app-server, --experimental. These
# names permit safe diagnosis only; being official never grants execution.
# SHA256 of JSON(sorted(names), separators=(",", ":")):
_NOTIFICATION_ENUM_SHA256 = "ee39f0f9628b5c691bef3498fd3d0d7bea521c4f9fc76ff7902497af662f33e7"
_OFFICIAL_NOTIFICATIONS = frozenset("""
error thread/started thread/status/changed thread/archived thread/deleted
thread/unarchived thread/closed thread/reverted skills/changed thread/name/updated
thread/attachment/updated thread/goal/updated thread/goal/cleared thread/queue/changed
project/changed thread/project/updated thread/environment/connected thread/environment/disconnected
thread/settings/updated thread/tokenUsage/updated turn/started hook/started turn/completed
hook/completed turn/diff/updated turn/plan/updated item/started item/autoApprovalReview/started
item/autoApprovalReview/completed autoApprovalReview/strictReviewRequired item/completed
item/agentMessage/delta item/plan/delta command/exec/outputDelta process/outputDelta process/exited
item/commandExecution/outputDelta item/commandExecution/terminalInteraction item/fileChange/outputDelta
item/fileChange/patchUpdated serverRequest/resolved item/mcpToolCall/progress
mcpServer/oauthLogin/completed mcpServer/startupStatus/updated mcpServer/event/stream/notification
account/updated account/gatewayOAuth/changed account/rateLimits/updated app/list/updated
remoteControl/status/changed externalAgentConfig/import/progress externalAgentConfig/import/completed
fs/changed item/reasoning/summaryTextDelta item/reasoning/summaryPartAdded item/reasoning/textDelta
thread/compacted model/rerouted model/verification modelProvider/authRecoveryStarted
modelProvider/authRecoveryCompleted turn/moderationMetadata model/safetyBuffering/updated warning
guardianWarning deprecationNotice configWarning fuzzyFileSearch/sessionUpdated fuzzyFileSearch/sessionCompleted
thread/realtime/started thread/realtime/itemAdded thread/realtime/item/started
thread/realtime/item/transcript/delta thread/realtime/item/completed thread/realtime/transcript/delta
thread/realtime/transcript/done thread/realtime/outputAudio/delta thread/realtime/sdp
thread/realtime/error thread/realtime/closed windows/worldWritableWarning windowsSandbox/setupCompleted
account/login/completed
""".split())
_INFORMATIONAL_NOTIFICATIONS = frozenset(("thread/status/changed", "thread/tokenUsage/updated",
                                        "account/rateLimits/updated", "deprecationNotice"))
_REMOTE_STATUSES = frozenset(("disabled", "connecting", "connected", "errored"))


def _notification_diagnostic(method, params) -> dict:
    """Finite official name or opaque hash/length; no arbitrary names or params."""
    if not isinstance(method, str):
        return {"method_type": "non_string"}
    if method not in _OFFICIAL_NOTIFICATIONS:
        raw = method.encode()
        return {"method_bytes": len(raw), "method_sha256": hashlib.sha256(raw).hexdigest()}
    result = {"official_method": method}
    if isinstance(params, dict):
        if method in ("warning", "configWarning", "guardianWarning"):
            result["reason"] = safe_error({"message": params.get("summary", params.get("message", ""))},
                                          source="notification.warning")
        if (method == "remoteControl/status/changed" and isinstance(params.get("status"), str)
                and params["status"] in _REMOTE_STATUSES):
            result["remote_status"] = params["status"]
    return result


def _informational_notification(method, params) -> bool:
    if not isinstance(method, str) or not isinstance(params, dict):
        return False
    if method == "account/updated":
        return is_account_status_notification(params)
    if method in _INFORMATIONAL_NOTIFICATIONS:
        return True
    # A disabled status is a startup observation, not a remote execution grant.
    # Never ignore a connected/connecting/errored control channel or an attached
    # environment. Installation/server identities are neither logged nor used.
    return (method == "remoteControl/status/changed" and isinstance(params, dict)
            and params.get("status") == "disabled" and params.get("environmentId") is None
            and isinstance(params.get("installationId"), str) and isinstance(params.get("serverName"), str))


def _path(path: Path, *, exists=True) -> Path:
    path = Path(path)
    if not path.is_absolute() or str(path) != str(path.resolve(strict=exists)):
        raise ValueError("canonical_absolute_path_required")
    if any(p.is_symlink() for p in (path, *path.parents)):
        raise ValueError("symlink_path_refused")
    return path


def _file_digest(path: Path) -> str:
    path = _path(path)
    stat = path.stat()
    if not path.is_file() or stat.st_nlink != 1:
        raise ValueError("single_regular_file_required")
    with path.open("rb") as stream:
        digest = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
        return digest.hexdigest()


@dataclass(frozen=True)
class FilePin:
    path: Path
    sha256: str

    def verify(self):
        if not re.fullmatch(r"[a-f0-9]{64}", self.sha256) or _file_digest(self.path) != self.sha256:
            raise ValueError("file_pin_mismatch")


@dataclass(frozen=True)
class PinnedSkill:
    """One caller-reviewed complete video Skill, never a model-selected path."""

    directory: Path
    pins: tuple[FilePin, ...]

    def verify(self) -> dict:
        root = _path(self.directory)
        expected = {"SKILL.md", "LICENSE", "NOTICE", "agents/openai.yaml", "references/protocol.md"}
        directories = {"agents", "references"}
        if (not root.is_dir() or not isinstance(self.pins, tuple) or len(self.pins) != len(expected) or
                any(not isinstance(pin, FilePin) for pin in self.pins)):
            raise ProtocolError("video_skill_complete_pins_required")
        actual, total = {}, 0
        for count, path in enumerate(root.rglob("*"), 1):
            if count > len(expected) + len(directories):
                raise ProtocolError("video_skill_layout_refused")
            _path(path)
            relative = path.relative_to(root).as_posix()
            info = path.stat()
            if path.is_dir():
                if relative not in directories:
                    raise ProtocolError("video_skill_layout_refused")
                continue
            if not path.is_file() or info.st_nlink != 1 or relative not in expected:
                raise ProtocolError("video_skill_layout_refused")
            total += info.st_size
            if not 0 < info.st_size <= 256 * 1024 or total > 1024 * 1024:
                raise ProtocolError("video_skill_byte_bound")
            actual[path] = relative
        if set(actual.values()) != expected or {pin.path for pin in self.pins} != set(actual):
            raise ProtocolError("video_skill_complete_pins_required")
        for pin in self.pins:
            pin.verify()
        entry = root / "SKILL.md"
        if not entry.read_bytes().startswith(b"---\nname: video\n"):
            raise ProtocolError("video_skill_identity_refused")
        package = {actual[pin.path]: pin.sha256 for pin in self.pins}
        digest = hashlib.sha256(json.dumps(package, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
        return {"name": "video", "path": str(entry), "sha256": package["SKILL.md"], "package_sha256": digest}

    def input(self) -> dict:
        value = self.verify()
        return {"type": "skill", "name": "video", "path": value["path"]}


def _verified_model_catalog(pin: FilePin | None) -> str | None:
    """A caller-reviewed single-model Direct catalog, never arbitrary CLI options."""
    if pin is None:
        return None
    if not isinstance(pin, FilePin):
        raise ProtocolError("model_catalog_file_pin_required")
    path = _path(pin.path)
    info = path.stat()
    if not path.is_file() or info.st_nlink != 1:
        raise ProtocolError("model_catalog_regular_file_required")
    if not 1 <= info.st_size <= 512 * 1024:
        raise ProtocolError("model_catalog_byte_bound")
    pin.verify()
    with path.open("rb") as stream:
        data = stream.read(512 * 1024 + 1)
    if not 1 <= len(data) <= 512 * 1024:
        raise ProtocolError("model_catalog_byte_bound")
    value = parse_object(data)
    models = value.get("models")
    if set(value) != {"models"} or not isinstance(models, list) or len(models) != 1:
        raise ProtocolError("model_catalog_single_model_required")
    model = models[0]
    required = {"slug", "display_name", "supported_reasoning_levels", "shell_type",
                "visibility", "supported_in_api", "priority", "tool_mode"}
    if (not isinstance(model, dict) or not required <= set(model) or
            not isinstance(model["slug"], str) or
            re.fullmatch(r"[A-Za-z0-9._-]{1,100}", model["slug"]) is None or
            not isinstance(model["display_name"], str) or not 0 < len(model["display_name"]) <= 256 or
            not isinstance(model["supported_reasoning_levels"], list) or
            len(model["supported_reasoning_levels"]) > 32 or
            model["shell_type"] not in ("unified_exec", "disabled") or
            model["visibility"] not in ("list", "hide", "none") or
            type(model["supported_in_api"]) is not bool or type(model["priority"]) is not int or
            model["tool_mode"] != "direct"):
        raise ProtocolError("model_catalog_metadata_shape")
    if not 1 <= path.stat().st_size <= 512 * 1024:
        raise ProtocolError("model_catalog_byte_bound")
    pin.verify()
    return model["slug"]


@dataclass(frozen=True)
class Command:
    name: str
    argv: tuple[str, ...]
    cwd: Path
    pins: tuple[FilePin, ...]
    kind: str

    def verify(self):
        if not re.fullmatch(r"[a-z][a-z0-9_]{0,31}", self.name):
            raise ValueError("invalid_operation_name")
        _path(self.cwd)
        if not self.cwd.is_dir() or not self.pins:
            raise ValueError("invalid_operation_directory_or_pins")
        for pin in self.pins:
            pin.verify()
        pinned = {str(pin.path) for pin in self.pins}
        if self.kind == "discovery":
            if (len(self.argv) != 4 or self.argv[2] != "--binary" or
                    Path(self.argv[1]).name != "discover.py" or any(self.argv[i] not in pinned for i in (0, 1, 3))):
                raise ValueError("discovery_argv_refused")
        elif self.kind == "preflight":
            # One fixed order, no repeated flags, stdin, shell expansion or extra options.
            if (len(self.argv) != 8 or self.argv[1] != "--workspace" or
                    self.argv[5] != "--input" or self.argv[7] != "--dry-run" or
                    " ".join(self.argv[3:5]) not in _PREVIEWS or
                    self.argv[0] not in pinned or self.argv[6] not in pinned):
                raise ValueError("preflight_argv_refused")
            for index, exists in ((2, False), (6, True)):
                if not _path(Path(self.argv[index]), exists=exists).is_relative_to(self.cwd):
                    raise ValueError("preflight_path_outside_directory")
        else:
            raise ValueError("operation_kind_refused")

    def arguments(self) -> dict:
        return {"operation": self.name, "cwd": str(self.cwd), "argv": list(self.argv)}


class Policy:
    def __init__(self, commands: tuple[Command, ...]):
        if not 1 <= len(commands) <= 8 or len({c.name for c in commands}) != len(commands):
            raise ValueError("one_to_eight_distinct_operations_required")
        for command in commands:
            command.verify()
        self.commands = commands
        self.directory = commands[0].cwd
        if any(c.cwd != self.directory for c in commands):
            raise ValueError("one_exact_directory_required")
        self.used = 0

    def claim(self, arguments) -> Command:
        if self.used >= len(self.commands) or not isinstance(arguments, dict):
            raise ProtocolError("operation_not_authorized")
        command = self.commands[self.used]
        if arguments != command.arguments() or set(arguments) != {"operation", "cwd", "argv"}:
            raise ProtocolError("operation_not_authorized")
        # Reverify immediately before spawning. Files are never supplied by the model.
        command.verify()
        self.used += 1
        return command

    def spec(self):
        return {"type": "function", "name": TOOL,
                "description": "Run one explicitly authorized local video discovery or dry-run. Exact argv/cwd only; no shell, writes, network, login, purchase, or retries.",
                "inputSchema": {"type": "object", "properties": {
                    "operation": {"type": "string", "enum": [c.name for c in self.commands]},
                    "cwd": {"type": "string", "const": str(self.directory)},
                    "argv": {"type": "array", "items": {"type": "string"}}},
                    "required": ["operation", "cwd", "argv"], "additionalProperties": False}}


def _stop(process):
    # Every caller created this exact process group with start_new_session=True.
    # Its leader can exit while descendants still own stdout/stderr. Leader
    # returncode is therefore not evidence that the owned group has finished.
    result = {"term": "not_attempted", "kill": "not_attempted", "leader_reaped": False}
    for name, value in (("term", signal.SIGTERM), ("kill", signal.SIGKILL)):
        try:
            os.killpg(process.pid, value)
            result[name] = "requested"
        except ProcessLookupError:
            result[name] = "group_absent"
        except PermissionError:
            result[name] = "permission_denied"
        except OSError:
            result[name] = "signal_failed"
        if name == "term":
            # A leader wait is not a grace period for its surviving descendants.
            # No unrelated PID, process scan, or alternate kill executable.
            time.sleep(.2)
    # Always attempt to reap the leader, independently of either signal result.
    try:
        process.wait(timeout=1)
        result["leader_reaped"] = True
    except (subprocess.TimeoutExpired, OSError):
        pass
    # Darwin can refuse KILL while the exited leader is still unreaped. Reaping
    # alone proves nothing about descendants: only an independent ESRCH from
    # this exact owned group proves absence. Existing, EPERM, and unknown stay
    # failed, and the original KILL refusal is retained in the receipt.
    if result["leader_reaped"] and result["term"] == "requested" and result["kill"] == "permission_denied":
        try:
            os.killpg(process.pid, 0)
            result["post_reap_group"] = "present"
        except ProcessLookupError:
            result["post_reap_group"] = "absent"
        except PermissionError:
            result["post_reap_group"] = "permission_denied"
        except OSError:
            result["post_reap_group"] = "probe_failed"
    result["passed"] = (result["leader_reaped"] and
                        (all(result[name] in ("requested", "group_absent") for name in ("term", "kill")) or
                         result.get("post_reap_group") == "absent"))
    return result


def _execute_argv(argv: tuple[str, ...], cwd: Path, *, deadline: float, seconds: float = 20.) -> tuple[dict, bytes]:
    """Shared bounded process owner; output stays in the client, never the model."""
    if not 0 < seconds <= 63:
        raise ValueError("bounded_local_command_seconds_required")
    remaining = min(seconds, deadline - time.monotonic())
    if remaining <= 0:
        raise ProtocolError("command_deadline")
    # Do not forward inherited API keys, proxy secrets, shell startup settings or HOME.
    process = subprocess.Popen(argv, cwd=cwd, shell=False, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
                               env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"})
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ, "out")
    selector.register(process.stderr, selectors.EVENT_READ, "err")
    output = bytearray()
    stderr_hash = hashlib.sha256()
    stderr_bytes = 0
    local_deadline = time.monotonic() + remaining
    failure = None
    try:
        while selector.get_map():
            if time.monotonic() >= local_deadline:
                raise ProtocolError("command_deadline")
            for key, _ in selector.select(min(.1, local_deadline - time.monotonic())):
                data = os.read(key.fileobj.fileno(), 65536)
                if not data:
                    selector.unregister(key.fileobj)
                elif key.data == "out":
                    output.extend(data)
                else:
                    stderr_bytes += len(data)
                    stderr_hash.update(data)
                if len(output) + stderr_bytes > 1024 * 1024:
                    raise ProtocolError("command_output_bound")
        process.wait(timeout=max(.001, local_deadline - time.monotonic()))
    except BaseException as error:
        failure = error
        raise
    finally:
        try:
            cleanup = _stop(process)
        finally:
            selector.close()
            process.stdout.close()
            process.stderr.close()
        if failure is not None:
            failure.cleanup = cleanup
    summary = {"exit_code": process.returncode, "stdout_bytes": len(output),
               "stdout_sha256": hashlib.sha256(output).hexdigest(), "stderr_bytes": stderr_bytes,
               "stderr_sha256": stderr_hash.hexdigest(),
               "cleanup": cleanup,
               "argv_sha256": hashlib.sha256(json.dumps(argv, separators=(",", ":")).encode()).hexdigest()}
    summary["passed"] = process.returncode == 0 and stderr_bytes == 0 and cleanup["passed"]
    return summary, bytes(output)


def execute(command: Command, *, deadline: float) -> dict:
    """Client-owned bounded argv execution. Raw stdout/stderr never leave here."""
    if getattr(command, "kind", None) == "local_production":
        # The separately reviewed policy materializes argv and bound inputs itself.
        from codex_production import LocalInvocation
        if not isinstance(command, LocalInvocation):
            raise ValueError("local_invocation_required")
        return command.execute(deadline=deadline)
    command.verify()
    summary, output = _execute_argv(command.argv, command.cwd, deadline=deadline)
    summary["operation"] = command.name
    ok = summary["passed"]
    if command.kind == "discovery":
        text = output.decode("utf-8", errors="strict").strip()
        match = re.fullmatch(r"video schema_version=1\.0 commands=([1-9][0-9]{0,3}) schema_sha256=([a-f0-9]{64})", text)
        ok = ok and match is not None
        if match:
            summary.update(commands=int(match[1]), schema_sha256=match[2])
    else:
        value = parse_object(bytes(output))
        ok = ok and value.get("schema_version") == "1.0" and value.get("ok") is True and value.get("state") == "dry_run"
        # No project data, CLI error text, request inputs, or machine output is echoed.
        summary["dry_run"] = ok
    summary["passed"] = ok
    return summary


def _mcp_names(names) -> frozenset[str]:
    # Override paths use TOML bare keys. Dotted/quoted/arbitrary names must not
    # select another setting, and are refused rather than escaped or guessed.
    if (not isinstance(names, (tuple, list, set, frozenset)) or len(names) > _MCP_LIMIT or
            any(not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", name) for name in names) or
            len(set(names)) != len(names)):
        raise ProtocolError("unsafe_mcp_name_set")
    return frozenset(names)


def server_arguments(executable: str = "codex", *, disabled_mcp_names=(), model_catalog: FilePin | None = None) -> list[str]:
    args = [executable]
    for feature in _DISABLED_FEATURES:
        args += ["-c", f"features.{feature}=false"]
    # An empty table merges with configured servers in 0.159.2; it does not
    # clear them. Explicitly disable every discovered key for this invocation.
    for name in sorted(_mcp_names(disabled_mcp_names)):
        args += ["-c", f"mcp_servers.{name}.enabled=false"]
    if model_catalog is not None:
        _verified_model_catalog(model_catalog)
        args += ["-c", "model_catalog_json=" + json.dumps(str(model_catalog.path))]
    args += ["-c", 'web_search="disabled"',
             "-c", 'history.persistence="none"', "-c", "analytics.enabled=false",
             "app-server", "--stdio"]
    return args


def _project_mcp(output: bytes) -> dict[str, bool]:
    """Parse only in memory. Config, transport, environment and auth never leave."""
    if len(output) > 1024 * 1024:
        raise ProtocolError("mcp_configuration_bound")
    wrapped = parse_object(b'{"data":' + output + b'}')
    if set(wrapped) != {"data"}:
        raise ProtocolError("mcp_configuration_shape")
    entries = wrapped["data"]
    if not isinstance(entries, list) or len(entries) > _MCP_LIMIT:
        raise ProtocolError("mcp_configuration_bound")
    projection = {}
    for entry in entries:
        if not isinstance(entry, dict) or type(entry.get("enabled")) is not bool:
            raise ProtocolError("mcp_configuration_shape")
        name = entry.get("name")
        _mcp_names((name,))
        if name in projection:
            raise ProtocolError("duplicate_mcp_name")
        projection[name] = entry["enabled"]
    return projection


def _mcp_projection(arguments: list[str], directory: Path, *, deadline: float) -> dict[str, bool]:
    """Bounded local official CLI listing, same cwd, minimal inherited state."""
    _path(directory)
    local_deadline = min(deadline, time.monotonic() + 10)
    if local_deadline <= time.monotonic():
        raise ProtocolError("mcp_configuration_deadline")
    process = subprocess.Popen(arguments, cwd=directory, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
                               env=dict(_PROBE_ENV))
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ, "out")
    selector.register(process.stderr, selectors.EVENT_READ, "err")
    output, stderr_bytes = bytearray(), 0
    failure = None
    try:
        while selector.get_map():
            remaining = local_deadline - time.monotonic()
            if remaining <= 0:
                raise ProtocolError("mcp_configuration_deadline")
            for key, _ in selector.select(min(.1, remaining)):
                data = os.read(key.fileobj.fileno(), 65536)
                if not data:
                    selector.unregister(key.fileobj)
                elif key.data == "out":
                    output.extend(data)
                else:
                    stderr_bytes += len(data)
                if len(output) + stderr_bytes > 1024 * 1024:
                    raise ProtocolError("mcp_configuration_bound")
        process.wait(timeout=max(.001, local_deadline - time.monotonic()))
        if process.returncode != 0 or stderr_bytes:
            raise ProtocolError("mcp_configuration_unavailable")
        return _project_mcp(bytes(output))
    except BaseException as error:
        failure = error
        raise
    finally:
        try:
            cleanup = _stop(process)
        finally:
            selector.close()
            process.stdout.close()
            process.stderr.close()
        if failure is not None:
            failure.cleanup = cleanup
        elif not cleanup["passed"]:
            error = ProtocolError("mcp_configuration_cleanup_failed")
            error.cleanup = cleanup
            raise error


def isolate_mcp(executable: str, directory: Path, *, deadline: float,
                model_catalog: FilePin | None = None) -> tuple[list[str], frozenset[str]]:
    """No global writes: discover keys, override each, and verify exact readback."""
    options = {} if model_catalog is None else {"model_catalog": model_catalog}
    arguments = server_arguments(executable, **options)
    before = _mcp_projection(arguments[:-2] + ["mcp", "list", "--json"], directory, deadline=deadline)
    names = _mcp_names(tuple(before))
    arguments = server_arguments(executable, disabled_mcp_names=names, **options)
    after = _mcp_projection(arguments[:-2] + ["mcp", "list", "--json"], directory, deadline=deadline)
    if set(after) != names or any(value is not False for value in after.values()):
        raise ProtocolError("mcp_configuration_not_isolated")
    _verified_model_catalog(model_catalog)
    return arguments, names


def _verify_mcp_inventory(result: dict, disabled_names: frozenset[str]):
    # Official status lists configured entries even when disabled. runtimeStatus
    # null alone proves nothing; require disabled config readback AND zero
    # capabilities/handshake metadata, with no active state or pagination.
    if set(result) - {"data", "nextCursor"} or result.get("nextCursor") is not None:
        raise ProtocolError("mcp_inventory_incomplete")
    entries = result.get("data")
    if not isinstance(entries, list) or len(entries) > _MCP_LIMIT:
        raise ProtocolError("mcp_inventory_shape")
    names = set()
    allowed = {"name", "authStatus", "tools", "resources", "resourceTemplates", "runtimeStatus",
               "serverCapabilities", "serverInfo", "toolsError", "httpOrigin", "pluginId"}
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) - allowed:
            raise ProtocolError("mcp_inventory_shape")
        name = entry.get("name")
        _mcp_names((name,))
        if name not in disabled_names or name in names:
            raise ProtocolError("mcp_inventory_name_mismatch")
        names.add(name)
        if (entry.get("tools") != {} or entry.get("resources") != [] or entry.get("resourceTemplates") != [] or
                entry.get("runtimeStatus") not in (None, "disabled", "notStarted") or
                any(entry.get(key) is not None for key in ("serverCapabilities", "serverInfo", "toolsError")) or
                entry.get("authStatus") not in ("unknown", "unsupported", "notLoggedIn", "bearerToken", "oAuth")):
            raise ProtocolError("mcp_inventory_not_isolated")
    if names != disabled_names:
        raise ProtocolError("mcp_inventory_name_mismatch")


def thread_parameters(policy: Policy, *, model_catalog: FilePin | None = None) -> dict:
    params = {"cwd": str(policy.directory), "approvalPolicy": "on-request", "sandbox": "read-only",
              "ephemeral": True, "environments": [], "runtimeWorkspaceRoots": [], "dynamicTools": [policy.spec()]}
    # Loading a catalog changes metadata, not the configured default model.
    # Select only its already reviewed sole model; never accept an arbitrary slug.
    model = _verified_model_catalog(model_catalog)
    if model is not None:
        params["model"] = model
    return params


class Broker:
    """One initialized thread and one finite turn. All other requests fail closed."""

    def __init__(self, policy: Policy, prompt: str, *, deadline: float, disabled_mcp_names=(), initialize_only=False,
                  model_catalog: FilePin | None = None, skill: PinnedSkill | None = None):
        if not isinstance(prompt, str) or not 0 < len(prompt.encode()) <= 65536:
            raise ValueError("bounded_nonempty_prompt_required")
        if policy.used:
            raise ValueError("fresh_policy_required")
        self.policy, self.prompt, self.deadline = policy, prompt, deadline
        self.model_catalog = model_catalog
        if skill is not None and not isinstance(skill, PinnedSkill):
            raise ProtocolError("video_skill_pin_required")
        self.skill = skill
        self.skill_identity = skill.verify() if skill is not None else None
        self.skill_submitted = False
        self.skill_catalog_verified = False
        self.expected_catalog_model = _verified_model_catalog(model_catalog)
        self.catalog_model_acknowledged = False
        self.catalog_model_receipt = None
        self.disabled_mcp_names = _mcp_names(disabled_mcp_names)
        self.initialize_only = initialize_only
        self.mcp_inventory_verified = False
        self.phase = "initialize"
        self.thread_id = self.turn_id = None
        self.items = {}
        self.calls = {}
        self.completed_items = set()
        self.agent_messages = []
        self.rpc_responses = set()
        self.errors, self.denials, self.executions = [], [], []
        self.command_cleanup_failures = []
        self.terminal = None
        self.event_types = {}
        self.unsupported_notifications = []
        self.unsupported_notification_count = 0

    @staticmethod
    def request(identity, method, params):
        return {"id": identity, "method": method, "params": params}

    def initialize(self):
        return self.request(1, "initialize", {"clientInfo": {"name": "video_preflight", "version": "1.0.0"},
                                             "capabilities": {"experimentalApi": True}})

    def _turn(self, identity):
        if not isinstance(identity, str) or not identity or len(identity) > 128:
            raise ProtocolError("invalid_turn_identity")
        if self.turn_id is not None and identity != self.turn_id:
            raise ProtocolError("turn_identity_changed")
        self.turn_id = identity

    def receive(self, message: dict) -> list[dict]:
        _verified_model_catalog(self.model_catalog)
        if self.skill is not None:
            self.skill.verify()
        method, identity = message.get("method"), message.get("id")
        params = message.get("params", {})
        if identity is None and isinstance(method, str) and method in _OFFICIAL_NOTIFICATIONS:
            self.event_types[method] = self.event_types.get(method, 0) + 1
        if self.terminal:
            if "id" not in message and _informational_notification(method, params):
                return []
            raise ProtocolError("event_after_turn_terminal")
        if not method:
            if (type(identity) is not int or identity not in ((1, 2, 3, 4, 5) if self.skill is not None else (1, 2, 3, 4)) or
                    identity in self.rpc_responses):
                raise ProtocolError("unexpected_rpc_response")
            self.rpc_responses.add(identity)
            if "error" in message:
                self.errors.append(safe_error(message["error"], source="rpc.error"))
                self.terminal = "failed"
                return []
            result = message.get("result")
            if not isinstance(result, dict):
                raise ProtocolError("rpc_result_missing")
            if identity == 1 and self.phase == "initialize":
                self.phase = "mcp_inventory"
                return [{"method": "initialized", "params": {}},
                        self.request(4, "mcpServerStatus/list", {"limit": _MCP_LIMIT, "detail": "toolsAndAuthOnly"})]
            if identity == 4 and self.phase == "mcp_inventory":
                _verify_mcp_inventory(result, self.disabled_mcp_names)
                self.mcp_inventory_verified = True
                if self.initialize_only:
                    self.terminal = "mcp_isolation_verified"
                    return []
                if self.skill is not None:
                    self.phase = "skill_inventory"
                    return [self.request(5, "skills/list", {"cwds": [str(self.policy.directory)], "forceReload": True})]
                self.phase = "thread"
                return [self.request(2, "thread/start", thread_parameters(self.policy, model_catalog=self.model_catalog))]
            if identity == 5 and self.phase == "skill_inventory":
                entries = result.get("data")
                if (set(result) != {"data"} or not isinstance(entries, list) or len(entries) != 1 or
                        not isinstance(entries[0], dict) or set(entries[0]) != {"cwd", "skills", "errors"} or
                        entries[0]["cwd"] != str(self.policy.directory) or entries[0]["errors"] != [] or
                        not isinstance(entries[0]["skills"], list) or len(entries[0]["skills"]) > 256):
                    raise ProtocolError("video_skill_inventory_refused")
                matches = [entry for entry in entries[0]["skills"] if isinstance(entry, dict) and
                           entry.get("path") == self.skill_identity["path"]]
                if len(matches) != 1 or matches[0].get("name") != "video" or matches[0].get("enabled") is not True:
                    raise ProtocolError("video_skill_not_enabled_at_pinned_path")
                self.skill.verify()
                self.skill_catalog_verified = True
                self.phase = "thread"
                return [self.request(2, "thread/start", thread_parameters(self.policy, model_catalog=self.model_catalog))]
            if identity == 2 and self.phase == "thread":
                if self.expected_catalog_model is not None:
                    actual = result.get("model")
                    received = actual if isinstance(actual, str) and re.fullmatch(r"[A-Za-z0-9._-]{1,100}", actual) else None
                    self.catalog_model_receipt = {"expected": self.expected_catalog_model, "received": received,
                                                  "selection": "reviewed_catalog_thread_parameter"}
                if self.expected_catalog_model is not None and result.get("model") != self.expected_catalog_model:
                    raise ProtocolError("catalog_model_not_acknowledged")
                self.catalog_model_acknowledged = self.expected_catalog_model is not None
                thread = result.get("thread", {})
                self.thread_id = thread.get("id")
                if (not isinstance(self.thread_id, str) or not self.thread_id or len(self.thread_id) > 128 or
                        result.get("cwd") != str(self.policy.directory) or result.get("approvalPolicy") != "on-request" or
                        result.get("sandbox", {}).get("type") != "readOnly" or result.get("runtimeWorkspaceRoots") != []):
                    raise ProtocolError("thread_boundary_not_acknowledged")
                self.phase = "turn"
                inputs = [{"type": "text", "text": self.prompt}]
                if self.skill is not None:
                    inputs.append(self.skill.input())
                    self.skill_submitted = True
                return [self.request(3, "turn/start", {"threadId": self.thread_id, "environments": [],
                                                       "runtimeWorkspaceRoots": [],
                                                       "input": inputs})]
            if identity == 3 and self.phase == "turn":
                self._turn(result.get("turn", {}).get("id"))
                return []
            raise ProtocolError("rpc_response_out_of_order")
        if not isinstance(method, str) or len(method) > 128:
            if identity is None:
                self._reject_notification(method, params)
            raise ProtocolError("invalid_method")
        if not isinstance(params, dict):
            raise ProtocolError("invalid_params")
        if identity is None and method == "turn/moderationMetadata":
            if (self.phase != "turn" or not is_turn_moderation_status(
                    params, thread_id=self.thread_id, turn_id=self.turn_id)):
                self._reject_notification(method, params)
                raise ProtocolError("invalid_turn_moderation_status")
            return []
        if identity is not None:
            if type(identity) not in (int, str) or isinstance(identity, str) and len(identity) > 128:
                raise ProtocolError("invalid_request_id")
            if method != "item/tool/call":
                # Never let a native command, patch, network or permission approval run.
                if method in ("item/commandExecution/requestApproval", "item/fileChange/requestApproval"):
                    self.denials.append("native_approval_refused")
                    self.terminal = "denied"
                    return [{"id": identity, "result": {"decision": "decline"}}]
                self.denials.append("unsupported_request_refused")
                self.terminal = "denied"
                return [{"id": identity, "error": {"code": -32601, "message": "Unsupported request; no action executed."}}]
            try:
                call = params.get("callId")
                if (self.phase != "turn" or self.turn_id is None or params.get("threadId") != self.thread_id or
                        params.get("turnId") != self.turn_id or params.get("tool") != TOOL or params.get("namespace") is not None or
                        set(params) - {"callId", "threadId", "turnId", "tool", "namespace", "arguments"} or
                        not isinstance(call, str) or call not in self.items or call in self.calls or
                        self.items[call] != params.get("arguments")):
                    raise ProtocolError("tool_identity_refused")
                command = self.policy.claim(params.get("arguments"))
                receipt = execute(command, deadline=self.deadline)
                self.executions.append(receipt)
                self.calls[call] = receipt["passed"]
                response = {"id": identity, "result": {"success": receipt["passed"],
                            "contentItems": [{"type": "inputText", "text": json.dumps(receipt, separators=(",", ":"))}]}}
                if not receipt["passed"]:
                    self.terminal = "command_failed"
                return [response]
            except (ValueError, OSError, subprocess.SubprocessError) as error:
                cleanup = getattr(error, "cleanup", None)
                if cleanup is not None and not cleanup["passed"]:
                    self.command_cleanup_failures.append(cleanup)
                self.denials.append(type(error).__name__)
                self.terminal = "denied"
                return [{"id": identity, "result": {"success": False, "contentItems": [
                    {"type": "inputText", "text": "Exact operation denied before execution, or execution did not complete. No retry."}]}}]
        # Handle only explicitly supported notifications. The larger official
        # enum above is diagnostic provenance, not a permissive dispatch list.
        known = {"thread/started", "thread/status/changed", "turn/started", "turn/completed", "error",
                 "item/started", "item/completed", "item/agentMessage/delta", "item/reasoning/summaryTextDelta",
                 "item/reasoning/summaryPartAdded", "item/reasoning/textDelta", "thread/tokenUsage/updated",
                 "account/rateLimits/updated", "serverRequest/resolved"}
        if _informational_notification(method, params):
            return []
        if method not in known:
            self._reject_notification(method, params)
            raise ProtocolError("unsupported_notification")
        if self.phase in ("initialize", "mcp_inventory", "skill_inventory"):
            raise ProtocolError("notification_before_mcp_inventory")
        if method in ("turn/started", "turn/completed", "item/started", "item/completed", "error"):
            if params.get("threadId") != self.thread_id:
                raise ProtocolError("notification_thread_mismatch")
        if method == "turn/started":
            self._turn(params.get("turn", {}).get("id"))
        elif method == "error":
            self.errors.append(safe_error(params.get("error"), source="app-server.error"))
            # No automatic retry, including willRetry=true. Parent chooses a changed condition.
            self.terminal = "failed"
        elif method in ("item/started", "item/completed"):
            if params.get("turnId") != self.turn_id:
                raise ProtocolError("notification_turn_mismatch")
            item = params.get("item", {})
            item_id, kind = item.get("id"), item.get("type")
            if kind == "dynamicToolCall":
                if item.get("tool") != TOOL or not isinstance(item_id, str):
                    raise ProtocolError("unexpected_dynamic_item")
                if method == "item/started":
                    if item_id in self.items:
                        raise ProtocolError("duplicate_tool_start")
                    self.items[item_id] = item.get("arguments")
                elif (item_id not in self.calls or item_id in self.completed_items or not self.calls[item_id] or
                      item.get("status") != "completed" or item.get("success") is not True):
                    raise ProtocolError("unmatched_tool_completion")
                else:
                    self.completed_items.add(item_id)
            elif kind not in ("agentMessage", "reasoning", "userMessage", "hookPrompt"):
                raise ProtocolError("native_execution_item_refused")
            elif kind == "agentMessage" and method == "item/completed":
                text = item.get("text")
                if not isinstance(text, str) or len(text.encode()) > 65536 or len(self.agent_messages) >= 64:
                    raise ProtocolError("bounded_agent_message_required")
                raw = text.encode()
                self.agent_messages.append({"bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest()})
        elif method == "turn/completed":
            turn = params.get("turn", {})
            self._turn(turn.get("id"))
            status = turn.get("status")
            if status not in ("completed", "failed", "interrupted"):
                raise ProtocolError("invalid_turn_terminal")
            self.terminal = status
            if turn.get("error"):
                self.errors.append(safe_error(turn["error"], source="turn.error"))
        return []

    def _reject_notification(self, method, params):
        self.unsupported_notification_count += 1
        if len(self.unsupported_notifications) < 8:
            self.unsupported_notifications.append(_notification_diagnostic(method, params))

    def summary(self):
        expected_responses = {1, 2, 3, 4, 5} if self.skill is not None else {1, 2, 3, 4}
        passed = (self.terminal == "completed" and self.rpc_responses == expected_responses and self.mcp_inventory_verified and
                  (self.skill is None or self.skill_catalog_verified) and
                  not self.errors and not self.denials and self.policy.used == len(self.policy.commands) and
                  len(self.executions) == len(self.calls) == len(self.items) == len(self.completed_items) == len(self.policy.commands) and
                  all(r["passed"] for r in self.executions))
        result = {"passed": passed, "status": self.terminal or "ended_without_turn", "errors": self.errors,
                "denials": self.denials, "executions": self.executions, "event_types": self.event_types,
                "command_cleanup_failures": self.command_cleanup_failures,
                "unsupported_notifications": self.unsupported_notifications,
                "unsupported_notification_count": self.unsupported_notification_count,
                "execution_control": "client_dynamic_tools_exact_argv", "host_environments": [],
                "mcp_inventory_verified": self.mcp_inventory_verified, "mcp_disabled_count": len(self.disabled_mcp_names),
                  "initialize_only": self.initialize_only,
                  "agent_messages": self.agent_messages,
                "native_approvals_accepted": 0}
        if self.model_catalog is not None:
            result["catalog_model_acknowledged"] = self.catalog_model_acknowledged
            result["catalog_model_receipt"] = self.catalog_model_receipt
        if self.skill_identity is not None:
            result["skill_input"] = dict(self.skill_identity, submitted=self.skill_submitted,
                                         catalog_verified=self.skill_catalog_verified)
        return result


def _consume(arguments: list[str], prompt: str, policy: Policy, *, seconds: float,
              disabled_mcp_names=(), initialize_only=False, model_catalog: FilePin | None = None,
              skill: PinnedSkill | None = None) -> dict:
    if not 0 < seconds <= 120:
        raise ValueError("one_to_120_seconds_required")
    started = time.monotonic()
    broker = Broker(policy, prompt, deadline=started + seconds, disabled_mcp_names=disabled_mcp_names,
                    initialize_only=initialize_only, model_catalog=model_catalog, skill=skill)
    _verified_model_catalog(model_catalog)
    process = subprocess.Popen(arguments, cwd=policy.directory, stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ, "out")
    selector.register(process.stderr, selectors.EVENT_READ, "err")
    os.set_blocking(process.stdin.fileno(), False)
    outgoing = bytearray()
    lines = JsonLines()
    stderr_hash, stderr_bytes = hashlib.sha256(), 0
    stdin_closed = False
    eof = {"out": False, "err": False}
    drain_deadline = None

    def queue(message):
        outgoing.extend((json.dumps(message, ensure_ascii=False, separators=(",", ":")) + "\n").encode())
        if len(outgoing) > 256 * 1024:
            raise ProtocolError("outbound_bound")
        if process.stdin not in [key.fileobj for key in selector.get_map().values()]:
            selector.register(process.stdin, selectors.EVENT_WRITE, "in")

    queue(broker.initialize())
    try:
        while selector.get_map():
            _verified_model_catalog(model_catalog)
            if skill is not None:
                skill.verify()
            if broker.terminal and not outgoing:
                if broker.terminal not in ("completed", "mcp_isolation_verified"):
                    break
                if not stdin_closed:
                    process.stdin.close()
                    stdin_closed = True
                    drain_deadline = min(broker.deadline, time.monotonic() + 2)
                if time.monotonic() >= drain_deadline:
                    break
            remaining = broker.deadline - time.monotonic()
            if remaining <= 0:
                if not broker.terminal:
                    broker.terminal = "hard_deadline"
                break
            if drain_deadline is not None:
                remaining = min(remaining, max(0, drain_deadline-time.monotonic()))
            for key, _ in selector.select(min(.1, remaining)):
                if key.data == "in":
                    written = os.write(process.stdin.fileno(), outgoing[:4096])
                    del outgoing[:written]
                    if not outgoing:
                        selector.unregister(process.stdin)
                    continue
                data = os.read(key.fileobj.fileno(), 65536)
                if not data:
                    selector.unregister(key.fileobj)
                    eof[key.data] = True
                if key.data == "err":
                    stderr_bytes += len(data)
                    stderr_hash.update(data)
                    if stderr_bytes > 1024 * 1024:
                        raise ProtocolError("stderr_bound")
                    continue
                for message in lines.feed(data, eof=not data):
                    for response in broker.receive(message):
                        queue(response)
                if not data and not broker.terminal:
                    broker.terminal = "ended_without_turn"
        _verified_model_catalog(model_catalog)
        if skill is not None:
            skill.verify()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        broker.errors.append({"source": "client", "protocol_code": str(error) if isinstance(error, ProtocolError) else type(error).__name__})
        broker.terminal = "client_failed"
    finally:
        try:
            # A completed turn can close the official stdio transport normally.
            # This short drain shares the original parent deadline; a persistent
            # server or any failure still uses the original owned-group cleanup.
            if stdin_closed and all(eof.values()) and drain_deadline is not None:
                try:
                    process.wait(timeout=max(.001, min(drain_deadline, broker.deadline)-time.monotonic()))
                except subprocess.TimeoutExpired:
                    pass
            exit_code = process.poll()
            group_absent = False
            if exit_code is not None:
                try:
                    os.killpg(process.pid, 0)
                except ProcessLookupError:
                    group_absent = True
                except OSError:
                    pass
            native_exit = {"stdin_closed": stdin_closed, "stdout_eof": eof["out"], "stderr_eof": eof["err"],
                           "observed_before_cleanup": exit_code is not None, "exit_code": exit_code,
                           "normal": stdin_closed and all(eof.values()) and exit_code == 0 and group_absent}
            if group_absent:
                cleanup = {"term": "not_attempted", "kill": "not_attempted", "leader_reaped": True,
                           "owned_group": "absent", "passed": True}
            else:
                cleanup = _stop(process)
        finally:
            selector.close()
            for stream in (process.stdin, process.stdout, process.stderr):
                stream.close()
    summary = broker.summary()
    summary["cleanup"] = cleanup
    summary["native_exit"] = native_exit
    summary["passed"] = summary["passed"] and cleanup["passed"]
    summary.update(seconds=round(time.monotonic() - started, 3), event_bytes=lines.bytes,
                   event_sha256=lines.digest.hexdigest(), stderr_bytes=stderr_bytes, stderr_sha256=stderr_hash.hexdigest())
    return summary


def run_codex(prompt: str, policy: Policy, *, seconds: float = 90, executable: str = "codex",
               model_catalog: FilePin | None = None, skill: PinnedSkill | None = None) -> dict:
    """Explicit online entry. Local MCP configuration gates precede app-server."""
    if not 0 < seconds <= 120:
        raise ValueError("one_to_120_seconds_required")
    deadline = time.monotonic() + seconds
    _verified_model_catalog(model_catalog)
    if skill is not None:
        if not isinstance(skill, PinnedSkill):
            raise ProtocolError("video_skill_pin_required")
        skill.verify()
    _verify_version(executable, timeout=min(10, seconds))
    options = {} if model_catalog is None else {"model_catalog": model_catalog}
    arguments, names = isolate_mcp(executable, policy.directory, deadline=deadline, **options)
    return _consume(arguments, prompt, policy, seconds=deadline - time.monotonic(), disabled_mcp_names=names,
                    skill=skill, **options)


def _verify_version(executable: str, *, timeout: float):
    probe = subprocess.run([executable, "--version"], capture_output=True, timeout=timeout, check=False,
                           env=dict(_PROBE_ENV))
    if probe.returncode != 0 or probe.stderr or probe.stdout.decode().strip() != VERSION:
        raise ValueError("codex_0_159_2_required_recheck_protocol_before_upgrade")


def probe_mcp_isolation(policy: Policy, *, seconds: float = 30, executable: str = "codex") -> dict:
    """Local initialize/inventory only; never sends thread/start or turn/start."""
    if not 0 < seconds <= 120:
        raise ValueError("one_to_120_seconds_required")
    deadline = time.monotonic() + seconds
    _verify_version(executable, timeout=min(10, seconds))
    arguments, names = isolate_mcp(executable, policy.directory, deadline=deadline)
    return _consume(arguments, "Verify local MCP isolation only.", policy, seconds=deadline - time.monotonic(),
                    disabled_mcp_names=names, initialize_only=True)
