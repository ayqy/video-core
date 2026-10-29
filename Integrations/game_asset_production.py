"""Resolve authored game elements, then bind actual originals through normal CLI.

Content is frozen before cache selection. Style anchors are explicit byte pins,
not an inventory supplied to the content planner. Missing PNGs remain an image
generation handoff; this module never invents a supplier, rights or approval.
Only --apply imports sources, records supplied evidence and makes one CAS edit.
It does not create entities, alter rules, render a movie or reuse old clips.
"""
from __future__ import annotations

import argparse
import copy
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess
import uuid
from datetime import datetime, timezone

from asset_reuse import AssetCache, AssetRequest, AssetRights, _read, _png
from codex_broker import FilePin
from codex_production import resolve_sources
from production_motion import _read_json


class GameAssetError(ValueError):
    pass


def need(condition, message):
    if not condition:
        raise GameAssetError(message)


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False)


def fields(value, required):
    need(isinstance(value, dict) and set(value) == set(required), "explicit game asset fields required")


def text(value, maximum=4096):
    need(isinstance(value, str) and value.strip() and "\0" not in value and len(value.encode()) <= maximum,
         "bounded nonempty source text required")
    return value


@dataclass(frozen=True)
class GameContentDesign:
    title: str
    concept: str
    elements: tuple
    digest: str

    @classmethod
    def from_dict(cls, value):
        fields(value, ("version", "title", "concept", "elements"))
        need(type(value["version"]) is int and value["version"] == 1, "game content design v1 required")
        title, concept = text(value["title"]), text(value["concept"], 16384)
        need(isinstance(value["elements"], list) and 1 <= len(value["elements"]) <= 64,
             "one to 64 content-selected game elements required")
        elements = []
        for item in value["elements"]:
            fields(item, ("name", "description", "transparent"))
            request = AssetRequest(item["name"], item["description"], "style assigned after content design", item["transparent"])
            elements.append((request.name, request.description, request.transparent))
        need(len({row[0].casefold() for row in elements}) == len(elements), "unique content element names required")
        return cls(title, concept, tuple(elements), hashlib.sha256(canonical(value).encode()).hexdigest())


@dataclass(frozen=True)
class GameStyle:
    name: str
    description: str
    anchors: tuple[FilePin, ...]

    @classmethod
    def from_dict(cls, value):
        fields(value, ("name", "description", "anchors"))
        need(isinstance(value["anchors"], list) and 1 <= len(value["anchors"]) <= 8,
             "one to eight actual game style references required")
        anchors = []
        for row in value["anchors"]:
            fields(row, ("path", "sha256"))
            need(isinstance(row["path"], str) and isinstance(row["sha256"], str)
                 and re.fullmatch(r"[a-f0-9]{64}", row["sha256"]), "pinned style reference required")
            path = Path(row["path"])
            data = _read(path, 8 * 1024 * 1024)
            need(data.startswith(b"\x89PNG\r\n\x1a\n") and len(data) >= 33 and data[12:16] == b"IHDR",
                 "style reference must be an actual PNG original")
            width, height = struct.unpack(">II", data[16:24])
            need(0 < width <= 4096 and 0 < height <= 4096, "bounded game style reference required")
            pin = FilePin(path, row["sha256"])
            pin.verify()
            anchors.append(pin)
        need(len({pin.sha256 for pin in anchors}) == len(anchors), "distinct actual style references required")
        return cls(text(value["name"], 128), text(value["description"], 2048), tuple(anchors))

    def verify(self):
        need(1 <= len(self.anchors) <= 8 and all(isinstance(pin, FilePin) for pin in self.anchors), "actual style reference pins required")
        for pin in self.anchors:
            pin.verify()

    def requests(self, design):
        # Reference identity describes the requested style, not cache availability.
        # The real reference paths go only to the image-generation handoff.
        style = (self.name + ": " + self.description + "; match these actual reference PNG SHA256: "
                 + ",".join(sorted(pin.sha256 for pin in self.anchors)))
        return tuple(AssetRequest(name, description, style, transparent) for name, description, transparent in design.elements)


def result(response):
    need(isinstance(response, dict) and response.get("ok") is True, "normal CLI rejected game source operation")
    value = response.get("result")
    return json.loads(value) if isinstance(value, str) and value[:1] in ("[", "{") else value


def dry_run(response, message):
    need(isinstance(response, dict) and response.get("ok") is True and response.get("state") == "dry_run", message)


def checked_bindings(project, design, bindings):
    need(isinstance(bindings, list) and 1 <= len(bindings) <= 256, "bounded explicit game role bindings required")
    names = {item[0] for item in design.elements}
    revision = project["revisions"][-1]
    scenes = {scene["id"]: scene for scene in revision["scenes"]}
    seen = set()
    for binding in bindings:
        fields(binding, ("name", "scene_id", "role"))
        role = text(binding["role"], 128)
        need(role == role.strip() and not any(ord(char) < 32 or ord(char) == 127 for char in role), "literal game role required")
        key = (binding["scene_id"], role)
        need(binding["name"] in names and key not in seen and binding["scene_id"] in scenes,
             "duplicate role target or undeclared content element")
        seen.add(key)
        scene = scenes[binding["scene_id"]]
        artwork = scene.get("classicArtwork")
        need(not scene.get("locked") and scene.get("kind") == "规则模拟" and isinstance(scene.get("gameWorld"), dict)
             and isinstance(artwork, dict), "unlocked actual game-world scene required")
        sprites = artwork.get("sprites", [])
        roles = [row["role"] for row in sprites]
        need(len(roles) == len(set(roles)), "existing game role identity is ambiguous")
    need({row["name"] for row in bindings} == names, "every designed element needs an explicit game role binding")
    for scene_id in sorted({row["scene_id"] for row in bindings}):
        scene = scenes[scene_id]
        roles = {row["role"] for row in scene["classicArtwork"]["sprites"]}
        roles.update(row["role"] for row in bindings if row["scene_id"] == scene_id)
        world = scene["gameWorld"]
        referenced = set(world["tiles"]) | {row["role"] for row in world["entities"]}
        referenced.update(row["role"] for row in world["updates"] if row.get("role") is not None)
        need(referenced <= roles and len(roles) <= 128, "all world references must be bound within 128 game sprites")
    return scenes


def source_record(cache, selection, use):
    record = cache.provenance(selection.request, sha256=selection.sha256, use=use)
    need(record.rights == selection.rights, "selected original rights changed")
    return record.prompt, record.provenance


def checked_proofs(proofs, selections, cache, use):
    need(isinstance(proofs, dict) and set(proofs) == {item.request.name for item in selections},
         "explicit source proof for every resolved element required")
    verified = {}
    for selection in selections:
        proof = proofs[selection.request.name]
        fields(proof, ("origin", "source", "owner", "license", "claim", "verified", "commercial_allowed", "upload_consent",
                       "expires_at", "actual_prompt", "provenance", "original_asset_ids", "checked_at"))
        need(proof["origin"] in ("generated", "downloaded"), "actual downloaded or generated origin required")
        rights = AssetRights(proof["owner"], proof["source"], proof["claim"], proof["verified"],
                             proof["commercial_allowed"], proof["upload_consent"], proof["expires_at"])
        need(rights == selection.rights and rights.verified, "native evidence must match explicitly verified cache rights")
        text(proof["license"])
        checked = datetime.fromisoformat(text(proof["checked_at"]).replace("Z", "+00:00"))
        need(checked.tzinfo is not None and checked.timestamp() <= datetime.now(timezone.utc).timestamp() + 60,
             "explicit actual timezone-aware source check date required")
        prompt, provenance = source_record(cache, selection, use)
        need(proof["actual_prompt"] == prompt and proof["provenance"] == provenance,
             "source proof must retain the exact registered prompt and provenance")
        text(prompt, 128 * 1024)
        text(provenance, 128 * 1024)
        originals = proof["original_asset_ids"]
        need(isinstance(originals, list) and originals and len(originals) <= 8
             and len(set(originals)) == len(originals) and all(isinstance(value, str) for value in originals),
             "explicit existing style-reference asset identities required")
        verified[selection.request.name] = proof
    return verified


def check_originals(scenes, bindings, proofs, style, assets):
    hashes = {pin.sha256 for pin in style.anchors}
    for binding in bindings:
        artwork = scenes[binding["scene_id"]]["classicArtwork"]
        sources = {row["assetID"]: row for row in artwork["sources"]}
        for original in proofs[binding["name"]]["original_asset_ids"]:
            asset, source = assets.get(original), sources.get(original)
            need(asset is not None and source is not None and asset["hash"] in hashes and source["hash"] == asset["hash"]
                 and source["evidenceID"] == asset.get("evidenceID"),
                 "style original must already have its own actual scene source and evidence")
            # A generated supplement must not claim the actual upstream source.
            if proofs[binding["name"]]["origin"] == "generated":
                need(proofs[binding["name"]]["source"] != source["source"],
                     "generated supplement cannot be declared an upstream downloaded original")


def check_plugin_budget(scenes, bindings, selections, assets, image_sources):
    need(isinstance(image_sources, dict), "explicit existing image-bank file pins required")
    chosen = {item.request.name: item for item in selections}
    for scene_id in sorted({row["scene_id"] for row in bindings}):
        artwork = scenes[scene_id]["classicArtwork"]
        sprites = {row["role"]: row["assetID"] for row in artwork["sprites"]}
        sizes, pixels = {}, {}
        for binding in (row for row in bindings if row["scene_id"] == scene_id):
            selected = chosen[binding["name"]]
            data = _read(selected.path, 8 * 1024 * 1024)
            width, height = _png(data, transparent=selected.request.transparent)
            need(width * height <= 24_000_000, "generated PNG exceeds plugin image pixel limit")
            prior = [row["id"] for row in assets.values() if row.get("hash") == selected.sha256 and row.get("ext") == "png"]
            need(len(prior) <= 1, "native game original identity is ambiguous")
            synthetic = prior[0] if prior else "sha256:" + selected.sha256
            sprites[binding["role"]] = synthetic
            sizes[synthetic] = len(data)
            pixels[synthetic] = width * height
        used = set(sprites.values())
        for asset_id in used - sizes.keys():
            need(asset_id in assets and asset_id in image_sources, "actual consumed game image source pin required")
            source = image_sources[asset_id]
            fields(source, ("path", "sha256"))
            need(source["sha256"] == assets[asset_id]["hash"] and assets[asset_id].get("ext") == "png"
                 and assets[asset_id].get("mediaType", "").startswith("image"),
                 "existing image-bank pin must match native source identity")
            data = _read(Path(source["path"]), 8 * 1024 * 1024)
            need(hashlib.sha256(data).hexdigest() == source["sha256"] and len(data) == assets[asset_id]["bytes"]
                 and data.startswith(b"\x89PNG\r\n\x1a\n") and len(data) >= 33 and data[12:16] == b"IHDR",
                 "actual consumed PNG bytes differ from native source identity")
            width, height = struct.unpack(">II", data[16:24])
            need(0 < width <= 4096 and 0 < height <= 4096 and width * height <= 24_000_000,
                 "existing PNG exceeds plugin image pixel limit")
            sizes[asset_id], pixels[asset_id] = len(data), width * height
        need(len(used) <= 32 and len(sprites) <= 128 and all(sizes[key] <= 8 * 1024 * 1024 for key in used)
             and sum(sizes[key] for key in used) <= 10 * 1024 * 1024 and sum(pixels[key] for key in used) <= 48_000_000,
             "game image bank exceeds actual plugin count or PNG byte budget")
        source_ids = {row["assetID"] for row in artwork["sources"]}
        need(len(source_ids) == len(artwork["sources"]), "existing game sources are ambiguous")
        source_ids.update(sprites[row["role"]] for row in bindings if row["scene_id"] == scene_id)
        need(len(source_ids) <= 64, "game source bank exceeds 64 exact source entries")
        # Final native importer/Host additionally decodes the complete bank.


def produce_game_assets(design, style, cache, project, bindings, invoke, *, proofs=None, image_sources=None, apply=False, generator=None, use="local_draft"):
    need(isinstance(design, GameContentDesign) and isinstance(style, GameStyle) and isinstance(cache, AssetCache),
         "freeze content and byte-bound game style before resolving originals")
    scenes = checked_bindings(project, design, bindings)
    style.verify()
    resolved = resolve_sources(cache, style.requests(design), generator=generator, use=use)
    if not resolved.ready:
        return dict(state="needs_generation", content_sha256=design.digest, changed=False, imported=0,
                    missing=tuple(dict(name=item.request.name, reason=item.reason, prompt=item.request.generation_prompt,
                                       references=tuple(dict(path=str(pin.path), sha256=pin.sha256) for pin in style.anchors))
                                  for item in resolved.missing))
    resolved.file_pins()
    proofs = checked_proofs(proofs, resolved.items, cache, use)
    scope = {"workspace_id": project["workspaceID"]}
    rows = result(invoke("assets list", scope, False))
    need(isinstance(rows, list) and all(row.get("workspaceID") == project["workspaceID"] for row in rows)
         and len({row["id"] for row in rows}) == len(rows), "unambiguous scoped native assets required")
    assets = {row["id"]: row for row in rows}
    check_originals(scenes, bindings, proofs, style, assets)
    check_plugin_budget(scenes, bindings, resolved.items, assets, image_sources)
    if not apply:
        return dict(state="planned", content_sha256=design.digest, changed=False, imported=0, missing=())
    selected, imported = {}, 0
    for item in resolved.items:
        resolved.file_pins()
        style.verify()
        proof = proofs[item.request.name]
        existing = [row for row in assets.values() if row.get("hash") == item.sha256 and row.get("ext") == "png"]
        need(len(existing) <= 1, "native original identity is ambiguous")
        if existing:
            expected_key = hashlib.sha256(canonical(dict(proof, asset_id=existing[0]["id"])).encode()).hexdigest()
            expected_id = str(uuid.uuid5(uuid.NAMESPACE_URL, "video/game-source/v1/" + expected_key))
            used_by_scene = any(any(row["assetID"] == existing[0]["id"] for row in scene["classicArtwork"]["sources"])
                                for scene in scenes.values() if scene.get("classicArtwork"))
            need(not used_by_scene or existing[0].get("evidenceID") == expected_id,
                 "existing consumed original has different evidence; retain its source and choose a separate original")
        body = dict(scope, path=str(item.path), request_id="game-source-import-v1-" + item.sha256)
        dry_run(invoke("assets import", copy.deepcopy(body), True), "normal game source import dry-run failed")
        resolved.file_pins()
        style.verify()
        asset = result(invoke("assets import", copy.deepcopy(body), False))
        need(isinstance(asset, dict) and asset.get("hash") == item.sha256 and asset.get("ext") == "png"
             and asset.get("workspaceID") == project["workspaceID"] and asset.get("mediaType", "").startswith("image")
             and asset.get("bytes") == item.path.stat().st_size, "normal importer returned another game original")
        same = [row for row in assets.values() if row.get("hash") == item.sha256 and row.get("ext") == "png"]
        need(len(same) <= 1 and (not same or same[0]["id"] == asset["id"]), "native duplicate original is ambiguous")
        if not same:
            imported += 1
        # Evidence is caller-supplied. No verification, licence, commercial or
        # upload permission is inferred from image generation or style matching.
        proof_key = hashlib.sha256(canonical(dict(proof, asset_id=asset["id"])).encode()).hexdigest()
        evidence_id = str(uuid.uuid5(uuid.NAMESPACE_URL, "video/game-source/v1/" + proof_key))
        evidence = dict(id=evidence_id, workspaceID=project["workspaceID"], assetID=asset["id"],
                        title="游戏补充素材来源：" + item.request.name, source=proof["source"], owner=proof["owner"],
                        claim=proof["claim"], verified=proof["verified"], commercialAllowed=proof["commercial_allowed"],
                        uploadConsent=proof["upload_consent"], checkedAt=proof["checked_at"])
        if proof["expires_at"] is not None:
            evidence["expiresAt"] = proof["expires_at"]
        # Existing same-source evidence is retained, avoiding repeated rights
        # mutation and its normal dependent-review invalidation.
        if asset.get("evidenceID") != evidence_id:
            evidence_body = dict(scope, evidence=evidence, request_id="game-source-proof-v1-" + proof_key)
            dry_run(invoke("evidence add", copy.deepcopy(evidence_body), True), "normal source evidence dry-run failed")
            resolved.file_pins()
            style.verify()
            result(invoke("evidence add", copy.deepcopy(evidence_body), False))
        rows = result(invoke("assets list", scope, False))
        matches = [row for row in rows if row.get("id") == asset["id"]]
        need(len(matches) == 1 and matches[0].get("evidenceID") == evidence_id and matches[0].get("hash") == item.sha256
             and matches[0].get("workspaceID") == project["workspaceID"], "normal evidence did not bind this actual original")
        assets[asset["id"]] = matches[0]
        selected[item.request.name] = (matches[0], evidence_id)
    revision = project["revisions"][-1]
    edits = []
    for scene_id in sorted({row["scene_id"] for row in bindings}):
        original = scenes[scene_id]
        candidate = copy.deepcopy(original)
        artwork = candidate["classicArtwork"]
        additions = []
        for binding in (row for row in bindings if row["scene_id"] == scene_id):
            name = binding["name"]
            asset, evidence_id = selected[name]
            proof = proofs[name]
            sprite = dict(role=binding["role"], assetID=asset["id"], x=0, y=0, width=1, height=1)
            positions = [i for i, row in enumerate(artwork["sprites"]) if row["role"] == binding["role"]]
            if positions:
                artwork["sprites"][positions[0]] = sprite
            else:
                artwork["sprites"].append(sprite)
            source = dict(assetID=asset["id"], hash=asset["hash"], source=proof["source"], owner=proof["owner"],
                          license=proof["license"], evidenceID=evidence_id)
            old = [row for row in artwork["sources"] if row["assetID"] == asset["id"]]
            need(not old or old == [source], "existing game source has a conflicting provenance; retain it")
            if not old:
                artwork["sources"].append(source)
            artwork["originalAssetIDs"] = list(dict.fromkeys(artwork.get("originalAssetIDs", []) + proof["original_asset_ids"]))
            candidate["evidenceIDs"] = list(dict.fromkeys(candidate.get("evidenceIDs", []) + [evidence_id]))
            marker = "game-source-v1/" + hashlib.sha256(canonical(dict(proof, asset_id=asset["id"], role=binding["role"])).encode()).hexdigest()
            if marker not in artwork.get("transformation", ""):
                additions.append(marker + "\n角色 " + binding["role"] + "；" + proof["origin"] + "; PNG SHA256 " + asset["hash"]
                                 + "\n具体来源 " + proof["source"] + "\n实际原始提示：\n" + proof["actual_prompt"]
                                 + "\n实际生成/下载记录：\n" + proof["provenance"]
                                 + "\n风格参考原图SHA256：" + ",".join(sorted(pin.sha256 for pin in style.anchors)))
        if additions:
            artwork["transformation"] = (artwork.get("transformation", "")
                + "\n下载原件基础与独立补充素材，逐源区分；生成补件不是上游原件，不声称整套Q版派生。\n" + "\n".join(additions))
        need(len(artwork["sources"]) <= 64 and len({row["assetID"] for row in artwork["sources"]}) == len(artwork["sources"]),
             "game sources must stay unique within 64 entries")
        if candidate != original:
            if candidate.get("voice"):
                candidate["voice"]["listened"] = False
            for caption in candidate.get("captions", []):
                caption["confirmed"] = False
            edits.append({"replaceScene": {"_0": scene_id, "_1": candidate}})
    if not edits:
        return dict(state="unchanged", content_sha256=design.digest, missing=(), changed=False, imported=imported, revision=revision["id"])
    style.verify()
    resolved.file_pins()
    body = dict(scope, project_id=project["id"], base_revision=revision["id"], edits=edits,
                text="按已冻结内容补齐游戏角色素材，保原地图规则原音与历史；声音字幕整片重新审核")
    body["request_id"] = "game-source-bind-v1-" + hashlib.sha256(canonical(body).encode()).hexdigest()
    dry_run(invoke("edit apply", copy.deepcopy(body), True), "normal game source CAS dry-run failed")
    resolved.file_pins()
    style.verify()
    response = invoke("edit apply", copy.deepcopy(body), False)
    need(response.get("ok") is True and response.get("state") == "needs_review" and response.get("project_id") == project["id"]
         and response.get("revision"), "normal editor did not return an unreviewed matching game revision")
    return dict(state="needs_review", content_sha256=design.digest, missing=(), changed=True, imported=imported, revision=response["revision"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("binary", "workspace", "cache", "design", "style", "bindings", "image-sources"):
        parser.add_argument("--" + name, type=Path, required=True)
    for name in ("sha256", "workspace-id", "project-id"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--proofs", type=Path)
    parser.add_argument("--use", choices=("local_draft", "commercial", "upload"), default="local_draft")
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    pin = FilePin(args.binary, args.sha256)
    design = GameContentDesign.from_dict(_read_json(args.design))
    style = GameStyle.from_dict(_read_json(args.style))
    bindings = _read_json(args.bindings)
    proofs = _read_json(args.proofs) if args.proofs else None
    cache = AssetCache(args.cache)
    def invoke(command, body, dry=False):
        pin.verify()
        request = copy.deepcopy(body)
        request.setdefault("request_id", "game-source-read-" + hashlib.sha256(canonical(body).encode()).hexdigest())
        completed = subprocess.run([str(pin.path), *command.split(), "--workspace", str(args.workspace), "--input", "-"]
                                   + (["--dry-run"] if dry else []), input=canonical(request), text=True,
                                   capture_output=True, timeout=180)
        need(completed.returncode == 0 and not completed.stderr, "normal game production CLI operation failed")
        response = json.loads(completed.stdout)
        need(response.get("ok") is True, "normal game production CLI rejected operation")
        return response
    projects = result(invoke("projects list", {"workspace_id": args.workspace_id}))
    found = [project for project in projects if project.get("id") == args.project_id and project.get("workspaceID") == args.workspace_id]
    need(len(found) == 1, "one scoped native project required")
    output = produce_game_assets(design, style, cache, found[0], bindings, invoke, proofs=proofs,
                                 image_sources=_read_json(args.image_sources), apply=args.apply, use=args.use)
    print("game asset stage: " + output["state"] + "; content SHA256=" + output["content_sha256"])
    for missing in output["missing"]:
        print("needs_generation: " + missing["name"] + " (" + missing["reason"] + ")\n" + missing["prompt"])
        for reference in missing["references"]:
            print("explicit style reference: " + reference["path"] + "; SHA256=" + reference["sha256"])
    return 2 if output["missing"] else 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, OSError, KeyError, TypeError, subprocess.TimeoutExpired) as error:
        raise SystemExit("game asset production failed: " + str(error))
