"""Put the cover title on the first existing narrated scene, without audio edits.

This is authoring only: remove one explicit silent title scene, retain every
spoken scene and its local clock, and let normal speech attach/render own audio.
"""
from copy import deepcopy
import hashlib
from pathlib import Path


def opening_sources(recipe):
    """Changes to either authoring dependency must invalidate old recipe caches."""
    return {"recipe": hashlib.sha256(Path(recipe).read_bytes()).hexdigest(),
            "narrated_opening": hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}


def with_narrated_cover(scenes, title):
    if not isinstance(scenes, list) or len(scenes) < 2 or not isinstance(title, str) or not title.strip():
        raise ValueError("An explicit cover and complete narrated scenes are required")
    cover, first = scenes[0], scenes[1]
    if (cover.get("durationFrames") != 48 or cover.get("narration") or cover.get("voice")
            or cover.get("captions") or cover.get("sourceGain", 0) != 0 or cover.get("musicGain", 0) != 0
            or not all(isinstance(scene.get("narration"), str) and scene["narration"].strip() for scene in scenes[1:])):
        raise ValueError("Remove only the known silent cover; never discard spoken content")
    if first.get("muted", False) or first.get("voiceGain", 1) <= 0 or first.get("pauseFrames", 0) != 0:
        raise ValueError("The first complete narration must start on an audible scene at frame zero")
    result = deepcopy(scenes[1:])
    result[0]["title"] = title
    return result
