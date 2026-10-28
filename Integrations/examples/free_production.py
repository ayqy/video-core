#!/usr/bin/env python3
"""Make an ordinary editable video with the free CLI, then restore its sources.

The content is an authored three-slot exercise. Kenney's actual English prompts
are cue sounds, never a purported Chinese narration. No model, App, activation,
paid plugin, product snapshot write or human media approval is involved.
"""
from __future__ import annotations

import argparse
import copy
from datetime import datetime, timezone
import fcntl
import hashlib
import io
import json
import math
import os
from pathlib import Path
import plistlib
import shutil
import sqlite3
import stat
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
import wave
import zipfile
from zoneinfo import ZoneInfo


# Content first: no filename, cache inventory or downloaded asset defines it.
TITLE = "放对三颗，才算完成"
KNOWLEDGE = "作者练习规则：三个空位，每格放一颗；放满三个位置才算完成。"
DEMONSTRATION = "先准备，再逐颗放入；已放数量依次为0、1、2、3，最后三个位置各一颗。"
SHOTS = (
    (60, TITLE, "三个空位，每格一颗", ""),
    (90, "先看清三个位置", "准备好，再开始。", "Ready"),
    (180, "一颗一格", "每放一颗，进度加一。", "Go"),
    (90, "三个位置都放满", "三颗齐了，操作完成。", "You win"),
)

IMAGE_ROOT = "https://raw.githubusercontent.com/KenneyNL/Starter-Kit-Match-3/4ddb3d2a50cbf247c79cafe9e7884d7d8f99c012/"
IMAGE_URL = IMAGE_ROOT + "sprites/tiles/tile-gem.png"
IMAGE_SHA = "40e70dd7fd6a0a951d309bdf6a2063e6593f52e753195bde3799dce3d1e74e30"
IMAGE_RIGHTS_URL = IMAGE_ROOT + "README.md"
IMAGE_RIGHTS_SHA = "c1e10c2f603c7cd44180ac3a0107961b300d413c1572c0c6653a88253d1fe271"
# This is the original published source package, not a generated delivery ZIP.
# Validate it in memory, retain only the exact three original Oggs and license.
VOICE_URL = "https://kenney.nl/media/pages/assets/voiceover-pack/3f7f168698-1677589897/kenney_voiceover-pack.zip"
VOICE_PACKAGE_SHA = "a5194df2f05f7ec439a8d4c1a7c20ba12ffe700d363a0733ae6fa826846af458"
VOICE_LICENSE_SHA = "57d021b53ab176ba287ee0e32abe3a31df86a2449715bf437789cf9779cc1d4e"
VOICES = (
    ("Ready", "ready.ogg", "4a49258fab1f84b00d0060e1535218b22a3b4bba61ef4d989b82e4cab15d69b3"),
    ("Go", "go.ogg", "1ba6aa2cb3710fd7c6e021622b4ef0428a0107c8f2db2e0dda8de8bcbdb56fd3"),
    ("You win", "you_win.ogg", "18907e24f8cbd0751831eed8d2dd1c2501ed587da6a7451404edf0876aa56150"),
)
RECIPE_VERSION = "free-production-2"
# Only this exact predecessor may reuse its existing business receipts. The
# resolver change does not alter the authored shots, audio originals or UUIDs.
SOURCE_REUSE_PREVIOUS_RECIPE_SHA = "5c647aa4023be1aff66c0fcf4166fe41bf9e8d54039f800b46d80ec8f43d86e7"
VOICE_ORIGINALS = tuple((name, pin, size) for (_, name, pin), size in zip(VOICES, (7313, 8283, 10736))) + (
    ("AUTHOR-LICENSE.txt", VOICE_LICENSE_SHA, 486),
)


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":"))


def unpack(response):
    value = response.get("result")
    return json.loads(value) if isinstance(value, str) and value[:1] in "[{" else value


def run(argv, *, timeout=120, data=None, cwd=None):
    result = subprocess.run([str(x) for x in argv], input=data, capture_output=True,
                            cwd=cwd, timeout=timeout)
    require(len(result.stdout) <= 10 * 1024 * 1024 and len(result.stderr) <= 64 * 1024,
            "命令输出超出有限上限；现场已保留")
    return result


def command(argv, **options):
    result = run(argv, **options)
    require(result.returncode == 0, "依赖或媒体检查失败：" + str(argv[0]))
    return result.stdout


def fetch(url, expected, maximum):
    # There is no user URL, auth header, credential, redirect destination or retry loop.
    try:
        with urllib.request.urlopen(url, timeout=40) as response:
            require(response.geturl().startswith("https://"), "来源必须保持HTTPS")
            data = response.read(maximum + 1)
    except urllib.error.HTTPError as error:
        raise RuntimeError("固定公开原件下载失败：HTTP " + str(error.code) + "；" + url) from None
    require(len(data) <= maximum and sha(data) == expected,
            "公开原件摘要变化或超限，拒绝采用：" + url)
    return data


def checked_original(path, expected, maximum):
    require(not any(item.is_symlink() for item in (path, *path.parents)),
            "原件路径不能包含符号链接：" + str(path))
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        before = os.fstat(descriptor)
        require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1 and 0 < before.st_size <= maximum,
                "原件必须是有界普通文件：" + str(path))
        with os.fdopen(descriptor, "rb", closefd=False) as stream:
            data = stream.read(maximum + 1)
        after = os.fstat(descriptor)
        require((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) ==
                (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns) and
                len(data) == before.st_size and sha(data) == expected,
                "原件摘要或读取期间状态变化，保留现场：" + str(path))
        return data
    finally:
        os.close(descriptor)


def cache_original(path, data, expected, maximum):
    require(0 < len(data) <= maximum and sha(data) == expected, "待缓存原件身份不符")
    if path.exists() or path.is_symlink():
        checked_original(path, expected, maximum)
        return path
    require(not any(item.is_symlink() for item in path.parents), "缓存父目录不能包含符号链接")
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(data)
    checked_original(path, expected, maximum)
    return path


def source_file(path, url, expected, maximum):
    if path.exists() or path.is_symlink():
        checked_original(path, expected, maximum)
        return path
    data = fetch(url, expected, maximum)
    return cache_original(path, data, expected, maximum)


def resolve_voice_sources(repo, source):
    """Resolve only the four fixed originals, without changing existing cache bytes."""
    require(not any(item.is_symlink() for item in (source, *source.parents)),
            "固定录音缓存路径不能包含符号链接")
    def target(name):
        return source / ("voice-author-license.txt" if name == "AUTHOR-LICENSE.txt" else name)

    present = []
    for name, pin, size in VOICE_ORIGINALS:
        path = target(name)
        exists = path.exists() or path.is_symlink()
        if exists:
            checked_original(path, pin, size)
        present.append(exists)
    if all(present):
        return target("AUTHOR-LICENSE.txt")

    local = repo / "ThirdParty/GameAssets/voiceover"
    require(not any(item.is_symlink() for item in (local, *local.parents)),
            "固定本地录音目录不能包含符号链接")
    local_present = [(local / name).exists() or (local / name).is_symlink()
                     for name, _, _ in VOICE_ORIGINALS]
    if any(local_present):
        require(all(local_present), "固定本地录音原件组不完整；保留现场，不改用其它声音")
        originals = {name: checked_original(local / name, pin, size)
                     for name, pin, size in VOICE_ORIGINALS}
    else:
        package = fetch(VOICE_URL, VOICE_PACKAGE_SHA, 3_000_000)
        with zipfile.ZipFile(io.BytesIO(package)) as published:
            originals = {}
            for _, filename, pin in VOICES:
                matches = [name for name in published.namelist() if name.endswith("Female/" + filename)]
                require(len(matches) == 1, "作者原录音成员不唯一")
                originals[filename] = published.read(matches[0])
            licenses = [published.read(name) for name in published.namelist()
                        if name.lower().endswith("license.txt") and published.getinfo(name).file_size < 100_000]
            matches = [data for data in licenses if sha(data) == VOICE_LICENSE_SHA]
            require(len(matches) == 1, "原作者CC0许可原件不符")
            originals["AUTHOR-LICENSE.txt"] = matches[0]
        del package  # No ZIP is written to cache or delivered.
    # Check the complete group before adding any missing member to the cache.
    for name, pin, size in VOICE_ORIGINALS:
        require(len(originals[name]) == size and sha(originals[name]) == pin, "固定录音或许可原件不符：" + name)
    for name, pin, size in VOICE_ORIGINALS:
        cache_original(target(name), originals[name], pin, size)
    return target("AUTHOR-LICENSE.txt")


class Recipe:
    """Own progress is separate from the product's workspace.sqlite."""
    def __init__(self, binary, expected, out, cache):
        self.binary, self.expected, self.out, self.cache = binary, expected, out, cache
        self.source_sha = sha(Path(__file__).read_bytes())
        require(binary.is_file() and sha(binary.read_bytes()) == expected, "CLI SHA256不符")
        cache.mkdir(parents=True, exist_ok=True)
        self.lock = (cache / "recipe.lock").open("a+b")
        try:
            fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("本配方缓存已有运行中的实例，请续接原运行")
        progress = cache / "recipe-progress.sqlite"
        existed = progress.exists()
        require(existed or not out.exists() or not any(out.iterdir()),
                "输出已有材料但缺配方进度；保留原件，请选新目录或恢复原配方缓存")
        out.mkdir(parents=True, exist_ok=True)
        self.store = sqlite3.connect(progress)
        self.store.execute("CREATE TABLE IF NOT EXISTS steps (name TEXT PRIMARY KEY, input TEXT NOT NULL, response TEXT)")
        self.store.execute("CREATE TABLE IF NOT EXISTS identity (name TEXT PRIMARY KEY, value TEXT NOT NULL)")
        identity = canonical(dict(version=RECIPE_VERSION, recipe_source_sha256=self.source_sha,
                                  binary=expected, out=str(out), shots=SHOTS))
        row = self.store.execute("SELECT value FROM identity WHERE name='recipe'").fetchone()
        previous_identity = canonical(dict(version=RECIPE_VERSION,
            recipe_source_sha256=SOURCE_REUSE_PREVIOUS_RECIPE_SHA, binary=expected, out=str(out), shots=SHOTS))
        require(row is None or row[0] in (identity, previous_identity),
                "配方输入、CLI或目标变化；不改已有制作现场")
        self.store.execute("INSERT OR IGNORE INTO identity VALUES ('recipe',?)", (identity,))
        self.store.execute("INSERT OR IGNORE INTO identity VALUES ('source_checked_at',?)",
                           (datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),))
        self.store.commit()
        self.checked_at = self.store.execute("SELECT value FROM identity WHERE name='source_checked_at'").fetchone()[0]
        self.work = out / "workspace"
        self.restored = out / "restored-workspace"

    def uid(self, name):
        return str(uuid.uuid5(uuid.NAMESPACE_URL, RECIPE_VERSION + str(self.out) + name))

    def invoke(self, name, cmd, payload=None, *, target=True, dry=False, timeout=120, fresh=False):
        require(sha(self.binary.read_bytes()) == self.expected, "CLI调用期间已变化")
        require(sha(Path(__file__).read_bytes()) == self.source_sha, "配方源码在运行期间已变化，保留原现场")
        body = copy.deepcopy(payload or {})
        body.setdefault("request_id", self.uid(name))
        target = self.work if target is True else target
        key = canonical(dict(command=cmd, body=body, target=str(target), dry=dry))
        row = self.store.execute("SELECT input,response FROM steps WHERE name=?", (name,)).fetchone()
        require(row is None or row[0] == key, "步骤输入变化，不覆盖原回执：" + name)
        if row and row[1] is not None and not fresh:
            return json.loads(row[1])
        self.store.execute("INSERT OR IGNORE INTO steps VALUES (?,?,NULL)", (name, key))
        self.store.commit()  # Persist submit intent before the native side effect.
        argv = [self.binary, *cmd.split()]
        if target:
            argv += ["--workspace", target]
        argv += ["--input", "-"]
        if dry:
            argv += ["--dry-run"]
        started = time.monotonic()
        result = run(argv, timeout=timeout, data=canonical(body).encode(), cwd=self.cache)
        try:
            value = json.loads(result.stdout)
        except (ValueError, UnicodeError):
            raise RuntimeError(cmd + "没有返回有效业务封套；请用相同参数续接原现场")
        require(result.returncode == 0 and not result.stderr and value.get("ok") is True,
                cmd + "：" + canonical(value.get("error", {})))
        self.store.execute("UPDATE steps SET response=? WHERE name=?", (canonical(value), name))
        self.store.commit()
        print(cmd + (" --dry-run" if dry else "") + " → " + value["state"] +
              " (" + str(round(time.monotonic() - started, 2)) + "s)", flush=True)
        return value

    def write(self, name, cmd, body, *, timeout=120):
        self.invoke(name + ":check", cmd, body, dry=True)
        return self.invoke(name, cmd, body, timeout=timeout)

    def current(self, wid, name):
        response = self.invoke(name, "projects list", dict(workspace_id=wid))
        matches = [p for p in unpack(response) if p["name"] == TITLE]
        require(len(matches) == 1, "需要本配方唯一普通项目")
        return matches[0]

    def edit(self, wid, project, operations, name):
        return self.write(name, "edit apply", dict(workspace_id=wid, project_id=project["id"],
            base_revision=project["revisions"][-1]["id"], edits=operations, text="普通入门操作片剪辑"))

    def backup(self, name, target):
        # backup create deliberately has no request replay. Reuse a single fully
        # written native backup if the caller stopped before recording its receipt.
        row = self.store.execute("SELECT response FROM steps WHERE name=?", (name,)).fetchone()
        if row and row[0]:
            response = json.loads(row[0])
        else:
            prior = sorted(target.glob("backup-*.videobackup"))
            require(len(prior) <= 1, "发现多个备份，不能猜测哪份属于本次操作")
            if prior:
                data = prior[0].read_bytes()
                envelope = plistlib.loads(data)
                require(sha(envelope["snapshot"]) == envelope["digest"], "旧备份封套摘要无效")
                response = dict(artifacts=[dict(path=str(prior[0]), bytes=len(data), sha256=sha(data))])
            else:
                response = self.invoke(name, "backup create", {}, target=target)
        item = response["artifacts"][0]
        path = Path(item["path"])
        require(path.is_file() and path.stat().st_size == item["bytes"] and sha(path.read_bytes()) == item["sha256"],
                "正常备份回执与原件不符")
        return path

    def original_job(self, wid, project):
        key = self.uid("submit")
        snapshot = inspect_snapshot(self.work / "workspace.sqlite")
        matches = [j for j in snapshot["jobs"] if j["requestKey"] == key and j["workspaceID"] == wid]
        require(len(matches) <= 1, "提交键对应多个作业，保留现场")
        if matches:
            job = matches[0]
            require(job["projectID"] == project["id"] and job["revisionID"] == project["revisions"][-1]["id"] and
                    job["quote"]["provider"] == "native" and job["quote"]["upper"]["amount"] == 0,
                    "原作业不属于当前冻结的零元普通制作")
            # A submit response may have been lost. Obtain the actual job by its
            # persisted native key, then use a normal fresh status receipt.
            self.invoke("original-submit-status", "jobs status", dict(workspace_id=wid, job_id=job["id"]), fresh=True)
            return job["id"]
        prior = self.store.execute("SELECT response FROM steps WHERE name='submit'").fetchone()
        require(prior is None or prior[0] is None, "已有成功提交回执但原作业不在库中，禁止补交")
        # No job exists for this key: a fresh zero-fee quote can replace an old
        # unused quote. Only our own two pending step records are renewed.
        quote = unpack(self.invoke("estimate", "render estimate",
            dict(workspace_id=wid, project_id=project["id"]), fresh=True))
        require(quote["provider"] == "native" and quote["upper"]["amount"] == 0,
                "只允许本地零元普通制作")
        quote["confirmed"] = True
        self.store.execute("DELETE FROM steps WHERE name IN ('submit','submit:check') AND response IS NULL")
        self.store.execute("DELETE FROM steps WHERE name='submit:check'")
        self.store.commit()
        response = self.write("submit", "render submit", dict(workspace_id=wid, project_id=project["id"], quote=quote))
        return response["job_id"]


def make_scene(uid, number, image_id):
    frames, title, body, cue = SHOTS[number]
    result = dict(id=uid("scene" + str(number)), kind="图文讲解", title=title, body=body,
        narration=cue, durationFrames=frames, sourceStartFrame=0, speed=1, preservePitch=True,
        locked=False, x=.5, y=.5, scale=1, voiceGain=1, sourceGain=0, musicGain=0,
        muted=False, pauseFrames=0, captions=[], simulation=dict(seed=42, initial=0,
        capacity=3, unit="本例空位", events=[]), character="", emotion="", color="2563EB",
        showPrice=False, keyframes=[], evidenceIDs=[], fontName="PingFangSC-Medium",
        paperPresentation=dict(version=1, layout="cover" if number == 0 else "explanation",
                               paperColor="FFF9EF", inkColor="243638"), layers=[])
    for i, x in enumerate((.25, .50, .75)):
        target_y, start_y = .54, .62
        keys = []
        if number == 2:
            begin, end = 24 + i * 42, 42 + i * 42
            keys = [dict(id=uid(f"key{i}-{f}"), frame=f, x=x, y=y, scale=scale)
                    for f, y, scale in ((0, start_y, .7), (begin, start_y, .7),
                                         (end, target_y, 1), (end+7, target_y, .94))]
        result["layers"].append(dict(id=uid(f"gem{number}-{i}"), kind="图片", text="",
            assetID=image_id, x=x, y=target_y if number == 3 else start_y,
            width=.10, height=.12, color="FFFFFF", opacity=1, startFrame=0,
            endFrame=frames, locked=False, keyframes=keys))
    if number:
        points = ([dict(frame=0, value=0)] if number == 1 else
            [dict(frame=f, value=v) for f, v in ((0, 0), (41, 0), (42, 1),
                (83, 1), (84, 2), (125, 2), (126, 3))] if number == 2 else
            [dict(frame=0, value=3)])
        result["layers"].append(dict(id=uid("chart"+str(number)), kind="数据图表", text="",
            x=.5, y=.30, width=.72, height=.28, color="243638", opacity=1,
            startFrame=0, endFrame=frames, locked=False, keyframes=[], dataPresentation=dict(version=1,
            chart=dict(title="放入进度", axisLabel="颗", minimum=0, maximum=3,
                series=[dict(id="placed", label="已放", color="E86F51", keyframes=points)]))))
    return result


def inspect_snapshot(path):
    connection = sqlite3.connect(path.as_uri() + "?mode=ro", uri=True)
    try:
        connection.execute("PRAGMA query_only=ON")
        return json.loads(connection.execute("SELECT payload FROM snapshot WHERE id=1").fetchone()[0])
    finally:
        connection.close()


def review_boundary(database):
    revisions = [r for p in database["projects"] for r in p["revisions"]]
    for revision in revisions:
        require(not any(revision["review"].values()), "不能自动授予任何文字/权利/媒体人审")
        for scene in revision["scenes"]:
            require(not scene.get("voice", {}).get("listened", False) and
                    all(not c["confirmed"] for c in scene["captions"]), "声音/字幕确认必须保持未审")
    require(not database["products"] and not database["providers"] and not database["publications"],
            "普通示例不能引入产品、供应商或平台发布记录")


def validate_restoration(backup, original_root, restored_root):
    archive = plistlib.loads(backup.read_bytes())
    require(sha(archive["snapshot"]) == archive["digest"], "备份封套摘要不符")
    expected = json.loads(archive["snapshot"])
    for root in (original_root, restored_root):
        actual = inspect_snapshot(root / "workspace.sqlite")
        review_boundary(actual)
        # Only the documented restore generation and artifact absolute-root
        # mapping are variable. No other field, order or media byte is ignored.
        for job in actual["jobs"]:
            for item in job["artifacts"]:
                item["path"] = Path(item["path"]).relative_to(root).as_posix()
        actual.pop("generation")
        reference = copy.deepcopy(expected)
        reference.pop("generation")
        require(actual == reference, "工程恢复存在generation/正常根映射之外的字段差异")
        for group in ("assets", "exports"):
            for relative, data in archive[group].items():
                path = root / relative
                require(path.is_file() and not path.is_symlink() and path.read_bytes() == data,
                        "源素材或产物恢复字节不同：" + relative)
    return expected, len(archive["assets"]), len(archive["exports"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--binary-sha256", help="可选预先核定的CLI摘要；未给定则固定本次实际二进制摘要")
    parser.add_argument("--output", "--out", dest="out", required=True, type=Path, help="新的输出目录；失败时用相同目录续接")
    parser.add_argument("--cache", type=Path, help="专属下载/配方进度缓存；默认在输出同级，须与输出分开")
    args = parser.parse_args()
    out = args.out.absolute()
    cache = (args.cache if args.cache else out.parent / (".free-production-" + sha(str(out).encode())[:12])).absolute()
    require(out != cache and out not in cache.parents and cache not in out.parents,
            "输出与缓存须为互不包含的专属目录")
    for path in (out, cache, args.binary.absolute()):
        require(not any(p.is_symlink() for p in (path, *path.parents)), "路径不能包含符号链接")
    repo = Path(__file__).resolve().parents[2]
    require(repo not in out.parents or repo / ".cache" in out.parents,
            "运行产物不能写入源码；请选外部输出目录或源码.cache内")
    ffmpeg, ffprobe = shutil.which("ffmpeg"), shutil.which("ffprobe")
    require(ffmpeg and ffprobe, "需要实际ffmpeg及ffprobe；安装依赖后以相同参数重跑，不替换音轨")
    binary = args.binary.resolve(strict=True)
    recipe = Recipe(binary, args.binary_sha256 or sha(binary.read_bytes()), out, cache)
    source = cache / "sources"
    source.mkdir(exist_ok=True)
    # The recipe was fully defined above, before this downstream source resolver.
    image = source_file(source / "tile-gem.png", IMAGE_URL, IMAGE_SHA, 100_000)
    image_rights = source_file(source / "image-author-readme.md", IMAGE_RIGHTS_URL, IMAGE_RIGHTS_SHA, 100_000)
    require("CC0 licensed" in image_rights.read_text(), "图像原作者CC0声明不可取")
    licensed = resolve_voice_sources(repo, source)
    require(b"CC0" in licensed.read_bytes(), "真实录音许可不可取")
    audio = []
    for words, filename, pin in VOICES:
        original, pcm = source / filename, source / (Path(filename).stem + ".wav")
        # Decode complete source without trimming, repetition, gain or new speech.
        command([ffmpeg, "-v", "error", "-nostdin", "-y", "-i", original,
                 "-ar", "48000", "-ac", "1", "-c:a", "pcm_s16le", pcm])
        with wave.open(str(pcm)) as wav:
            require(wav.getframerate() == 48000 and wav.getnchannels() == 1 and wav.getsampwidth() == 2,
                    "完整录音转换参数不符")
            frames = math.ceil(wav.getnframes() * 30 / wav.getframerate())
        require(0 < frames <= 90, "真实提示音时长不适配当前镜头，不截断")
        audio.append((words, pcm, frames, pin))
    schema = recipe.invoke("schema", "schema", target=None)
    require(len(unpack(schema)["commands"]) >= 1, "真实CLI能力目录缺失")
    recipe.invoke("capabilities", "capabilities", target=None)
    recipe.invoke("doctor-before", "doctor", target=None)
    wid = unpack(recipe.write("workspace", "workspaces create", dict(name=TITLE)))["id"]
    recipe.write("script", "script create", dict(workspace_id=wid, name=TITLE,
        knowledge=KNOWLEDGE, demonstration=DEMONSTRATION, hook=TITLE,
        purpose="非商业教学", aspect="16:9"))
    imported = []
    for index, (path, origin, claim) in enumerate([(image, IMAGE_URL,
            "原作者README明确此2D宝石图CC0；仅此原图，不扩展至品牌或其它素材。")]+[
            (pcm, VOICE_URL + "#Female/" + filename,
             "原作者CC0完整英文提示录音：" + words + "；原Ogg SHA256 " + pin +
             "；完整转换PCM，不冒中文知识旁白、真人试听或商业可交付批准。")
            for (words, pcm, _, pin), (_, filename, _) in zip(audio, VOICES)]):
        item = unpack(recipe.write("asset"+str(index), "assets import", dict(workspace_id=wid, path=str(path))))
        evidence = dict(id=recipe.uid("evidence"+str(index)), workspaceID=wid,
            title="Kenney原件来源核对", source=origin, claim=claim,
            owner="Kenney Vleugels（Kenney.nl）", commercialAllowed=False, uploadConsent=False,
            verified=True, checkedAt=recipe.checked_at, assetID=item["id"])
        # The actual first-run check time is stable across resumptions; it is
        # neither a fabricated expiry nor a human media approval.
        recipe.write("evidence"+str(index), "evidence add", dict(workspace_id=wid, evidence=evidence))
        imported.append(item)
    project = recipe.current(wid, "project-before-edit")
    scenes = [make_scene(recipe.uid, i, imported[0]["id"]) for i in range(len(SHOTS))]
    recipe.edit(wid, project, [{"removeScene": {"_0": x["id"]}} for x in project["revisions"][-1]["scenes"]] +
        [{"insertScene": {"_0": scene, "_1": i}} for i, scene in enumerate(scenes)] +
        [{"cta": {"_0": ""}}], "edit-story")
    for index, (words, pcm, frames, _) in enumerate(audio, 1):
        project = recipe.current(wid, "project-for-voice"+str(index))
        scene = project["revisions"][-1]["scenes"][index]
        plan = unpack(recipe.invoke("normalize"+str(index), "speech normalize", dict(text=words, dictionary=[]), target=None))
        plan.update(voiceIdentifier=None, confirmed=True)
        response = recipe.write("voice"+str(index), "speech attach", dict(workspace_id=wid,
            project_id=project["id"], scene_id=scene["id"], base_revision=project["revisions"][-1]["id"],
            asset_id=imported[index]["id"], speech_plan=plan, extend_scene=False, timeout_seconds=90))
        take = unpack(response)
        require(take["source_sha256"] == sha(pcm.read_bytes()) and take["duration_frames"] == frames and
                not take["listened"] and not take["captions_confirmed"], "原词录音或审核边界变化")
    project = recipe.current(wid, "project-before-render")
    job_id = recipe.original_job(wid, project)
    (out / "job.md").write_text("# 原制作作业\n\n" + job_id + "\n\n失败时使用相同参数续接此job，不创建替代job。\n")
    status = recipe.invoke("job-before-run", "jobs status", dict(workspace_id=wid, job_id=job_id), fresh=True)
    state = unpack(status)["state"]
    require(state not in ("cancelled", "cancel_requested", "unknown_remote", "billing_pending"),
            "原作业已取消或需外部核对；本配方不另交作业或处理远端费用")
    if state in ("failed", "interrupted", "running"):
        # One bounded recovery worker per invocation, always the original job.
        # Its normal lease rules wait/skip a live owner and recover stale leases.
        count = recipe.store.execute("SELECT COUNT(*) FROM steps WHERE name LIKE 'recover-worker-%' AND name NOT LIKE '%:check'").fetchone()[0]
        recipe.write("recover-worker-" + str(count), "worker run", dict(workspace_id=wid,
            job_ids=[job_id], max_jobs=1, timeout_seconds=300, resume_interrupted=True, query_remote=False), timeout=330)
    elif state == "queued":
        recipe.invoke("run", "jobs run", dict(workspace_id=wid, job_id=job_id), timeout=600)
    final = recipe.invoke("job-after-run", "jobs status", dict(workspace_id=wid, job_id=job_id), fresh=True)
    actual_job = unpack(final)
    require(actual_job["state"] == "needs_review" and len(actual_job["artifacts"]) == 4,
            "原作业尚未产生待审四件；保留原job后续接")
    for item in actual_job["artifacts"]:
        path = Path(item["path"])
        require(path.is_file() and path.stat().st_size == item["bytes"] and sha(path.read_bytes()) == item["sha256"],
                "产物与正常索引不一致")
    video = next(Path(a["path"]) for a in actual_job["artifacts"] if a["mime"] == "video/mp4")
    info = json.loads(command([ffprobe, "-v", "error", "-count_frames", "-show_streams", "-of", "json", video]))
    picture = next(s for s in info["streams"] if s["codec_type"] == "video")
    sound = next(s for s in info["streams"] if s["codec_type"] == "audio")
    total = sum(x[0] for x in SHOTS)
    require(picture["codec_name"] == "h264" and picture["width"] == 1280 and picture["height"] == 720 and
            picture["r_frame_rate"] == "30/1" and int(picture["nb_read_frames"]) == total and
            sound["codec_name"] == "aac" and sound["sample_rate"] == "48000", "完整成片参数与本例不符")
    command([ffmpeg, "-v", "error", "-xerror", "-nostdin", "-i", video, "-map", "0:v:0",
             "-map", "0:a:0", "-f", "null", "-"], timeout=120)
    backup = recipe.backup("backup", recipe.work)
    recipe.invoke("restore", "backup restore", dict(path=str(backup)), target=recipe.restored)
    doctor = unpack(recipe.invoke("doctor-restored", "doctor", {}, target=recipe.restored))
    require(doctor["database"]["read_only"] and doctor["database"]["validated"], "恢复自检未通过")
    database, source_count, output_count = validate_restoration(backup, recipe.work, recipe.restored)
    require(len(database["projects"]) == 1 and len(database["jobs"]) == 1 and output_count == 4,
            "本例必须只有一个普通作业及其四件")
    current = database["projects"][0]["revisions"][-1]
    cue_count = sum(len(s["captions"]) for s in current["scenes"])
    require(cue_count == len(VOICES), "字幕须仅对应三条真实英文原词")
    (out / "summary.md").write_text("# 免费基础制作与恢复\n\n" +
        datetime.now(ZoneInfo("Asia/Shanghai")).isoformat() + "（北京时间）。本例为作者三格放入练习，非高级游戏仿真或中文知识旁白。\n\n" +
        "配方源码SHA256 " + recipe.source_sha + "；CLI SHA256 " + recipe.expected + "；作业 " + job_id + "；版本 " + current["id"] +
        "。普通CLI素材/脚本/分层剪辑/声音/零元制作、四件及独立恢复通过。\n\n" +
        str(total) + "帧，" + str(total/30) + "秒，1280×720/30fps H.264＋48kHz AAC完整双轨解码；" +
        str(source_count) + "份真实源，" + str(len(database["projects"][0]["revisions"])) + "版，1作业/4件，" +
        str(cue_count) + "条原词字幕。正常备份及新目录恢复全字段核同，仅generation与产物根映射不同；原件逐字节同。\n\n" +
        "Ready／Go／You win来自Kenney CC0真实英文提示录音，原词字幕不冒中文讲解。来源核验与人审分开，" +
        "商业/上传未授；声音、字幕及五项Review始终未审，作业needs_review，须真实完整看听后才能作已审交付。" +
        "本配方不证明干净未安装环境、宿主模型调用、两架构发行或完整制作形态质量；运行方须另给环境证据。\n\n" +
        "|实际四件|字节|SHA256|\n|---|---:|---|\n" +
        "".join("|" + a["path"] + "|" + str(a["bytes"]) + "|" + a["sha256"] + "|\n" for a in actual_job["artifacts"]) +
        "\n含源备份：" + str(backup) + "；SHA256 " + sha(backup.read_bytes()) + "。\n\n" +
        "图像来源：" + IMAGE_URL + "；SHA256 " + IMAGE_SHA + "。\n" +
        "图像作者CC0声明：" + IMAGE_RIGHTS_URL + "；SHA256 " + IMAGE_RIGHTS_SHA + "。\n" +
        "声音原作者包：" + VOICE_URL + "；原响应SHA256 " + VOICE_PACKAGE_SHA + "；未保存或交付ZIP。" +
        "原作者许可SHA256 " + VOICE_LICENSE_SHA + "；三个原Ogg和完整PCM保存在所选缓存，工程引用的真实PCM已正常含源恢复。\n\n" +
        "|真实英文提示|原Ogg SHA256|完整PCM SHA256|实际源帧|\n|---|---|---|---:|\n" +
        "".join("|" + words + "|" + pin + "|" + sha(pcm.read_bytes()) + "|" + str(frames) + "|\n"
                for words, pcm, frames, pin in audio))
    print("免费制作配方完成；待审交接：" + str(out / "summary.md"), flush=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, sqlite3.Error, subprocess.SubprocessError, zipfile.BadZipFile) as error:
        print("制作未完成：" + str(error) + "；原目录和原作业保留，请用完全相同参数续接。", file=sys.stderr)
        raise SystemExit(2)
