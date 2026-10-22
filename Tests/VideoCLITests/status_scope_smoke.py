#!/usr/bin/env python3
"""Actual Core/Advanced entrypoint regression: readonly doctor and scoped status.

Creates isolated synthetic records, makes no provider or purchase request and
does not represent real customer authorization or iOS user-chain acceptance.
"""
import argparse
import copy
import json
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--advanced", type=Path)
    parser.add_argument("--scratch", type=Path, required=True)
    args = parser.parse_args()
    core = args.binary.resolve(strict=True)
    hosts = [core]
    if args.advanced:
        hosts.append(args.advanced.resolve(strict=True))
    scratch = args.scratch.resolve(strict=True)
    root = Path(tempfile.mkdtemp(prefix="status-scope-", dir=scratch))
    calls = 0

    def call(command, body=None, binary=core, expected=0, workspace=root):
        nonlocal calls
        process = subprocess.run([str(binary), *command.split(), "--workspace", str(workspace), "--input", "-"],
                                 input=json.dumps(body or {}), text=True, capture_output=True, timeout=30)
        assert process.returncode == expected, (binary.name, command, process.returncode)
        assert not process.stderr, (binary.name, command, "unexpected stderr")
        lines = process.stdout.strip().splitlines()
        assert len(lines) == 1, (command, "stdout must contain one machine envelope")
        response = json.loads(lines[0])
        assert response["schema_version"] == "1.0" and response["ok"] == (expected == 0)
        calls += 1
        return response

    def payload():
        with sqlite3.connect(root / "workspace.sqlite") as connection:
            return bytes(connection.execute("SELECT payload FROM snapshot WHERE id=1").fetchone()[0])

    def rewrite(snapshot):
        # Isolated test fixture only; shipping commands still use Repository transactions.
        with sqlite3.connect(root / "workspace.sqlite") as connection:
            connection.execute("UPDATE snapshot SET payload=? WHERE id=1", (json.dumps(snapshot, separators=(",", ":"), ensure_ascii=False).encode(),))

    try:
        workspace = call("workspaces create", {"name": "权限回归隔离记录", "request_id": "create"})["result"]
        product = {"id": "product", "workspaceID": workspace["id"], "sku": "one", "name": "课程", "checkout": "https://example.com/course",
                   "audience": "初学者", "task": "复现输入输出", "outcome": "理解上下文", "prerequisite": "", "scope": "基础知识",
                   "prices": [{"id": "price", "money": {"amount": 1, "currency": "CNY"}, "from": "2020-01-01T00:00:00Z", "source": "产品页", "verified": True}],
                   "assetIDs": [], "tags": [], "archived": False}
        call("products import", {"workspace_id": workspace["id"], "product": product, "request_id": "import"})
        draft = call("script create", {"workspace_id": workspace["id"], "product_id": product["id"], "knowledge": "输入输出共用上下文",
                                      "demonstration": "对照实际界面", "hook": "查看上下文", "purpose": "非商业教学", "request_id": "draft"})
        quote = call("render estimate", {"workspace_id": workspace["id"], "project_id": draft["project_id"]})["result"]
        quote["confirmed"] = True
        submitted = call("render submit", {"workspace_id": workspace["id"], "project_id": draft["project_id"], "quote": quote, "request_id": "original"})
        db = json.loads(payload())
        job = db["jobs"][0]
        job.update(requestKey="PRIVATE_REQUEST_KEY", remoteID="PRIVATE_REMOTE_ID", actual={"amount": 72, "currency": "USD"},
                   billing=[{"id": "PRIVATE_BILL_ID", "kind": "charge", "money": {"amount": 72, "currency": "USD"}, "source": "PRIVATE_BILL_RECEIPT", "at": "2020-01-01T00:00:00Z"}],
                   message="PRIVATE_BILL_MESSAGE", progress=1, state="needs_review",
                   artifacts=[{"id": "artifact", "path": "/private-customer-dir/video.mp4", "mime": "video/mp4", "bytes": 123, "sha256": "a" * 64, "revision": job["revisionID"]}])
        job["quote"]["provider"] = "PRIVATE_PROVIDER_REFERENCE"
        db["workspaces"][0]["grants"] = [{"id": "grant", "principal": "reviewer", "role": "reviewer", "projectIDs": [job["projectID"]],
                                             "revisionIDs": [job["revisionID"]], "expiresAt": "2099-01-01T00:00:00Z", "revoked": False}]
        new_revision = copy.deepcopy(db["projects"][0]["revisions"][-1])
        new_revision["id"] = "ungranted-revision"
        new_revision["number"] += 1
        db["projects"][0]["revisions"].append(new_revision)
        new_job = copy.deepcopy(job)
        new_job.update(id="ungranted-job", revisionID=new_revision["id"], message="PRIVATE_UNGRANTED_REVISION")
        new_job["artifacts"] = []
        db["jobs"].append(new_job)
        rewrite(db)
        before = payload()
        for host in hosts:
            doctor = call("doctor", binary=host)["result"]
            assert doctor["repository_schema"] == 1 and doctor["repository_generation"] == db["generation"]
            assert payload() == before, "doctor mutated the snapshot"
            body = {"workspace_id": workspace["id"], "job_id": submitted["job_id"], "principal": "reviewer"}
            response = call("jobs status", body, binary=host)
            assert set(response["result"]) == {"id", "projectID", "revisionID", "state", "progress", "artifacts"}
            assert response["result"]["revisionID"] == draft["revision"] and response["result"]["artifacts"][0]["sha256"] == "a" * 64
            encoded = json.dumps(response)
            for secret in ("PRIVATE_", "private-customer-dir", "ungranted-revision", "requestKey", "remoteID", "quote", "billing", "USD"):
                assert secret not in encoded, (host.name, "scoped response leaked a protected field")
            assert response["cost"]["actual"] is None
            owner = call("jobs status", {**body, "principal": "local-owner"}, binary=host)["result"]
            assert owner["actual"]["amount"] == 72 and owner["message"] == "PRIVATE_BILL_MESSAGE"
            denied = call("jobs status", {**body, "job_id": "ungranted-job"}, binary=host, expected=3)
            assert "PRIVATE_" not in json.dumps(denied)
            assert payload() == before, "status mutated the snapshot"
        db["workspaces"][0]["grants"][0]["revoked"] = True
        rewrite(db)
        for host in hosts:
            call("jobs status", {"workspace_id": workspace["id"], "job_id": submitted["job_id"], "principal": "reviewer"}, binary=host, expected=3)
        # A decodable but invalid model must fail a real domain validation probe.
        db["products"][0]["scope"] = ""
        rewrite(db)
        invalid = payload()
        for host in hosts:
            call("doctor", binary=host, expected=2)
            assert payload() == invalid, "failed doctor changed invalid source data"
            missing = root / ("missing-" + host.name)
            call("doctor", binary=host, expected=8, workspace=missing)
            assert not missing.exists(), "readonly doctor created a missing repository"
        print(f"真实宿主入口回归通过：{len(hosts)}种宿主、只读doctor有效/无效/不存在工程、原版本权限/撤销、受限JSON无财务服务标识；机器封套{calls}次。")
    finally:
        shutil.rmtree(root)


if __name__ == "__main__":
    main()
