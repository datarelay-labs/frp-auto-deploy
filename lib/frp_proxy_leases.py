#!/usr/bin/env python3
"""Ephemeral NewProxy authorization leases (runtime-only, not backup state)."""
from __future__ import annotations

import fcntl
import json
import os
import secrets
import time
from pathlib import Path

DEFAULT_LEASE_DIR = '/run/frp-auto-deploy/proxy-leases'
MAX_LEASES = 512
LEASE_FILE_MODE = 0o600


def lease_dir_from_cfg(cfg=None):
    root = os.environ.get('FRP_DEPLOY_TEST_ROOT') or os.environ.get('FRP_SERVER_TEST_ROOT') or ''
    custom = ''
    if isinstance(cfg, dict):
        custom = str(cfg.get('proxy_lease_dir') or '').strip()
    if custom:
        rel = custom.lstrip('/')
        return str(Path(root) / rel) if root else custom
    return str(Path(root) / DEFAULT_LEASE_DIR.lstrip('/')) if root else DEFAULT_LEASE_DIR


def _lock_path(lease_dir):
    return str(Path(lease_dir) / '.leases.lock')


def _acquire_lock(lease_dir):
    path = Path(lease_dir)
    path.mkdir(parents=True, exist_ok=True)
    os.chmod(str(path), 0o700)
    fd = os.open(_lock_path(lease_dir), os.O_CREAT | os.O_RDWR, LEASE_FILE_MODE)
    fcntl.flock(fd, fcntl.LOCK_EX)
    return fd


def _release_lock(fd):
    if fd is None:
        return
    try:
        fcntl.flock(fd, fcntl.LOCK_UN)
    except OSError:
        pass
    try:
        os.close(fd)
    except OSError:
        pass


def _lease_file(lease_dir, token):
    return Path(lease_dir) / ('lease-%s.json' % token)


def _read_lease(path):
    if path.is_symlink():
        raise ValueError('refusing symlink lease file')
    raw = path.read_text(encoding='utf-8')
    data = json.loads(raw)
    if not isinstance(data, dict):
        raise ValueError('invalid lease record')
    return data


def _atomic_write(path, data):
    path = Path(path)
    if path.is_symlink():
        raise ValueError('refusing symlink lease target')
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile_mkstemp(path.parent, path.name)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as handle:
            json.dump(data, handle, indent=2, sort_keys=True)
            handle.write('\n')
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp, LEASE_FILE_MODE)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            try:
                os.unlink(tmp)
            except OSError:
                pass


def tempfile_mkstemp(parent, name):
    import tempfile

    return tempfile.mkstemp(prefix=name + '.', suffix='.tmp', dir=str(parent))


def expire_stale(lease_dir, now=None):
    now = float(now if now is not None else time.time())
    base = Path(lease_dir)
    if not base.is_dir():
        return 0
    removed = 0
    for path in base.glob('lease-*.json'):
        if path.is_symlink():
            continue
        try:
            data = _read_lease(path)
            if float(data.get('expires_at') or 0) <= now:
                path.unlink(missing_ok=True)
                removed += 1
        except (OSError, ValueError, json.JSONDecodeError):
            try:
                path.unlink(missing_ok=True)
                removed += 1
            except OSError:
                pass
    return removed


def _list_active(lease_dir, now=None):
    now = float(now if now is not None else time.time())
    expire_stale(lease_dir, now=now)
    out = []
    base = Path(lease_dir)
    if not base.is_dir():
        return out
    for path in sorted(base.glob('lease-*.json')):
        if path.is_symlink():
            continue
        try:
            data = _read_lease(path)
            if float(data.get('expires_at') or 0) > now:
                out.append(data)
        except (OSError, ValueError, json.JSONDecodeError):
            continue
    return out


def has_active_lease(lease_dir, remote_port=None, client_id=None, service_id=None):
    now = time.time()
    for rec in _list_active(lease_dir, now=now):
        if remote_port is not None and int(rec.get('remote_port') or -1) != int(remote_port):
            continue
        if client_id is not None and str(rec.get('client_id') or '') != str(client_id):
            continue
        if service_id is not None and str(rec.get('service_id') or '') != str(service_id):
            continue
        return True
    return False


def acquire_lease(lease_dir, client_id, service_id, remote_port, run_id='', ttl_sec=30):
    fd = _acquire_lock(lease_dir)
    try:
        now = time.time()
        expire_stale(lease_dir, now=now)
        active = _list_active(lease_dir, now=now)
        while len(active) >= MAX_LEASES:
            oldest = min(active, key=lambda item: float(item.get('expires_at') or 0))
            token = str(oldest.get('token') or '')
            if token:
                _lease_file(lease_dir, token).unlink(missing_ok=True)
            active = _list_active(lease_dir, now=now)
        token = secrets.token_hex(16)
        record = {
            'client_id': str(client_id),
            'service_id': str(service_id),
            'remote_port': int(remote_port),
            'run_id': str(run_id or ''),
            'created_at': now,
            'expires_at': now + float(ttl_sec),
            'token': token,
        }
        _atomic_write(_lease_file(lease_dir, token), record)
        return True
    except OSError:
        return False
    finally:
        _release_lock(fd)


def release_leases_for_proxy(lease_dir, proxy_name='', run_id=''):
    fd = _acquire_lock(lease_dir)
    try:
        now = time.time()
        for path in Path(lease_dir).glob('lease-*.json'):
            if path.is_symlink():
                continue
            try:
                data = _read_lease(path)
            except (OSError, ValueError, json.JSONDecodeError):
                continue
            if run_id and str(data.get('run_id') or '') == run_id:
                path.unlink(missing_ok=True)
        expire_stale(lease_dir, now=now)
    finally:
        _release_lock(fd)
