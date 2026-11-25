"""Authenticate the private persisted model-array pool as ordinary schema-1 DTOs.

Pooled arrays are shared *read-only* views.  Deep-copy a selected scene before
editing it; ``deepcopy`` deliberately returns ordinary mutable lists/dicts.
The original array bytes, including Swift's floating-point representation, are
authenticated directly and are never re-encoded to check their digest.
"""
from copy import deepcopy
import base64
import binascii
import hashlib
import json
import re


ENCODING = 'model-array-pool-v1'
MAXIMUM_SNAPSHOT_BYTES = 1_000_000_000
ARRAY_LIMITS = {'instances': (1, 128), 'transformTracks': (0, 128), 'jointTracks': (0, 4096)}
_HASH = re.compile('[a-f0-9]{64}')


def _need(value, message):
    if not value:
        raise ValueError(message)


def _immutable(*args, **kwargs):
    raise TypeError('pooled model arrays are read-only; deepcopy the selected scene before editing')


class _ReadOnlyList(list):
    __setitem__ = __delitem__ = append = clear = extend = insert = pop = remove = reverse = sort = _immutable
    __iadd__ = __imul__ = _immutable

    def __deepcopy__(self, memo):
        return deepcopy(list(self), memo)


class _ReadOnlyDict(dict):
    __setitem__ = __delitem__ = clear = pop = popitem = setdefault = update = __ior__ = _immutable

    def __deepcopy__(self, memo):
        return deepcopy(dict(self), memo)


def _freeze(value):
    if isinstance(value, list):
        return _ReadOnlyList(_freeze(child) for child in value)
    if isinstance(value, dict):
        return _ReadOnlyDict((key, _freeze(child)) for key, child in value.items())
    return value


def _pairs(items):
    result = {}
    for key, value in items:
        _need(key not in result, 'repository JSON contains a duplicate object key')
        result[key] = value
    return result


def _invalid_constant(value):
    raise ValueError('repository JSON contains a non-finite number')


def parse_json(raw):
    return json.loads(raw, object_pairs_hook=_pairs, parse_constant=_invalid_constant)


def _no_nested_reference(value):
    pending = [value]
    while pending:
        item = pending.pop()
        if isinstance(item, dict):
            _need(not (set(item) == {'ref'} and type(item['ref']) is str and _HASH.fullmatch(item['ref'])),
                  'pooled model arrays cannot contain nested references')
            pending.extend(item.values())
        elif isinstance(item, list):
            pending.extend(item)


class ModelArrayPool:
    """One authenticated pool; returned arrays must only be read, never edited."""
    def __init__(self, pools, *, maximum_bytes=MAXIMUM_SNAPSHOT_BYTES):
        _need(type(maximum_bytes) is int and 0 < maximum_bytes <= MAXIMUM_SNAPSHOT_BYTES,
              'repository snapshot input budget is invalid')
        _need(type(pools) is dict and set(pools) == set(ARRAY_LIMITS),
              'repository model-array pool requires exactly the three supported kinds')
        self.arrays = {}
        self.used = {kind: set() for kind in ARRAY_LIMITS}
        self.maximum_references = maximum_bytes // 64
        self.reference_count = 0
        total_bytes = 0
        for kind, limits in ARRAY_LIMITS.items():
            entries = pools[kind]
            _need(type(entries) is list, 'repository model-array pool kind must be a list')
            values = self.arrays[kind] = {}
            for entry in entries:
                _need(type(entry) is dict and set(entry) == {'digest', 'json'}
                      and type(entry['digest']) is str and _HASH.fullmatch(entry['digest'])
                      and type(entry['json']) is str,
                      'repository model-array pool entry is invalid')
                digest = entry['digest']
                _need(digest not in values, 'repository model-array pool contains a duplicate digest')
                _need(len(entry['json']) <= ((maximum_bytes + 2) // 3) * 4,
                      'repository pooled array exceeds the unchanged input budget')
                try:
                    raw = base64.b64decode(entry['json'], validate=True)
                except (ValueError, binascii.Error) as error:
                    raise ValueError('repository pooled array is not strict base64') from error
                total_bytes += len(raw)
                _need(0 < len(raw) <= maximum_bytes and total_bytes <= maximum_bytes,
                      'repository pooled arrays exceed the unchanged input budget')
                _need(base64.b64encode(raw).decode('ascii') == entry['json'],
                      'repository pooled array base64 is not canonical')
                actual = hashlib.sha256((ENCODING + '\0' + kind + '\0').encode() + raw).hexdigest()
                _need(actual == digest, 'repository pooled array digest differs from the original bytes')
                value = parse_json(raw)
                _need(type(value) is list and limits[0] <= len(value) <= limits[1]
                      and all(type(child) is dict for child in value),
                      'repository pooled array has the wrong type or exceeds its original scene count limit')
                _no_nested_reference(value)
                values[digest] = _freeze(value)

    def resolve(self, kind, reference):
        _need(kind in self.arrays and type(reference) is dict and set(reference) == {'ref'}
              and type(reference['ref']) is str and _HASH.fullmatch(reference['ref']),
              'repository model-array position requires one exact digest reference')
        digest = reference['ref']
        _need(digest in self.arrays[kind], 'repository model-array reference is missing or has the wrong kind')
        self.reference_count += 1
        _need(self.reference_count <= self.maximum_references,
              'repository model-array references exceed the unchanged input budget')
        self.used[kind].add(digest)
        return self.arrays[kind][digest]

    def expand_scenes(self, scenes):
        _need(type(scenes) is list, 'repository revision scenes must be a list')
        for scene in scenes:
            _need(type(scene) is dict, 'repository scene must be an object')
            model = scene.get('modelScene3D')
            if model is None:
                continue
            _need(type(model) is dict, 'repository model scene must be an object')
            for kind in ARRAY_LIMITS:
                _need(kind in model, 'repository model scene is missing a pooled array position')
                model[kind] = self.resolve(kind, model[kind])
        return scenes

    def finish(self):
        _need(self.reference_count > 0, 'repository pooled encoding requires a model-array reference')
        _need(all(set(values) == self.used[kind] for kind, values in self.arrays.items()),
              'repository model-array pool contains an orphan entry')


def decode_snapshot(raw, *, maximum_bytes=MAXIMUM_SNAPSHOT_BYTES, allow_unversioned=False):
    """Decode bounded persisted JSON to schema-1 DTOs with read-only pooled arrays."""
    _need(type(maximum_bytes) is int and 0 < maximum_bytes <= MAXIMUM_SNAPSHOT_BYTES,
          'repository snapshot input budget is invalid')
    _need(type(raw) in (bytes, str), 'repository snapshot must be JSON bytes or text')
    size = len(raw) if isinstance(raw, bytes) else len(raw.encode('utf-8'))
    _need(0 < size <= maximum_bytes, 'repository snapshot exceeds the unchanged input budget')
    value = parse_json(raw)
    _need(type(value) is dict, 'repository snapshot must be an object')
    schema = value.get('schema')
    if (schema == 1 and type(schema) is int) or ('schema' not in value and allow_unversioned):
        _need('repositoryEncoding' not in value and 'modelArrayPool' not in value,
              'schema-1 repository cannot contain pooled encoding metadata')
        return value
    _need(type(schema) is int and schema == 2 and value.get('repositoryEncoding') == ENCODING
          and 'modelArrayPool' in value, 'repository schema or pool encoding is unsupported')
    pool = ModelArrayPool(value.pop('modelArrayPool'), maximum_bytes=size)
    projects = value.get('projects')
    _need(type(projects) is list, 'repository projects must be a list')
    for project in projects:
        _need(type(project) is dict and type(project.get('revisions')) is list,
              'repository project revisions must be a list')
        for revision in project['revisions']:
            _need(type(revision) is dict and 'scenes' in revision, 'repository revision scenes are missing')
            pool.expand_scenes(revision['scenes'])
    pool.finish()
    value.pop('repositoryEncoding')
    value['schema'] = 1
    return value


def sqlite_pool(connection):
    """Read only pool metadata in the caller's existing SQLite read snapshot.

    This scoped reader authenticates every pool entry but resolves only the
    selected revisions. Global orphan validation belongs to ``decode_snapshot``;
    a scoped usage audit must not claim complete repository validation.
    """
    _need(connection.in_transaction, 'scoped pool reads require an existing SQLite read transaction')
    size, schema, schema_type, encoding_type, pool_type, encoding, raw = connection.execute(
        "SELECT length(CAST(payload AS BLOB)),json_extract(payload,'$.schema'),"
        "json_type(payload,'$.schema'),json_type(payload,'$.repositoryEncoding'),"
        "json_type(payload,'$.modelArrayPool'),"
        "json_extract(payload,'$.repositoryEncoding'),json_extract(payload,'$.modelArrayPool') "
        'FROM snapshot WHERE id=1').fetchone()
    _need(type(size) is int and 0 < size <= MAXIMUM_SNAPSHOT_BYTES,
          'repository snapshot exceeds the unchanged input budget')
    if schema_type is None or schema_type == 'integer' and schema == 1:
        _need(encoding_type is None and pool_type is None,
              'schema-1 repository cannot contain pooled encoding metadata')
        return None
    _need(schema_type == 'integer' and schema == 2 and encoding_type == 'text'
          and encoding == ENCODING and pool_type == 'object' and raw is not None,
          'repository schema or pool encoding is unsupported')
    return ModelArrayPool(parse_json(raw), maximum_bytes=size)
