"""Read the authenticated JSON of normal v1/v2/v3 portable backups.

This checks the envelope and bounded snapshot only. Existing callers retain
their source-file, CAS, history, review and restoration comparisons.
"""
import hashlib
import json
import plistlib
import zlib


MAXIMUM_BACKUP_BYTES = 350 * 1024 * 1024
MAXIMUM_SNAPSHOT_BYTES = 350 * 1024 * 1024
ENCODING = 'deflate-raw-v1'


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
        decoder = zlib.decompressobj(-15)
        try:
            # One extra byte detects a false short declaration without an
            # unbounded flush or expansion beyond the declared budget.
            raw = decoder.decompress(blob, count + 1)
        except zlib.error as error:
            raise ValueError('compressed backup snapshot is corrupt') from error
        if len(raw) != count or not decoder.eof or decoder.unused_data or decoder.unconsumed_tail:
            raise ValueError('compressed backup length, end or trailing bytes differ')
    else:
        raise ValueError('normal backup version is unsupported')
    if hashlib.sha256(raw).hexdigest() != archive.get('digest'):
        raise ValueError('normal backup decoded snapshot digest differs')
    return raw


def read_backup(raw, *, maximum_bytes=MAXIMUM_BACKUP_BYTES):
    if type(raw) is not bytes or type(maximum_bytes) is not int or not 0 < maximum_bytes <= MAXIMUM_BACKUP_BYTES or not 0 < len(raw) <= maximum_bytes:
        raise ValueError('normal backup envelope exceeds its bounded input budget')
    archive = plistlib.loads(raw)
    snapshot = json.loads(decoded_snapshot(archive))
    if not isinstance(snapshot, dict):
        raise ValueError('normal backup JSON snapshot must be a dictionary')
    return archive, snapshot
