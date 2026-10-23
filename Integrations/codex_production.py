"""Client-owned, hash-bound ordinary video plans for the native Codex broker.

This is an opt-in production contract, separate from the discovery/dry-run policy.
The model selects a named step; it never supplies CLI arguments, input JSON, paths
or generated IDs. Templates and source files are explicitly pinned by the caller.
Only a new workspace and its own verified backup can be used. Import has no side
effects; construction validates the plan, and only an approved call writes inputs.
"""
from __future__ import annotations

from copy import deepcopy
from dataclasses import dataclass
import hashlib
import json
import math
import os
from pathlib import Path
import re
import tempfile

from codex_events import ProtocolError, parse_object

_FIELDS = {
    "workspaces create": ({"name"}, set()),
    "assets import": ({"workspace_id", "path"}, set()),
    "assets list": ({"workspace_id"}, set()),
    "projects create": ({"workspace_id", "name", "scenes"}, {"aspect"}),
    "projects list": ({"workspace_id"}, set()),
    "script create": ({"workspace_id", "knowledge", "demonstration", "hook"}, {"name", "purpose", "aspect", "kind"}),
    "edit apply": ({"workspace_id", "project_id", "base_revision", "edits"}, {"text"}),
    "render estimate": ({"workspace_id", "project_id"}, set()),
    "render submit": ({"workspace_id", "project_id", "quote", "request_id"}, set()),
    "jobs status": ({"workspace_id", "job_id"}, set()),
    "jobs cancel": ({"workspace_id", "job_id"}, set()),
    "worker run": ({"workspace_id", "job_ids", "max_jobs", "timeout_seconds", "query_remote"}, {"resume_interrupted"}),
    "backup create": (set(), set()),
    "backup restore": ({"path"}, set()),
    "doctor": (set(), set()),
}
_WRITES = frozenset(("workspaces create", "assets import", "projects create", "script create", "edit apply",
                     "render submit", "jobs cancel", "worker run", "backup create", "backup restore"))
_ENVELOPE = frozenset(("schema_version", "request_id", "ok", "state", "project_id", "revision", "job_id",
                       "artifacts", "result", "error", "cost"))
_COST = frozenset(("currency", "estimated", "reserved", "actual", "unknown"))
_SCENE = frozenset(("id", "kind", "title", "body", "narration", "durationFrames", "assetID", "evidenceIDs",
                    "sourceStartFrame", "sourceEndFrame", "speed", "preservePitch", "locked", "x", "y", "scale",
                    "voiceGain", "sourceGain", "musicGain", "muted", "pauseFrames", "captions", "voice", "simulation",
                    "character", "emotion", "color", "showPrice", "keyframes", "classicArtworkRequired", "fontName"))
_ASSET = frozenset(("id", "workspaceID", "name", "hash", "ext", "bytes", "mediaType", "durationFrames", "pages",
                    "warnings", "evidenceID", "tags", "importedAt", "generatedSource"))
_JOB = frozenset(("id", "workspaceID", "projectID", "revisionID", "digest", "requestKey", "quote", "state",
                  "remoteID", "progress", "actual", "billingUnknown", "refundPending", "artifacts", "message",
                  "createdAt", "updatedAt", "attempt", "cacheHit", "lease", "billing", "remoteCheckedAt",
                  "providerAttempts", "videoGeneration", "outputAssetIDs"))
_QUOTE = frozenset(("id", "projectID", "revisionID", "digest", "upper", "unit", "provider", "expiresAt",
                    "attempts", "confirmed", "createdAt"))
_EXPORTS = {"workspaces create": {"workspace_id"}, "assets import": {"asset_id"},
            "projects create": {"project_id", "revision"}, "script create": {"project_id", "revision"},
            "edit apply": {"project_id", "revision"}, "render estimate": {"quote"},
            "render submit": {"job_id"}, "backup create": {"backup_path"}}
_STATES = {"projects create": {"needs_review"}, "script create": {"needs_review"}, "edit apply": {"needs_review"},
           "render submit": {"queued"}, "jobs cancel": {"cancelled"}, "worker run": {"completed"},
           "jobs status": {"queued", "running", "needs_review", "cancelled", "failed", "interrupted"}}
_SECRET = frozenset(("password", "passwd", "api_key", "apikey", "access_token", "refresh_token", "authorization",
                     "cookie", "cookies", "secret", "private_key", "principal", "profile_id", "product_id"))


def _fail(reason):
    raise ProtocolError(reason)


def _id(value):
    # Codec.id() uses UUID().uuidString.lowercased(), including the separators.
    return isinstance(value, str) and re.fullmatch(r"[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}", value) is not None


def _object(value, allowed, required=()):
    if not isinstance(value, dict) or not set(required) <= set(value) <= set(allowed):
        _fail("local_object_shape_refused")


def _tree(value, depth=0):
    if depth > 32:
        _fail("local_input_depth_refused")
    if isinstance(value, dict):
        if any(not isinstance(k, str) or k.lower() in _SECRET for k in value):
            _fail("local_sensitive_field_refused")
        for child in value.values():
            _tree(child, depth + 1)
    elif isinstance(value, list):
        if len(value) > 256:
            _fail("local_input_array_refused")
        for child in value:
            _tree(child, depth + 1)
    elif isinstance(value, float) and not math.isfinite(value):
        _fail("local_nonfinite_input_refused")
    elif isinstance(value, str) and (len(value.encode()) > 65536 or "\0" in value):
        _fail("local_input_text_refused")


@dataclass(frozen=True)
class ResultBinding:
    """Replace exactly one null in a pinned template from a validated earlier export."""
    target: tuple[str | int, ...]
    step: str
    field: str


@dataclass(frozen=True)
class LocalStep:
    name: str
    command: str
    input_file: Path
    bindings: tuple[ResultBinding, ...] = ()
    workspace: str = "primary"
    confirm_zero_quote: bool = False
    expected_state: str | None = None


class LocalInvocation:
    kind = "local_production"

    def __init__(self, policy, step, body, input_file, input_pin):
        self.policy, self.step, self.body = policy, step, body
        self.name, self.cwd = step.name, policy.directory
        self.input_file, self.input_pin = input_file, input_pin
        self.argv = (str(policy.binary), "--workspace", str(policy.roots[step.workspace]),
                     *step.command.split(), "--input", str(input_file))

    def execute(self, *, deadline):
        return self.policy._execute(self, deadline=deadline)


class LocalProductionPolicy:
    """A caller-approved finite plan. The broker owns all actual argv and IDs.

    ``pins`` must include the native CLI, every input template, and every imported
    source. All output roots are new canonical children of ``directory``. No old
    workspace, remote job, background worker, review grant, deletion, account or
    provider operation is accepted. ``confirm_zero_quote`` is explicit caller
    authorization for the exact native zero-cost quote, never a paid quote.
    """
    def __init__(self, *, binary: Path, directory: Path, workspace: Path, steps: tuple[LocalStep, ...],
                 pins: tuple, source_roots: tuple[Path, ...] = (), restore_roots: dict[str, Path] | None = None):
        from codex_broker import FilePin, _path
        self.directory, self.binary = _path(directory), _path(binary)
        if not self.directory.is_dir() or not os.access(self.binary, os.X_OK):
            _fail("local_native_binary_or_directory_required")
        if not 1 <= len(steps) <= 32 or any(not isinstance(s, LocalStep) for s in steps):
            _fail("local_one_to_32_steps_required")
        self.commands = steps
        self.pins = pins
        if not 1 <= len(pins) <= 96 or any(not isinstance(p, FilePin) for p in pins) or len({p.path for p in pins}) != len(pins):
            _fail("local_unique_file_pins_required")
        self.pin_map = {p.path: p for p in pins}
        sizes = [p.path.stat().st_size for p in pins]
        if any(size > 128*1024*1024 for size in sizes) or sum(sizes) > 256*1024*1024:
            _fail("local_pinned_file_inventory_bound")
        self._verify_pins()
        if self.binary not in self.pin_map:
            _fail("local_binary_pin_required")
        self.sources = tuple(_path(p) for p in source_roots)
        if any(not p.is_dir() for p in self.sources):
            _fail("local_source_directory_required")
        self.roots = {"primary": _path(workspace, exists=False)}
        for name, path in (restore_roots or {}).items():
            if not re.fullmatch(r"[a-z][a-z0-9_]{0,31}", name) or name == "primary":
                _fail("local_restore_name_refused")
            self.roots[name] = _path(path, exists=False)
        roots = list(self.roots.values())
        if any(p.exists() or not p.is_relative_to(self.directory) or p == self.directory for p in roots):
            _fail("local_new_child_workspace_required")
        if any(a == b or a in b.parents or b in a.parents for i, a in enumerate(roots) for b in roots[i+1:]):
            _fail("local_distinct_workspace_roots_required")
        if any(a == b or a in b.parents or b in a.parents for a in roots for b in self.sources):
            _fail("local_sources_separate_from_outputs_required")
        self.templates = {}
        earlier = {}
        request_ids = set()
        for index, step in enumerate(steps):
            if (not re.fullmatch(r"[a-z][a-z0-9_]{0,31}", step.name) or step.name in earlier or
                    step.command not in _FIELDS or step.workspace not in self.roots):
                _fail("local_step_identity_or_command_refused")
            if step.confirm_zero_quote and step.command != "render submit":
                _fail("local_quote_confirmation_scope_refused")
            if step.expected_state is not None and step.expected_state not in _STATES.get(step.command, {"succeeded"}):
                _fail("local_expected_state_refused")
            if step.input_file not in self.pin_map or step.input_file.stat().st_size > 262144:
                _fail("local_pinned_bounded_template_required")
            body = parse_object(step.input_file.read_bytes())
            _tree(body)
            required, optional = _FIELDS[step.command]
            _object(body, required | optional | {"request_id"}, required)
            request = body.get("request_id")
            if not isinstance(request, str) or not re.fullmatch(r"[a-zA-Z0-9_-]{1,128}", request) or request in request_ids:
                _fail("local_unique_request_id_required")
            request_ids.add(request)
            targets = []
            for binding in step.bindings:
                if (not isinstance(binding, ResultBinding) or binding.step not in earlier or
                        binding.field not in _EXPORTS.get(earlier[binding.step], set())):
                    _fail("local_previous_typed_binding_required")
                self._slot(body, binding.target, require_null=True)
                if any(binding.target[:len(t)] == t or t[:len(binding.target)] == binding.target for t in targets):
                    _fail("local_overlapping_binding_refused")
                targets.append(binding.target)
            if step.command == "worker run":
                self._worker_input(body, check_jobs=False)
            if step.command == "render submit" and not step.confirm_zero_quote:
                _fail("local_explicit_zero_quote_confirmation_required")
            if index == 0 and (step.command != "workspaces create" or step.workspace != "primary"):
                _fail("local_first_step_must_create_workspace")
            if index > 0 and step.command == "workspaces create":
                _fail("local_only_one_workspace_creation")
            if step.command == "assets import":
                source = _path(Path(body.get("path", "")))
                if source not in self.pin_map or not any(source.is_relative_to(p) for p in self.sources):
                    _fail("local_pinned_approved_source_required")
            self.templates[step.name] = body
            earlier[step.name] = step.command
        material = {"binary": str(self.binary), "cwd": str(self.directory), "roots": {k: str(v) for k, v in self.roots.items()},
                    "sources": list(map(str, self.sources)), "pins": sorted((str(p.path), p.sha256) for p in pins),
                    "steps": [{"name": s.name, "command": s.command, "workspace": s.workspace,
                               "input": str(s.input_file), "confirm_zero_quote": s.confirm_zero_quote,
                               "expected_state": s.expected_state,
                               "bindings": [(b.target, b.step, b.field) for b in s.bindings]} for s in steps]}
        self.plan_sha256 = hashlib.sha256(json.dumps(material, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
        self.used = 0
        self.failed = False
        self.pending = None
        self.values, self.assets, self.projects, self.jobs, self.backups = {}, set(), {}, {}, {}
        self.workspace_id = None
        self.active_roots = set()
        self.input_directory = None

    @staticmethod
    def _slot(body, target, *, require_null=False):
        if not isinstance(target, tuple) or not 1 <= len(target) <= 16:
            _fail("local_binding_target_refused")
        node = body
        for part in target[:-1]:
            if isinstance(node, dict) and isinstance(part, str) and part in node:
                node = node[part]
            elif isinstance(node, list) and type(part) is int and 0 <= part < len(node):
                node = node[part]
            else:
                _fail("local_binding_target_refused")
        part = target[-1]
        if not ((isinstance(node, dict) and isinstance(part, str) and part in node) or
                (isinstance(node, list) and type(part) is int and 0 <= part < len(node))):
            _fail("local_binding_target_refused")
        if require_null and node[part] is not None:
            _fail("local_binding_must_replace_null")
        return node, part

    def _verify_pins(self):
        for pin in self.pins:
            pin.verify()

    def arguments(self, step):
        return {"operation": step.name, "cwd": str(self.directory), "plan_sha256": self.plan_sha256}

    def spec(self):
        from codex_broker import TOOL
        return {"type": "function", "name": TOOL,
                "description": "Execute the next caller-approved local ordinary-video step. The client binds verified IDs and exact argv. No shell, accounts, providers, purchases, review grants, deletion, overwrite or retries.",
                "inputSchema": {"type": "object", "properties": {
                    "operation": {"type": "string", "enum": [s.name for s in self.commands]},
                    "cwd": {"type": "string", "const": str(self.directory)},
                    "plan_sha256": {"type": "string", "const": self.plan_sha256}},
                    "required": ["operation", "cwd", "plan_sha256"], "additionalProperties": False}}

    def claim(self, arguments):
        from codex_broker import FilePin, _path
        if self.failed or self.pending is not None or self.used >= len(self.commands):
            _fail("local_plan_not_ready_or_consumed")
        step = self.commands[self.used]
        if arguments != self.arguments(step):
            _fail("local_exact_step_required")
        self._verify_pins()
        for name, root in self.roots.items():
            _path(root, exists=name in self.active_roots)
        body = deepcopy(self.templates[step.name])
        for binding in step.bindings:
            key = (binding.step, binding.field)
            if key not in self.values:
                _fail("local_verified_binding_missing")
            node, part = self._slot(body, binding.target, require_null=True)
            node[part] = deepcopy(self.values[key])
        if step.command == "render submit" and step.confirm_zero_quote:
            quote = body.get("quote")
            self._quote(quote, confirmed=False)
            quote["confirmed"] = True
        try:
            self._body(step, body)
        except (KeyError, TypeError, AttributeError):
            _fail("local_input_shape_refused")
        if self.input_directory is None:
            self.input_directory = Path(tempfile.mkdtemp(prefix=".video-codex-inputs-", dir=self.directory))
            os.chmod(self.input_directory, 0o700)
        _path(self.input_directory)
        path = self.input_directory / (str(self.used).zfill(2) + ".json")
        raw = json.dumps(body, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(raw)
        invocation = LocalInvocation(self, step, body, path, FilePin(path, hashlib.sha256(raw).hexdigest()))
        self.pending = invocation
        self.used += 1
        return invocation

    def _body(self, step, body):
        from codex_broker import _path
        _tree(body)
        command, root = step.command, self.roots[step.workspace]
        for key in ("workspace_id", "project_id", "base_revision", "job_id"):
            if key in body and not _id(body[key]):
                _fail("local_typed_bound_id_required")
        if "name" in body and (not isinstance(body["name"], str) or not body["name"].strip()):
            _fail("local_nonempty_name_required")
        if "path" in body and not isinstance(body["path"], str):
            _fail("local_bound_file_path_required")
        if command in ("workspaces create", "backup restore"):
            if root.exists():
                _fail("local_no_overwrite_new_root_required")
        elif step.workspace not in self.active_roots:
            _fail("local_workspace_not_created_by_plan")
        if "workspace_id" in body and body["workspace_id"] != self.workspace_id:
            _fail("local_workspace_binding_required")
        if "project_id" in body and body["project_id"] not in self.projects:
            _fail("local_project_binding_required")
        if "base_revision" in body and self.projects.get(body.get("project_id")) != body["base_revision"]:
            _fail("local_current_revision_binding_required")
        if command == "assets import":
            path = _path(Path(body["path"]))
            if path not in self.pin_map or not any(path.is_relative_to(p) for p in self.sources):
                _fail("local_source_path_refused")
        if command in ("projects create", "script create"):
            if body.get("purpose", "非商业教学") != "非商业教学" or body.get("kind", "图文讲解") not in ("图文讲解", "图片", "真实录屏"):
                _fail("local_ordinary_noncommercial_project_required")
            if body.get("aspect", "16:9") not in ("16:9", "9:16"):
                _fail("local_aspect_refused")
            if command == "projects create":
                if not isinstance(body["scenes"], list) or not 1 <= len(body["scenes"]) <= 64:
                    _fail("local_bounded_scenes_required")
                for scene in body["scenes"]:
                    self._scene(scene)
        if command == "edit apply":
            if not isinstance(body["edits"], list) or not 1 <= len(body["edits"]) <= 64:
                _fail("local_bounded_edits_required")
            for edit in body["edits"]:
                if not isinstance(edit, dict) or len(edit) != 1:
                    _fail("local_edit_shape_refused")
                kind, value = next(iter(edit.items()))
                shapes = {"replaceScene": {"_0", "_1"}, "insertScene": {"_0", "_1"}, "moveScene": {"_0", "_1"},
                          "splitScene": {"_0", "_1"}, "music": {"_0"}, "aspect": {"_0"}}
                if kind not in shapes:
                    _fail("local_edit_kind_refused")
                _object(value, shapes[kind], shapes[kind])
                if kind in ("replaceScene", "insertScene"):
                    self._scene(value["_1"] if kind == "replaceScene" else value["_0"])
                if kind == "music" and value["_0"] is not None and value["_0"] not in self.assets:
                    _fail("local_imported_audio_required")
        if command == "render submit":
            if not step.confirm_zero_quote:
                _fail("local_explicit_zero_quote_confirmation_required")
            self._quote(body["quote"], confirmed=True)
            if body["quote"]["projectID"] != body["project_id"] or body["quote"]["revisionID"] != self.projects[body["project_id"]]:
                _fail("local_quote_project_revision_mismatch")
        if command.startswith("jobs ") and body["job_id"] not in self.jobs:
            _fail("local_original_native_job_required")
        if command == "worker run":
            self._worker_input(body, check_jobs=True)
        if command == "backup restore":
            path = _path(Path(body["path"]))
            artifact = self.backups.get(str(path))
            if artifact is None:
                _fail("local_own_verified_backup_required")
            self._artifact(artifact, self.roots["primary"])

    def _worker_input(self, body, *, check_jobs):
        ids = body["job_ids"]
        if (not isinstance(ids, list) or not 1 <= len(ids) <= 4 or type(body["max_jobs"]) is not int or
                body["max_jobs"] != len(ids) or type(body["timeout_seconds"]) is not int or
                not 5 <= body["timeout_seconds"] <= 60 or body["query_remote"] is not False or
                body.get("resume_interrupted", False) is not False):
            _fail("local_finite_native_worker_required")
        if check_jobs and (any(not _id(x) or x not in self.jobs for x in ids) or len(set(ids)) != len(ids)):
            _fail("local_original_native_worker_jobs_required")

    def _scene(self, scene):
        _object(scene, _SCENE, {"id", "kind", "title", "body", "narration", "durationFrames"})
        if (not _id(scene["id"]) or scene["kind"] not in ("图文讲解", "图片", "真实录屏") or
                scene.get("showPrice", False) is not False or scene.get("evidenceIDs", []) != []):
            _fail("local_ordinary_scene_required")
        if scene.get("assetID") is not None and scene["assetID"] not in self.assets:
            _fail("local_imported_scene_asset_required")
        if scene.get("simulation", {}) not in ({}, {"seed": 42, "initial": 100, "capacity": 200, "unit": "上下文单位", "events": []}):
            _fail("local_no_advanced_simulation")
        captions = scene.get("captions", [])
        if not isinstance(captions, list):
            _fail("local_caption_array_required")
        for caption in captions:
            _object(caption, {"id", "text", "startFrame", "endFrame", "alignment", "confirmed"}, {"confirmed"})
            if caption["confirmed"] is not False:
                _fail("local_no_human_review_grant")
        if scene.get("voice") is not None:
            voice = scene["voice"]
            _object(voice, {"assetID", "textDigest", "durationFrames", "method", "listened"}, {"assetID", "listened"})
            if voice["assetID"] not in self.assets or voice["listened"] is not False:
                _fail("local_imported_unreviewed_voice_required")

    def _quote(self, quote, *, confirmed):
        _object(quote, _QUOTE, _QUOTE)
        _object(quote["upper"], {"amount", "currency"}, {"amount", "currency"})
        if (not _id(quote["id"]) or quote["projectID"] not in self.projects or
                self.projects[quote["projectID"]] != quote["revisionID"] or quote["provider"] != "native" or
                quote["confirmed"] is not confirmed or quote["upper"] != {"amount": 0, "currency": "CNY"} or
                type(quote["upper"]["amount"]) not in (int, float) or
                quote["unit"] != "CNY" or type(quote["attempts"]) is not int or quote["attempts"] != 1 or
                not isinstance(quote["digest"], str) or re.fullmatch(r"[a-f0-9]{64}", quote["digest"]) is None):
            _fail("local_exact_native_zero_quote_required")

    def _artifact(self, value, root):
        from codex_broker import _path, _file_digest
        _object(value, {"id", "path", "mime", "bytes", "sha256", "revision"}, {"id", "path", "mime", "bytes", "sha256", "revision"})
        path = _path(Path(value["path"]))
        minimum = 0 if value["mime"] == "application/x-subrip" else 1
        if (not path.is_relative_to(root) or type(value["bytes"]) is not int or not minimum <= value["bytes"] <= 512*1024*1024 or
                path.stat().st_size != value["bytes"] or _file_digest(path) != value["sha256"]):
            _fail("local_artifact_path_bytes_or_hash_refused")

    def _response(self, invocation, output, *, dry):
        value = parse_object(output)
        _object(value, _ENVELOPE, _ENVELOPE)
        if (value["schema_version"] != "1.0" or value["request_id"] != invocation.body["request_id"] or
                value["ok"] is not True or value["error"] is not None):
            _fail("local_success_envelope_required")
        _object(value["cost"], _COST, _COST)
        if (value["cost"]["currency"] != "CNY" or any(value["cost"][k] is not None and
                (type(value["cost"][k]) not in (int, float) or value["cost"][k] != 0)
                for k in ("estimated", "reserved", "actual"))):
            _fail("local_zero_cost_envelope_required")
        if not isinstance(value["artifacts"], list) or len(value["artifacts"]) > 4:
            _fail("local_artifact_inventory_refused")
        for key in ("project_id", "revision", "job_id"):
            if value[key] is not None and not _id(value[key]):
                _fail("local_response_id_refused")
        command, body = invocation.step.command, invocation.body
        if dry:
            if value["state"] != "dry_run" or value["artifacts"] or any(value[k] is not None for k in ("project_id", "revision", "job_id")):
                _fail("local_exact_dry_run_required")
            return value
        allowed = _STATES.get(command, {"succeeded"})
        if value["state"] not in allowed or (invocation.step.expected_state is not None and value["state"] != invocation.step.expected_state):
            _fail("local_actual_state_refused")
        root = self.roots[invocation.step.workspace]
        result, exports = value["result"], {}
        if command == "workspaces create":
            _object(result, {"id", "name", "owner", "salt", "grants"}, {"id", "name", "owner", "salt", "grants"})
            if not _id(result["id"]) or result["name"] != body["name"] or result["grants"] != []:
                _fail("local_created_workspace_receipt_refused")
            exports["workspace_id"] = result["id"]
        elif command == "assets import":
            _object(result, _ASSET, {"id", "workspaceID", "hash", "ext", "bytes", "mediaType"})
            if (not _id(result["id"]) or result["workspaceID"] != self.workspace_id or
                    result["hash"] != self.pin_map[Path(body["path"])].sha256 or
                    type(result["bytes"]) is not int or result["bytes"] != Path(body["path"]).stat().st_size):
                _fail("local_imported_source_receipt_refused")
            if result.get("generatedSource") is not None or result.get("evidenceID") is not None:
                _fail("local_import_must_not_grant_rights")
            exports["asset_id"] = result["id"]
        elif command in ("projects create", "script create", "edit apply"):
            if not _id(value["project_id"]) or not _id(value["revision"]):
                _fail("local_project_revision_receipt_required")
            if command == "edit apply" and (value["project_id"] != body["project_id"] or value["revision"] == body["base_revision"]):
                _fail("local_new_revision_receipt_required")
            if command in ("projects create", "script create") and result != {"review_required": True}:
                _fail("local_unreviewed_project_receipt_required")
            if command == "edit apply" and result is not None:
                _fail("local_edit_result_shape_refused")
            exports.update(project_id=value["project_id"], revision=value["revision"])
        elif command == "render estimate":
            self._quote(result, confirmed=False)
            if result["projectID"] != body["project_id"]:
                _fail("local_estimate_scope_refused")
            exports["quote"] = result
        elif command == "render submit":
            if not _id(value["job_id"]):
                _fail("local_native_job_receipt_required")
            exports["job_id"] = value["job_id"]
        elif command == "jobs status":
            _object(result, _JOB, {"id", "workspaceID", "projectID", "revisionID", "quote", "state", "artifacts"})
            if (result["id"] != body["job_id"] or value["job_id"] != body["job_id"] or
                    result["workspaceID"] != self.workspace_id or result["projectID"] != self.jobs[body["job_id"]] or
                    result["revisionID"] != self.projects.get(result["projectID"]) or
                    result["state"] != value["state"] or result.get("remoteID") is not None):
                _fail("local_original_job_scope_refused")
            self._quote(result["quote"], confirmed=True)
            if not isinstance(result["artifacts"], list) or len(result["artifacts"]) > 4:
                _fail("local_job_artifact_inventory_refused")
            for artifact in result["artifacts"]:
                self._artifact(artifact, root)
                if artifact["revision"] != result["revisionID"]:
                    _fail("local_artifact_revision_mismatch")
            if value["state"] == "needs_review" and (len(result["artifacts"]) != 4 or
                    {a["mime"] for a in result["artifacts"]} != {"video/mp4", "image/png", "application/x-subrip", "text/plain"}):
                _fail("local_four_reviewable_artifacts_required")
            if value["artifacts"] != result["artifacts"]:
                _fail("local_job_artifact_inventory_mismatch")
        elif command == "jobs cancel":
            if value["job_id"] != body["job_id"]:
                _fail("local_cancel_original_job_required")
        elif command == "worker run":
            _object(result, {"id", "requestID", "principal", "plan", "fingerprint", "state", "createdAt", "updatedAt", "deadline", "pid", "outcomes"},
                    {"id", "requestID", "plan", "state", "outcomes"})
            plan = result["plan"]
            _object(plan, {"workspaceID", "jobIDs", "maximumJobs", "timeoutSeconds", "resumeInterrupted", "queryRemote", "version"},
                    {"workspaceID", "jobIDs", "maximumJobs", "timeoutSeconds", "resumeInterrupted", "queryRemote"})
            if (result["requestID"] != body["request_id"] or result["state"] != "completed" or
                    plan["workspaceID"] != self.workspace_id or plan["jobIDs"] != body["job_ids"] or
                    plan["maximumJobs"] != body["max_jobs"] or plan["timeoutSeconds"] != body["timeout_seconds"] or
                    plan["queryRemote"] is not False or plan["resumeInterrupted"] is not False or
                    not isinstance(result["outcomes"], list) or len(result["outcomes"]) != len(body["job_ids"])):
                _fail("local_worker_receipt_scope_refused")
            if any(not isinstance(x, dict) for x in result["outcomes"]) or sorted(x.get("jobID", "") for x in result["outcomes"]) != sorted(body["job_ids"]):
                _fail("local_worker_original_jobs_required")
            for item in result["outcomes"]:
                _object(item, {"jobID", "state", "note"}, {"jobID", "state", "note"})
                if item["state"] != "needs_review":
                    _fail("local_worker_did_not_produce_reviewable_output")
        elif command == "backup create":
            if len(value["artifacts"]) != 1:
                _fail("local_one_verified_backup_required")
            artifact = value["artifacts"][0]
            self._artifact(artifact, root)
            if artifact["mime"] != "application/octet-stream" or artifact["revision"] != "" or not artifact["path"].endswith(".videobackup"):
                _fail("local_backup_artifact_type_refused")
            exports["backup_path"] = artifact["path"]
        elif command in ("assets list", "projects list"):
            if not isinstance(result, list) or len(result) > 256 or any(not isinstance(x, dict) or x.get("workspaceID") != self.workspace_id for x in result):
                _fail("local_list_scope_refused")
        elif command == "doctor":
            if not isinstance(result, dict) or result.get("database", {}).get("validated") is not True or result["database"].get("read_only") is not True:
                _fail("local_read_only_doctor_required")
        elif command == "backup restore" and not isinstance(result, str):
            _fail("local_restore_receipt_required")
        return value, exports

    def _execute(self, invocation, *, deadline):
        from codex_broker import _execute_argv
        if self.pending is not invocation or self.failed:
            _fail("local_invocation_not_pending")
        phases = []
        try:
            dry = invocation.step.command in _WRITES
            for preview in ((True, False) if dry else (False,)):
                self._verify_pins()
                invocation.input_pin.verify()
                self._body(invocation.step, invocation.body)
                argv = invocation.argv + (("--dry-run",) if preview else ())
                maximum = invocation.body.get("timeout_seconds", 17) + 3 if invocation.step.command == "worker run" else 20
                receipt, raw = _execute_argv(argv, self.directory, deadline=deadline, seconds=maximum)
                receipt["phase"] = "dry_run" if preview else "actual"
                phases.append(receipt)
                self._verify_pins()
                invocation.input_pin.verify()
                if not receipt["passed"]:
                    _fail("local_child_did_not_complete")
                checked = self._response(invocation, raw, dry=preview)
            value, exports = checked
            command = invocation.step.command
            if command == "workspaces create":
                self.workspace_id = exports["workspace_id"]
                self.active_roots.add("primary")
            elif command == "assets import":
                self.assets.add(exports["asset_id"])
            elif command in ("projects create", "script create", "edit apply"):
                self.projects[exports["project_id"]] = exports["revision"]
            elif command == "render submit":
                self.jobs[exports["job_id"]] = invocation.body["project_id"]
            elif command == "backup create":
                self.backups[exports["backup_path"]] = deepcopy(value["artifacts"][0])
            elif command == "backup restore":
                self.active_roots.add(invocation.step.workspace)
            for key, export in exports.items():
                self.values[(invocation.step.name, key)] = deepcopy(export)
            self.pending = None
            return {"operation": invocation.name, "passed": True, "state": value["state"], "phases": phases,
                    "binding_count": len(exports), "plan_sha256": self.plan_sha256, "human_review_granted": False}
        except (KeyError, TypeError, AttributeError):
            self.failed = True
            _fail("local_response_or_input_shape_refused")
        except BaseException:
            self.failed = True
            raise
