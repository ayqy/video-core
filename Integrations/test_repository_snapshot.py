"""Small representation fixtures; these are not live SDK/visual receipts."""
import base64
from copy import deepcopy
import hashlib
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest

import repository_snapshot as codec


def entry(kind, raw):
    return dict(digest=hashlib.sha256((codec.ENCODING+'\0'+kind+'\0').encode()+raw).hexdigest(),
                json=base64.b64encode(raw).decode())


def fixture(*, history=2):
    # Keep the externally supplied float spellings; do not Python-reencode them
    # when authenticating bytes emitted by another implementation.
    arrays = dict(instances=b'[{"id":"chair","name":"\\u85e4\\u7f16","x":-0.0,"tiny":1e-07}]',
                  transformTracks=b'[{"instanceID":"chair","frames":[0,1]}]', jointTracks=b'[]')
    pool = {kind: [entry(kind, raw)] for kind,raw in arrays.items()}
    model = {kind: dict(ref=values[0]['digest']) for kind,values in pool.items()}
    document = dict(schema=2, repositoryEncoding=codec.ENCODING, modelArrayPool=pool,
        generation=3, projects=[dict(id='project', revisions=[dict(id=str(i),
            scenes=[dict(id='scene', modelScene3D=deepcopy(model))]) for i in range(history)])])
    logical = deepcopy(document)
    logical['schema']=1; logical.pop('repositoryEncoding'); logical.pop('modelArrayPool')
    for revision in logical['projects'][0]['revisions']:
        revision['scenes'][0]['modelScene3D']={kind:json.loads(raw) for kind,raw in arrays.items()}
    return document, logical


def encode(document):
    return json.dumps(document, ensure_ascii=False, separators=(',', ':')).encode()


class RepositorySnapshotTests(unittest.TestCase):
    def test_legacy_schema_one_preserves_value_and_independent_arrays(self):
        _, logical=fixture()
        restored=codec.decode_snapshot(encode(logical))
        self.assertEqual(restored, logical)
        self.assertIsNot(restored['projects'][0]['revisions'][0]['scenes'][0]['modelScene3D']['instances'],
                         restored['projects'][0]['revisions'][1]['scenes'][0]['modelScene3D']['instances'])

    def test_twenty_six_histories_share_only_read_only_authenticated_arrays(self):
        document, logical=fixture(history=26)
        original=deepcopy(document)
        result=codec.decode_snapshot(encode(document))
        self.assertEqual(result, logical); self.assertEqual(document, original)
        scenes=[r['scenes'][0] for r in result['projects'][0]['revisions']]
        first=scenes[0]['modelScene3D']['instances']
        self.assertIs(first, scenes[-1]['modelScene3D']['instances'])
        self.assertEqual(json.loads(json.dumps(result)),logical)
        for operation in (lambda:first.append({}),lambda:first[0].update(x=3),
                          lambda:first.__setitem__(0,{})):
            with self.assertRaises(TypeError): operation()
        selected=deepcopy(scenes[0])
        self.assertIs(type(selected['modelScene3D']['instances']),list)
        self.assertIs(type(selected['modelScene3D']['instances'][0]),dict)
        selected['modelScene3D']['instances'][0]['x']=5
        self.assertEqual(first[0]['x'], -0.0)

    def test_domain_separator_uses_original_raw_bytes_and_correct_array_kind(self):
        document,_=fixture()
        source=document['modelArrayPool']['instances'][0]
        source['digest']=hashlib.sha256(base64.b64decode(source['json'])).hexdigest()
        with self.assertRaisesRegex(ValueError,'digest differs'): codec.decode_snapshot(encode(document))
        document,_=fixture()
        document['projects'][0]['revisions'][0]['scenes'][0]['modelScene3D']['instances']=dict(
            ref=document['modelArrayPool']['transformTracks'][0]['digest'])
        with self.assertRaisesRegex(ValueError,'missing or has the wrong kind'): codec.decode_snapshot(encode(document))

    def test_duplicate_missing_and_orphan_entries_fail_closed(self):
        for mode in ('duplicate','missing','orphan'):
            document,_=fixture()
            values=document['modelArrayPool']['instances']
            if mode=='duplicate': values.append(deepcopy(values[0]))
            elif mode=='missing': values.clear()
            else: values.append(entry('instances',b'[{"id":"unused"}]'))
            with self.subTest(mode=mode),self.assertRaises(ValueError): codec.decode_snapshot(encode(document))

    def test_empty_schema_two_shell_without_any_array_reference_is_rejected(self):
        document=dict(schema=2,repositoryEncoding=codec.ENCODING,
                      modelArrayPool={kind:[] for kind in codec.ARRAY_LIMITS},projects=[])
        with self.assertRaisesRegex(ValueError,'requires a model-array reference'):
            codec.decode_snapshot(encode(document))

    def test_wrong_array_reference_and_pool_types_fail_closed(self):
        for replacement in ([],None,dict(ref='f'*64,extra=True),dict(ref=4),dict(ref='F'*64)):
            document,_=fixture()
            document['projects'][0]['revisions'][0]['scenes'][0]['modelScene3D']['instances']=replacement
            with self.subTest(value=replacement),self.assertRaises(ValueError):codec.decode_snapshot(encode(document))
        for replacement in (None,[],dict(instances=[]),dict(instances=[],transformTracks=[],jointTracks=[],extra=[])):
            document,_=fixture();document['modelArrayPool']=replacement
            with self.subTest(pool=replacement),self.assertRaises(ValueError):codec.decode_snapshot(encode(document))

    def test_nested_references_non_arrays_non_objects_and_scene_count_limits_are_rejected(self):
        for kind,raw in [('instances',encode([dict(nested=dict(ref='0'*64))])),('instances',b'{}'),
                         ('instances',b'[1]'),('instances',b'[]'),
                         ('instances',encode([{}]*129)),('transformTracks',encode([{}]*129)),
                         ('jointTracks',encode([{}]*4097))]:
            document,_=fixture();document['modelArrayPool'][kind]=[entry(kind,raw)]
            with self.subTest(kind=kind,raw=raw[:30]),self.assertRaises(ValueError):codec.decode_snapshot(encode(document))
        document,_=fixture()
        raw=encode([dict(id='chair',materialInterpretation=dict(
            alphaCutoutByMaterialID={'ref':dict(threshold=0.5)}))])
        value=entry('instances',raw);document['modelArrayPool']['instances']=[value]
        for revision in document['projects'][0]['revisions']:
            revision['scenes'][0]['modelScene3D']['instances']=dict(ref=value['digest'])
        restored=codec.decode_snapshot(encode(document))
        material=restored['projects'][0]['revisions'][0]['scenes'][0]['modelScene3D']['instances'][0]
        self.assertEqual(material['materialInterpretation']['alphaCutoutByMaterialID']['ref'],dict(threshold=0.5))

    def test_schema_markers_and_metadata_are_strict(self):
        for schema in (None,True,1,3,'2'):
            document,_=fixture();document['schema']=schema
            with self.subTest(schema=schema),self.assertRaises(ValueError):codec.decode_snapshot(encode(document))
        for key,value in [('repositoryEncoding',None),('repositoryEncoding','other'),('modelArrayPool',None)]:
            document,_=fixture();document[key]=value
            with self.subTest(key=key,value=value),self.assertRaises(ValueError):codec.decode_snapshot(encode(document))
        for key in ('repositoryEncoding','modelArrayPool'):
            with self.assertRaises(ValueError):codec.decode_snapshot(encode(dict(schema=1,**{key:None})))

    def test_duplicate_json_keys_nonfinite_values_and_noncanonical_base64_are_rejected(self):
        with self.assertRaises(ValueError):codec.decode_snapshot(b'{"schema":1,"schema":1}')
        with self.assertRaises(ValueError):codec.decode_snapshot(b'{"schema":1,"number":NaN}')
        document,_=fixture();document['modelArrayPool']['instances'][0]['json']+='\n'
        with self.assertRaises(ValueError):codec.decode_snapshot(encode(document))
        document,_=fixture();document['modelArrayPool']['instances'][0]['extra']=1
        with self.assertRaises(ValueError):codec.decode_snapshot(encode(document))

    def test_input_budget_remains_bounded_before_json_decode(self):
        raw=encode(fixture()[0])
        with self.assertRaises(ValueError):codec.decode_snapshot(raw,maximum_bytes=len(raw)-1)
        for limit in (0,True,codec.MAXIMUM_SNAPSHOT_BYTES+1):
            with self.assertRaises(ValueError):codec.decode_snapshot(raw,maximum_bytes=limit)

    def test_scoped_sqlite_pool_requires_and_reuses_one_read_snapshot(self):
        document,logical=fixture()
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'workspace.sqlite'
            with sqlite3.connect(path) as writer:
                writer.execute('PRAGMA journal_mode=WAL')
                writer.execute('CREATE TABLE snapshot(id INTEGER PRIMARY KEY,payload BLOB)')
                writer.execute('INSERT INTO snapshot VALUES(1,?)',(encode(document),))
            with sqlite3.connect(path.as_uri()+'?mode=ro',uri=True) as reader:
                with self.assertRaises(ValueError):codec.sqlite_pool(reader)
                reader.execute('BEGIN');pool=codec.sqlite_pool(reader)
                with sqlite3.connect(path) as writer:
                    writer.execute('UPDATE snapshot SET payload=? WHERE id=1',(b'{"schema":1}',))
                raw=reader.execute("SELECT json_extract(payload,'$.projects[0].revisions[0].scenes') FROM snapshot").fetchone()[0]
                scenes=pool.expand_scenes(json.loads(raw))
                self.assertEqual(scenes,logical['projects'][0]['revisions'][0]['scenes'])
                self.assertEqual(pool.arrays,codec.sqlite_pool(reader).arrays)

    def test_scoped_sqlite_schema_one_cannot_hide_null_pool_metadata(self):
        with sqlite3.connect(':memory:') as connection:
            connection.execute('CREATE TABLE snapshot(id INTEGER PRIMARY KEY,payload TEXT)')
            for document in (dict(schema=1,modelArrayPool=None),dict(schema=True),dict(schema=2)):
                connection.execute('INSERT OR REPLACE INTO snapshot VALUES(1,?)',(json.dumps(document),))
                with self.assertRaises(ValueError):codec.sqlite_pool(connection)


if __name__=='__main__':unittest.main()
