"""Decode a pinned original take into source-frame RMS cues, without editing it.

The returned cues drive opening/closing of a cartoon mouth. They are acoustic
energy, not phonemes or recognition. Audio bytes, voice settings and approvals
are untouched. Call this after a real take exists, before the normal CAS edit.
Native decoding is run only in a managed FangFang media batch.
"""
from __future__ import annotations

import array
import hashlib
import math
from pathlib import Path
import shutil
import subprocess
import sys


class EnergyError(ValueError):
    pass


def _need(condition, message):
    if not condition:
        raise EnergyError(message)


def _hash(value):
    return hashlib.sha256(value).hexdigest()


def energy_from_pcm(raw: bytes, *, sample_rate: int, fps: int,
                    duration_frames: int, step_frames: int = 3) -> list[dict]:
    """Consume the complete decoded mono float32 stream, including its tail.

    A final sub-frame encoder pad belongs to the last cue; it is not removed
    from the original take. The declared duration comes from its VoiceTake.
    """
    _need(type(sample_rate) is int and 8000 <= sample_rate <= 192000,
          'invalid actual PCM sample rate')
    _need(type(fps) is int and 1 <= fps <= 120 and type(duration_frames) is int
          and 1 <= duration_frames <= 7200 and type(step_frames) is int
          and 1 <= step_frames <= fps, 'invalid source frame bounds')
    _need(isinstance(raw, bytes) and raw and len(raw) % 4 == 0
          and len(raw) <= sample_rate * 60 * 4, 'incomplete or unbounded mono float32 stream')
    samples = array.array('f'); samples.frombytes(raw)
    if sys.byteorder != 'little':
        samples.byteswap()
    # A float decoder/resampler can legitimately overshoot full scale even
    # when the untouched original is PCM16. Do not clip that analysis signal
    # or infer that the original audio itself was rewritten.
    _need(all(math.isfinite(v) and abs(v) <= 8 for v in samples),
          'decoded PCM is not bounded finite audio')
    seconds = len(samples) / sample_rate
    _need(abs(seconds - duration_frames / fps) <= 2 / fps,
          'actual complete PCM duration differs from the bound take')
    cues = []
    consumed = 0
    for start in range(0, duration_frames, step_frames):
        end = min(duration_frames, start + step_frames)
        stop = len(samples) if end == duration_frames else min(len(samples), end * sample_rate // fps)
        bucket = samples[consumed:stop]
        rms = math.sqrt(math.fsum(v * v for v in bucket) / len(bucket)) if bucket else 0.0
        cues.append(dict(startFrame=start, endFrame=end, rms=round(min(1, rms), 8)))
        consumed = stop
    _need(consumed == len(samples) and cues[0]['startFrame'] == 0
          and cues[-1]['endFrame'] == duration_frames, 'decoded tail was not consumed')
    return cues


def analyze_take(path: Path, *, source_sha256: str, voice_asset_id: str,
                 text_digest: str, actor_id: str, duration_frames: int,
                 fps: int = 30, step_frames: int = 3,
                 decoder: Path | None = None) -> dict:
    """Return CartoonSpeechTrack for the actual complete, immutable original.

    No arbitrary SSML, post-processing, time stretch, silence insertion or
    output audio is produced. The caller binds this to the unchanged scene.
    """
    for digest in (source_sha256, text_digest):
        _need(isinstance(digest, str) and len(digest) == 64
              and all(c in '0123456789abcdef' for c in digest), 'invalid source identity')
    for identity in (voice_asset_id, actor_id):
        _need(isinstance(identity, str) and 1 <= len(identity) <= 128,
              'invalid declared voice or actor identity')
    _need(type(duration_frames) is int and type(fps) is int and 1 <= fps <= 120
          and 1 <= duration_frames <= 60 * fps, 'take must have a bounded real duration')
    path = path.absolute()
    _need(path.is_file() and not path.is_symlink() and path.resolve() == path
          and 64 <= path.stat().st_size <= 64 * 1024 * 1024, 'original must be an ordinary bounded file')
    original = path.read_bytes()
    _need(_hash(original) == source_sha256, 'original take changed before decoding')
    decoder = (decoder or Path(shutil.which('ffmpeg') or '/missing-ffmpeg')).resolve(strict=True)
    _need(decoder.is_file() and decoder.resolve() == decoder, 'explicit ordinary decoder required')
    decoder_sha = _hash(decoder.read_bytes())
    result = subprocess.run([str(decoder), '-nostdin', '-v', 'error', '-i', str(path),
                             '-map', '0:a:0', '-vn', '-ac', '1', '-ar', '48000',
                             '-f', 'f32le', 'pipe:1'], capture_output=True, timeout=90)
    _need(result.returncode == 0 and not result.stderr, 'complete original audio decode failed')
    _need(path.read_bytes() == original and _hash(decoder.read_bytes()) == decoder_sha,
          'original or decoder changed during analysis')
    energy = energy_from_pcm(result.stdout, sample_rate=48000, fps=fps,
                             duration_frames=duration_frames, step_frames=step_frames)
    return dict(actorID=actor_id, voiceAssetID=voice_asset_id,
                sourceSHA256=source_sha256, textDigest=text_digest,
                durationFrames=duration_frames, energy=energy)
