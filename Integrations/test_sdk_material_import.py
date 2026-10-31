"""Synthetic adapter rules only: these tests are not Native/media evidence."""
from copy import deepcopy
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
import uuid

from sdk_material_import import invoke_import, validate_receipt


def identity(label):
    return str(uuid.uuid5(uuid.NAMESPACE_URL, 'synthetic-adapter-rule/' + label))


class SyntheticReceiptRules(unittest.TestCase):
    """No Swift helper, image decoder, Core importer or JS is executed here."""

    def setUp(self):
        self.workspace = identity('workspace')
        self.project = identity('project')
        self.revision = identity('revision')
        root = Path('/synthetic-owner/ThirdParty/GameAssets')
        self.spec = dict(version=1, kind='mota-world', resources=str(root), materials={})
        self.materials, self.assets, self.evidence, sources = {}, [], [], {}
        image_ids = []
        # Deliberately synthetic names, bytes, sources and IDs; no fixed native
        # descriptor/receipt is copied and no production asset is opened.
        for index in range(15):
            alias = 'original_' + str(index)
            ext = 'js' if index < 3 else ('md' if index == 3 else 'png')
            relative = 'synthetic/file_' + str(index) + '.' + ext
            text = 'passive original source ' + str(index)
            digest = hashlib.sha256(text.encode()).hexdigest()
            asset_id, proof_id = identity('asset-' + str(index)), identity('proof-' + str(index))
            row = dict(path=root / relative, sha256=digest, source='https://example.test/frozen/' + relative,
                       owner='original upstream owner ' + str(index), claim='original retained claim ' + str(index),
                       license='original restrictive license ' + str(index))
            self.spec['materials'][alias] = relative
            self.materials[alias] = row
            source = dict(assetID=asset_id, evidenceID=proof_id, hash=digest,
                          source=row['source'], owner=row['owner'], license=row['license'])
            sources[relative] = source
            is_image = ext == 'png'
            asset = dict(id=asset_id, workspaceID=self.workspace, hash=digest, evidenceID=proof_id,
                         name='file_' + str(index) + '.' + ext, ext=ext, bytes=len(text.encode()),
                         mediaType='image' if is_image else 'text', warnings=[],
                         pages=[] if is_image else [dict(number=1, requiresOCR=False, text=text)])
            self.assets.append(asset)
            if is_image:
                image_ids.append(asset_id)
            self.evidence.append(dict(id=proof_id, workspaceID=self.workspace, assetID=asset_id,
                                      source=row['source'], owner=row['owner'], claim=row['claim'],
                                      verified=True, commercialAllowed=False, uploadConsent=False))
        self.receipt = dict(workspaceID=self.workspace, projectID=self.project, baseRevision=self.revision,
                            assetsByPath=sources, artwork=dict(sources=list(deepcopy(sources).values()),
                            originalAssetIDs=image_ids, sprites=[dict(role='synthetic', assetID=image_ids[0])]))

    def validate(self):
        return validate_receipt(self.receipt, self.spec, self.materials, self.workspace,
                                self.project, self.revision, self.assets, self.evidence)

    def test_retains_actual_declared_source_owner_license_and_evidence_ids(self):
        before = deepcopy((self.receipt, self.materials, self.assets, self.evidence))
        bindings = self.validate()
        self.assertEqual(len(bindings), 15)
        first = bindings['original_0']
        self.assertEqual(first, dict(asset_id=self.assets[0]['id'], evidence_id=self.evidence[0]['id'],
                                    hash=self.materials['original_0']['sha256'],
                                    source=self.materials['original_0']['source'],
                                    owner=self.materials['original_0']['owner'],
                                    license=self.materials['original_0']['license']))
        self.assertEqual(before, (self.receipt, self.materials, self.assets, self.evidence))

    def test_unknown_or_changed_scope_identity_is_rejected(self):
        for field in ('workspaceID', 'projectID', 'baseRevision'):
            with self.subTest(field=field):
                original = self.receipt[field]
                self.receipt[field] = identity('foreign-' + field)
                with self.assertRaises(ValueError):
                    self.validate()
                self.receipt[field] = original

    def test_all_fifteen_unique_source_paths_are_required(self):
        relative = self.spec['materials']['original_0']
        del self.receipt['assetsByPath'][relative]
        with self.assertRaises(ValueError):
            self.validate()

    def test_source_or_evidence_cannot_be_replaced_with_generated_defaults(self):
        for field in ('source', 'owner', 'claim'):
            with self.subTest(field=field):
                original = self.evidence[0][field]
                self.evidence[0][field] = 'local-generated:generic-default'
                with self.assertRaises(ValueError):
                    self.validate()
                self.evidence[0][field] = original
        self.assets[0]['generatedSource'] = {'provider': 'synthetic'}
        with self.assertRaises(ValueError):
            self.validate()

    def test_passive_js_is_text_and_cannot_supply_actual_media(self):
        self.assets[0]['mediaType'] = 'image'
        with self.assertRaises(ValueError):
            self.validate()
        self.assets[0]['mediaType'] = 'text'
        self.receipt['artwork']['originalAssetIDs'].append(self.assets[0]['id'])
        with self.assertRaises(ValueError):
            self.validate()

    def test_source_page_must_retain_complete_original_bytes(self):
        self.assets[0]['pages'][0]['text'] += ' edited'
        with self.assertRaises(ValueError):
            self.validate()

    def test_receipt_bindings_must_match_real_assets_and_original_claim(self):
        self.assets[0]['evidenceID'] = self.evidence[1]['id']
        with self.assertRaises(ValueError):
            self.validate()
        self.assets[0]['evidenceID'] = self.evidence[0]['id']
        self.evidence[0]['uploadConsent'] = True
        with self.assertRaises(ValueError):
            self.validate()

    def test_duplicate_normal_records_and_artwork_source_injection_are_rejected(self):
        self.assets.append(deepcopy(self.assets[0]))
        with self.assertRaises(ValueError):
            self.validate()
        self.assets.pop()
        self.receipt['artwork']['sources'][0] = deepcopy(self.receipt['artwork']['sources'][1])
        with self.assertRaises(ValueError):
            self.validate()

    def test_declaration_cannot_escape_resources_or_alias_another_file(self):
        for value in ('../escape.js', '/absolute.js', 'synthetic/../escape.js', 'synthetic//file.js'):
            with self.subTest(value=value):
                self.spec['materials']['original_0'] = value
                with self.assertRaises(ValueError):
                    self.validate()
        self.spec['materials']['original_0'] = self.spec['materials']['original_1']
        with self.assertRaises(ValueError):
            self.validate()

    def test_owner_license_and_relative_file_path_are_not_inferred_from_receipt(self):
        row = self.materials['original_0']
        original = row['license']
        row['license'] = 'broader guessed license'
        with self.assertRaises(ValueError):
            self.validate()
        row['license'] = original
        row['path'] = Path('/synthetic-owner/other/file.js')
        with self.assertRaises(ValueError):
            self.validate()


class SyntheticInvocationRules(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.helper = self.root / 'compiled-helper'
        self.helper.write_bytes(b'synthetic placeholder; never executed')
        self.helper.chmod(0o700)
        self.workspace = self.root / 'already-restored'
        self.workspace.mkdir()
        self.resources = self.root / 'ThirdParty' / 'GameAssets'
        self.resources.mkdir(parents=True)
        self.workspace_id, self.project_id = identity('workspace'), identity('project')

    def call(self, runner):
        return invoke_import(self.helper, self.workspace, self.workspace_id,
                             self.project_id, self.resources, runner=runner)

    def test_uses_rtk_and_exact_four_explicit_argument_pairs_without_shell(self):
        calls = []

        def fake_runner(argv, **kwargs):
            calls.append((argv, kwargs))
            return SimpleNamespace(returncode=0, stdout=b'{"receipt":"synthetic"}\n', stderr=b'')

        self.assertEqual(self.call(fake_runner), {'receipt': 'synthetic'})
        self.assertEqual(calls[0][0], ['rtk', 'proxy', str(self.helper), '--workspace', str(self.workspace),
                                     '--workspace-id', self.workspace_id, '--project-id', self.project_id,
                                     '--resources', str(self.resources)])
        self.assertEqual(calls[0][1], dict(stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120, check=False))
        self.assertFalse((self.workspace / 'workspace.sqlite').exists())

    def test_duplicate_json_or_native_rejection_is_not_accepted(self):
        for response in (SimpleNamespace(returncode=0, stdout=b'{"x":1,"x":2}', stderr=b''),
                         SimpleNamespace(returncode=1, stdout=b'{}', stderr=b'fixed category'),
                         SimpleNamespace(returncode=0, stdout=b'{}', stderr=b'unexpected warning'),
                         SimpleNamespace(returncode=0, stdout=b'not-json', stderr=b'')):
            with self.subTest(response=response):
                with self.assertRaises(ValueError):
                    self.call(lambda *args, **kwargs: response)

    def test_symlink_workspace_and_missing_resources_are_rejected_before_invocation(self):
        alias = self.root / 'workspace-link'
        alias.symlink_to(self.workspace, target_is_directory=True)
        self.workspace = alias
        with self.assertRaises(ValueError):
            self.call(lambda *args, **kwargs: self.fail('must not execute'))


if __name__ == '__main__':
    unittest.main()
