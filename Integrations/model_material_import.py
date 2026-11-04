"""Finite author bridge for the normal SDK's real DAE/PNG package importer.

No SQLite writer, renderer, inspector substitute or synthetic rights records are
implemented here. The native bridge owns actual inspection, CAS and atomic source
registration; callers verify its receipt against ordinary assets/backup reads.
"""
from copy import deepcopy
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import unicodedata
import uuid


MAXIMUM_FILES = 512
MAXIMUM_BYTES = 64 * 1024 * 1024
_HASH = re.compile(r'[0-9a-f]{64}')
_ALIAS = re.compile(r'[A-Za-z0-9_-]{1,80}')
_FILE_FIELDS = frozenset(('path', 'bytes', 'sha256', 'source', 'owner', 'claim', 'license'))
_REFERENCE_FIELDS = frozenset(('assetID', 'sha256', 'bytes', 'fileExtension'))
_RECEIPT_FIELDS = frozenset(('workspaceID', 'projectID', 'baseRevision', 'resources',
                             'assetsByPath', 'evidenceIDsByPath'))
EVIDENCE_TITLE = '本地非商业三维来源'


def _need(condition, message):
    if not condition:
        raise ValueError(message)


def _identity(value):
    try:
        return isinstance(value, str) and str(uuid.UUID(value)) == value.lower()
    except (ValueError, AttributeError, TypeError):
        return False


def _text(value):
    return (isinstance(value, str) and value == value.strip() and bool(value)
            and len(value.encode('utf-8')) <= 4096
            and not any(unicodedata.category(char) in ('Cc', 'Cf') and char not in '\n\t\r' for char in value))


def _relative(value, extension=None):
    _need(isinstance(value, str) and value and len(value.encode('utf-8')) <= 4096
          and '\x00' not in value and '\\' not in value, 'normalized relative source path required')
    path = PurePosixPath(value)
    _need(not path.is_absolute() and str(path) == value and len(path.parts) <= 96
          and all(part not in ('', '.', '..') for part in path.parts)
          and path.suffix in ('.dae', '.png')
          and (extension is None or path.suffix == '.' + extension),
          'explicit relative DAE/PNG source path required')
    return path


def evidence_claim(row):
    """Literal declaration retained in Evidence, without commercial/upload grant."""
    return row['claim'] + '\n许可声明：' + row['license'] + '\n用途：local-noncommercial'


def validate_spec(spec):
    """Return exact declared source rows, without touching files or guessing paths.

    Models are keyed by an author alias. Each has one DAE ``model`` row and a
    ``textures`` map keyed by each actual DAE image alias. Rows have exactly
    path/bytes/sha256/source/owner/claim/license. Paths are relative to the
    separately selected physical source root. Actual alias closure is checked by
    the native DAEInspector, not reconstructed by Python or trusted from JSON.
    """
    _need(isinstance(spec, dict) and set(spec) == {'version', 'kind', 'use', 'models'}
          and type(spec['version']) is int and spec['version'] == 1
          and spec['kind'] == 'model-packages' and spec['use'] == 'local-noncommercial',
          'explicit version 1 local-noncommercial model-packages declaration required')
    models = spec['models']
    _need(isinstance(models, dict) and 1 <= len(models) <= 128, 'one to 128 explicit models required')
    files, identities = {}, {}
    total = 0
    for alias, package in models.items():
        _need(isinstance(alias, str) and _ALIAS.fullmatch(alias) and isinstance(package, dict)
              and set(package) == {'model', 'textures'}, 'exact model package declaration required')
        _need(isinstance(package['textures'], dict) and len(package['textures']) <= MAXIMUM_FILES,
              'bounded explicit texture bindings required')
        rows = [(package['model'], 'dae')]
        for texture_alias, row in package['textures'].items():
            _relative(texture_alias, 'png')
            # The SDK also percent-decodes and validates the actual DAE alias.
            _need('%' not in texture_alias and '?' not in texture_alias and '#' not in texture_alias
                  and ':' not in texture_alias, 'canonical plain PNG alias required')
            rows.append((row, 'png'))
        for row, extension in rows:
            _need(isinstance(row, dict) and set(row) == _FILE_FIELDS, 'complete exact source declaration required')
            _relative(row['path'], extension)
            _need(type(row['bytes']) is int and 1 <= row['bytes'] <= (MAXIMUM_BYTES if extension == 'dae' else 32 * 1024 * 1024)
                  and isinstance(row['sha256'], str) and _HASH.fullmatch(row['sha256'])
                  and all(_text(row[field]) for field in ('source', 'owner', 'claim', 'license')),
                  'bounded exact size, SHA256 and literal provenance required')
            _need(row['path'] not in files or files[row['path']] == row,
                  'one source path cannot declare different bytes or rights')
            identity = (row['sha256'], extension)
            if identity in identities:
                prior = identities[identity]
                _need(all(prior[field] == row[field] for field in _FILE_FIELDS - {'path'}),
                      'identical stored bytes cannot declare conflicting provenance')
            else:
                total += row['bytes']
                _need(total <= MAXIMUM_BYTES, 'deduplicated model closure exceeds 64MiB')
                identities[identity] = row
            files[row['path']] = deepcopy(row)
    _need(len(files) <= MAXIMUM_FILES, 'model import exceeds 512 declared actual files')
    return files


def _absolute(value):
    _need(isinstance(value, (str, os.PathLike)), 'absolute ordinary path required')
    value = os.fspath(value)
    _need(isinstance(value, str) and value.startswith('/') and value != '/' and '\x00' not in value
          and str(PurePosixPath(value)) == value and '..' not in PurePosixPath(value).parts,
          'absolute normalized path required')
    return Path(value)


def _ordinary(value, *, directory):
    path = _absolute(value)
    _need(not path.is_symlink() and path.resolve(strict=True) == path
          and (path.is_dir() if directory else path.is_file()), 'existing ordinary physical path required')
    return path


def verify_sources(spec, source_root):
    """Read only the selected files with no-follow/nonblocking descriptors.

    This hashes actual source bytes before invoking the already compiled native
    helper. It is not image/DAE effect acceptance; the SDK remains authoritative.
    """
    files = validate_spec(spec)
    root = _ordinary(source_root, directory=True)
    root_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        for row in files.values():
            descriptors, parent = [], root_fd
            try:
                parts = PurePosixPath(row['path']).parts
                for part in parts[:-1]:
                    parent = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=parent)
                    descriptors.append(parent)
                descriptor = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=parent)
                try:
                    before = os.fstat(descriptor)
                    _need(stat.S_ISREG(before.st_mode) and before.st_nlink == 1 and before.st_size == row['bytes'],
                          'source must be an exact single-link ordinary file')
                    digest, total = hashlib.sha256(), 0
                    while True:
                        chunk = os.read(descriptor, 65536)
                        if not chunk:
                            break
                        total += len(chunk)
                        _need(total <= row['bytes'], 'source changed size while reading')
                        digest.update(chunk)
                    after, located = os.fstat(descriptor), os.stat(parts[-1], dir_fd=parent, follow_symlinks=False)
                    _need((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns)
                          == (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns)
                          and stat.S_ISREG(located.st_mode) and (located.st_dev, located.st_ino) == (before.st_dev, before.st_ino)
                          and total == row['bytes'] and digest.hexdigest() == row['sha256'],
                          'actual source identity, SHA256 or length differs')
                finally:
                    os.close(descriptor)
            finally:
                for descriptor in reversed(descriptors):
                    os.close(descriptor)
        opened, located = os.fstat(root_fd), os.stat(root, follow_symlinks=False)
        _need(stat.S_ISDIR(located.st_mode) and (opened.st_dev, opened.st_ino) == (located.st_dev, located.st_ino),
              'source root changed during verification')
    finally:
        os.close(root_fd)
    return files


def _records(values, label):
    _need(isinstance(values, list) and len(values) <= 100000, 'bounded normal ' + label + ' records required')
    result = {}
    for value in values:
        _need(isinstance(value, dict) and _identity(value.get('id')) and value['id'] not in result,
              'unique actual ' + label + ' IDs required')
        result[value['id']] = value
    return result


def validate_receipt(receipt, spec, workspace_id, project_id, base_revision, assets, evidence):
    """Verify actual SDK bindings against normal asset and backup evidence reads.

    This does not approve appearance/audio or recreate an inspection. The actual
    native resource is returned unchanged for the normal author scene contract.
    """
    files = validate_spec(spec)
    _need(all(_identity(value) for value in (workspace_id, project_id, base_revision)), 'actual scope IDs required')
    _need(isinstance(receipt, dict) and set(receipt) == _RECEIPT_FIELDS
          and receipt['workspaceID'] == workspace_id and receipt['projectID'] == project_id
          and receipt['baseRevision'] == base_revision, 'native receipt scope differs')
    references, proof_ids, resources = receipt['assetsByPath'], receipt['evidenceIDsByPath'], receipt['resources']
    _need(isinstance(references, dict) and isinstance(proof_ids, dict) and isinstance(resources, dict)
          and set(references) == set(files) and set(proof_ids) == set(files)
          and set(resources) == set(spec['models']), 'native receipt does not cover the exact declared sources/models')
    actual_assets, actual_evidence = _records(assets, 'asset'), _records(evidence, 'evidence')
    for path, row in files.items():
        reference, proof_id = references[path], proof_ids[path]
        _need(isinstance(reference, dict) and set(reference) == _REFERENCE_FIELDS
              and _identity(reference['assetID']) and _identity(proof_id)
              and reference['sha256'] == row['sha256'] and type(reference['bytes']) is int
              and reference['bytes'] == row['bytes'] and reference['fileExtension'] == PurePosixPath(path).suffix[1:],
              'actual source reference differs from frozen declaration')
        asset, proof = actual_assets.get(reference['assetID']), actual_evidence.get(proof_id)
        _need(asset is not None and asset.get('workspaceID') == workspace_id
              and asset.get('hash') == row['sha256'] and asset.get('bytes') == row['bytes']
              and asset.get('ext') == reference['fileExtension'] and asset.get('evidenceID') == proof_id
              and asset.get('mediaType') == ('model3d' if reference['fileExtension'] == 'dae' else 'image')
              and asset.get('generatedSource') is None and asset.get('durationFrames') is None
              and asset.get('pages', []) == [] and asset.get('warnings', []) == [],
              'normal asset is not the actual unmodified declared DAE/PNG')
        _need(proof is not None and proof.get('workspaceID') == workspace_id and proof.get('assetID') == asset['id']
              and proof.get('title') == EVIDENCE_TITLE and proof.get('source') == row['source']
              and proof.get('owner') == row['owner'] and proof.get('claim') == evidence_claim(row)
              and proof.get('verified') is True and proof.get('commercialAllowed') is False
              and proof.get('uploadConsent') is False, 'normal evidence differs or grants undeclared rights')
    for alias, package in spec['models'].items():
        resource = resources[alias]
        _need(isinstance(resource, dict) and set(resource) == {'model', 'inspection', 'textures'}
              and resource['model'] == references[package['model']['path']]
              and isinstance(resource['textures'], dict) and set(resource['textures']) == set(package['textures'])
              and all(resource['textures'][key] == references[row['path']] for key, row in package['textures'].items()),
              'native resource closure does not match explicit original texture bindings')
        inspection = resource['inspection']
        _need(isinstance(inspection, dict) and inspection.get('sha256') == package['model']['sha256']
              and inspection.get('bytes') == package['model']['bytes'] and isinstance(inspection.get('images'), list)
              and all(isinstance(image, dict) and set(image) == {'id', 'relativePath'} for image in inspection['images'])
              and {image['relativePath'] for image in inspection['images']} == set(package['textures']),
              'native inspection identity or actual image aliases differ')
    return deepcopy(resources)


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        _need(key not in result, 'duplicate native receipt field')
        result[key] = value
    return result


def invoke_import(helper, workspace, workspace_id, project_id, base_revision, source_root, spec,
                  *, timeout=180, runner=None):
    """Invoke a precompiled, caller-frozen helper, with no shell or compilation."""
    helper, workspace = _ordinary(helper, directory=False), _ordinary(workspace, directory=True)
    source_root = _ordinary(source_root, directory=True)
    _need(os.access(helper, os.X_OK) and all(_identity(value) for value in (workspace_id, project_id, base_revision)),
          'compiled helper and actual existing workspace/project/revision required')
    _need(type(timeout) is int and 1 <= timeout <= 660, 'finite native import timeout required')
    verify_sources(spec, source_root)
    declaration = json.dumps(spec, ensure_ascii=False, allow_nan=False, separators=(',', ':')).encode('utf-8')
    _need(len(declaration) <= 8 * 1024 * 1024, 'model declaration exceeds 8MiB')
    response = (runner or subprocess.run)(
        ['rtk', 'proxy', str(helper), '--workspace', str(workspace), '--workspace-id', workspace_id,
         '--project-id', project_id, '--base-revision', base_revision, '--source-root', str(source_root)],
        input=declaration, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout, check=False)
    _need(response.returncode == 0 and not response.stderr, 'normal model SDK bridge rejected the request')
    _need(isinstance(response.stdout, bytes) and 1 <= len(response.stdout) <= 8 * 1024 * 1024,
          'bounded actual SDK receipt required')
    try:
        receipt = json.loads(response.stdout, object_pairs_hook=_unique_object)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError('model bridge did not return one valid JSON receipt') from error
    _need(isinstance(receipt, dict), 'model bridge receipt must be an object')
    return receipt
