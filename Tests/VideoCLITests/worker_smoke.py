#!/usr/bin/env python3
"""Real Apple host CLI regression. Build video separately; no provider or purchase."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--scratch", type=Path, required=True)
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    scratch = args.scratch.resolve(strict=True)
    root = Path(tempfile.mkdtemp(prefix="agent-smoke-", dir=scratch))
    calls = 0
    active = None
    workspace = None

    def call(command, body=None, expected=0):
        nonlocal calls
        process = subprocess.run([str(binary), *command.split(), "--workspace", str(root), "--input", "-"],
                                 input=json.dumps(body or {}), text=True, capture_output=True, timeout=80)
        assert process.returncode == expected, (command, process.returncode, process.stdout)
        assert not process.stderr, (command, "unexpected stderr")
        lines = process.stdout.strip().splitlines()
        assert len(lines) == 1, (command, "stdout must be one machine envelope")
        result = json.loads(lines[0])
        assert result["schema_version"] == "1.0" and isinstance(result["ok"], bool)
        calls += 1
        return result

    def wait_worker(worker_id):
        end = time.monotonic() + 65
        while time.monotonic() < end:
            value = call("worker status", {"workspace_id": workspace["id"], "worker_id": worker_id})["result"]
            if value["state"] not in ("pending", "running", "stop_requested"):
                return value
            time.sleep(.25)
        raise AssertionError("finite worker exceeded test deadline")

    try:
        assert len(call("schema")["result"]["commands"]) >= 37
        workspace = call("workspaces create", {"name": "本机实际链", "request_id": "workspace"})["result"]
        assert call("workspaces create", {"name": "本机实际链", "request_id": "workspace"})["result"]["id"] == workspace["id"]
        product = {"id": "p", "workspaceID": workspace["id"], "sku": "one", "name": "课程",
                   "checkout": "https://example.com/course", "audience": "初学者", "task": "理解上下文",
                   "outcome": "复现输入输出", "prerequisite": "会用聊天", "scope": "上下文",
                   "prices": [{"id": "price", "money": {"amount": 1, "currency": "CNY"}, "from": "2020-01-01T00:00:00Z",
                               "source": "已有产品页", "verified": True}], "assetIDs": [], "tags": [], "archived": False}
        call("products import", {"workspace_id": workspace["id"], "product": product, "request_id": "product"})
        draft = {"workspace_id": workspace["id"], "product_id": "p", "knowledge": "输入输出共同占用上下文",
                 "demonstration": "在实际界面对照记录", "hook": "为什么输出也占容量", "purpose": "非商业教学",
                 "aspect": "16:9", "request_id": "draft"}
        first = call("script create", draft)
        assert call("script create", draft)["project_id"] == first["project_id"]
        call("script create", {**draft, "hook": "不同内容"}, 6)
        projects = call("projects list", {"workspace_id": workspace["id"]})["result"]
        assert len(projects) == 1
        project = projects[0]
        scene = project["revisions"][-1]["scenes"][0]
        scene.update(title="知识演示", body="输入与输出共用上下文", durationFrames=60, showPrice=False, narration="")
        edits = [{"removeScene": {"_0": s["id"]}} for s in project["revisions"][-1]["scenes"][1:]]
        edits += [{"replaceScene": {"_0": scene["id"], "_1": scene}}]
        edit = {"workspace_id": workspace["id"], "project_id": project["id"], "base_revision": first["revision"],
                "edits": edits, "request_id": "edit"}
        revision = call("edit apply", edit)["revision"]
        assert call("edit apply", edit)["revision"] == revision
        quote = call("render estimate", {"workspace_id": workspace["id"], "project_id": project["id"]})["result"]
        quote["confirmed"] = True
        job = call("render submit", {"workspace_id": workspace["id"], "project_id": project["id"],
                                     "quote": quote, "request_id": "original-job"})["job_id"]
        worker = {"workspace_id": workspace["id"], "job_ids": [job], "max_jobs": 1, "timeout_seconds": 60,
                  "request_id": "finite-background"}
        # subprocess.run returned: the launching CLI has exited before this status check.
        launched = call("worker launch", worker)["result"]
        active = launched["id"]
        try:
            assert os.getsid(launched["pid"]) == launched["pid"], "worker must own an independent OS session"
        except ProcessLookupError:
            assert call("worker status", {"workspace_id": workspace["id"], "worker_id": active})["state"] == "completed"
        assert call("worker launch", worker)["result"]["id"] == active
        terminal = wait_worker(active)
        assert terminal["state"] == "completed", terminal
        finished = call("jobs status", {"workspace_id": workspace["id"], "job_id": job})["result"]
        assert finished["state"] == "needs_review", finished
        assert finished["requestKey"] == "original-job" and finished["attempt"] == 1 and finished["artifacts"]
        call("worker launch", {**worker, "max_jobs": 2}, 6)
        empty = call("worker run", {"workspace_id": workspace["id"], "request_id": "empty", "timeout_seconds": 5})["result"]
        assert empty["state"] == "completed" and not empty["outcomes"]
        # Stop the worker which owns the next original job; its lease cannot finish late.
        new_job = call("render submit", {"workspace_id": workspace["id"], "project_id": project["id"],
                                         "quote": quote, "request_id": "resume-original"})["job_id"]
        cancel_worker = {**worker, "job_ids": [new_job], "request_id": "stoppable"}
        active = call("worker launch", cancel_worker)["result"]["id"]
        call("worker stop", {"workspace_id": workspace["id"], "worker_id": active})
        assert wait_worker(active)["state"] in ("stopped", "completed")
        state = call("jobs status", {"workspace_id": workspace["id"], "job_id": new_job})["state"]
        assert state in ("queued", "interrupted", "needs_review")
        if state != "needs_review":
            active = call("worker launch", {**cancel_worker, "request_id": "explicit-resume", "resume_interrupted": True})["result"]["id"]
            assert wait_worker(active)["state"] == "completed"
            assert call("jobs status", {"workspace_id": workspace["id"], "job_id": new_job})["state"] == "needs_review"
        assert len(call("projects list", {"workspace_id": workspace["id"]})["result"]) == 1
        print(f"真实CLI回归通过：原子重放/冲突、独立有限worker、2秒H.264原job、停止与原ID续跑；机器封套{calls}次。")
    finally:
        if active and workspace:
            try:
                call("worker stop", {"workspace_id": workspace["id"], "worker_id": active})
                wait_worker(active)
            except Exception:
                pass
        shutil.rmtree(root)


if __name__ == "__main__":
    main()
