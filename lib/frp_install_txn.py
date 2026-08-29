#!/usr/bin/env python3
"""Pre-cutover snapshot and restore for the server installer.

Never rotates or deletes CA material, the FRP token, the registry, or
reservations. Those paths are excluded from both snapshot and restore.
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

PROTECTED_EXACT = (
    'etc/frp/server_token',
    'var/lib/frp-auto-deploy/registry.json',
)
PROTECTED_PREFIXES = (
    'etc/frp-auto-deploy/pki/',
    'var/lib/frp-auto-deploy/enrollments/',
    'var/lib/frp-auto-deploy/bootstrap/',
)

SNAPSHOT_RELS = (
    'etc/frp-auto-deploy/config.json',
    'etc/frp/frps.toml',
    'etc/frp-auto-deploy/frontend.conf',
    'var/lib/frp-auto-deploy/nginx-ownership',
    'etc/systemd/system/frps.service',
    'etc/systemd/system/frp-port-allocator.service',
    'etc/systemd/system/frp-frontend.service',
    'usr/local/bin/frps',
    'usr/local/lib/frp-auto-deploy/frp-port-allocator.py',
    'usr/local/lib/frp-auto-deploy/frp_mgmt_auth.py',
    'usr/local/lib/frp-auto-deploy/frp_pki.py',
    'usr/local/lib/frp-auto-deploy/frp_frontend.py',
    'usr/local/lib/frp-auto-deploy/frp-common.sh',
    'usr/local/lib/frp-auto-deploy/frp-doctor-common.sh',
    'usr/local/lib/frp-auto-deploy/frp_doctor.py',
    'usr/local/lib/frp-auto-deploy/frp_install_txn.py',
    'usr/local/lib/frp-auto-deploy/frp-server-upgrade.sh',
    'usr/local/lib/frp-auto-deploy/frp_client_registry.py',
    'usr/local/lib/frp-auto-deploy/release-manifest.json',
    'usr/local/lib/frp-auto-deploy/SHA256SUMS',
    'usr/local/sbin/frp-create-client',
    'usr/local/sbin/frp-clients',
    'usr/local/sbin/frp-client-info',
    'usr/local/sbin/frp-client-set',
    'usr/local/sbin/frp-release-client',
    'usr/local/sbin/frp-release-service',
    'usr/local/sbin/frp-revoke-client',
    'usr/local/sbin/frp-set-client-installer-url',
    'usr/local/sbin/frp-server-status',
    'usr/local/sbin/frp-project-update',
    'usr/local/sbin/frp-update',
    'usr/local/sbin/frpctl',
    'etc/frp-auto-deploy/version',
)

UNIT_NAMES = (
    'frps.service',
    'frp-port-allocator.service',
    'frp-frontend.service',
)


def _is_protected(rel):
    rel = rel.lstrip('/')
    if rel in PROTECTED_EXACT:
        return True
    return any(rel.startswith(prefix) for prefix in PROTECTED_PREFIXES)


def _mode(path):
    return stat.S_IMODE(path.stat().st_mode)


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
    # Under a test root, systemd state is not meaningful for the host.
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
    meta = json.loads(meta_path.read_text(encoding='utf-8'))
    files_dir = dest / 'files'
    for item in meta.get('present') or []:
        rel = str(item.get('path') or '')
        if not rel or _is_protected(rel):
            continue
        src = files_dir / rel
        if not src.is_file():
            continue
        target = root / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        tmp = target.with_name(target.name + '.restore.tmp')
        shutil.copy2(str(src), str(tmp))
        mode = int(item.get('mode') or _mode(src))
        os.chmod(tmp, mode)
        tmp.replace(target)
    for rel in meta.get('absent') or []:
        rel = str(rel or '')
        if not rel or _is_protected(rel):
            continue
        target = root / rel
        if target.is_file() or target.is_symlink():
            target.unlink()
    return meta


def apply_service_states(meta, skip=False):
    """Restore enabled/active semantics for project units after file restore."""
    if skip or not meta:
        return True
    services = meta.get('services') or {}
    if services.get('skipped'):
        return True
    if not shutil.which('systemctl'):
        return True
    ok = True
    try:
        subprocess.run(
            ['systemctl', 'daemon-reload'],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=30,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        ok = False
    for item in services.get('units') or []:
        unit = str(item.get('unit') or '')
        if not unit:
            continue
        enabled = item.get('enabled')
        active = item.get('active')
        try:
            if enabled in ('enabled', 'enabled-runtime'):
                subprocess.run(
                    ['systemctl', 'enable', unit],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=30,
                    check=False,
                )
            elif enabled in ('disabled', 'disabled-runtime'):
                subprocess.run(
                    ['systemctl', 'disable', unit],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=30,
                    check=False,
                )
            if active == 'active':
                subprocess.run(
                    ['systemctl', 'restart', unit],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=60,
                    check=False,
                )
            elif active in ('inactive', 'failed'):
                subprocess.run(
                    ['systemctl', 'stop', unit],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=60,
                    check=False,
                )
        except (OSError, subprocess.SubprocessError):
            ok = False
    nginx = services.get('nginx') or {}
    if nginx:
        enabled = nginx.get('enabled')
        active = nginx.get('active')
        try:
            if enabled in ('enabled', 'enabled-runtime'):
                subprocess.run(
                    ['systemctl', 'enable', 'nginx.service'],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=30,
                    check=False,
                )
            elif enabled in ('disabled', 'disabled-runtime'):
                subprocess.run(
                    ['systemctl', 'disable', 'nginx.service'],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=30,
                    check=False,
                )
            if active == 'active':
                subprocess.run(
                    ['systemctl', 'restart', 'nginx.service'],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=60,
                    check=False,
                )
            elif active in ('inactive', 'failed'):
                subprocess.run(
                    ['systemctl', 'stop', 'nginx.service'],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=60,
                    check=False,
                )
        except (OSError, subprocess.SubprocessError):
            ok = False
    return ok


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
    meta = restore(args.root, args.dest)
    if meta is None:
        sys.stderr.write('ERROR: install snapshot metadata is missing\n')
        return 1
    if args.apply_services:
        apply_service_states(meta, skip=bool(os.environ.get('FRP_SERVER_TEST_ROOT')))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
