"""Portable format regressions use external raw-DEFLATE streams, no product writes."""
from copy import deepcopy
import hashlib
import json
import plistlib
from pathlib import Path
import sqlite3
import struct
import tempfile
import unittest
from unittest.mock import patch, Mock
import zlib

import backup_snapshot as backup_module
from backup_snapshot import (decoded_snapshot, read_backup, read_backup_file, file_identity,
    member_identities, copy_verified_file, MAXIMUM_SNAPSHOT_BYTES, MAGIC)


def archive(value, version=3):
    raw = json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode()
    result = dict(version=version, snapshot=raw, digest=hashlib.sha256(raw).hexdigest(), assets={}, exports={})
    if version == 3:
        encoder = zlib.compressobj(wbits=-15)
        result.update(snapshot=encoder.compress(raw)+encoder.flush(), snapshotEncoding='deflate-raw-v1', snapshotBytes=len(raw))
    return result


def file_archive(value, members=(), *, encoding='json-raw-v1', changes=None, entries=None, blob=None):
    """Small format fixtures only; never product or capacity evidence."""
    raw = json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode()
    if blob is None:
        if encoding == 'deflate-raw-v1':
            encoder = zlib.compressobj(wbits=-15)
            blob = encoder.compress(raw)+encoder.flush()
        else:
            blob = raw
    rows = [dict(kind=kind, path=path, bytes=len(content), sha256=hashlib.sha256(content).hexdigest())
            for kind, path, content in members] if entries is None else entries
    manifest = dict(version=4, snapshotEncoding=encoding, snapshotBytes=len(raw), snapshotStoredBytes=len(blob),
        snapshotDigest=hashlib.sha256(raw).hexdigest(), entries=rows, totalFileBytes=sum(row['bytes'] for row in rows))
    manifest.update(changes or {})
    encoded = plistlib.dumps(manifest, fmt=plistlib.FMT_BINARY, sort_keys=True)
    return MAGIC+struct.pack('>Q', len(encoded))+encoded+blob+b''.join(content for _, _, content in members)


class BackupSnapshotTests(unittest.TestCase):
    def test_schema_two_pool_decodes_logically_without_changing_authenticated_archive_bytes(self):
        from test_repository_snapshot import fixture
        document,logical=fixture(history=26)
        for version in (1,2,3):
            item=archive(document,version)
            actual,snapshot=read_backup(plistlib.dumps(item,fmt=plistlib.FMT_BINARY))
            self.assertEqual(snapshot,logical)
            self.assertEqual(actual,item)
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'pooled.videobackup'
            path.write_bytes(file_archive(document,encoding='deflate-raw-v1'))
            actual,snapshot=read_backup_file(path)
            self.assertEqual(snapshot,logical)
            self.assertEqual(actual['snapshotBytes'],len(json.dumps(document,ensure_ascii=False,separators=(',',':')).encode()))

    def test_valid_outer_backup_digest_cannot_hide_invalid_model_pool(self):
        from test_repository_snapshot import fixture
        document,_=fixture()
        document['modelArrayPool']['instances'][0]['digest']='0'*64
        with self.assertRaisesRegex(ValueError,'pooled array digest'):
            read_backup(plistlib.dumps(archive(document),fmt=plistlib.FMT_BINARY))
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'bad-pool.videobackup';path.write_bytes(file_archive(document))
            with self.assertRaisesRegex(ValueError,'pooled array digest'):read_backup_file(path)

    def test_normal_sqlite_inspection_and_backup_return_the_same_schema_one_values(self):
        from examples.free_production import inspect_snapshot
        from test_repository_snapshot import fixture,encode
        document,logical=fixture(history=26)
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'workspace.sqlite'
            with sqlite3.connect(path) as connection:
                connection.execute('CREATE TABLE snapshot(id INTEGER PRIMARY KEY,payload BLOB)')
                connection.execute('INSERT INTO snapshot VALUES(1,?)',(encode(document),))
            before=path.read_bytes()
            actual=inspect_snapshot(path)
            self.assertEqual(actual,logical)
            self.assertEqual(actual,read_backup(plistlib.dumps(archive(document),fmt=plistlib.FMT_BINARY))[1])
            self.assertEqual(path.read_bytes(),before)

    def test_large_unicode_histories_and_sources_remain_exact_across_all_versions(self):
        value = dict(generation=8, projects=[dict(revisions=[dict(id='原版本', review=dict(visual=False))])],
                     sources=['原声/原图/原模型'], terminology={'原样中文': '夏天海面；'*100000})
        for version in (1, 2, 3):
            with self.subTest(version=version):
                item = archive(value, version)
                original = deepcopy(item)
                actual, snapshot = read_backup(plistlib.dumps(item, fmt=plistlib.FMT_BINARY))
                self.assertEqual(snapshot, value)
                self.assertEqual(actual, original)
                self.assertEqual(item, original)

    def test_external_rfc1951_fixture_decodes_without_a_zlib_wrapper(self):
        raw = b'{"sample":"standard raw deflate"}'
        compressed = bytes([171,86,42,78,204,45,200,73,85,178,82,42,46,73,204,75,73,44,74,81,40,74,44,87,72,73,77,203,73,44,73,85,170,5,0])
        self.assertEqual(decoded_snapshot(dict(version=3, snapshot=compressed, snapshotEncoding='deflate-raw-v1',
            snapshotBytes=len(raw), digest=hashlib.sha256(raw).hexdigest())), raw)

    def test_truncation_trailing_bytes_and_concatenated_streams_are_rejected(self):
        original = archive({'whole': 'same source'*10000})
        for blob in (original['snapshot'][:-1], original['snapshot']+b'\0', original['snapshot']*2):
            with self.subTest(bytes=len(blob)), self.assertRaises(ValueError):
                decoded_snapshot(dict(original, snapshot=blob))

    def test_wrong_length_encoding_digest_and_missing_metadata_are_rejected(self):
        original = archive({'whole': 'same source'*10000})
        for change in (dict(snapshotBytes=1), dict(snapshotBytes=original['snapshotBytes']+1),
                       dict(snapshotBytes=MAXIMUM_SNAPSHOT_BYTES+1), dict(snapshotBytes=True),
                       dict(snapshotEncoding='zlib'), dict(digest='0'*64), dict(snapshotBytes=None)):
            with self.subTest(change=change), self.assertRaises(ValueError):
                decoded_snapshot(dict(original, **change))

    def test_high_compression_cannot_expand_past_the_declared_budget(self):
        original = archive({'large': 'A'*(2*1024*1024)})
        self.assertLess(len(original['snapshot']), original['snapshotBytes']//100)
        with self.assertRaises(ValueError):
            decoded_snapshot(dict(original, snapshotBytes=64))

    def test_envelope_and_expansion_limits_are_independent(self):
        original = archive({'large': 'A'*10000})
        raw = plistlib.dumps(original, fmt=plistlib.FMT_BINARY)
        with self.assertRaises(ValueError):
            read_backup(raw, maximum_bytes=len(raw)-1)
        with patch('backup_snapshot.MAXIMUM_SNAPSHOT_BYTES', 5000), self.assertRaises(ValueError):
            read_backup(raw)
        self.assertEqual(read_backup(raw)[1]['large'], 'A'*10000)

    def test_legacy_metadata_unknown_versions_and_non_database_json_are_rejected(self):
        for version in (1, 2):
            with self.subTest(version=version), self.assertRaises(ValueError):
                decoded_snapshot(dict(archive({}, version), snapshotBytes=2))
        for version in (0, 4, True):
            with self.subTest(version=version), self.assertRaises(ValueError):
                decoded_snapshot(dict(archive({}), version=version))
        with self.assertRaises(ValueError):
            read_backup(plistlib.dumps(archive([])))

    def test_normal_free_recipe_keeps_full_fields_source_bytes_and_review_boundaries(self):
        from examples import free_production
        value = dict(generation=7, projects=[dict(revisions=[dict(id='old', review={'visual': False},
            scenes=[dict(captions=[], voice={'listened': False})])])], jobs=[], products=[], providers=[],
            publications=[], terminology={'原样中文': '全量保留'*100000})
        item=archive(value);item['assets']={'assets/original.txt':b'original'}
        with tempfile.TemporaryDirectory() as temporary:
            base=Path(temporary);backup=base/'complete.videobackup';backup.write_bytes(plistlib.dumps(item))
            roots=[base/'original',base/'restored']
            for root in roots:
                (root/'assets').mkdir(parents=True);(root/'assets/original.txt').write_bytes(b'original')
            with patch.object(free_production,'inspect_snapshot',side_effect=lambda _:deepcopy(value)):
                self.assertEqual(free_production.validate_restoration(backup,*roots),(value,1,0))
            changed=deepcopy(value);changed['projects'][0]['revisions'][0]['review']['visual']=True
            with patch.object(free_production,'inspect_snapshot',return_value=changed), self.assertRaises(RuntimeError):
                free_production.validate_restoration(backup,*roots)

    def test_normal_knowledge_snapshot_reader_accepts_v3_and_retains_its_tighter_envelope_budget(self):
        from knowledge_story_smoke import snapshot
        value={'projects':[{'revisions':[{'id':'whole original'}]}],'terminology':{'keep':'汉字'*100000}}
        with tempfile.TemporaryDirectory() as temporary:
            path=Path(temporary)/'normal.videobackup';item=archive(value)
            path.write_bytes(plistlib.dumps(item));self.assertEqual(snapshot(path),(value,item))
            item['snapshot']+=b'\0';path.write_bytes(plistlib.dumps(item))
            with self.assertRaises(ValueError):snapshot(path)


class FileBackupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.path = self.base/'complete.videobackup'
        self.source = b'original small source\0'
        self.source_path = 'assets/'+hashlib.sha256(self.source).hexdigest()+'.txt'
        self.members = [('assets', self.source_path, self.source),
                        ('exports', 'exports/job/video.mp4', b'format-rule-only-not-media'),
                        ('visualCache', 'cache/visuals/'+'a'*64+'.plist', b'cache-metadata-format-only')]
        self.value = dict(generation=7, projects=[dict(revisions=[dict(id='old', review={'visual': False})])],
                          terminology={'保留完整中文历史': '汉字海面；'*1000})

    def write(self, raw):
        self.path.write_bytes(raw)
        return self.path

    def test_raw_and_compressed_file_snapshots_keep_all_groups_lazy_and_original_fields(self):
        for encoding in ('json-raw-v1', 'deflate-raw-v1'):
            self.write(file_archive(self.value, self.members, encoding=encoding))
            result, snapshot = read_backup_file(self.path)
            self.assertEqual(snapshot, self.value)
            self.assertEqual(result['version'], 4)
            self.assertNotIsInstance(result['assets'], dict)
            self.assertEqual(result['assets'][self.source_path], self.source)
            self.assertEqual(member_identities(result, 'assets'),
                {self.source_path: dict(bytes=len(self.source), sha256=hashlib.sha256(self.source).hexdigest())})
            self.assertEqual(set(result['visualCache']), {'a'*64+'.plist'})
            self.assertEqual(len(result['exports']), 1)

    def test_every_member_is_actually_hashed_even_when_never_materialized(self):
        raw = file_archive(self.value, self.members)
        for changed in (raw[:-1]+bytes([raw[-1]^1]), raw[:-1], raw+b'\0'):
            self.write(changed)
            with self.assertRaises(ValueError):
                read_backup_file(self.path)

    def test_zero_length_historical_member_and_empty_file_set_remain_supported(self):
        for members in ((), [('exports', 'exports/job/empty.txt', b'')]):
            self.write(file_archive(self.value, members))
            result, _ = read_backup_file(self.path)
            expected = {} if not members else {'exports/job/empty.txt': dict(bytes=0, sha256=hashlib.sha256(b'').hexdigest())}
            self.assertEqual(member_identities(result, 'exports'), expected)

    def test_mutation_during_initial_verification_is_rejected_before_return(self):
        self.write(file_archive(self.value))
        original = backup_module._read
        calls = 0
        def reading(stream, count, digest=None):
            nonlocal calls
            result = original(stream, count, digest)
            calls += 1
            if calls == 4:  # Header, length, manifest, then snapshot.
                with self.path.open('r+b') as writer:
                    writer.write(b'X')
            return result
        with patch.object(backup_module, '_read', side_effect=reading):
            with self.assertRaisesRegex(ValueError, 'changed'):read_backup_file(self.path)

    def test_manifest_requires_exact_fields_and_non_boolean_numeric_values(self):
        changes = [dict(extra='unexpected'), dict(version=True), dict(version=3),
                   dict(snapshotBytes=True), dict(snapshotStoredBytes=True), dict(totalFileBytes=True),
                   dict(snapshotDigest='A'*64), dict(snapshotEncoding='unknown'), dict(entries={})]
        for change in changes:
            with self.subTest(change=change):
                self.write(file_archive(self.value, self.members, changes=change))
                with self.assertRaises(ValueError):read_backup_file(self.path)

    def test_member_order_duplicates_kinds_paths_sizes_and_cas_digest_are_strict(self):
        entry = dict(kind='assets', path=self.source_path, bytes=len(self.source), sha256=hashlib.sha256(self.source).hexdigest())
        bad = [dict(entry, extra=1), dict(entry, bytes=True), dict(entry, bytes=-1),
               dict(entry, kind='other'), dict(entry, path='assets/'+'a'*64+'.txt'),
               dict(entry, path='../outside'), dict(entry, sha256='A'*64),
               dict(entry, kind='exports', path='exports/job/../outside'),
               dict(entry, kind='visualCache', path='cache/visuals/invalid.mp4')]
        for row in bad:
            with self.subTest(row=row):
                self.write(file_archive(self.value, entries=[row]))
                with self.assertRaises(ValueError):read_backup_file(self.path)
        for rows in ([entry, entry], [dict(entry, kind='exports', path='exports/job/a'), entry]):
            self.write(file_archive(self.value, entries=rows))
            with self.assertRaises(ValueError):read_backup_file(self.path)

    def test_independent_manifest_member_snapshot_and_caller_budgets_precede_payload_reads(self):
        raw = file_archive(self.value, self.members)
        self.write(raw)
        for constant, limit in [('MAXIMUM_MANIFEST_BYTES', 1), ('MAXIMUM_ENTRIES', 1),
                                ('MAXIMUM_FILE_BYTES', 1), ('MAXIMUM_FILE_SNAPSHOT_BYTES', 1)]:
            with self.subTest(constant=constant), patch.object(backup_module, constant, limit):
                with self.assertRaises(ValueError):read_backup_file(self.path)
        with self.assertRaises(ValueError):read_backup_file(self.path, maximum_bytes=len(raw)-1)
        for length in (0, backup_module.MAXIMUM_MANIFEST_BYTES+1, 2**64-1):
            self.write(MAGIC+struct.pack('>Q', length)+b'x')
            with self.assertRaises(ValueError):read_backup_file(self.path)

    def test_snapshot_digest_lengths_raw_size_and_deflate_end_are_authenticated(self):
        original = archive(self.value)
        blob = original['snapshot']
        for bad in (blob[:-1], blob+b'\0', blob+blob):
            self.write(file_archive(self.value, encoding='deflate-raw-v1', blob=bad))
            with self.assertRaises(ValueError):read_backup_file(self.path)
        for change in (dict(snapshotDigest='0'*64), dict(snapshotBytes=1), dict(snapshotStoredBytes=1)):
            self.write(file_archive(self.value, changes=change))
            with self.assertRaises(ValueError):read_backup_file(self.path)
        self.write(file_archive([]))
        with self.assertRaises(ValueError):read_backup_file(self.path)

    def test_file_reader_keeps_legacy_versions_and_bytes_api_keeps_its_old_limit(self):
        for version in (1, 2, 3):
            item = archive(self.value, version)
            raw = plistlib.dumps(item, fmt=plistlib.FMT_BINARY)
            self.write(raw)
            self.assertEqual(read_backup_file(self.path), (item, self.value))
            with patch.object(backup_module, 'MAXIMUM_BACKUP_BYTES', len(raw)-1):
                with self.assertRaises(ValueError):read_backup_file(self.path)
        raw = file_archive(self.value)
        with self.assertRaisesRegex(ValueError, 'streaming file API'):read_backup(raw)
        with patch.object(backup_module, 'MAXIMUM_BACKUP_BYTES', 8):
            self.write(raw)
            self.assertEqual(read_backup_file(self.path)[1], self.value)

    def test_lazy_members_reject_later_mutation_or_replacement_and_bound_bytes_access(self):
        self.write(file_archive(self.value, self.members))
        result, _ = read_backup_file(self.path)
        with self.assertRaisesRegex(ValueError, 'too large'):
            result['assets'].read_member(self.source_path, maximum_bytes=0)
        with self.path.open('r+b') as handle:
            handle.seek(-1, 2);handle.write(b'!')
        with self.assertRaisesRegex(ValueError, 'changed'):member_identities(result, 'assets')
        self.write(file_archive(self.value, self.members))
        result, _ = read_backup_file(self.path)
        replacement = self.base/'replacement';replacement.write_bytes(self.path.read_bytes());replacement.replace(self.path)
        with self.assertRaisesRegex(ValueError, 'changed'):result['assets'][self.source_path]

    def test_member_identity_comparison_uses_complete_verified_sets_without_loading_values(self):
        self.write(file_archive(self.value, self.members))
        first, _ = read_backup_file(self.path)
        other = self.base/'other';other.write_bytes(self.path.read_bytes())
        second, _ = read_backup_file(other)
        with patch.object(backup_module._FileMembers, '__getitem__', side_effect=AssertionError('must not materialize')):
            self.assertEqual(first['assets'], second['assets'])
            self.assertEqual(member_identities(first, 'assets'), member_identities(second, 'assets'))
        self.assertEqual(first['assets'], {self.source_path: self.source})
        self.assertNotEqual(first['assets'], {})

    def test_stream_identity_copy_and_reader_do_not_use_whole_file_read_bytes(self):
        raw = file_archive(self.value, self.members)
        self.write(raw)
        expected = dict(bytes=len(raw), sha256=hashlib.sha256(raw).hexdigest())
        target = self.base/'copied.videobackup'
        with patch.object(Path, 'read_bytes', side_effect=AssertionError('whole file read forbidden')), \
             patch.object(backup_module, 'CHUNK_BYTES', 7):
            self.assertEqual(file_identity(self.path), expected)
            result, snapshot = read_backup_file(self.path)
            self.assertEqual(snapshot, self.value)
            self.assertEqual(result['assets'][self.source_path], self.source)
            copy_verified_file(self.path, target, expected=expected)
            self.assertEqual(file_identity(target), expected)
            self.assertEqual(copy_verified_file(self.path, target, expected=expected), target)
        self.assertEqual(list(self.base.glob('.backup-*')), [])
        target.write_bytes(b'preserve different existing output')
        with self.assertRaises(ValueError):copy_verified_file(self.path, target, expected=expected)
        self.assertEqual(target.read_bytes(), b'preserve different existing output')

    def test_failed_stream_copy_removes_partial_file_without_publishing_destination(self):
        raw = file_archive(self.value, self.members);self.write(raw)
        target = self.base/'failed.videobackup'
        with self.assertRaises(ValueError):
            copy_verified_file(self.path, target, expected=dict(bytes=len(raw), sha256='0'*64))
        self.assertFalse(target.exists())
        self.assertEqual(list(self.base.glob('.backup-*')), [])

    def test_symlink_hardlink_and_non_regular_inputs_are_rejected(self):
        self.write(file_archive(self.value))
        alias = self.base/'alias';alias.symlink_to(self.path)
        with self.assertRaises(ValueError):read_backup_file(alias)
        hard = self.base/'hard';hard.hardlink_to(self.path)
        with self.assertRaises(ValueError):read_backup_file(hard)
        with self.assertRaises((ValueError, OSError)):read_backup_file(self.base)

    def test_interrupted_free_recipe_reuses_compressed_and_file_backup_without_replay(self):
        from examples.free_production import Recipe
        for version in (3, 4):
            home = self.base/str(version);home.mkdir()
            path = home/'backup-one.videobackup'
            raw = plistlib.dumps(archive(self.value), fmt=plistlib.FMT_BINARY) if version == 3 else file_archive(self.value, self.members)
            path.write_bytes(raw)
            recipe = Recipe.__new__(Recipe);recipe.store = sqlite3.connect(':memory:')
            self.addCleanup(recipe.store.close)
            recipe.store.execute('CREATE TABLE steps (name TEXT, response TEXT)')
            recipe.invoke = Mock(side_effect=AssertionError('must reuse the exact backup, not replay creation'))
            with patch.object(Path, 'read_bytes', side_effect=AssertionError('whole file read forbidden')):
                self.assertEqual(recipe.backup('interrupted', home), path)
            recipe.invoke.assert_not_called()

    def test_free_restoration_stream_compares_every_source_without_inheriting_review(self):
        from examples import free_production
        value = dict(generation=7, projects=[dict(revisions=[dict(id='old', review={'visual': False},
            scenes=[dict(captions=[], voice={'listened': False})])])], jobs=[], products=[], providers=[], publications=[])
        self.write(file_archive(value, [('assets', self.source_path, self.source)]))
        roots = [self.base/'original', self.base/'restored']
        for root in roots:
            (root/'assets').mkdir(parents=True);(root/self.source_path).write_bytes(self.source)
        with patch.object(free_production, 'inspect_snapshot', side_effect=lambda _: deepcopy(value)), \
             patch.object(Path, 'read_bytes', side_effect=AssertionError('whole file read forbidden')):
            self.assertEqual(free_production.validate_restoration(self.path, *roots), (value, 1, 0))
        (roots[-1]/self.source_path).write_bytes(b'changed')
        with patch.object(free_production, 'inspect_snapshot', side_effect=lambda _: deepcopy(value)):
            with self.assertRaises(RuntimeError):free_production.validate_restoration(self.path, *roots)

    def test_knowledge_reader_accepts_file_format_and_retains_its_tighter_budget(self):
        from knowledge_story_smoke import snapshot
        self.write(file_archive(self.value, self.members))
        self.assertEqual(snapshot(self.path)[0], self.value)
        with patch('knowledge_story_smoke.read_backup_file', wraps=read_backup_file) as reader:
            snapshot(self.path)
            self.assertEqual(reader.call_args.kwargs, dict(maximum_bytes=16*1024*1024))

    def test_document_material_snapshot_uses_file_reader_and_checks_native_receipt(self):
        from production_document import DocumentProduction
        raw=file_archive(self.value,self.members);self.write(raw)
        native=dict(path=str(self.path),bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest())
        controller=DocumentProduction.__new__(DocumentProduction)
        controller.uid=lambda label:'exact-'+label
        controller.invoke=Mock(return_value=dict(artifacts=[native]))
        with patch.object(Path,'read_bytes',side_effect=AssertionError('whole file read forbidden')):
            self.assertEqual(controller.material_snapshot('original'),self.value)
        controller.invoke.assert_called_once_with('backup create',dict(request_id='exact-material-snapshot-original'))
        controller.invoke.return_value=dict(artifacts=[dict(native,sha256='0'*64)])
        with self.assertRaisesRegex(ValueError,'artifact differs'):controller.material_snapshot('different')


if __name__ == '__main__':
    unittest.main()
