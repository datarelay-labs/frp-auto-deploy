#!/usr/bin/env python3
"""Pre-cutover snapshot and restore for the server installer.

Never rotates or deletes CA material, the FRP token, the registry, or
reservations. Those paths are excluded from both snapshot and restore.

Managed project-file lists come from server-project-files.manifest.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import stat
import subprocess
import sys
from pathlib import Path

from frp_project_files import protected_exact, protected_prefixes, snapshot_rels

PROTECTED_EXACT = protected_exact()
PROTECTED_PREFIXES = protected_prefixes()
SNAPSHOT_RELS = tuple(snapshot_rels())
SNAPSHOT_RELS_SET = frozenset(SNAPSHOT_RELS)

UNIT_NAMES = (
    'frps.service',
    'frp-port-allocator.service',
    'frp-frontend.service',
)


class SnapshotRestoreError(ValueError):
    """Malformed or unsafe install-snapshot metadata."""


def _is_protected(rel):
    rel = rel.lstrip('/')
    if rel in PROTECTED_EXACT:
        return True
    return any(rel.startswith(prefix) for prefix in PROTECTED_PREFIXES)


def _mode(path):
    return stat.S_IMODE(path.stat().st_mode)


def _normalize_mode_value(mode):
    if mode is None:
        raise SnapshotRestoreError('missing mode')
    if isinstance(mode, bool):
        raise SnapshotRestoreError('invalid mode type')
    if isinstance(mode, int):
        value = mode
    else:
        text = str(mode).strip()
        if not text:
            raise SnapshotRestoreError('missing mode')
        if text.startswith('0o') or text.startswith('0O'):
            text = text[2:]
        try:
            value = int(text, 8) if len(text) <= 4 and all(c in '01234567' for c in text) else int(text)
        except ValueError as exc:
            raise SnapshotRestoreError('invalid mode: %s' % mode) from exc
    if value < 0 or value > 0o7777:
        raise SnapshotRestoreError('invalid mode: %s' % mode)
    return value


def _reject_symlink(path: Path, label: str):
    if path.is_symlink():
        raise SnapshotRestoreError('%s is a symlink: %s' % (label, path))
    for parent in path.parents:
        if parent == path.anchor or str(parent) == '/':
            break
        if parent.is_symlink():
            raise SnapshotRestoreError('%s path has symlink parent: %s' % (label, path))


def _validate_snapshot_rel(rel, *, allowlist=SNAPSHOT_RELS_SET):
    if not isinstance(rel, str) or not rel:
        raise SnapshotRestoreError('empty snapshot path')
    if rel.startswith('/') or rel.startswith('\\'):
        raise SnapshotRestoreError('absolute snapshot path refused: %s' % rel)
    if '\\' in rel:
        raise SnapshotRestoreError('snapshot path escape refused: %s' % rel)
    parts = rel.split('/')
    if any(p in ('', '.', '..') for p in parts):
        raise SnapshotRestoreError('snapshot path traversal refused: %s' % rel)
    if _is_protected(rel):
        raise SnapshotRestoreError('protected snapshot path refused: %s' % rel)
    if rel not in allowlist:
        raise SnapshotRestoreError('snapshot path outside allowlist: %s' % rel)
    return rel


def _ensure_under(root: Path, candidate: Path, label: str):
    root_r = root.resolve(strict=False)
    cand_r = candidate.resolve(strict=False)
    try:
        cand_r.relative_to(root_r)
    except ValueError as exc:
        raise SnapshotRestoreError('%s escapes root: %s' % (label, candidate)) from exc
    return cand_r


def _unit_state(unit):
    """Best-effort enabled/active capture. Never raises."""
    state = {'unit': unit, 'enabled': None, 'active': None}
    if not shutil.which('systemctl'):
        return state
    try:
        enabled = subprocess.run(
            ['systemctl', 'is-enabled', unit],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        state['enabled'] = (enabled.stdout or '').strip() or None
    except (OSError, subprocess.SubprocessError):
        pass
    try:
        active = subprocess.run(
            ['systemctl', 'is-active', unit],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        state['active'] = (active.stdout or '').strip() or None
    except (OSError, subprocess.SubprocessError):
        pass
    return state


def capture_service_states(root):
    """Capture project unit and nginx ownership-relevant service state."""
    root = Path(root)
    if str(root) not in ('', '/', '.') and os.environ.get('FRP_SERVER_TEST_ROOT'):
        return {'units': [], 'skipped': True}
    units = [_unit_state(name) for name in UNIT_NAMES]
    nginx = _unit_state('nginx.service')
    return {'units': units, 'nginx': nginx, 'skipped': False}


def snapshot(root, dest, extra=None):
    root = Path(root)
    dest = Path(dest)
    files_dir = dest / 'files'
    files_dir.mkdir(parents=True, exist_ok=True)
    present = []
    absent = []
    for rel in SNAPSHOT_RELS:
        if _is_protected(rel):
            continue
        src = root / rel
        if src.is_file():
            target = files_dir / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(str(src), str(target))
            os.chmod(target, _mode(src))
            present.append({'path': rel, 'mode': _mode(src)})
        else:
            absent.append(rel)
    service_states = capture_service_states(root)
    meta = {
        'present': present,
        'absent': absent,
        'services': service_states,
        'extra': extra or {},
    }
    (dest / 'metadata.json').write_text(
        json.dumps(meta, indent=2, sort_keys=True) + '\n', encoding='utf-8'
    )
    os.chmod(dest / 'metadata.json', 0o600)
    return meta


def restore(root, dest):
    root = Path(root)
    dest = Path(dest)
    meta_path = dest / 'metadata.json'
    if not meta_path.is_file():
        return None
    _reject_symlink(meta_path, 'metadata')
    try:
        meta = json.loads(meta_path.read_text(encoding='utf-8'))
    except Exception as exc:
        raise SnapshotRestoreError('snapshot metadata is not valid JSON') from exc
    if not isinstance(meta, dict):
        raise SnapshotRestoreError('snapshot metadata must be an object')
    present = meta.get('present')
    absent = meta.get('absent')
    if present is None:
        present = []
    if absent is None:
        absent = []
    if not isinstance(present, list) or not isinstance(absent, list):
        raise SnapshotRestoreError('snapshot present/absent must be lists')

    files_dir = dest / 'files'
    root_resolved = root.resolve(strict=False)
    dest_resolved = dest.resolve(strict=False)

    for item in present:
        if not isinstance(item, dict):
            raise SnapshotRestoreError('present entry must be an object')
        rel = _validate_snapshot_rel(str(item.get('path') or ''))
        mode = _normalize_mode_value(item.get('mode'))
        src = files_dir / rel
        _reject_symlink(src, 'snapshot file')
        if not src.is_file():
            raise SnapshotRestoreError('snapshot file missing: %s' % rel)
        _ensure_under(dest_resolved, src, 'snapshot file')
        target = root / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        _ensure_under(root_resolved, target, 'restore target')
        tmp = target.with_name(target.name + '.restore.tmp')
        shutil.copy2(str(src), str(tmp))
        os.chmod(tmp, mode)
        tmp.replace(target)
    for rel_raw in absent:
        rel = _validate_snapshot_rel(str(rel_raw or ''))
        target = root / rel
        _ensure_under(root_resolved, target, 'absent target')
        if target.is_file() or target.is_symlink():
            target.unlink()
    return meta


def _systemctl(args, timeout=30):
    if os.environ.get('FRP_INSTALL_TXN_HOOK_SYSTEMD_FAIL') == '1':
        return False
    if not shutil.which('systemctl'):
        return False
    try:
        result = subprocess.run(
            ['systemctl', *args],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=timeout,
            check=False,
        )
        return result.returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def apply_service_states(meta, skip=False):
    """Restore enabled/active semantics for project units after file restore."""
    if skip or not meta:
        return True
    services = meta.get('services') or {}
    if services.get('skipped'):
        return True
    if not shutil.which('systemctl'):
        return True
    if not _systemctl(['daemon-reload'], timeout=30):
        return False
    for item in services.get('units') or []:
        unit = str(item.get('unit') or '')
        if not unit:
            continue
        enabled = item.get('enabled')
        active = item.get('active')
        if enabled in ('enabled', 'enabled-runtime'):
            if not _systemctl(['enable', unit], timeout=30):
                return False
        elif enabled in ('disabled', 'disabled-runtime'):
            if not _systemctl(['disable', unit], timeout=30):
                return False
        if active == 'active':
            if not _systemctl(['restart', unit], timeout=60):
                return False
        elif active in ('inactive', 'failed'):
            if not _systemctl(['stop', unit], timeout=60):
                return False
    nginx = services.get('nginx') or {}
    if nginx:
        enabled = nginx.get('enabled')
        active = nginx.get('active')
        if enabled in ('enabled', 'enabled-runtime'):
            if not _systemctl(['enable', 'nginx.service'], timeout=30):
                return False
        elif enabled in ('disabled', 'disabled-runtime'):
            if not _systemctl(['disable', 'nginx.service'], timeout=30):
                return False
        if active == 'active':
            if not _systemctl(['restart', 'nginx.service'], timeout=60):
                return False
        elif active in ('inactive', 'failed'):
            if not _systemctl(['stop', 'nginx.service'], timeout=60):
                return False
    return True


def verify_service_states(meta, skip=False):
    if skip or not meta:
        return True
    services = meta.get('services') or {}
    if services.get('skipped'):
        return True
    if not shutil.which('systemctl'):
        return True
    for item in services.get('units') or []:
        unit = str(item.get('unit') or '')
        if not unit:
            continue
        current = _unit_state(unit)
        expected_enabled = item.get('enabled')
        expected_active = item.get('active')
        if expected_enabled in ('enabled', 'enabled-runtime'):
            if current.get('enabled') not in ('enabled', 'enabled-runtime', 'static'):
                return False
        if expected_active == 'active' and current.get('active') != 'active':
            return False
        if expected_active in ('inactive', 'failed') and current.get('active') == 'active':
            return False
    return True


def main(argv=None):
    parser = argparse.ArgumentParser(description='Server installer snapshot/restore')
    parser.add_argument('action', choices=('snapshot', 'restore'))
    parser.add_argument('--root', required=True)
    parser.add_argument('--dest', required=True)
    parser.add_argument(
        '--apply-services',
        action='store_true',
        help='After restore, re-apply captured unit enabled/active state',
    )
    args = parser.parse_args(argv)
    if args.action == 'snapshot':
        snapshot(args.root, args.dest)
        return 0
    try:
        meta = restore(args.root, args.dest)
    except SnapshotRestoreError as exc:
        sys.stderr.write('ERROR: %s\n' % exc)
        return 1
    if meta is None:
        sys.stderr.write('ERROR: install snapshot metadata is missing\n')
        return 1
    skip = bool(os.environ.get('FRP_SERVER_TEST_ROOT'))
    if args.apply_services:
        if not apply_service_states(meta, skip=skip):
            sys.stderr.write('ERROR: service-state restoration failed\n')
            return 1
        if not verify_service_states(meta, skip=skip):
            sys.stderr.write('ERROR: restored service state verification failed\n')
            return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
