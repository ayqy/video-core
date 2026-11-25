"""Read authenticated normal portable backups without buffering file containers.

The legacy bytes API keeps its original v1/v2/v3 budgets. The file API also
checks every v4 member's actual bytes before returning lazy member mappings.
Callers retain their business, CAS, history, review and restore comparisons.
"""
from collections.abc import Mapping
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import struct
import tempfile
import zlib
from repository_snapshot import decode_snapshot


MAXIMUM_BACKUP_BYTES = 350 * 1024 * 1024
MAXIMUM_SNAPSHOT_BYTES = 350 * 1024 * 1024
ENCODING = 'deflate-raw-v1'
MAGIC = b'VIDBAK04'
MAXIMUM_FILE_BYTES = 64 * 1024 * 1024 * 1024
MAXIMUM_MANIFEST_BYTES = 64 * 1024 * 1024
MAXIMUM_FILE_SNAPSHOT_BYTES = 1_000_000_000
MAXIMUM_ENTRIES = 200_000
MAXIMUM_MEMBER_READ_BYTES = 300 * 1024 * 1024
MAXIMUM_CONTAINER_BYTES = 16 + MAXIMUM_MANIFEST_BYTES + MAXIMUM_FILE_SNAPSHOT_BYTES + MAXIMUM_FILE_BYTES
CHUNK_BYTES = 1024 * 1024
_MANIFEST_KEYS = {'version', 'snapshotEncoding', 'snapshotBytes', 'snapshotStoredBytes',
                  'snapshotDigest', 'entries', 'totalFileBytes'}
_ENTRY_KEYS = {'kind', 'path', 'bytes', 'sha256'}


def _need(ok, message):
    if not ok:
        raise ValueError(message)


def _digest(value):
    return type(value) is str and re.fullmatch('[0-9a-f]{64}', value) is not None


def _stamp(value):
    return (value.st_dev, value.st_ino, value.st_mode, value.st_nlink, value.st_size,
            value.st_mtime_ns, value.st_ctime_ns)


@contextmanager
def _ordinary(path):
    """Keep one no-follow descriptor and reject replacement or mutation."""
    path = Path(path)
    _need(not path.is_symlink(), 'backup must be an ordinary file, not a symbolic link')
    fd = os.open(path, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0))
    with os.fdopen(fd, 'rb') as stream:
        before = os.fstat(stream.fileno())
        _need(stat.S_ISREG(before.st_mode) and before.st_nlink == 1,
              'backup must be an ordinary file with one link')
        yield stream, _stamp(before)
        _need(_stamp(os.fstat(stream.fileno())) == _stamp(before)
              and _stamp(os.stat(path, follow_symlinks=False)) == _stamp(before),
              'backup file changed while reading')


def _read(stream, count, digest=None):
    # Call only with independently checked finite lengths. Avoid a whole-file
    # read even for a bounded snapshot or the legacy envelope.
    result = bytearray()
    while len(result) < count:
        block = stream.read(min(CHUNK_BYTES, count - len(result)))
        _need(block, 'backup payload is truncated')
        if digest is not None:
            digest.update(block)
        result.extend(block)
    return bytes(result)


def file_identity(path):
    """Return actual size/SHA256 using bounded blocks and a stable descriptor."""
    with _ordinary(path) as (stream, stamp):
        _need(0 <= stamp[4] <= MAXIMUM_CONTAINER_BYTES, 'backup file exceeds its input budget')
        digest = hashlib.sha256()
        while True:
            block = stream.read(CHUNK_BYTES)
            if not block:
                break
            digest.update(block)
        return dict(bytes=stamp[4], sha256=digest.hexdigest())


def copy_verified_file(source, destination, *, expected):
    """Copy a pinned backup in blocks; preserve any different existing output."""
    _need(isinstance(expected, dict) and set(expected) == {'bytes', 'sha256'}
          and type(expected['bytes']) is int and 0 <= expected['bytes'] <= MAXIMUM_CONTAINER_BYTES
          and _digest(expected['sha256']), 'explicit complete backup identity required')
    target = Path(destination)
    if target.exists() or target.is_symlink():
        _need(file_identity(target) == expected, 'preserve existing different backup output')
        return target
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with _ordinary(source) as (stream, stamp):
            _need(stamp[4] == expected['bytes'], 'source backup size differs')
            with tempfile.NamedTemporaryFile(prefix='.backup-', dir=target.parent, delete=False) as output:
                temporary = Path(output.name)
                digest = hashlib.sha256()
                while True:
                    block = stream.read(CHUNK_BYTES)
                    if not block:
                        break
                    output.write(block)
                    digest.update(block)
                _need(digest.hexdigest() == expected['sha256'], 'source backup digest differs')
                output.flush()
                os.fsync(output.fileno())
        # Atomic no-overwrite publication; the temporary link is removed below.
        try:
            os.link(temporary, target)
        except FileExistsError:
            _need(file_identity(target) == expected, 'preserve concurrently created different backup')
        return target
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def _inflate(blob, count):
    decoder = zlib.decompressobj(-15)
    try:
        raw = decoder.decompress(blob, count + 1)
    except zlib.error as error:
        raise ValueError('compressed backup snapshot is corrupt') from error
    _need(len(raw) == count and decoder.eof and not decoder.unused_data and not decoder.unconsumed_tail,
          'compressed backup length, end or trailing bytes differ')
    return raw


def decoded_snapshot(archive):
    if not isinstance(archive, dict):
        raise ValueError('normal backup envelope must be a dictionary')
    blob, version = archive.get('snapshot'), archive.get('version')
    if type(blob) is not bytes or not 0 < len(blob) <= MAXIMUM_SNAPSHOT_BYTES or type(version) is not int:
        raise ValueError('normal backup snapshot input or version is invalid')
    if version in (1, 2):
        if archive.get('snapshotEncoding') is not None or archive.get('snapshotBytes') is not None:
            raise ValueError('legacy backup cannot contain compressed-snapshot metadata')
        raw = blob
    elif version == 3:
        count = archive.get('snapshotBytes')
        if archive.get('snapshotEncoding') != ENCODING or type(count) is not int or not 0 < count <= MAXIMUM_SNAPSHOT_BYTES:
            raise ValueError('compressed backup encoding or expanded length is invalid')
        # One extra byte detects a false short declaration without an unbounded
        # flush or expansion beyond the declared budget.
        raw = _inflate(blob, count)
    else:
        raise ValueError('normal backup version is unsupported')
    if hashlib.sha256(raw).hexdigest() != archive.get('digest'):
        raise ValueError('normal backup decoded snapshot digest differs')
    return raw


def read_backup(raw, *, maximum_bytes=MAXIMUM_BACKUP_BYTES):
    if type(raw) is not bytes or type(maximum_bytes) is not int or not 0 < maximum_bytes <= MAXIMUM_BACKUP_BYTES or not 0 < len(raw) <= maximum_bytes:
        raise ValueError('normal backup envelope exceeds its bounded input budget')
    _need(not raw.startswith(MAGIC), 'file backup requires the streaming file API')
    archive = plistlib.loads(raw)
    snapshot = decode_snapshot(decoded_snapshot(archive), maximum_bytes=MAXIMUM_SNAPSHOT_BYTES,
                               allow_unversioned=True)
    if not isinstance(snapshot, dict):
        raise ValueError('normal backup JSON snapshot must be a dictionary')
    return archive, snapshot


class _FileMembers(Mapping):
    """Verified v4 members, reopened only when a caller needs one small file."""
    def __init__(self, path, stamp, entries):
        self._path, self._stamp, self._entries = path, stamp, entries

    def _stable(self):
        _need(_stamp(os.stat(self._path, follow_symlinks=False)) == self._stamp,
              'verified backup changed before member access')

    def __iter__(self):
        self._stable()
        return iter(self._entries)

    def __len__(self):
        self._stable()
        return len(self._entries)

    def __getitem__(self, key):
        return self.read_member(key)

    def read_member(self, key, *, maximum_bytes=MAXIMUM_MEMBER_READ_BYTES):
        entry = self._entries[key]
        _need(type(maximum_bytes) is int and 0 <= maximum_bytes <= MAXIMUM_MEMBER_READ_BYTES
              and entry['bytes'] <= maximum_bytes,
              'member is too large for bytes access; use its verified file identity')
        with _ordinary(self._path) as (stream, stamp):
            _need(stamp == self._stamp, 'verified backup changed before member access')
            stream.seek(entry['offset'])
            digest = hashlib.sha256()
            value = _read(stream, entry['bytes'], digest)
            _need(digest.hexdigest() == entry['sha256'], 'verified backup member bytes changed')
            return value

    def identities(self):
        self._stable()
        return {name: dict(bytes=row['bytes'], sha256=row['sha256']) for name, row in self._entries.items()}

    def __eq__(self, other):
        if not isinstance(other, Mapping):
            return NotImplemented
        return self.identities() == _member_identities(other)


def _member_identities(members):
    if isinstance(members, _FileMembers):
        return members.identities()
    _need(isinstance(members, Mapping), 'portable members must be a mapping')
    result = {}
    for name, value in members.items():
        _need(type(name) is str and type(value) is bytes, 'legacy portable member must contain bytes')
        result[name] = dict(bytes=len(value), sha256=hashlib.sha256(value).hexdigest())
    return result


def member_identities(archive, kind):
    """Compare complete verified sets without allocating all v4 member bytes."""
    _need(kind in ('assets', 'exports', 'visualCache'), 'unknown portable member kind')
    return _member_identities(archive.get(kind) or {})


def _entry(entry):
    _need(type(entry) is dict and set(entry) == _ENTRY_KEYS, 'exact portable member fields required')
    kind, path, size, digest = (entry.get(k) for k in ('kind', 'path', 'bytes', 'sha256'))
    _need(type(kind) is str and kind in ('assets', 'exports', 'visualCache')
          and type(path) is str and len(path.encode('utf-8')) <= 4096
          and type(size) is int and 0 <= size <= MAXIMUM_FILE_BYTES and _digest(digest),
          'portable member kind, path, size or digest is invalid')
    if kind == 'assets':
        match = re.fullmatch(r'assets/([a-f0-9]{64})\.[a-z0-9]{1,12}', path)
        _need(match is not None and match.group(1) == digest, 'portable asset CAS path differs from its digest')
    elif kind == 'exports':
        _need('..' not in path and re.fullmatch(r'(exports/[a-z0-9-]+/[A-Za-z0-9._-]+|drafts/[a-z0-9-]+\.txt)', path),
              'portable export path is invalid')
    else:
        _need(re.fullmatch(r'cache/visuals/[a-f0-9]{64}\.(plist|mp4)', path), 'portable visual-cache path is invalid')
    return kind, path, size, digest


def read_backup_file(path, *, maximum_bytes=None):
    """Authenticate a complete ordinary file; all v4 members are stream hashed.

    ``maximum_bytes`` is an optional tighter caller budget. Legacy input always
    retains the old 350 MiB limit. The returned mappings do not retain an open
    descriptor and reject subsequent source replacement or mutation.
    """
    _need(maximum_bytes is None or type(maximum_bytes) is int and 0 < maximum_bytes <= MAXIMUM_CONTAINER_BYTES,
          'backup file input budget is invalid')
    path = Path(path).absolute()
    with _ordinary(path) as (stream, stamp):
        size = stamp[4]
        _need(0 < size <= (maximum_bytes or MAXIMUM_CONTAINER_BYTES), 'backup file exceeds its input budget')
        magic = _read(stream, min(8, size))
        if magic != MAGIC:
            _need(size <= MAXIMUM_BACKUP_BYTES, 'legacy backup envelope exceeds its bounded input budget')
            stream.seek(0)
            return read_backup(_read(stream, size), maximum_bytes=min(maximum_bytes or MAXIMUM_BACKUP_BYTES, MAXIMUM_BACKUP_BYTES))
        _need(size >= 16, 'file backup header is truncated')
        manifest_size = struct.unpack('>Q', _read(stream, 8))[0]
        _need(0 < manifest_size <= MAXIMUM_MANIFEST_BYTES and manifest_size <= size - 16,
              'file backup manifest length exceeds its input budget')
        manifest_raw = _read(stream, manifest_size)
        _need(manifest_raw.startswith(b'bplist00'), 'file backup manifest must use binary property list')
        manifest = plistlib.loads(manifest_raw)
        _need(type(manifest) is dict and set(manifest) == _MANIFEST_KEYS
              and type(manifest.get('version')) is int and manifest['version'] == 4,
              'exact supported file backup manifest required')
        encoding, count, stored = (manifest.get(k) for k in ('snapshotEncoding', 'snapshotBytes', 'snapshotStoredBytes'))
        _need(type(encoding) is str and encoding in (ENCODING, 'json-raw-v1')
              and type(count) is int and 0 < count <= MAXIMUM_FILE_SNAPSHOT_BYTES
              and type(stored) is int and 0 < stored <= MAXIMUM_FILE_SNAPSHOT_BYTES
              and _digest(manifest.get('snapshotDigest'))
              and (stored < count if encoding == ENCODING else stored == count),
              'file backup snapshot encoding, lengths or digest is invalid')
        entries, total = manifest.get('entries'), manifest.get('totalFileBytes')
        _need(type(entries) is list and len(entries) <= MAXIMUM_ENTRIES
              and type(total) is int and 0 <= total <= MAXIMUM_FILE_BYTES,
              'file backup member count or total exceeds its input budget')
        groups = {kind: {} for kind in ('assets', 'exports', 'visualCache')}
        offset, measured, prior = 16 + manifest_size + stored, 0, None
        for row in entries:
            kind, name, length, digest = _entry(row)
            key = (kind, name)
            _need(prior is None or prior < key, 'file backup members must be strictly sorted and unique')
            prior = key
            measured += length
            _need(measured <= MAXIMUM_FILE_BYTES, 'file backup members exceed their total budget')
            local_name = name.removeprefix('cache/visuals/') if kind == 'visualCache' else name
            groups[kind][local_name] = dict(offset=offset, bytes=length, sha256=digest)
            offset += length
        _need(measured == total and offset == size, 'file backup total size, payload length or EOF differs')
        blob = _read(stream, stored)
        raw = _inflate(blob, count) if encoding == ENCODING else blob
        _need(hashlib.sha256(raw).hexdigest() == manifest['snapshotDigest'], 'file backup original snapshot digest differs')
        snapshot = decode_snapshot(raw, maximum_bytes=MAXIMUM_FILE_SNAPSHOT_BYTES, allow_unversioned=True)
        _need(type(snapshot) is dict, 'normal backup JSON snapshot must be a dictionary')
        # This first complete pass authenticates actual bytes, not just trusted
        # metadata, including files no caller will later ask to materialize.
        for row in entries:
            remaining, digest = row['bytes'], hashlib.sha256()
            while remaining:
                block = stream.read(min(CHUNK_BYTES, remaining))
                _need(block, 'file backup member payload is truncated')
                digest.update(block)
                remaining -= len(block)
            _need(digest.hexdigest() == row['sha256'], 'file backup member digest differs')
        _need(not stream.read(1), 'file backup contains trailing bytes')
        archive = dict(version=4, snapshot=blob, snapshotEncoding=encoding, snapshotBytes=count,
                       digest=manifest['snapshotDigest'])
        archive.update({kind: _FileMembers(path, stamp, values) for kind, values in groups.items()})
        return archive, snapshot
