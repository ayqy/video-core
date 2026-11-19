"""Portable format regressions use external raw-DEFLATE streams, no product writes."""
from copy import deepcopy
import hashlib
import json
import plistlib
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zlib

from backup_snapshot import decoded_snapshot, read_backup, MAXIMUM_SNAPSHOT_BYTES


def archive(value, version=3):
    raw = json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode()
    result = dict(version=version, snapshot=raw, digest=hashlib.sha256(raw).hexdigest(), assets={}, exports={})
    if version == 3:
        encoder = zlib.compressobj(wbits=-15)
        result.update(snapshot=encoder.compress(raw)+encoder.flush(), snapshotEncoding='deflate-raw-v1', snapshotBytes=len(raw))
    return result


class BackupSnapshotTests(unittest.TestCase):
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


if __name__ == '__main__':
    unittest.main()
