"""Validate and invoke the existing native Mota importPack bridge.

The caller owns source freezing, the normal CLI asset list and normal backup
snapshots before/after the call. This module never opens SQLite, fabricates
evidence, runs upstream JS, or sends passive source files to assets import.
Rule tests using synthetic records are not Native import/media evidence.
"""
from copy import deepcopy
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import uuid


_SOURCE_FIELDS = frozenset(('assetID', 'evidenceID', 'hash', 'source', 'owner', 'license'))
_RECEIPT_FIELDS = frozenset(('workspaceID', 'projectID', 'baseRevision', 'artwork', 'assetsByPath'))
_ALIAS = re.compile(r'[A-Za-z0-9_-]{1,80}')
_HASH = re.compile(r'[0-9a-f]{64}')


def _need(condition, message):
    if not condition:
        raise ValueError(message)


def _identity(value):
    try:
        return isinstance(value, str) and str(uuid.UUID(value)) == value.lower()
    except (ValueError, AttributeError, TypeError):
        return False


def _text(value):
    return isinstance(value, str) and bool(value.strip()) and len(value) <= 16000


def _absolute(value):
    _need(isinstance(value, (str, os.PathLike)), 'absolute ordinary path required')
    value = os.fspath(value)
    _need(isinstance(value, str) and value.startswith('/') and '\x00' not in value
          and str(PurePosixPath(value)) == value and '..' not in PurePosixPath(value).parts,
          'absolute normalized path required')
    return Path(value)


def _resources(value):
    path = _absolute(value)
    _need(path.name == 'GameAssets' and path.parent.name == 'ThirdParty',
          'explicit ThirdParty/GameAssets resource root required')
    return path


def _spec(spec, materials):
    _need(isinstance(spec, dict) and set(spec) == {'version', 'kind', 'resources', 'materials'}
          and type(spec['version']) is int and spec['version'] == 1 and spec['kind'] == 'mota-world',
          'explicit version 1 mota-world import declaration required')
    root = _resources(spec['resources'])
    declared = spec['materials']
    _need(isinstance(declared, dict) and len(declared) == 15
          and isinstance(materials, dict) and set(materials) == set(declared),
          'all fifteen uniquely aliased declared original files are required')
    paths = {}
    for alias, relative in declared.items():
        _need(isinstance(alias, str) and _ALIAS.fullmatch(alias) and alias != 'voice',
              'safe non-reserved material alias required')
        _need(isinstance(relative, str) and relative and '\x00' not in relative and '\\' not in relative,
              'passive source path must be a relative POSIX path')
        path = PurePosixPath(relative)
        _need(not path.is_absolute() and str(path) == relative and '..' not in path.parts
              and path.suffix in ('.png', '.js', '.md') and relative not in paths,
              'unique normalized passive original path required')
        row = materials[alias]
        _need(isinstance(row, dict) and {'path', 'sha256', 'source', 'owner', 'claim', 'license'} <= set(row),
              'complete owner material provenance declaration required')
        _need(_absolute(row['path']) == root / relative
              and isinstance(row['sha256'], str) and _HASH.fullmatch(row['sha256'])
              and all(_text(row[key]) for key in ('source', 'owner', 'claim', 'license')),
              'owner declaration must bind the exact original path, digest and provenance')
        paths[relative] = (alias, row)
    return paths


def validate_spec(spec, materials):
    """Validate the complete declarative path/provenance map before writes."""
    return _spec(spec, materials)


def _records(values, label):
    _need(isinstance(values, list) and len(values) <= 100000, 'bounded normal ' + label + ' records required')
    result = {}
    for value in values:
        _need(isinstance(value, dict) and _identity(value.get('id')) and value['id'] not in result,
              'unique normal ' + label + ' identities required')
        result[value['id']] = value
    return result


def validate_receipt(receipt, spec, materials, workspace_id, project_id, base_revision, assets, evidence):
    """Cross-check a native receipt against caller declarations and normal reads.

    ``materials`` contains exactly spec's fifteen aliases, using the existing
    document rows (path/sha256/source/owner/claim/license). Paths and hashes come
    from those frozen owner declarations, never inferred from this receipt.
    ``assets`` is the normal Core assets-list result, and ``evidence`` comes
    from the normal backup snapshot. Full snapshot scope checks stay with the
    caller and the native bridge; this pure function does not touch files.
    """
    declared = _spec(spec, materials)
    _need(all(_identity(value) for value in (workspace_id, project_id, base_revision)),
          'explicit actual workspace/project/current revision identities required')
    _need(isinstance(receipt, dict) and set(receipt) == _RECEIPT_FIELDS
          and receipt['workspaceID'] == workspace_id and receipt['projectID'] == project_id
          and receipt['baseRevision'] == base_revision, 'native receipt identity differs')
    by_path = receipt['assetsByPath']
    _need(isinstance(by_path, dict) and set(by_path) == set(declared),
          'native receipt must cover exactly all fifteen declared original paths')
    actual_assets = _records(assets, 'asset')
    actual_evidence = _records(evidence, 'evidence')
    artwork = receipt['artwork']
    _need(isinstance(artwork, dict) and isinstance(artwork.get('sources'), list)
          and len(artwork['sources']) == 15, 'complete native artwork source bindings required')
    source_ids = set()
    proof_ids = set()
    result = {}
    image_ids = set()
    for relative, (alias, row) in declared.items():
        source = by_path[relative]
        _need(isinstance(source, dict) and set(source) == _SOURCE_FIELDS
              and _identity(source['assetID']) and _identity(source['evidenceID'])
              and source['assetID'] not in source_ids and source['evidenceID'] not in proof_ids,
              'each concrete original needs its own actual asset and evidence identity')
        source_ids.add(source['assetID'])
        proof_ids.add(source['evidenceID'])
        _need(source['hash'] == row['sha256']
              and all(source[key] == row[key] for key in ('source', 'owner', 'license')),
              'native source identity must retain the frozen owner declaration')
        asset = actual_assets.get(source['assetID'])
        proof = actual_evidence.get(source['evidenceID'])
        ext = PurePosixPath(relative).suffix[1:]
        media_type = 'image' if ext == 'png' else 'text'
        _need(asset is not None and asset.get('workspaceID') == workspace_id
              and asset.get('hash') == row['sha256'] and asset.get('evidenceID') == source['evidenceID']
              and asset.get('ext') == ext and asset.get('mediaType') == media_type
              and type(asset.get('bytes')) is int and asset['bytes'] > 0
              and asset.get('generatedSource') is None and asset.get('durationFrames') is None
              and asset.get('warnings', []) == [], 'normal asset is not the exact passive original')
        pages = asset.get('pages', [])
        if media_type == 'image':
            _need(pages == [], 'original image cannot contain injected source-text pages')
            image_ids.add(asset['id'])
        else:
            _need(isinstance(pages, list) and len(pages) == 1 and isinstance(pages[0], dict)
                  and pages[0].get('number') == 1 and pages[0].get('requiresOCR') is False
                  and isinstance(pages[0].get('text'), str) and bool(pages[0]['text'])
                  and len(pages[0]['text'].encode('utf-8')) == asset['bytes']
                  and hashlib.sha256(pages[0]['text'].encode('utf-8')).hexdigest() == row['sha256'],
                  'passive JS/metadata must retain its complete original UTF8 source-text bytes')
        _need(proof is not None and proof.get('workspaceID') == workspace_id
              and proof.get('assetID') == source['assetID']
              and all(proof.get(key) == row[key] for key in ('source', 'owner', 'claim'))
              and proof.get('verified') is True and proof.get('commercialAllowed') is False
              and proof.get('uploadConsent') is False, 'normal evidence must retain the original SDK source, owner and claim')
        _need(sum(item == source for item in artwork['sources']) == 1,
              'native artwork must retain each complete concrete source binding once')
        result[alias] = dict(asset_id=source['assetID'], evidence_id=source['evidenceID'],
                             hash=source['hash'], source=source['source'], owner=source['owner'], license=source['license'])
    _need(all(isinstance(item, dict) and set(item) == _SOURCE_FIELDS
              and item['assetID'] in source_ids for item in artwork['sources']),
          'native artwork contains an undeclared source')
    originals = artwork.get('originalAssetIDs')
    _need(isinstance(originals, list) and len(originals) == len(image_ids) and set(originals) == image_ids,
          'native artwork original-media IDs must match real images, excluding passive source metadata')
    sprites = artwork.get('sprites')
    _need(isinstance(sprites, list) and 1 <= len(sprites) <= 128
          and all(isinstance(sprite, dict) and sprite.get('assetID') in image_ids for sprite in sprites),
          'native sprites must bind actual imported images')
    return deepcopy(result)


def _ordinary(path, *, directory):
    path = _absolute(path)
    _need(not path.is_symlink() and path.resolve(strict=True) == path
          and (path.is_dir() if directory else path.is_file()), 'existing ordinary physical path required')
    return path


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        _need(key not in result, 'duplicate native receipt JSON field')
        result[key] = value
    return result


def invoke_import(helper, workspace, workspace_id, project_id, resources, *, timeout=120, runner=None):
    """Run an already compiled local bridge, without a shell or upstream JS.

    The owner freezes/compiles the helper and captures normal before/after
    snapshots. The optional runner exists for synthetic invocation-rule tests.
    """
    helper = _ordinary(helper, directory=False)
    workspace = _ordinary(workspace, directory=True)
    resources = _ordinary(_resources(resources), directory=True)
    _need(os.access(helper, os.X_OK) and _identity(workspace_id) and _identity(project_id),
          'compiled executable and explicit actual workspace/project IDs required')
    _need(type(timeout) is int and 1 <= timeout <= 660, 'bounded native import timeout required')
    run = runner or subprocess.run
    response = run(['rtk', 'proxy', str(helper), '--workspace', str(workspace),
                    '--workspace-id', workspace_id, '--project-id', project_id, '--resources', str(resources)],
                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout, check=False)
    _need(response.returncode == 0 and not response.stderr, 'normal native import bridge rejected the request')
    _need(isinstance(response.stdout, bytes) and 1 <= len(response.stdout) <= 8 * 1024 * 1024,
          'bounded native JSON receipt required')
    try:
        receipt = json.loads(response.stdout, object_pairs_hook=_unique_object)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError('native import did not return one valid JSON receipt') from error
    _need(isinstance(receipt, dict), 'native import receipt must be an object')
    return receipt
