"""Offline, guarded lookup migration for the separately installed optional mods."""
from pathlib import Path, PurePosixPath
import argparse
import base64
import datetime
import hashlib
import json
import os
import stat
import sys
import tempfile


def digest(data):
    return hashlib.sha256(data).hexdigest()


def target(root, relative):
    parts = PurePosixPath(relative).parts
    if not parts or any(p in ('.', '..') or ':' in p or '\\' in p for p in parts):
        raise ValueError('Unsafe patch path: ' + relative)
    if PurePosixPath(relative).is_absolute():
        raise ValueError('Absolute patch path')
    path = root
    for part in parts:
        path = path / part
        if path.exists():
            info = path.lstat()
            if stat.S_ISLNK(info.st_mode) or getattr(info, 'st_file_attributes', 0) & 0x400:
                raise ValueError('Refusing linked/reparse path: ' + str(path))
    path.resolve().relative_to(root)
    return path


def patched(data, item):
    if digest(data) != item['beforeSHA256']:
        raise ValueError('Unrecognized file: ' + item['path'])
    chunks, cursor = [], 0
    for edit in item['edits']:
        start, end = edit['start'], edit['end']
        if not isinstance(start, int) or not isinstance(end, int) or not cursor <= start <= end <= len(data):
            raise ValueError('Invalid patch range')
        before = base64.b64decode(edit['before'], validate=True)
        after = base64.b64decode(edit['after'], validate=True)
        if data[start:end] != before:
            raise ValueError('Patch context mismatch')
        chunks.extend((data[cursor:start], after))
        cursor = end
    chunks.append(data[cursor:])
    result = b''.join(chunks)
    if digest(result) != item['afterSHA256']:
        raise ValueError('Patch result checksum mismatch')
    return result


def atomic_write(path, data):
    fd, name = tempfile.mkstemp(prefix='.frlg-lookup-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--mods-dir', required=True, help='Existing game mods directory; close the game first')
    ap.add_argument('--apply', action='store_true', help='Apply after validating all installed supported mods')
    args = ap.parse_args()
    root = Path(args.mods_dir).absolute()
    if not root.is_dir() or root.resolve() != root:
        raise ValueError('Use the real absolute mods directory, not a linked directory')
    root = root.resolve()
    recipe_path = Path(__file__).resolve().parents[1] / 'lib/compat/consumer-updates/recipe.json'
    recipe = json.loads(recipe_path.read_text(encoding='utf8'))
    if recipe.get('schema') != 'frlg-consumer-lookups/1':
        raise ValueError('Unknown patch recipe')
    engine = target(root, 'FRLG_VOXEL/lib/compat/LegacyBridge.lua')
    if digest(engine.read_bytes()) != recipe['engineBootstrapSHA256']:
        raise ValueError('Install the matching FRLG_VOXEL beta before updating optional mods')
    plan, report = [], []
    for mod in recipe['mods']:
        mid = mod['id']
        folder = target(root, mid)
        if not folder.exists():
            report.append({'mod': mid, 'status': 'not installed; skipped'})
            continue
        manifest = json.loads(target(root, mid + '/manifest.json').read_text(encoding='utf8'))
        if manifest.get('id') != mid or manifest.get('version') != mod['version']:
            raise ValueError('Unsupported installed version: ' + mid)
        changes = 0
        for item in mod['files']:
            path = target(root, mid + '/' + item['path'])
            data = path.read_bytes()
            if digest(data) == item['afterSHA256']:
                continue
            result = patched(data, item)
            plan.append((path, data, result))
            changes += 1
        report.append({'mod': mid, 'status': 'update available' if changes else 'already updated', 'files': changes})
    # Nothing is written before every version, source and resulting hash passes.
    backup = None
    if args.apply and plan:
        backup_parent = target(root, 'FRLG_VOXEL/consumer-update-backups')
        backup_parent.mkdir(exist_ok=True)
        backup = Path(tempfile.mkdtemp(prefix=datetime.datetime.now().strftime('%Y%m%d-%H%M%S-'), dir=backup_parent))
        records = []
        for path, before, after in plan:
            rel = path.relative_to(root)
            saved = backup / rel
            saved.parent.mkdir(parents=True, exist_ok=True)
            saved.write_bytes(before)
            if digest(saved.read_bytes()) != digest(before):
                raise ValueError('Backup verification failed')
            records.append({'path': rel.as_posix(), 'beforeSHA256': digest(before), 'afterSHA256': digest(after)})
        receipt = {'status': 'backed up', 'files': records}
        receipt_path = backup / 'receipt.json'
        receipt_path.write_text(json.dumps(receipt, indent=2) + '\n', encoding='utf8')
        written = []
        try:
            # Detect edits since preflight before starting the transaction.
            for path, before, _ in plan:
                if path.read_bytes() != before:
                    raise ValueError('File changed since preflight: ' + str(path))
            for path, before, after in plan:
                atomic_write(path, after)
                written.append((path, before))
                if path.read_bytes() != after:
                    raise ValueError('Written file verification failed')
            receipt['status'] = 'applied'
        except Exception as exc:
            failures = []
            for path, before in reversed(written):
                try:
                    atomic_write(path, before)
                    if path.read_bytes() != before:
                        raise ValueError('Restored file verification failed')
                except Exception as rollback_error:
                    failures.append({'path': str(path), 'error': str(rollback_error)})
            receipt['status'] = 'rollback incomplete' if failures else 'rolled back'
            receipt['error'] = str(exc)
            receipt['rollbackErrors'] = failures
            raise
        finally:
            receipt_path.write_text(json.dumps(receipt, indent=2) + '\n', encoding='utf8')
    print(json.dumps({'mode': 'apply' if args.apply else 'dry run', 'files': len(plan),
                      'mods': report, 'backup': str(backup) if backup else None}))


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print('No completed update: ' + str(exc), file=sys.stderr)
        sys.exit(1)
