"""Content-first, local original-image reuse for production scripts.

The content planner supplies requirements, never a cache inventory. A generator
adapter receives one requirement's prompt only. Without an adapter, misses stay
``needs_generation`` until a caller registers a real original. Cache selection
does not grant native-workspace rights, upload consent or human review.
"""
from __future__ import annotations

from contextlib import contextmanager
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import stat
import struct
import time
import unicodedata
import uuid
import zlib


MAX_IMAGE = 16 * 1024 * 1024
MAX_TEXT = 128 * 1024
USES = frozenset(("local_draft", "commercial", "upload"))


class AssetReuseError(ValueError):
    pass


def _text(value, label, maximum=4096):
    if not isinstance(value, str) or not value.strip() or "\0" in value or len(value.encode()) > maximum:
        raise AssetReuseError(label + " must be bounded nonempty text")
    return unicodedata.normalize("NFKC", " ".join(value.split()))


def _json(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False)


def _source_text(value, label):
    _text(value, label, MAX_TEXT)
    return value  # Retain the exact source prompt/provenance, including original newlines.


def _canonical(path, *, exists=True):
    path = Path(path)
    if not path.is_absolute() or path != path.resolve(strict=exists):
        raise AssetReuseError("canonical absolute path required")
    if any(p.is_symlink() for p in (path, *path.parents)):
        raise AssetReuseError("symbolic links are not accepted")
    return path


def _read(path, maximum):
    path = _canonical(path)
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        before = os.fstat(stream.fileno())
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or not 0 < before.st_size <= maximum:
            raise AssetReuseError("bounded single-link ordinary file required")
        data = stream.read(maximum + 1)
        after, current = os.fstat(stream.fileno()), path.lstat()
        identity = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
        if identity(before) != identity(after) or identity(after) != identity(current) or len(data) != before.st_size:
            raise AssetReuseError("source changed during read")
    return data


def _same_directory(path, descriptor):
    _canonical(path)
    opened, current = os.fstat(descriptor), path.lstat()
    if not stat.S_ISDIR(current.st_mode) or (opened.st_dev, opened.st_ino) != (current.st_dev, current.st_ino):
        raise AssetReuseError("cache directory changed during operation")


@contextmanager
def _directory(path):
    path = _canonical(path)
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        _same_directory(path, descriptor)
        yield descriptor
    finally:
        os.close(descriptor)


def _png(data, *, transparent):
    """Validate bounded single-frame 8-bit RGBA/LA PNG, including alpha pixels.

    Native MaterialImporter remains the final Apple-framework decode boundary.
    Unsupported PNG variants are explicit errors, never guessed conversions.
    """
    if len(data) > MAX_IMAGE or not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise AssetReuseError("PNG original required")
    position, chunks, compressed, ended, idat_ended = 8, [], bytearray(), False, False
    width = height = channels = 0
    while position < len(data):
        if position + 12 > len(data):
            raise AssetReuseError("truncated PNG chunk")
        size = struct.unpack(">I", data[position:position + 4])[0]
        kind = data[position + 4:position + 8]
        if not re.fullmatch(b"[A-Za-z]{4}", kind) or position + 12 + size > len(data):
            raise AssetReuseError("invalid PNG chunk")
        body = data[position + 8:position + 8 + size]
        crc = struct.unpack(">I", data[position + 8 + size:position + 12 + size])[0]
        if zlib.crc32(kind + body) & 0xffffffff != crc:
            raise AssetReuseError("PNG chunk checksum mismatch")
        if not chunks and kind != b"IHDR":
            raise AssetReuseError("PNG header must be first")
        if kind == b"IHDR":
            if chunks or size != 13:
                raise AssetReuseError("invalid PNG header")
            width, height, depth, color, compression, filtering, interlace = struct.unpack(">IIBBBBB", body)
            if not (0 < width <= 4096 and 0 < height <= 4096 and width * height <= 16_777_216
                    and depth == 8 and color in (4, 6) and compression == filtering == interlace == 0):
                raise AssetReuseError("only bounded noninterlaced 8-bit RGBA/LA PNG is supported")
            channels = 4 if color == 6 else 2
        elif kind == b"IDAT":
            if idat_ended:
                raise AssetReuseError("non-contiguous PNG image data")
            compressed.extend(body)
        elif kind == b"IEND":
            if size or not compressed:
                raise AssetReuseError("invalid PNG end")
            ended = True
            position += size + 12
            break
        elif kind in (b"acTL", b"fcTL", b"fdAT") or (kind[0] & 32 == 0 and kind != b"PLTE"):
            raise AssetReuseError("animated or unknown critical PNG chunk")
        if kind != b"IDAT" and compressed:
            idat_ended = True
        chunks.append(kind)
        position += size + 12
    if not ended or position != len(data):
        raise AssetReuseError("PNG must contain exactly one complete image")
    stride = width * channels
    expected = height * (stride + 1)
    decoder = zlib.decompressobj()
    try:
        pixels = decoder.decompress(compressed, expected + 1)
    except zlib.error as error:
        raise AssetReuseError("PNG image data cannot be decompressed") from error
    if len(pixels) != expected or not decoder.eof or decoder.unused_data or decoder.unconsumed_tail:
        raise AssetReuseError("PNG decompressed size mismatch")
    previous = bytearray(stride)
    has_transparency = False
    for y in range(height):
        offset = y * (stride + 1)
        method = pixels[offset]
        row = bytearray(pixels[offset + 1:offset + 1 + stride])
        if method > 4:
            raise AssetReuseError("unknown PNG row filter")
        # The stream length/checksum/filter of every row is still checked. Once
        # a transparent pixel is proved, reconstructing further colors has no
        # bearing on this cache contract; native import performs final decode.
        if has_transparency or not transparent:
            continue
        if method:
            for x in range(stride):
                left = row[x - channels] if x >= channels else 0
                up = previous[x]
                upper_left = previous[x - channels] if x >= channels else 0
                if method == 1:
                    predictor = left
                elif method == 2:
                    predictor = up
                elif method == 3:
                    predictor = (left + up) // 2
                else:
                    p = left + up - upper_left
                    distances = (abs(p - left), abs(p - up), abs(p - upper_left))
                    predictor = (left, up, upper_left)[distances.index(min(distances))]
                row[x] = (row[x] + predictor) & 255
        has_transparency |= any(value < 255 for value in row[channels - 1::channels])
        previous = row
    if transparent and not has_transparency:
        raise AssetReuseError("requirement needs actual transparent pixels")
    return width, height


@dataclass(frozen=True)
class AssetRequest:
    name: str
    description: str
    style: str
    transparent: bool = True

    def __post_init__(self):
        for field in ("name", "description", "style"):
            object.__setattr__(self, field, _text(getattr(self, field), field))
        if type(self.transparent) is not bool:
            raise AssetReuseError("transparent must be boolean")

    @classmethod
    def from_dict(cls, value):
        if not isinstance(value, dict) or set(value) != {"name", "description", "style", "transparent"}:
            raise AssetReuseError("asset requirement fields must be name, description, style, transparent")
        return cls(**value)

    @property
    def key(self):
        canonical = {**asdict(self), "schema": 1, "format": "png"}
        canonical["name"] = self.name.casefold()
        return hashlib.sha256(_json(canonical).encode()).hexdigest()

    @property
    def generation_prompt(self):
        # Deliberately a function of content alone; no cache path/list/state enters it.
        return (f"Create one reusable illustration of {self.name}. {self.description}\n"
                f"Visual style: {self.style}.\n"
                + ("Use a genuinely transparent background and preserve alpha. " if self.transparent else "Use the background described above. ")
                + "Deliver one separate PNG original, without a sprite sheet, watermark or explanatory text.")


@dataclass(frozen=True)
class AssetRights:
    owner: str
    source: str
    claim: str
    verified: bool = False
    commercial_allowed: bool = False
    upload_consent: bool = False
    expires_at: str | None = None

    def __post_init__(self):
        for field in ("owner", "source", "claim"):
            object.__setattr__(self, field, _text(getattr(self, field), field))
        if any(type(getattr(self, field)) is not bool for field in ("verified", "commercial_allowed", "upload_consent")):
            raise AssetReuseError("rights flags must be boolean")
        if self.expires_at is not None:
            self.expiry()

    def expiry(self):
        try:
            value = datetime.fromisoformat(self.expires_at.replace("Z", "+00:00"))
        except (AttributeError, TypeError, ValueError) as error:
            raise AssetReuseError("expiry must be timezone-aware ISO date") from error
        if value.tzinfo is None:
            raise AssetReuseError("expiry must have a timezone")
        return value.timestamp()

    def allowed(self, use, now):
        return ((self.expires_at is None or self.expiry() > now)
                and (use == "local_draft" or self.verified)
                and (use != "commercial" or self.commercial_allowed)
                and (use != "upload" or self.upload_consent))


@dataclass(frozen=True)
class GeneratedAsset:
    path: Path
    sha256: str
    prompt: str
    provenance: str
    rights: AssetRights


@dataclass(frozen=True)
class AssetResolution:
    request: AssetRequest
    state: str
    reason: str
    path: Path | None = None
    sha256: str | None = None
    rights: AssetRights | None = None
    generated: bool = False


class AssetCache:
    """Caller-selected local SQLite index and content-addressed original PNGs.

    ``ensure`` serializes the same key across processes through the callback.
    External resolve→imagegen→register remains an explicit two-phase handoff;
    register refuses conflicting live originals instead of overwriting them.
    """
    def __init__(self, directory: Path, *, lock_seconds=30):
        self.directory = _canonical(directory, exists=False)
        with _directory(self.directory.parent) as parent:
            try:
                os.mkdir(self.directory.name, mode=0o700, dir_fd=parent)
            except FileExistsError:
                pass
            _same_directory(self.directory.parent, parent)
        _canonical(self.directory)
        if not 0 < lock_seconds <= 300:
            raise AssetReuseError("lock timeout must be within 300 seconds")
        self.lock_seconds = lock_seconds
        with _directory(self.directory) as root:
            for name in ("objects", "locks"):
                _same_directory(self.directory, root)
                try:
                    os.mkdir(name, mode=0o700, dir_fd=root)
                except FileExistsError:
                    pass
                _canonical(self.directory / name)
        self.database = self.directory / "index.sqlite"
        with self._db() as connection:
            connection.execute("CREATE TABLE IF NOT EXISTS originals (id TEXT PRIMARY KEY, key TEXT NOT NULL, request TEXT NOT NULL, sha256 TEXT NOT NULL, bytes INTEGER NOT NULL, width INTEGER NOT NULL, height INTEGER NOT NULL, prompt TEXT NOT NULL, provenance TEXT NOT NULL, rights TEXT NOT NULL, state TEXT NOT NULL, reason TEXT NOT NULL, created REAL NOT NULL)")
            connection.execute("CREATE TABLE IF NOT EXISTS current (key TEXT PRIMARY KEY, original_id TEXT NOT NULL)")
            connection.execute("CREATE TABLE IF NOT EXISTS failures (key TEXT NOT NULL, reason TEXT NOT NULL, created REAL NOT NULL)")
            connection.execute("CREATE TABLE IF NOT EXISTS revoked_originals (sha256 TEXT PRIMARY KEY, reason TEXT NOT NULL, created REAL NOT NULL)")
            connection.execute("INSERT OR IGNORE INTO revoked_originals SELECT sha256, 'source_revoked', created FROM originals WHERE state='revoked'")

    @contextmanager
    def _db(self):
        # Work in memory, then atomically publish a complete SQLite image through
        # a pinned directory FD. SQLite never creates a journal through a caller-
        # replaceable absolute cache path. /dev/fd is supported by this Mac host.
        with self._lock("index-db"), _directory(self.directory) as root:
            connection = sqlite3.connect(":memory:")
            connection.row_factory = sqlite3.Row
            existed = False
            try:
                try:
                    descriptor = os.open("index.sqlite", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=root)
                except FileNotFoundError:
                    descriptor = None
                if descriptor is not None:
                    try:
                        value = os.fstat(descriptor)
                        if not stat.S_ISREG(value.st_mode) or value.st_nlink != 1 or not 0 < value.st_size <= 32 * 1024 * 1024:
                            raise AssetReuseError("bounded single-link cache index required")
                        source = sqlite3.connect(f"file:/dev/fd/{descriptor}?mode=ro", uri=True)
                        try:
                            source.backup(connection)
                        finally:
                            source.close()
                        existed = True
                    finally:
                        os.close(descriptor)
                schema = connection.execute("PRAGMA schema_version").fetchone()[0]
                _same_directory(self.directory, root)
                with connection:
                    yield connection
                _same_directory(self.directory, root)
                changed = connection.total_changes or schema != connection.execute("PRAGMA schema_version").fetchone()[0]
                if not existed or changed:
                    _same_directory(self.directory, root)
                    temporary = ".index-" + uuid.uuid4().hex
                    descriptor = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_RDWR | os.O_NOFOLLOW, 0o600, dir_fd=root)
                    try:
                        target = sqlite3.connect(f"/dev/fd/{descriptor}")
                        try:
                            target.execute("PRAGMA journal_mode=MEMORY")
                            connection.backup(target)
                        finally:
                            target.close()
                        if not 0 < os.fstat(descriptor).st_size <= 32 * 1024 * 1024:
                            raise AssetReuseError("cache index is full; preserve originals and choose a new cache directory")
                        os.fsync(descriptor)
                        _same_directory(self.directory, root)
                        if self.database.is_symlink():
                            raise AssetReuseError("cache index link appeared")
                        os.replace(temporary, "index.sqlite", src_dir_fd=root, dst_dir_fd=root)
                        os.fsync(root)
                    finally:
                        os.close(descriptor)
                        try:
                            os.unlink(temporary, dir_fd=root)
                        except FileNotFoundError:
                            pass
            finally:
                connection.close()

    @contextmanager
    def _lock(self, key):
        path = self.directory / "locks" / key
        with _directory(self.directory / "locks") as directory:
            _canonical(path, exists=False)
            descriptor = os.open(key, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600, dir_fd=directory)
            try:
                value = os.fstat(descriptor)
                if not stat.S_ISREG(value.st_mode) or value.st_nlink != 1:
                    raise AssetReuseError("cache lock must be ordinary single-link file")
                deadline = time.monotonic() + self.lock_seconds
                while True:
                    try:
                        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        break
                    except BlockingIOError:
                        if time.monotonic() >= deadline:
                            raise AssetReuseError("same asset is busy; retry after its generator finishes")
                        time.sleep(0.02)
                _same_directory(self.directory / "locks", directory)
                current = path.lstat()
                if (current.st_dev, current.st_ino) != (value.st_dev, value.st_ino):
                    raise AssetReuseError("cache lock changed during operation")
                yield
                _same_directory(self.directory / "locks", directory)
            finally:
                os.close(descriptor)

    def _failure(self, key, reason):
        with self._db() as connection:
            connection.execute("INSERT INTO failures VALUES (?, ?, ?)", (key, reason, time.time()))

    def _resolve(self, request, use):
        if not isinstance(request, AssetRequest) or use not in USES:
            raise AssetReuseError("typed requirement and known use required")
        with self._db() as connection:
            row = connection.execute("SELECT originals.* FROM current JOIN originals ON original_id=id WHERE current.key=?", (request.key,)).fetchone()
        if row is None:
            return AssetResolution(request, "needs_generation", "not_found")
        if not re.fullmatch(r"[a-f0-9]{64}", row["sha256"]):
            raise AssetReuseError("cache index contains an invalid original hash")
        if row["request"] != _json(asdict(request)):
            # name-only case-fold equivalence is allowed; every visual constraint stays exact.
            previous = AssetRequest.from_dict(json.loads(row["request"]))
            if previous.key != request.key:
                raise AssetReuseError("cache requirement binding mismatch")
        if row["state"] != "active":
            return AssetResolution(request, "needs_generation", row["reason"] or row["state"])
        with self._db() as connection:
            revoked = connection.execute("SELECT 1 FROM revoked_originals WHERE sha256=?", (row["sha256"],)).fetchone()
        if revoked:
            return AssetResolution(request, "needs_generation", "revoked")
        rights = AssetRights(**json.loads(row["rights"]))
        if not rights.allowed(use, time.time()):
            reason = "expired" if rights.expires_at and rights.expiry() <= time.time() else "use_not_permitted"
            return AssetResolution(request, "needs_generation", reason)
        path = self.directory / "objects" / (row["sha256"] + ".png")
        try:
            data = _read(path, MAX_IMAGE)
            if len(data) != row["bytes"] or hashlib.sha256(data).hexdigest() != row["sha256"]:
                raise AssetReuseError("original hash mismatch")
            if _png(data, transparent=request.transparent) != (row["width"], row["height"]):
                raise AssetReuseError("original dimensions changed")
        except (AssetReuseError, OSError) as error:
            with self._db() as connection:
                connection.execute("UPDATE originals SET state='invalid',reason='integrity_failed' WHERE id=?", (row["id"],))
            self._failure(request.key, "integrity_failed")
            return AssetResolution(request, "needs_generation", "integrity_failed")
        return AssetResolution(request, "available", "cache_hit", path, row["sha256"], rights)

    def resolve(self, request: AssetRequest, *, use="local_draft"):
        with self._lock(request.key):
            return self._resolve(request, use)

    def _register(self, request, generated, use):
        if not isinstance(generated, GeneratedAsset) or not isinstance(generated.rights, AssetRights):
            raise AssetReuseError("real GeneratedAsset and typed rights required")
        if not re.fullmatch(r"[a-f0-9]{64}", generated.sha256):
            raise AssetReuseError("pinned original SHA-256 required")
        if use not in USES:
            raise AssetReuseError("known use required")
        prompt = _source_text(generated.prompt, "actual source prompt")
        provenance = _source_text(generated.provenance, "actual generation provenance")
        if not generated.rights.allowed(use, time.time()):
            raise AssetReuseError("source rights do not permit this use")
        data = _read(generated.path, MAX_IMAGE)
        digest = hashlib.sha256(data).hexdigest()
        if digest != generated.sha256:
            raise AssetReuseError("original differs from caller pin")
        width, height = _png(data, transparent=request.transparent)
        old = self._resolve(request, use)
        if old.state == "available":
            if old.sha256 != digest:
                raise AssetReuseError("different live original already satisfies this requirement")
            return old
        with self._db() as connection:
            revoked = connection.execute("SELECT 1 FROM revoked_originals WHERE sha256=?", (digest,)).fetchone()
        if revoked:
            raise AssetReuseError("the same revoked original cannot be silently reactivated")
        path = self.directory / "objects" / (digest + ".png")
        with self._lock("object-" + digest), _directory(self.directory / "objects") as objects:
            if path.exists():
                if _read(path, MAX_IMAGE) != data:
                    raise AssetReuseError("content-addressed original is damaged; preserve it for inspection")
            else:
                _same_directory(self.directory / "objects", objects)
                temporary = ".original-" + uuid.uuid4().hex
                descriptor = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600, dir_fd=objects)
                try:
                    with os.fdopen(descriptor, "wb") as stream:
                        stream.write(data)
                        stream.flush()
                        os.fsync(stream.fileno())
                    _same_directory(self.directory / "objects", objects)
                    _canonical(path, exists=False)
                    os.replace(temporary, path.name, src_dir_fd=objects, dst_dir_fd=objects)
                    os.fsync(objects)
                finally:
                    try:
                        os.unlink(temporary, dir_fd=objects)
                    except FileNotFoundError:
                        pass
                if _read(path, MAX_IMAGE) != data:
                    raise AssetReuseError("concurrent original does not match content hash")
        identifier = str(uuid.uuid4())
        with self._db() as connection:
            if connection.execute("SELECT 1 FROM revoked_originals WHERE sha256=?", (digest,)).fetchone():
                raise AssetReuseError("source was revoked before registration committed")
            connection.execute("INSERT INTO originals VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)", (
                identifier, request.key, _json(asdict(request)), digest, len(data), width, height,
                prompt, provenance, _json(asdict(generated.rights)), "active", "", time.time()))
            connection.execute("INSERT INTO current VALUES (?,?) ON CONFLICT(key) DO UPDATE SET original_id=excluded.original_id", (request.key, identifier))
        return AssetResolution(request, "available", "registered_original", path, digest, generated.rights)

    def register(self, request: AssetRequest, generated: GeneratedAsset, *, use="local_draft"):
        with self._lock(request.key):
            try:
                return self._register(request, generated, use)
            except Exception:
                self._failure(request.key, "registration_failed")
                raise

    def ensure(self, request: AssetRequest, generator=None, *, use="local_draft"):
        with self._lock(request.key):
            old = self._resolve(request, use)
            if old.state == "available" or generator is None:
                return old
            try:
                generated = generator(request.generation_prompt)
                if not isinstance(generated, GeneratedAsset) or generated.prompt != request.generation_prompt:
                    raise AssetReuseError("adapter must return the real original for this exact prompt")
                result = self._register(request, generated, use)
                return AssetResolution(request, result.state, "generated_and_registered", result.path,
                                       result.sha256, result.rights, generated=True)
            except Exception:
                self._failure(request.key, "generation_failed")
                raise

    def revoke(self, request: AssetRequest):
        with self._lock(request.key), self._db() as connection:
            row = connection.execute("SELECT sha256 FROM originals WHERE id=(SELECT original_id FROM current WHERE key=?)", (request.key,)).fetchone()
            if row:
                connection.execute("INSERT INTO revoked_originals VALUES (?, 'source_revoked', ?) ON CONFLICT(sha256) DO NOTHING", (row["sha256"], time.time()))
                connection.execute("UPDATE originals SET state='revoked',reason='revoked' WHERE sha256=?", (row["sha256"],))
