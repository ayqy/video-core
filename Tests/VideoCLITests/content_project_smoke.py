#!/usr/bin/env python3
"""Exercise ordinary content projects through the actual free CLI entrypoint."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--scratch", type=Path, required=True)
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    root = Path(tempfile.mkdtemp(prefix="content-project-", dir=args.scratch.resolve(strict=True)))
    calls = 0

    def call(command, body=None, expected=0, dry=False):
        nonlocal calls
        argv = [str(binary), *command.split(), "--workspace", str(root), "--input", "-"]
        if dry:
            argv.append("--dry-run")
        process = subprocess.run(argv, input=json.dumps(body or {}), text=True,
                                 capture_output=True, timeout=30)
        assert process.returncode == expected, (command, process.returncode)
        assert not process.stderr, (command, "unexpected diagnostics")
        lines = process.stdout.strip().splitlines()
        assert len(lines) == 1, (command, "expected one machine response")
        response = json.loads(lines[0])
        assert response["ok"] == (expected == 0)
        calls += 1
        return response

    def result(response):
        value = response["result"]
        return json.loads(value) if isinstance(value, str) else value

    try:
        catalog = result(call("schema"))
        assert {1, 2} == set(catalog["ir_schema_versions"])
        workspace = result(call("workspaces create", {"name": "普通内容入口回归", "request_id": "workspace"}))
        scope = {"workspace_id": workspace["id"]}
        create = {**scope, "name": "真实空草稿", "request_id": "empty"}
        call("projects create", create, dry=True)
        assert result(call("projects list", scope)) == []
        first = call("projects create", create)
        assert call("projects create", create) == first
        call("projects create", {**create, "name": "冲突的名称"}, expected=6)
        projects = result(call("projects list", scope))
        assert len(projects) == 1
        empty = projects[0]["revisions"][-1]
        assert empty["scenes"] == [] and empty["schemaVersion"] == 2
        assert "product" not in empty and empty["contentContext"]["workspaceID"] == workspace["id"]
        assert result(call("products list", scope)) == []
        quote = result(call("render estimate", {**scope, "project_id": first["project_id"]}))
        quote["confirmed"] = True
        call("render submit", {**scope, "project_id": first["project_id"], "quote": quote,
                               "request_id": "empty-render"}, expected=5)
        script = {**scope, "knowledge": "状态取决于真实输入。", "demonstration": "执行后对照结果。",
                  "hook": "如何观察状态？", "request_id": "script"}
        call("script create", script, dry=True)
        planned = call("script create", script)
        assert call("script create", script) == planned
        call("script create", {**script, "product_id": "foreign-product", "request_id": "foreign"}, expected=2)
        call("projects create", {**scope, "name": "越权草稿", "principal": "stranger", "request_id": "denied"}, expected=3)
        projects = result(call("projects list", scope))
        assert len(projects) == 2
        teaching = next(p for p in projects if p["id"] == planned["project_id"])["revisions"][-1]
        assert "product" not in teaching and teaching["cta"] == ""
        assert [s["body"] for s in teaching["scenes"]] == [script["knowledge"], script["demonstration"]]
        assert all(not s["showPrice"] for s in teaching["scenes"])
        assert result(call("doctor"))["database"]["validated"]
        print(f"content_project_smoke: passed ({calls} actual CLI calls)")
    finally:
        shutil.rmtree(root)


if __name__ == "__main__":
    main()
