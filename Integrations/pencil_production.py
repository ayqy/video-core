"""Resolve an authored drawing design, then bind originals through the normal CLI.

The content-only design is frozen before consulting AssetCache. No inventory is
offered to a content planner. A missing explicit generator leaves the stage at
needs_generation, without importing anything or editing a project. A caller may
register a real imagegen original and repeat the same design. This stage handles
arbitrary named drawings, not the nine bundled seed illustrations.

--apply imports verified original bytes and updates existing authored image
layers through the normal CAS editor. It never grants evidence, commerce,
upload consent or review. Rendering remains an explicit normal production step.
"""
from __future__ import annotations

import argparse
import copy
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import subprocess

from asset_reuse import AssetRequest, AssetCache
from codex_broker import FilePin
from codex_production import resolve_sources
from production_motion import _read_json


class ProductionError(ValueError):
    pass


def _canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False)


@dataclass(frozen=True)
class ContentDesign:
    title: str
    concept: str
    drawings: tuple[AssetRequest, ...]
    digest: str

    @classmethod
    def from_dict(cls, value):
        if not isinstance(value, dict) or set(value) != {"version", "title", "concept", "drawings"} or type(value["version"]) is not int or value["version"] != 1:
            raise ProductionError("content design v1 fields required")
        for name in ("title", "concept"):
            if not isinstance(value[name], str) or not value[name].strip() or len(value[name].encode()) > 16384:
                raise ProductionError("bounded content title and concept required")
        if not isinstance(value["drawings"], list) or not 1 <= len(value["drawings"]) <= 64:
            raise ProductionError("one to 64 authored drawing requirements required")
        drawings = tuple(AssetRequest.from_dict(item) for item in value["drawings"])
        if len({item.name for item in drawings}) != len(drawings) or len({item.key for item in drawings}) != len(drawings):
            raise ProductionError("unique drawing names and requirements required")
        # This digest describes content alone, independently of current cache state.
        return cls(value["title"], value["concept"], drawings, hashlib.sha256(_canonical(value).encode()).hexdigest())


def _result(response):
    if not isinstance(response, dict) or not response.get("ok"):
        raise ProductionError("normal CLI rejected the operation")
    value = response.get("result")
    return json.loads(value) if isinstance(value, str) else value


def _bindings(project, design, bindings):
    if not isinstance(bindings, list) or not 1 <= len(bindings) <= 256:
        raise ProductionError("bounded authored image bindings required")
    names = {item.name for item in design.drawings}
    scenes = {scene["id"]: scene for scene in project["revisions"][-1]["scenes"]}
    seen = set()
    for binding in bindings:
        if not isinstance(binding, dict) or set(binding) != {"name", "scene_id", "layer_id"} or binding["name"] not in names:
            raise ProductionError("binding must refer to a designed drawing")
        target = (binding["scene_id"], binding["layer_id"])
        if target in seen or target[0] not in scenes:
            raise ProductionError("duplicate or missing scene binding")
        seen.add(target)
        scene = scenes[target[0]]
        matches = [layer for layer in scene.get("layers", []) if layer["id"] == target[1]]
        if len(matches) != 1 or matches[0]["kind"] != "图片" or scene.get("locked") or matches[0].get("locked"):
            raise ProductionError("binding requires an unlocked existing image layer")
    if {item["name"] for item in bindings} != names:
        raise ProductionError("each designed drawing must have an authored binding")


def produce_drawings(design, cache, project, bindings, invoke, *, apply=False, generator=None):
    """Normal production stage; invoke(command, body, dry) returns native envelopes."""
    if not isinstance(design, ContentDesign):
        raise ProductionError("freeze a content design before resolving sources")
    _bindings(project, design, bindings)  # Reject a bad author plan before any import.
    resolved = resolve_sources(cache, design.drawings, generator=generator)
    if not resolved.ready:
        return dict(state="needs_generation", content_sha256=design.digest,
                    missing=tuple((item.request.name, item.reason, item.request.generation_prompt) for item in resolved.missing),
                    imported=0, changed=False)
    resolved.file_pins()  # Recheck revocation, expiry, use and original byte pins.
    if not apply:
        return dict(state="planned", content_sha256=design.digest, missing=(), imported=0, changed=False)
    scope = {"workspace_id": project["workspaceID"]}
    assets = _result(invoke("assets list", scope, False))
    if not isinstance(assets, list) or any(asset.get("workspaceID") != scope["workspace_id"] for asset in assets):
        raise ProductionError("scoped native asset inventory required")
    selected, imported = {}, 0
    for item in resolved.items:
        # Do not carry an old successful selection across generation/approval waits.
        resolved.file_pins()
        matches = [asset for asset in assets if asset.get("hash") == item.sha256 and asset.get("ext") == "png"]
        if len(matches) > 1:
            raise ProductionError("native original binding is ambiguous")
        # Even an existing metadata match must pass the normal importer's real
        # workspace-source byte check. A list response is not integrity proof.
        body = dict(scope, path=str(item.path), request_id="drawing-import-v1-" + item.sha256)
        dry = invoke("assets import", copy.deepcopy(body), True)
        if not dry.get("ok") or dry.get("state") != "dry_run":
            raise ProductionError("native source import dry-run failed")
        resolved.file_pins()
        asset = _result(invoke("assets import", copy.deepcopy(body), False))
        if not isinstance(asset, dict) or asset.get("workspaceID") != scope["workspace_id"] or asset.get("hash") != item.sha256 or asset.get("ext") != "png" or (matches and asset.get("id") != matches[0]["id"]):
            raise ProductionError("native importer did not bind the pinned PNG")
        if not matches:
            assets.append(asset)
            imported += 1
        selected[item.request.name] = asset["id"]
    # Source retrieval does not infer or copy a workspace evidence/review grant.
    revision = project["revisions"][-1]
    scenes = copy.deepcopy(revision["scenes"])
    for binding in bindings:
        scene = next(value for value in scenes if value["id"] == binding["scene_id"])
        layer = next(value for value in scene["layers"] if value["id"] == binding["layer_id"])
        layer["assetID"] = selected[binding["name"]]
    edits = []
    for original, candidate in zip(revision["scenes"], scenes):
        if candidate != original:
            if candidate.get("voice"):
                candidate["voice"]["listened"] = False
            for caption in candidate.get("captions", []):
                caption["confirmed"] = False
            edits.append({"replaceScene": {"_0": original["id"], "_1": candidate}})
    if not edits:
        return dict(state="unchanged", content_sha256=design.digest, missing=(), imported=imported, changed=False, revision=revision["id"])
    resolved.file_pins()
    body = dict(scope, project_id=project["id"], base_revision=revision["id"], edits=edits,
                text="按已冻结内容需求复用或补齐原图；正常绑定图层，不代替声音字幕或整片审核")
    body["request_id"] = "drawing-bind-v1-" + hashlib.sha256(_canonical(body).encode()).hexdigest()
    dry = invoke("edit apply", copy.deepcopy(body), True)
    if not dry.get("ok") or dry.get("state") != "dry_run":
        raise ProductionError("normal image binding dry-run failed")
    resolved.file_pins()
    result = invoke("edit apply", copy.deepcopy(body), False)
    if not result.get("ok") or result.get("state") != "needs_review" or result.get("project_id") != project["id"] or not result.get("revision"):
        raise ProductionError("normal editor did not return a matching draft revision")
    return dict(state="needs_review", content_sha256=design.digest, missing=(), imported=imported, changed=True, revision=result["revision"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--sha256", required=True)
    parser.add_argument("--workspace", type=Path, required=True)
    parser.add_argument("--workspace-id", required=True)
    parser.add_argument("--project-id", required=True)
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--design", type=Path, required=True)
    parser.add_argument("--bindings", type=Path, required=True)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    pin = FilePin(binary, args.sha256)
    design = ContentDesign.from_dict(_read_json(args.design))
    bindings = _read_json(args.bindings)
    cache = AssetCache(args.cache)
    def invoke(command, body, dry=False):
        pin.verify()
        request = copy.deepcopy(body)
        request.setdefault("request_id", "drawing-read-" + hashlib.sha256(_canonical(body).encode()).hexdigest())
        result = subprocess.run([str(binary), *command.split(), "--workspace", str(args.workspace), "--input", "-"] + (["--dry-run"] if dry else []),
                                input=_canonical(request), text=True, capture_output=True, timeout=180)
        if result.returncode or result.stderr:
            raise ProductionError("normal CLI operation failed")
        response = json.loads(result.stdout)
        if not isinstance(response, dict) or not response.get("ok"):
            raise ProductionError("normal CLI rejected the operation")
        return response
    projects = _result(invoke("projects list", {"workspace_id": args.workspace_id}))
    matches = [value for value in projects if value.get("id") == args.project_id and value.get("workspaceID") == args.workspace_id] if isinstance(projects, list) else []
    if len(matches) != 1:
        raise ProductionError("unique scoped native project required")
    result = produce_drawings(design, cache, matches[0], bindings, invoke, apply=args.apply)
    print("drawing stage: " + result["state"] + "; content SHA256=" + result["content_sha256"])
    for name, reason, prompt in result["missing"]:
        print("needs_generation: " + name + " (" + reason + ")\n" + prompt)
    if result["missing"]:
        return 2
    print("imported=" + str(result["imported"]) + "; changed=" + str(result["changed"]))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, OSError, KeyError, TypeError, subprocess.TimeoutExpired) as error:
        raise SystemExit("drawing production failed: " + str(error))
