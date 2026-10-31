"""Pin a complete existing normal publication before using an advanced Host.

This verifies the original package/cold-load receipts and every issued byte.
The installed Host remains responsible for signatures, trust and entitlements;
the caller cannot issue a package, replace a trust root or invent a license.
"""
from pathlib import Path

from production_workflow import need, read, sha


def checked_importer(helper, expected_sha256, receipt_path, runtime):
    """Bind a normal SDK link to the current bridge source and Native build."""
    helper, receipt_path, runtime = map(Path, (helper, receipt_path, runtime))
    source=Path(__file__).with_name('native')/'ImportMotaMaterials.swift'
    need(helper.is_file() and not helper.is_symlink() and receipt_path.is_file()
         and not receipt_path.is_symlink(), 'ordinary SDK product and original link receipt required')
    record=read(receipt_path); native=read(runtime/'verified-runtime.plist')
    product=record['product']; source_key='Integrations/native/ImportMotaMaterials.swift'
    need(record['version']==1 and record['stage']=='current-normal-sdk-link'
         and record['newly_executed_rules']==0
         and record['native_input_sha256']==native['native_input_sha256']
         and product['path']==str(helper.resolve()) and product['bytes']==helper.stat().st_size
         and product['sha256']==expected_sha256==sha(helper.read_bytes())
         and record['source_sha256']==sha(source.read_bytes())
         and record['inputs'][source_key]==dict(bytes=source.stat().st_size,sha256=sha(source.read_bytes())),
         'the SDK bridge must come from this current source and matching normal Native link')
    return {str(path.resolve()):sha(path.read_bytes()) for path in (helper,receipt_path,source)}


def checked_runtime(runtime):
    runtime=Path(runtime).resolve(strict=True)
    proof=runtime/'verified-runtime.plist';package=runtime/'package-passed.plist'
    need(not proof.is_symlink() and not package.is_symlink(),'ordinary original publication receipts required')
    record=read(proof);packed=read(package)
    need(record['format']==1 and record['stage']=='verified' and packed['stage']=='package'
        and record['package_receipt_sha256']==sha(package.read_bytes())
        and runtime.name==record['runtime_input_sha256']
        and record['native_input_sha256']==packed['native_input_sha256']
        and set(record['signed'])=={'video','video-advanced','video-publisher','video-plugin-bridge','video-game-plugin','video-cartoon-plugin'}
        and set(record['packages'])=={'game','cartoon'}
        and record['source_commit']==packed['source_commit']
        and record['helpers']==packed['helpers'] and record['product_origins']==packed['product_origins']
        and record['signed']==packed['signed'] and record['packages']==packed['packages']
        and record['actual_rules']==record['reused_rules_claim']==0
        and {m['pluginID'] for m in record['modules']}=={'video.game','video.cartoon'},
        'a complete actual normal package/cold-load publication is required')
    pins={str(proof):sha(proof.read_bytes()),str(package):sha(package.read_bytes())}
    for name,origin in record['product_origins'].items():
        path=Path(origin['receipt']);raw=path.read_bytes();original=read(path)
        need(not path.is_symlink() and origin['mode']=='current_normal_release'
            and sha(raw)==origin['receipt_sha256'] and original['stage']=='current_normal_release'
            and original['native_input_sha256']==record['native_input_sha256']
            and original['newly_executed_rules']==0,'normal Release provenance differs')
        pins[str(path)]=origin['receipt_sha256']
    for name,row in record['signed'].items():
        path=runtime/'native'/name
        need(path==Path(row['path']) and path.is_file() and not path.is_symlink()
            and path.stat().st_size==row['bytes'] and sha(path.read_bytes())==row['sha256'],
            'verified installed executable differs')
        pins[str(path)]=row['sha256']
    for kind in ('game','cartoon'):
        folder=runtime/'catalog'/('video.'+kind+'.videoplugin')
        need(folder.is_dir() and not folder.is_symlink(),'both original issued packages required')
        current=[]
        for path in sorted(folder.rglob('*')):
            need(not path.is_symlink(),'issued package must not contain symlinks')
            if path.is_file():
                current.append(dict(path=path.relative_to(folder).as_posix(),bytes=path.stat().st_size,
                    mode=path.stat().st_mode & 0o777,sha256=sha(path.read_bytes())))
        need(record['packages'][kind]['path']==str(folder)
            and current==record['packages'][kind]['files'],'complete original package inventory differs')
        for path in folder.rglob('*'):
            if path.is_file():pins[str(path)]=sha(path.read_bytes())
    return pins
