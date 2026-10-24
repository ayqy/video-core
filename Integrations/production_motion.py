"""Compile authored motion into the normal, editable SceneLayer keyframe IR.

This production stage runs after content, narration and required drawings have
been designed. It never enumerates an asset cache, rewrites a prompt, changes
the script, retimes audio, or approves a preview. Coordinates and event times
are explicit author inputs on each scene's source-frame axis. The output uses
the existing Core sampler, split/speed rules, renderer and revision editor.

The CLI plans by default; --apply sends one normal CAS edit transaction, after
its normal dry-run. It does not render or generate drawings as a side effect.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import math
from pathlib import Path
import subprocess
import sys
from typing import Any, Callable


class MotionError(ValueError):
    pass


def _object(value: Any, required: set[str], optional: set[str], name: str) -> dict:
    if not isinstance(value, dict) or not required <= value.keys() or value.keys() - required - optional:
        raise MotionError(name + " has missing or unsupported fields")
    return value


def _integer(value: Any, low: int, high: int, name: str) -> int:
    if type(value) is not int or not low <= value <= high:
        raise MotionError(name + " is outside its integer range")
    return value


def _number(value: Any, low: float, high: float, name: str) -> float:
    if type(value) not in (int, float) or not math.isfinite(value) or not low <= value <= high:
        raise MotionError(name + " is outside its finite range")
    return float(value)


def _identity(value: Any, name: str) -> str:
    if not isinstance(value, str) or not value or len(value) > 200:
        raise MotionError(name + " is not an identity")
    return value


def _point(value: Any, name: str) -> tuple[float, float]:
    if not isinstance(value, list) or len(value) != 2:
        raise MotionError(name + " must contain x and y")
    return _number(value[0], 0, 1, name + ".x"), _number(value[1], 0, 1, name + ".y")


def _stable_key(scene_id: str, layer_id: str, frame: int, x: float, y: float, scale: float) -> dict:
    data = json.dumps(["motion-v1", scene_id, layer_id, frame, x, y, scale], separators=(",", ":"), allow_nan=False)
    digest = hashlib.sha256(data.encode()).hexdigest()
    identity = "-".join((digest[:8], digest[8:12], digest[12:16], digest[16:20], digest[20:32]))
    return dict(id=identity, frame=frame, x=x, y=y, scale=scale)


def _sample(layer: dict, frame: int) -> tuple[float, float, float]:
    """The existing Scene.layout linear interpolation, without changing its rules."""
    keys = sorted(layer.get("keyframes", []), key=lambda key: key["frame"])
    if not keys:
        return layer["x"], layer["y"], 1.0
    if frame <= keys[0]["frame"]:
        a = keys[0]
        return a["x"], a["y"], a["scale"]
    for a, b in zip(keys, keys[1:]):
        if frame <= b["frame"]:
            p = (frame - a["frame"]) / (b["frame"] - a["frame"])
            return tuple(a[k] + (b[k] - a[k]) * p for k in ("x", "y", "scale"))
    a = keys[-1]
    return a["x"], a["y"], a["scale"]


def _dimensions(aspect: str) -> tuple[int, int]:
    try:
        return {"16:9": (1280, 720), "9:16": (720, 1280)}[aspect]
    except (KeyError, TypeError):
        raise MotionError("unsupported revision aspect") from None


def _bounds(event: dict, aspect: str) -> tuple[float, float, float, float]:
    width, height = _dimensions(aspect)
    # At least the renderer's 24px frame margin. Authors can choose a narrower
    # drawing area to protect a title/body/caption, never a wider unsafe canvas.
    margin = (24 / width, 24 / height, 1 - 24 / width, 1 - 24 / height)
    raw = event.get("safe_rect", list(margin))
    if not isinstance(raw, list) or len(raw) != 4:
        raise MotionError("safe_rect must contain left, top, right and bottom")
    rect = tuple(_number(v, 0, 1, "safe_rect") for v in raw)
    if not (margin[0] <= rect[0] < rect[2] <= margin[2] and margin[1] <= rect[1] < rect[3] <= margin[3]):
        raise MotionError("safe_rect must remain inside the renderer safe canvas")
    return rect


def _validate_geometry(layer: dict, rect: tuple[float, float, float, float]) -> None:
    width = _number(layer.get("width"), .01, 1, "layer width")
    height = _number(layer.get("height"), .01, 1, "layer height")
    keys = sorted(layer.get("keyframes", []), key=lambda key: key["frame"])
    index = 0
    for frame in range(layer["startFrame"], layer["endFrame"]):
        if not keys:
            x, y, scale = layer["x"], layer["y"], 1.
        elif frame <= keys[0]["frame"]:
            x, y, scale = (keys[0][k] for k in ("x", "y", "scale"))
        else:
            while index + 1 < len(keys) and keys[index + 1]["frame"] < frame:
                index += 1
            if index + 1 == len(keys):
                x, y, scale = (keys[index][k] for k in ("x", "y", "scale"))
            else:
                a, b = keys[index], keys[index + 1]
                progress = (frame - a["frame"]) / (b["frame"] - a["frame"])
                x, y, scale = (a[k] + (b[k] - a[k]) * progress for k in ("x", "y", "scale"))
        if not (rect[0] - 1e-9 <= x - width * scale / 2 and x + width * scale / 2 <= rect[2] + 1e-9
                and rect[1] - 1e-9 <= y - height * scale / 2 and y + height * scale / 2 <= rect[3] + 1e-9):
            raise MotionError("motion leaves its safe_rect at source frame " + str(frame))


def _event_keys(layer: dict, event: dict) -> tuple[list[tuple[int, float, float, float]], dict | None]:
    """Large, short, authored gestures; durations remain source-frame integers."""
    start, duration = event["start_frame"], event["duration_frames"]
    end = start + duration
    base = (float(layer["x"]), float(layer["y"]))
    x, y = base
    kind = event["kind"]
    optional = {
        "pop": {"peak_scale", "initial_scale"},
        "swoop": {"from", "peak_scale", "initial_scale"},
        "transfer": {"from", "to", "arc", "peak_scale"},
        "emphasis": {"peak_scale"},
        "shake": {"distance"},
        "reveal": set(),
    }
    if kind not in optional:
        raise MotionError("unsupported authored motion kind")
    shared = {"scene_id", "layer_id", "kind", "start_frame", "duration_frames", "safe_rect", "replace_existing"}
    if event.keys() - shared - optional[kind]:
        raise MotionError(kind + " has unsupported motion parameters")
    peak = _number(event.get("peak_scale", 1.35), 1, 4, "peak_scale")
    if kind in ("pop", "swoop"):
        initial = _number(event.get("initial_scale", .25), .1, 1, "initial_scale")
        sx, sy = _point(event["from"], "from") if kind == "swoop" and "from" in event else base
        return [(start, sx, sy, initial), (start + duration * 2 // 3, x, y, peak), (end, x, y, 1.)], None
    if kind == "transfer":
        sx, sy = _point(event.get("from", list(base)), "from")
        tx, ty = _point(event.get("to"), "to")
        arc = _number(event.get("arc", .16), 0, 1, "arc")
        middle = start + duration // 2
        return [(start, sx, sy, 1.), (middle, (sx + tx) / 2, min(sy, ty) - arc, peak), (end, tx, ty, 1.)], None
    if kind == "emphasis":
        return [(start, x, y, 1.), (start + duration // 2, x, y, peak), (end, x, y, 1.)], None
    if kind == "shake":
        distance = _number(event.get("distance", .035), 0, 1, "distance")
        return [(start, x, y, 1.), (start + duration // 4, x - distance, y, 1.),
                (start + duration // 2, x + distance, y, 1.),
                (start + duration * 3 // 4, x - distance / 2, y, 1.), (end, x, y, 1.)], None
    entrance = copy.deepcopy(layer.get("entrance") or dict(version=1, kind="revealLeft", startFrame=start, endFrame=end))
    if entrance.get("version") != 1 or entrance.get("kind") != "revealLeft":
        raise MotionError("reveal only retimes an authored revealLeft entrance")
    offset = entrance.get("sourceOffsetFrames", 0)
    _integer(offset, 0, 54000, "entrance source offset")
    entrance.update(startFrame=offset + start, endFrame=offset + end)
    if entrance["endFrame"] > 54000:
        raise MotionError("reveal source window exceeds the existing IR")
    return [], entrance


def compile_motion(project: dict, spec: dict) -> dict:
    """Return one normal CAS request body; never mutate the supplied project.

    spec: version, base_revision, fps, events. Every event identifies an
    existing unlocked drawing layer, an explicit source interval and one
    gesture. Existing keyframes require replace_existing=true. This is an
    explicit author choice, not an automatic reinterpretation of old motion.
    """
    _object(spec, {"version", "base_revision", "fps", "events"}, set(), "motion spec")
    if type(spec["version"]) is not int or spec["version"] != 1:
        raise MotionError("unsupported motion spec version")
    revision = project.get("revisions", [])[-1] if project.get("revisions") else None
    if not isinstance(revision, dict) or spec["base_revision"] != revision.get("id"):
        raise MotionError("motion base revision is stale")
    fps = _integer(spec["fps"], 1, 120, "fps")
    if fps != revision.get("fps"):
        raise MotionError("motion fps must match the existing revision")
    events = spec["events"]
    if not isinstance(events, list) or not 1 <= len(events) <= 256:
        raise MotionError("motion spec requires 1 to 256 authored events")
    scenes = {s["id"]: s for s in revision.get("scenes", [])}
    if len(scenes) != len(revision.get("scenes", [])):
        raise MotionError("duplicate scene identity")
    groups: dict[tuple[str, str], list[dict]] = {}
    for raw in events:
        _object(raw, {"scene_id", "layer_id", "kind", "start_frame", "duration_frames"},
                {"safe_rect", "replace_existing", "peak_scale", "initial_scale", "from", "to", "arc", "distance"}, "motion event")
        scene_id = _identity(raw["scene_id"], "scene_id")
        layer_id = _identity(raw["layer_id"], "layer_id")
        _identity(raw["kind"], "kind")
        if "replace_existing" in raw and type(raw["replace_existing"]) is not bool:
            raise MotionError("replace_existing must be a Boolean")
        _integer(raw["start_frame"], 0, 53999, "start_frame")
        _integer(raw["duration_frames"], 4, 54000, "duration_frames")
        groups.setdefault((scene_id, layer_id), []).append(copy.deepcopy(raw))
    changed = copy.deepcopy(scenes)
    summaries = []
    for (scene_id, layer_id), group in groups.items():
        if scene_id not in scenes:
            raise MotionError("motion scene does not exist")
        scene = scenes[scene_id]
        if scene.get("locked"):
            raise MotionError("motion scene is locked")
        layers = scene.get("layers") or []
        targets = [layer for layer in layers if layer.get("id") == layer_id]
        if len(targets) != 1:
            raise MotionError("motion layer does not exist uniquely")
        original = targets[0]
        if original.get("locked"):
            raise MotionError("motion layer is locked")
        if original.get("kind") not in ("图片", "色块"):
            raise MotionError("motion gestures preserve text and numeric readability; target a drawing layer")
        if scene.get("pauseFrames", 0) and original.get("entrance") is None:
            raise MotionError("a paused drawing needs an authored entrance to preserve the renderer final-frame hold")
        start = _integer(original.get("startFrame"), 0, 53999, "layer start")
        end = _integer(original.get("endFrame"), start + 1, scene["durationFrames"], "layer end")
        group.sort(key=lambda event: event["start_frame"])
        last_end = -1
        points = []
        held = (float(original["x"]), float(original["y"]), 1.)
        candidate = copy.deepcopy(original)
        replaced_keys = any(event["kind"] != "reveal" for event in group)
        for event in group:
            event_end = event["start_frame"] + event["duration_frames"]
            if event["start_frame"] < start or event_end >= end or event["start_frame"] <= last_end:
                raise MotionError("motion intervals overlap or exceed the existing visible source window")
            last_end = event_end
            anchor = copy.deepcopy(original)
            anchor["x"], anchor["y"] = held[:2]
            keys, entrance = _event_keys(anchor, event)
            if event["kind"] == "reveal" and original.get("kind") != "图片":
                raise MotionError("reveal requires a drawing image")
            if keys:
                if event["start_frame"] > start:
                    points.append((event["start_frame"] - 1, *held))
                points += keys
                held = keys[-1][1:]
            if entrance is not None:
                candidate["entrance"] = entrance
            summaries.append(dict(scene_id=scene_id, layer_id=layer_id, kind=event["kind"],
                                  source_start=event["start_frame"], source_end=event_end))
        if points:
            if points[0][0] > start:
                points.insert(0, (start, float(original["x"]), float(original["y"]), 1.))
            by_frame = {point[0]: point for point in points}
            candidate["keyframes"] = [_stable_key(scene_id, layer_id, *point) for point in sorted(by_frame.values())]
            for key in candidate["keyframes"]:
                _number(key["x"], 0, 1, "keyframe x")
                _number(key["y"], 0, 1, "keyframe y")
                _number(key["scale"], .1, 4, "keyframe scale")
        if replaced_keys and original.get("keyframes") != candidate.get("keyframes") and original.get("keyframes") and not all(event.get("replace_existing", False) for event in group):
            raise MotionError("existing keyframes require the author's explicit replace_existing choice")
        for event in group:
            _validate_geometry(candidate, _bounds(event, revision["aspect"]))
        position = next(i for i, layer in enumerate(layers) if layer["id"] == layer_id)
        changed[scene_id]["layers"][position] = candidate
    edits = []
    for original in revision["scenes"]:
        candidate = changed[original["id"]]
        if candidate != original:
            if candidate.get("voice") is not None:
                candidate["voice"]["listened"] = False
            for caption in candidate.get("captions", []):
                caption["confirmed"] = False
            edits.append({"replaceScene": {"_0": original["id"], "_1": candidate}})
    return dict(workspace_id=project["workspaceID"], project_id=project["id"],
                base_revision=revision["id"], edits=edits,
                text="依已构思内容和真实句段编排可编辑大动作；保持原声音、字幕边界与场景时长", events=summaries)


def apply_motion(project: dict, spec: dict, invoke: Callable[[str, dict, bool], dict]) -> dict:
    """Use the shipped editor once; do not write the workspace database."""
    plan = compile_motion(project, spec)
    if not plan["edits"]:
        return dict(changed=False, scenes=0, events=len(plan["events"]), revision=plan["base_revision"])
    body = {k: v for k, v in plan.items() if k != "events"}
    digest = hashlib.sha256(json.dumps(body, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()).hexdigest()
    body["request_id"] = "production-motion-v1-" + digest
    dry = invoke("edit apply", copy.deepcopy(body), True)
    if not dry.get("ok") or dry.get("state") != "dry_run":
        raise MotionError("normal editor dry-run rejected the authored motion")
    result = invoke("edit apply", copy.deepcopy(body), False)
    if not result.get("ok") or result.get("state") != "needs_review" or result.get("project_id") != project["id"] or not result.get("revision"):
        raise MotionError("normal editor did not return a matching needs_review revision")
    return dict(changed=True, scenes=len(plan["edits"]), events=len(plan["events"]), revision=result["revision"])


def _read_json(path: Path) -> Any:
    if path.stat().st_size > 16 * 1024 * 1024:
        raise MotionError("motion input exceeds its bounded size")
    def pairs(items):
        obj = {}
        for k, v in items:
            if k in obj:
                raise MotionError("duplicate JSON field")
            obj[k] = v
        return obj
    def constant(_):
        raise MotionError("non-finite JSON number")
    return json.loads(path.read_text(), object_pairs_hook=pairs, parse_constant=constant)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--sha256", required=True, help="approved normal CLI binary SHA256")
    parser.add_argument("--workspace", type=Path, required=True)
    parser.add_argument("--workspace-id", required=True)
    parser.add_argument("--project-id", required=True)
    parser.add_argument("--spec", type=Path, required=True)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    if len(args.sha256) != 64 or any(c not in "0123456789abcdef" for c in args.sha256):
        raise MotionError("binary pin must be a lowercase SHA256")
    def invoke(command, body, dry=False):
        if hashlib.sha256(binary.read_bytes()).hexdigest() != args.sha256:
            raise MotionError("normal CLI binary changed")
        request = copy.deepcopy(body)
        request.setdefault("request_id", "production-motion-read-" + hashlib.sha256(json.dumps(request, sort_keys=True).encode()).hexdigest())
        result = subprocess.run([str(binary), *command.split(), "--workspace", str(args.workspace), "--input", "-"] + (["--dry-run"] if dry else []),
                                input=json.dumps(request, ensure_ascii=False, allow_nan=False), text=True, capture_output=True, timeout=180)
        if result.returncode or result.stderr:
            raise MotionError("normal CLI operation failed; no unchecked output is forwarded")
        try:
            response = json.loads(result.stdout)
        except (ValueError, TypeError):
            raise MotionError("normal CLI returned an invalid response") from None
        if not isinstance(response, dict) or not response.get("ok"):
            raise MotionError("normal CLI rejected the operation")
        return response
    response = invoke("projects list", {"workspace_id": args.workspace_id})
    projects = response.get("result")
    if isinstance(projects, str):
        projects = json.loads(projects)
    matches = [p for p in projects if p.get("id") == args.project_id and p.get("workspaceID") == args.workspace_id] if isinstance(projects, list) else []
    if len(matches) != 1:
        raise MotionError("the selected normal project does not exist uniquely")
    spec = _read_json(args.spec)
    if args.apply:
        result = apply_motion(matches[0], spec, invoke)
        print("motion applied" if result["changed"] else "motion already matches; no revision created")
        print("scenes=" + str(result["scenes"]) + " events=" + str(result["events"]) + " revision=" + result["revision"])
    else:
        plan = compile_motion(matches[0], spec)
        print("motion planned; workspace unchanged")
        print("scenes=" + str(len(plan["edits"])) + " events=" + str(len(plan["events"])))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (MotionError, OSError, subprocess.TimeoutExpired, ValueError, KeyError, TypeError) as error:
        print("motion failed: " + str(error), file=sys.stderr)
        raise SystemExit(1)
