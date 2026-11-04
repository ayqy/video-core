"""Finite source/adapter rules only; no Native import or effect is claimed."""
from copy import deepcopy
import hashlib
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
import uuid

from model_material_import import (EVIDENCE_TITLE, evidence_claim, invoke_import,
                                   validate_receipt, validate_spec, verify_sources)


def identity(label):
    return str(uuid.uuid5(uuid.NAMESPACE_URL, 'model-import-rule/' + label))


class ModelMaterialImportRules(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.workspace = self.root / 'existing-workspace'
        self.workspace.mkdir()
        self.helper = self.root / 'compiled-helper'
        self.helper.write_text('synthetic runner only')
        self.helper.chmod(0o700)
        self.rows = {}
        for path, data in [('derived/actor.dae', b'<synthetic-rule-only/>'),
                           ('original/body.png', b'not-a-real-png-rule-only')]:
            location = self.root / path
            location.parent.mkdir(parents=True, exist_ok=True)
            location.write_bytes(data)
            self.rows[path] = dict(path=path, bytes=len(data), sha256=hashlib.sha256(data).hexdigest(),
                                   source='https://example.test/original/' + path, owner='original owner',
                                   claim='literal declared provenance', license='local review only')
        self.spec = dict(version=1, kind='model-packages', use='local-noncommercial',
                         models={'actor': dict(model=deepcopy(self.rows['derived/actor.dae']),
                                               textures={'body.png': deepcopy(self.rows['original/body.png'])})})
        self.workspace_id, self.project_id, self.revision = [identity(x) for x in ('workspace', 'project', 'revision')]
        self.assets, self.evidence, references, proofs = [], [], {}, {}
        for path, row in self.rows.items():
            asset_id, evidence_id = identity(path), identity('proof/' + path)
            extension = Path(path).suffix[1:]
            reference = dict(assetID=asset_id, sha256=row['sha256'], bytes=row['bytes'], fileExtension=extension)
            references[path], proofs[path] = reference, evidence_id
            self.assets.append(dict(id=asset_id, workspaceID=self.workspace_id, hash=row['sha256'],
                                    bytes=row['bytes'], ext=extension, evidenceID=evidence_id,
                                    mediaType='model3d' if extension == 'dae' else 'image', pages=[], warnings=[]))
            self.evidence.append(dict(id=evidence_id, workspaceID=self.workspace_id, assetID=asset_id,
                                      title=EVIDENCE_TITLE, source=row['source'], owner=row['owner'],
                                      claim=evidence_claim(row), verified=True, commercialAllowed=False, uploadConsent=False))
        resource = dict(model=references['derived/actor.dae'], textures={'body.png': references['original/body.png']},
                        inspection=dict(sha256=self.rows['derived/actor.dae']['sha256'],
                                        bytes=self.rows['derived/actor.dae']['bytes'],
                                        images=[dict(id='actual-source-image', relativePath='body.png')]))
        self.receipt = dict(workspaceID=self.workspace_id, projectID=self.project_id, baseRevision=self.revision,
                            resources={'actor': resource}, assetsByPath=references, evidenceIDsByPath=proofs)

    def validate(self):
        return validate_receipt(self.receipt, self.spec, self.workspace_id, self.project_id,
                                self.revision, self.assets, self.evidence)

    def test_exact_source_and_normal_receipt_are_preserved_without_mutation(self):
        before = deepcopy((self.spec, self.receipt, self.assets, self.evidence))
        self.assertEqual(verify_sources(self.spec, self.root), self.rows)
        result = self.validate()
        self.assertEqual(result, self.receipt['resources'])
        result['actor']['textures'].clear()
        self.assertEqual(before, (self.spec, self.receipt, self.assets, self.evidence))

    def test_unknown_fields_commercial_scope_and_unbounded_declarations_reject(self):
        for field, value in [('version', True), ('use', 'commercial'), ('kind', 'mota-world'), ('extra', 'hidden')]:
            with self.subTest(field=field):
                spec = deepcopy(self.spec)
                spec[field] = value
                with self.assertRaises(ValueError):
                    validate_spec(spec)
        for path in ('../actor.dae', '/actor.dae', 'derived//actor.dae', 'derived/./actor.dae'):
            spec = deepcopy(self.spec)
            spec['models']['actor']['model']['path'] = path
            with self.assertRaises(ValueError):
                validate_spec(spec)
        spec = deepcopy(self.spec)
        spec['models']['actor']['model']['bytes'] = 64 * 1024 * 1024
        with self.assertRaises(ValueError):
            validate_spec(spec)

    def test_shared_bytes_reuse_requires_identical_literal_provenance(self):
        spec = deepcopy(self.spec)
        spec['models']['second'] = deepcopy(spec['models']['actor'])
        self.assertEqual(len(validate_spec(spec)), 2)
        spec['models']['second']['model']['owner'] = 'other owner'
        with self.assertRaises(ValueError):
            validate_spec(spec)
        spec = deepcopy(self.spec)
        texture = deepcopy(spec['models']['actor']['textures']['body.png'])
        texture['path'] = 'other/body.png'
        texture['license'] = 'different rights'
        spec['models']['actor']['textures']['other.png'] = texture
        with self.assertRaises(ValueError):
            validate_spec(spec)

    def test_changed_source_hash_symlink_hardlink_and_fifo_reject_before_runner(self):
        file = self.root / 'derived/actor.dae'
        original = file.read_bytes()
        file.write_bytes(b'x' * len(original))
        with self.assertRaises(ValueError):
            verify_sources(self.spec, self.root)
        file.write_bytes(original)
        target = self.root / 'saved.dae'
        file.rename(target)
        file.symlink_to(target)
        with self.assertRaises((ValueError, OSError)):
            verify_sources(self.spec, self.root)
        file.unlink()
        os.link(target, file)
        with self.assertRaises(ValueError):
            verify_sources(self.spec, self.root)
        file.unlink()
        os.mkfifo(file)
        with self.assertRaises(ValueError):
            verify_sources(self.spec, self.root)

    def test_wrong_scope_resource_alias_hash_or_missing_source_reject(self):
        for field in ('workspaceID', 'projectID', 'baseRevision'):
            original = self.receipt[field]
            self.receipt[field] = identity('foreign-' + field)
            with self.assertRaises(ValueError):
                self.validate()
            self.receipt[field] = original
        original = deepcopy(self.receipt)
        self.receipt['resources']['actor']['textures']['hidden.png'] = self.receipt['assetsByPath']['original/body.png']
        with self.assertRaises(ValueError):
            self.validate()
        self.receipt = deepcopy(original)
        self.receipt['resources']['actor']['inspection']['sha256'] = '0' * 64
        with self.assertRaises(ValueError):
            self.validate()
        self.receipt = deepcopy(original)
        del self.receipt['evidenceIDsByPath']['original/body.png']
        with self.assertRaises(ValueError):
            self.validate()

    def test_real_asset_proof_binding_and_noncommercial_scope_cannot_be_upgraded(self):
        for key, value in [('owner', 'different'), ('claim', 'different'), ('verified', False),
                           ('commercialAllowed', True), ('uploadConsent', True), ('assetID', identity('foreign'))]:
            with self.subTest(key=key):
                before = self.evidence[0][key]
                self.evidence[0][key] = value
                with self.assertRaises(ValueError):
                    self.validate()
                self.evidence[0][key] = before
        self.assets[0]['generatedSource'] = {'provider': 'synthetic'}
        with self.assertRaises(ValueError):
            self.validate()

    def test_invocation_passes_finite_exact_declaration_and_revision_without_shell(self):
        calls = []

        def runner(args, **kwargs):
            calls.append((args, kwargs))
            return SimpleNamespace(returncode=0, stderr=b'', stdout=json.dumps(self.receipt).encode())

        result = invoke_import(self.helper, self.workspace, self.workspace_id, self.project_id, self.revision,
                               self.root, self.spec, timeout=90, runner=runner)
        self.assertEqual(result, self.receipt)
        args, options = calls[0]
        self.assertEqual(args[:3], ['rtk', 'proxy', str(self.helper)])
        self.assertEqual(args[args.index('--base-revision') + 1], self.revision)
        self.assertEqual(json.loads(options['input']), self.spec)
        self.assertEqual(options['timeout'], 90)
        self.assertNotIn('shell', options)
        for invalid in (0, 661, True):
            with self.assertRaises(ValueError):
                invoke_import(self.helper, self.workspace, self.workspace_id, self.project_id,
                               self.revision, self.root, self.spec, timeout=invalid, runner=runner)
        self.assertEqual(len(calls), 1)

    def test_helper_failure_duplicate_receipt_and_extra_output_reject(self):
        for response in [SimpleNamespace(returncode=1, stderr=b'', stdout=b'{}'),
                         SimpleNamespace(returncode=0, stderr=b'diagnostic', stdout=b'{}'),
                         SimpleNamespace(returncode=0, stderr=b'', stdout=b'{"x":1,"x":2}'),
                         SimpleNamespace(returncode=0, stderr=b'', stdout=b'{}\n{}')]:
            with self.subTest(response=response), self.assertRaises(ValueError):
                invoke_import(self.helper, self.workspace, self.workspace_id, self.project_id, self.revision,
                               self.root, self.spec, runner=lambda *_args, **_kwargs: response)


if __name__ == '__main__':
    unittest.main()
