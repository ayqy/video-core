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


def _action_cost_scene(identity, subjects, story):
    """Plain editable props for independent debit events; no model evaluation."""
    value = scene(identity)
    value["durationFrames"] = 600
    value["narration"] = "".join(row["narration"] for row in story.stage("shots")["shots"])
    # Match the example's declared 13-by-7, cover-fit stage anchors. This only
    # locates real layer props; monetary quantities still come from Core.
    side = max(1280 / 13, 720 / 7)
    hands = {actor: dict(x=((1280 - 13 * side) / 2 + (column + .5) * side) / 1280,
                         y=((720 - 7 * side) / 2 + 4 * side) / 720)
             for actor, column in (("qing", 3), ("lan", 9))}
    for layer in value["layers"]:
        layer["endFrame"] = 600
        for actor in ("qing", "lan"):
            if layer["id"] == subjects[actor + "_coin"]:
                layer.update(hands[actor], startFrame=90, endFrame=300)
    for key, actor, end in (("low_qing_fee", "qing", 80), ("low_lan_fee", "lan", 80),
                            ("high_qing_fee", "qing", 600), ("high_lan_fee", "lan", 600),
                            ("high_second_fee", "qing", 600)):
        # Layer opacity multiplies StoryAction opacity: future show actions
        # provide pre-action hiding; zero base opacity would remain invisible.
        value["layers"].append(dict(id=subjects[key], kind="色块", text="", **hands[actor],
            width=.08, height=.08, color="E0AA28", opacity=1, startFrame=0,
            endFrame=end, locked=False, keyframes=[]))
    return value


def snapshot(path):
    raw = path.read_bytes()
    need(len(raw) <= 16 * 1024 * 1024, "unexpectedly large author-only backup")
    envelope = plistlib.loads(raw)
    need(sha(envelope["snapshot"]) == envelope["digest"], "normal backup snapshot hash differs")
    return json.loads(envelope["snapshot"]), envelope


def _delivery_scene(identity, subjects, story, frames):
    """Editable ordinary props only; this author-contract test renders no media."""
    value = scene(identity)
    value.update(durationFrames=frames, layers=[],
                 narration="".join(row["narration"] for row in story.stage("shots")["shots"]))
    side = max(1280 / 13, 720 / 7)
    def hand(column):
        return dict(x=((1280 - 13 * side) / 2 + (column + .5) * side) / 1280,
                    y=((720 - 7 * side) / 2 + 4 * side) / 720)
    for key in subjects:
        seller = key in ("seller", "cargo", "retained_cargo")
        retained = key.startswith("retained_")
        end = frames // 2 if key in ("cargo", "buyer_coin") else frames
        value["layers"].append(dict(id=subjects[key], kind="色块", text="",
            **hand(3 if seller else 9), width=.1, height=.1, color="26856C" if seller else "3265A8",
            opacity=0 if key == "pool" else 1, startFrame=frames // 2 if retained else 0,
            endFrame=end, locked=False, keyframes=[]))
    return value


def run(binary, output, *, action_cost=False, delivery=False):
    need(not (action_cost and delivery), "select one explicit author invocation")
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
    if action_cost:
        from examples.knowledge_action_cost import (SUBJECTS as cost_subjects, cost_models,
            presentation as cost_presentation, story_plan as cost_story_plan)
        pins[ROOT / "Integrations/examples/knowledge_action_cost.py"] = sha((ROOT / "Integrations/examples/knowledge_action_cost.py").read_bytes())
    if delivery:
        from examples.knowledge_delivery import (FRAMES as delivery_frames, SUBJECTS as delivery_subjects,
            delivery_models, presentation as delivery_presentation, story_plan as delivery_story_plan)
        path = ROOT / "Integrations/examples/knowledge_delivery.py"
        pins[path] = sha(path.read_bytes())
    calls = []
    allowed = {"workspaces create", "projects create", "projects list", "edit apply",
               "knowledge compare", "backup create", "backup restore", "doctor"}

    def call(command, body=None, dry=False, *, directory=workspace, expected=True,
             error_contains="旧轨迹仅保留作历史，请重新运行复核", error_code="needs_review"):
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
        need((process.returncode == 0) is expected and response.get("ok") is expected,
             command + " returned an unexpected outcome: " + str(response.get("error"))[:400])
        if not expected:
            need(isinstance(response.get("error"), dict) and response["error"].get("code") == error_code
                 and response.get("state") == error_code
                 and error_contains in response["error"].get("message", ""),
                 command + " must reject the unsafe edit through the normal Core verifier")
        if dry and expected:
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
    models = delivery_models() if delivery else cost_models() if action_cost else protocol_models()
    source_scenes = {key: scene("source-" + key, model=model) for key, model in models.items()}
    source_created = write("projects create", dict(scope, name="真实有限协议来源",
        scenes=list(source_scenes.values())))
    target_scene = (_delivery_scene("presentation", delivery_subjects, delivery_story_plan(), delivery_frames) if delivery
                    else _action_cost_scene("presentation", cost_subjects, cost_story_plan())
                    if action_cost else scene("presentation"))
    target_created = write("projects create", dict(scope, name="普通图层作者内部验证",
        scenes=[target_scene]))
    source_project = project(source_created["project_id"])
    target_project = project(target_created["project_id"])
    source_history = deepcopy(source_project["revisions"])
    target_history = deepcopy(target_project["revisions"])
    make_plan = delivery_presentation if delivery else cost_presentation if action_cost else presentation
    plan = make_plan(target_project, {key: row["id"] for key, row in source_scenes.items()})
    plan["target"]["mode"] = "pencil"
    plan["balances"] = []
    recorded = record_sources(source_project, plan, call)
    latest_source = project(source_project["id"])
    need(latest_source["revisions"][:-1] == source_history
         and latest_source["revisions"][-1]["id"] == recorded["revision"],
         "normal source recording changed earlier history")
    source_rows = {row["id"]: row for row in recorded["sources"]}
    baseline, alternative = ("delivered", "withheld") if delivery else ("low", "high") if action_cost else ("consent", "decline")
    flows = [(row.get("sourceActorID"), row.get("destinationActorID"), row["amount"])
        for event in source_rows[baseline]["trace"]["events"]
        for row in (event.get("ruleExecution") or {}).get("transfers", [])]
    need(sorted(flows) == ([("buyer", "seller", 3)] if delivery else [("lan", "qing", 1), ("qing", "lan", 3)]),
         "actual native payment/transfer flows differ")
    rejected_flows = [row for event in source_rows[alternative]["trace"]["events"]
        for row in (event.get("ruleExecution") or {}).get("transfers", [])]
    balances = {key: {row["id"]: row["resources"] for row in value["trace"]["finalResources"]}
                for key, value in source_rows.items()}
    expected_balances = ({"delivered": {"seller": 3, "buyer": 3}, "withheld": {"seller": 0, "buyer": 6}} if delivery
                         else {"low": {"qing": 2, "lan": 3}, "high": {"qing": 1, "lan": 0}} if action_cost
                         else {"consent": {"qing": 3, "lan": 4}, "decline": {"qing": 5, "lan": 2}})
    need(not rejected_flows and balances == expected_balances,
         "real source counterfactual balances or no-transfer result differ")
    if action_cost:
        need(recorded["version"] == 2 and source_rows["high"]["actionCost"] == dict(actionID="consent", newCost=2),
             "actual recorded source lost its explicit v2 single-cost declaration")
        pools = {key: row["trace"]["events"][-1]["ruleExecution"]["poolAfter"] for key, row in source_rows.items()}
        need(pools == {"low": 2, "high": 6}, "native final rule pools differ")
        first_costs = {key: {a["id"]: a["cost"] for a in row["trace"]["events"][2]["actors"]}
                       for key, row in source_rows.items()}
        need(first_costs == {"low": {"qing": 1, "lan": 1}, "high": {"qing": 2, "lan": 2}},
             "native first-round actual debits differ from the one-cost intervention")
    applied = apply_presentation(target_project, plan, recorded, call)
    need(applied["changed"] is True, "first normal author application did not create a revision")
    current = project(target_project["id"])
    need(current["revisions"][:-1] == target_history
         and current["revisions"][-1]["id"] == applied["revision"], "author edit changed earlier target history")
    current_scene = current["revisions"][-1]["scenes"][0]
    need(current_scene["kind"] == "图文讲解" and len(current_scene["storyActions"]) == (len(plan["beats"]) if action_cost or delivery else 9)
         and len(current_scene["storyCausality"]["sources"]) == 2
         and current_scene.get("voice") is None and current_scene.get("gameWorld") is None,
         "ordinary author must retain typed sources without private modules or unrelated speech")
    need(not any(current["revisions"][-1]["review"].values()), "author test must not grant human review")
    if delivery:
        bindings = current_scene["storyCausality"]["bindings"]
        goods = [row for row in bindings if row["kind"] == "delivery"]
        payments = [row for row in bindings if row["kind"] == "payment"]
        action_by_id = {row["id"]: row for row in current_scene["storyActions"]}
        need(len(goods) == len(payments) == 1, "one actual delivery and payment required")
        good, paid = goods[0], payments[0]
        need(good["actorID"] == paid["toActorID"] == "seller"
             and good["toActorID"] == paid["fromActorID"] == "buyer"
             and good["actionID"] in paid["requires"] and paid["amount"] == 3
             and good["eventID"] == "1-收益结算" and paid["eventID"] == "2-收益结算"
             and action_by_id[good["actionID"]]["quantity"] == 1
             and action_by_id[paid["actionID"]]["quantity"] == 3
             and action_by_id[good["actionID"]]["endFrame"] <= action_by_id[paid["actionID"]]["startFrame"],
             "actual one-good delivery and later reverse payment lost their typed causal boundary")
        forged = deepcopy(current_scene)
        next(row for row in forged["storyCausality"]["bindings"] if row["kind"] == "payment")["requires"] = []
        call("edit apply", dict(workspace_id=workspace_id, project_id=current["id"],
             base_revision=current["revisions"][-1]["id"], edits=[{"replaceScene": {"_0": forged["id"], "_1": forged}}],
             text="内部验证：缺交货前置的付款必须被正常Core拒绝"), True, expected=False,
             error_contains="售货付款必须依赖同户交给本买家的真实交货")
        need(project(current["id"])["revisions"] == current["revisions"],
             "rejected premature payment must leave the full target history unchanged")
        duplicate = deepcopy(current_scene)
        extra_subject, extra_action = "extra-claimed-cargo", "duplicate-delivery-claim"
        cargo_action = deepcopy(action_by_id[good["actionID"]])
        cargo_layer = deepcopy(next(row for row in duplicate["layers"] if row["id"] == cargo_action["subjectID"]))
        cargo_layer["id"] = extra_subject
        cargo_action.update(id=extra_action, subjectID=extra_subject)
        cargo_binding = deepcopy(good)
        cargo_binding["actionID"] = extra_action
        duplicate["layers"].append(cargo_layer)
        duplicate["storyActions"].append(cargo_action)
        duplicate["storyCausality"]["actors"].append(dict(actorID="seller", subjectID=extra_subject))
        duplicate["storyCausality"]["bindings"].append(cargo_binding)
        call("edit apply", dict(workspace_id=workspace_id, project_id=current["id"],
             base_revision=current["revisions"][-1]["id"], edits=[{"replaceScene": {"_0": duplicate["id"], "_1": duplicate}}],
             text="内部验证：直接CLI不可把同一交货转换认领成第二件货"), True, expected=False,
             error_code="invalid_input", error_contains="同一次真实交货状态转换不能重复认领")
        need(project(current["id"])["revisions"] == current["revisions"],
             "duplicate delivery rejected by native Core must leave the full target history unchanged")
    if action_cost:
        need(current_scene["storyCausality"]["version"] == 2,
             "normal target scene must retain the actual v2 causal contract")
        bindings = current_scene["storyCausality"]["bindings"]
        action_by_id = {row["id"]: row for row in current_scene["storyActions"]}
        deposits = [(row["sourceID"], row["fromActorID"], row["amount"])
                    for row in bindings if row["kind"] == "deposit"]
        need(sorted(deposits) == [("high", "lan", 2), ("high", "qing", 2), ("high", "qing", 2),
                                  ("low", "lan", 1), ("low", "qing", 1)],
             "typed deposit bindings differ from the actual per-event native debits")
        need(all(action_by_id[row["actionID"]]["quantity"] == row["amount"] for row in bindings
                 if row["kind"] in ("deposit", "transfer")),
             "editable money quantities must match the native typed bindings")
        forged = deepcopy(current_scene)
        forged["storyCausality"]["sources"][0]["trace"]["finalResources"][0]["resources"] += 1
        call("edit apply", dict(workspace_id=workspace_id, project_id=current["id"],
             base_revision=current["revisions"][-1]["id"],
             edits=[{"replaceScene": {"_0": forged["id"], "_1": forged}}],
             text="内部正常Core拒绝伪造实迹；不得写入任何旧历史"), True, expected=False)
        need(project(current["id"])["revisions"] == current["revisions"],
             "normal Core forged-trace rejection must leave the complete target history unchanged")
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
    if delivery:
        print("knowledge_story_smoke: passed (" + str(len(calls))
              + " actual normal CLI calls; delivery=v1; real sources=2; delivery_tick=5; payment_tick=11;"
              + " goods=1; payment=3; balances=3/3 vs 0/6; native_missing_delivery_rejected=true;"
              + " native_duplicate_delivery_rejected=true; idempotent=true; independent_restore=true; media=false; speech=false; review=false)")
    elif action_cost:
        print("knowledge_story_smoke: passed (" + str(len(calls))
              + " actual normal CLI calls; action_cost=v2; real sources=2; transfers=3/1 vs none;"
              + " balances=2/3 vs 1/0; pools=2/6; deposits=1/2; native_forged_trace_rejected=true;"
              + " idempotent=true; independent_restore=true; media=false; speech=false; review=false)")
    else:
        print("knowledge_story_smoke: passed (" + str(len(calls))
              + " actual normal CLI calls; real sources=2; transfers=3/1; balances=3/4 vs 5/2;"
              + " idempotent=true; independent_restore=true; media=false; speech=false; review=false)")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    choice = parser.add_mutually_exclusive_group()
    choice.add_argument("--action-cost", action="store_true",
                        help="exercise the explicit v2 one-action-cost counterfactual through the normal CLI")
    choice.add_argument("--delivery", action="store_true",
                        help="exercise actual delivery before a later payment through the normal CLI")
    args = parser.parse_args()
    try:
        run(args.binary, args.output, action_cost=args.action_cost, delivery=args.delivery)
        return 0
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print("knowledge_story_smoke: failed; dedicated workspace retained at "
              + str(args.output.absolute()) + "; " + str(error)[:600], file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
