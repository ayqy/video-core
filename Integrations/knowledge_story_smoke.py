#!/usr/bin/env python3
"""Exercise the public knowledge author through the actual normal CLI.

This is an internal author-contract test with ordinary shape layers. It does
not render media, synthesize speech, use advanced modules, or grant review.
Sources are real normal-Core recordings, never literal trace fixtures. All
workspace changes use the CLI. Failure retains the dedicated output directory.
"""
from copy import deepcopy
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import time
import uuid


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Integrations"))
from knowledge_story import record_sources, apply_presentation
from examples.knowledge_exchange import SUBJECTS, protocol_models, story_plan, presentation


def need(condition, message):
    if not condition:
        raise ValueError(message)


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True,
                      separators=(",", ":"), allow_nan=False).encode()


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def scene(identity, *, model=None):
    value = dict(id=identity, kind="规则模拟" if model is not None else "图文讲解",
        title="通用知识作者合同验证", body="内部普通图层合同测试，不是有声知识样片。",
        narration="", durationFrames=360 if model is not None else 480,
        evidenceIDs=[], sourceStartFrame=0, speed=1, preservePitch=True,
        locked=False, x=.5, y=.5, scale=1, voiceGain=1, sourceGain=0,
        musicGain=0, muted=False, pauseFrames=0, captions=[],
        simulation=dict(seed=19, initial=7 if model is not None else 0,
            capacity=7 if model is not None else 1, unit="硬币", events=[]),
        character="", emotion="", color="FFFFFF", showPrice=False,
        keyframes=[], layers=[], classicArtworkRequired=False)
    if model is not None:
        value["simulation"]["knowledge"] = deepcopy(model)
    else:
        value["narration"] = "".join(row["narration"] for row in story_plan().stage("shots")["shots"])
        # Codable Layer.Kind uses its actual Chinese wire value. These shapes
        # prove ordinary editable subject IDs, not finished illustration art.
        for key, x, y, color in [("qing", .25, .55, "26856C"),
                ("lan", .75, .55, "3265A8"), ("qing_coin", .4, .4, "E0AA28"),
                ("lan_coin", .7, .4, "D79820"), ("agreed", .55, .3, "9372BD"),
                ("pool", .5, .8, "FFFFFF")]:
            value["layers"].append(dict(id=SUBJECTS[key], kind="色块", text="",
                x=x, y=y, width=.12, height=.12, color=color,
                opacity=0 if key == "pool" else 1, startFrame=0, endFrame=480,
                locked=False, keyframes=[]))
    return value


def snapshot(path):
    raw = path.read_bytes()
    need(len(raw) <= 16 * 1024 * 1024, "unexpectedly large author-only backup")
    envelope = plistlib.loads(raw)
    need(sha(envelope["snapshot"]) == envelope["digest"], "normal backup snapshot hash differs")
    return json.loads(envelope["snapshot"]), envelope


def run(binary, output):
    deadline = time.monotonic() + 90
    binary = binary.resolve(strict=True)
    need(binary.is_file(), "the actual built normal CLI is required")
    need(not output.is_symlink(), "output must be a dedicated directory, not a symlink")
    output = output.absolute()
    if output.exists():
        need(output.is_dir() and not any(output.iterdir()), "output must be empty; failed workspaces are retained")
    else:
        output.mkdir(parents=True)
    workspace, restored = output / "workspace", output / "restored"
    pins = {path: sha(path.read_bytes()) for path in [binary, Path(__file__).resolve(),
        ROOT / "Integrations/knowledge_story.py", ROOT / "Integrations/story_action.py",
        ROOT / "Integrations/story_planning.py", ROOT / "Integrations/examples/knowledge_exchange.py"]}
    calls = []
    allowed = {"workspaces create", "projects create", "projects list", "edit apply",
               "knowledge compare", "backup create", "backup restore", "doctor"}

    def call(command, body=None, dry=False, *, directory=workspace):
        need(command in allowed, "unexpected command outside this author-contract test")
        need(all(sha(path.read_bytes()) == expected for path, expected in pins.items()),
             "author or binary changed during the actual CLI chain")
        remaining = deadline - time.monotonic()
        need(remaining > 0, "author-contract chain exceeded its 90-second deadline")
        data = deepcopy(body or {})
        data.setdefault("request_id", "knowledge-story-smoke-" + uuid.uuid4().hex)
        argv = [str(binary), *command.split(), "--workspace", str(directory), "--input", "-"]
        if dry:
            argv.append("--dry-run")
        process = subprocess.run(argv, input=canonical(data), stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, timeout=min(30, remaining))
        need(len(process.stdout) <= 16 * 1024 * 1024 and not process.stderr,
             command + " returned unexpected diagnostics or an unbounded response")
        lines = process.stdout.strip().splitlines()
        need(len(lines) == 1, command + " must return one normal envelope")
        response = json.loads(lines[0])
        need(response.get("request_id") == data["request_id"], command + " response is not correlated")
        need(process.returncode == 0 and response.get("ok") is True,
             command + " failed: " + str(response.get("error"))[:400])
        if dry:
            need(response.get("state") == "dry_run", command + " did not honor dry-run")
        calls.append((command, dry))
        return response

    def write(command, body):
        data = deepcopy(body)
        data.setdefault("request_id", "knowledge-story-smoke-" + uuid.uuid4().hex)
        call(command, data, True)
        return call(command, data)

    def projects():
        value = call("projects list", {"workspace_id": workspace_id})["result"]
        need(isinstance(value, list), "normal project query did not return projects")
        return value

    def project(identity):
        rows = [row for row in projects() if row["id"] == identity]
        need(len(rows) == 1, "selected project is missing or duplicated")
        return rows[0]

    def artifact(response):
        rows = response.get("artifacts", [])
        need(len(rows) == 1, "normal backup must return one actual artifact")
        row = rows[0]
        path = Path(row["path"])
        raw = path.read_bytes()
        need(len(raw) == row["bytes"] and sha(raw) == row["sha256"], "normal backup artifact changed")
        return path

    created = write("workspaces create", {"name": "公开通用知识作者合同验证"})
    workspace_id = created["result"]["id"]
    scope = dict(workspace_id=workspace_id, aspect="16:9")
    models = protocol_models()
    source_scenes = {key: scene("source-" + key, model=model) for key, model in models.items()}
    source_created = write("projects create", dict(scope, name="真实有限协议来源",
        scenes=list(source_scenes.values())))
    target_created = write("projects create", dict(scope, name="普通图层作者内部验证",
        scenes=[scene("presentation")]))
    source_project = project(source_created["project_id"])
    target_project = project(target_created["project_id"])
    source_history = deepcopy(source_project["revisions"])
    target_history = deepcopy(target_project["revisions"])
    plan = presentation(target_project, {key: row["id"] for key, row in source_scenes.items()})
    plan["target"]["mode"] = "pencil"
    plan["balances"] = []
    recorded = record_sources(source_project, plan, call)
    latest_source = project(source_project["id"])
    need(latest_source["revisions"][:-1] == source_history
         and latest_source["revisions"][-1]["id"] == recorded["revision"],
         "normal source recording changed earlier history")
    source_rows = {row["id"]: row for row in recorded["sources"]}
    flows = [(row.get("sourceActorID"), row.get("destinationActorID"), row["amount"])
        for event in source_rows["consent"]["trace"]["events"]
        for row in (event.get("ruleExecution") or {}).get("transfers", [])]
    need(sorted(flows) == [("lan", "qing", 1), ("qing", "lan", 3)], "actual two-way native flows differ")
    rejected_flows = [row for event in source_rows["decline"]["trace"]["events"]
        for row in (event.get("ruleExecution") or {}).get("transfers", [])]
    balances = {key: {row["id"]: row["resources"] for row in value["trace"]["finalResources"]}
                for key, value in source_rows.items()}
    need(not rejected_flows and balances == {"consent": {"qing": 3, "lan": 4},
         "decline": {"qing": 5, "lan": 2}}, "real source counterfactual balances or no-transfer result differ")
    applied = apply_presentation(target_project, plan, recorded, call)
    need(applied["changed"] is True, "first normal author application did not create a revision")
    current = project(target_project["id"])
    need(current["revisions"][:-1] == target_history
         and current["revisions"][-1]["id"] == applied["revision"], "author edit changed earlier target history")
    current_scene = current["revisions"][-1]["scenes"][0]
    need(current_scene["kind"] == "图文讲解" and len(current_scene["storyActions"]) == 9
         and len(current_scene["storyCausality"]["sources"]) == 2
         and current_scene.get("voice") is None and current_scene.get("gameWorld") is None,
         "ordinary author must retain typed sources without private modules or unrelated speech")
    need(not any(current["revisions"][-1]["review"].values()), "author test must not grant human review")
    before_second = sum(command == "edit apply" and not dry for command, dry in calls)
    refreshed = deepcopy(plan)
    refreshed["target"]["base_revision"] = current["revisions"][-1]["id"]
    unchanged = apply_presentation(current, refreshed, recorded, call)
    need(unchanged["changed"] is False
         and before_second == sum(command == "edit apply" and not dry for command, dry in calls)
         and project(current["id"])["revisions"] == current["revisions"],
         "same evaluated plan must not create another CAS edit")
    need(project(source_project["id"]) == latest_source, "target author changed the frozen source project")
    doctor = call("doctor")["result"]
    need(doctor["database"]["validated"] is True, "actual source workspace doctor failed")
    original_backup = artifact(call("backup create"))
    before, original_archive = snapshot(original_backup)
    need(before["projects"] == projects() and not before["jobs"] and not before["assets"],
         "author-only backup must contain the actual projects without media jobs/assets")
    call("backup restore", dict(path=str(original_backup)), True, directory=restored)
    call("backup restore", dict(path=str(original_backup)), directory=restored)
    restored_doctor = call("doctor", directory=restored)["result"]
    need(restored_doctor["database"]["validated"] is True, "independent restored workspace doctor failed")
    restored_rows = call("projects list", dict(workspace_id=workspace_id), directory=restored)["result"]
    need(restored_rows == before["projects"], "independent restore changed sources, histories, or the target revision")
    restored_backup = artifact(call("backup create", directory=restored))
    after, restored_archive = snapshot(restored_backup)
    need(after["projects"] == before["projects"] and after["assets"] == before["assets"]
         and after["jobs"] == before["jobs"] and restored_archive["assets"] == original_archive["assets"],
         "normal re-export changed actual source records, target revisions, assets or jobs")
    need(all(sha(path.read_bytes()) == expected for path, expected in pins.items()), "frozen inputs changed before completion")
    need(time.monotonic() <= deadline, "author-contract chain exceeded its 90-second deadline")
    print("knowledge_story_smoke: passed (" + str(len(calls))
          + " actual normal CLI calls; real sources=2; transfers=3/1; balances=3/4 vs 5/2;"
          + " idempotent=true; independent_restore=true; media=false; speech=false; review=false)")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        run(args.binary, args.output)
        return 0
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print("knowledge_story_smoke: failed; dedicated workspace retained at "
              + str(args.output.absolute()) + "; " + str(error)[:600], file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
