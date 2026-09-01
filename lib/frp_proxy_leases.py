#!/usr/bin/env python3
"""Ephemeral NewProxy authorization leases (runtime-only, not backup state).

Leases only cover the authorization → FRPS bind/listener visibility window.
They are not a session database and must not be backed up.

Lock order (see lib/frp_control_locks.py):

  1. server-lifecycle.lock   (backup/restore only)
  2. registry.lock           (NewProxy authorization, release, allocator writers)
  3. proxy-leases/.leases.lock
     only while already holding registry.lock for authorization/release-safety

Never acquire registry.lock while holding the lease lock.
"""
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
LEASE_SCHEMA = 1
REQUIRED_FIELDS = (
    'lease_schema',
    'client_id',
    'service_id',
    'remote_port',
    'created_at',
    'expires_at',
    'token',
)


class LeaseStoreInvalid(ValueError):
    """Malformed/unreadable lease state. Release and NewProxy must fail closed."""


class LeaseCapacityExceeded(ValueError):
    """Active unexpired leases already occupy MAX_LEASES."""


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
    if path.exists() and path.is_symlink():
        raise LeaseStoreInvalid('LEASE_STORE_INVALID: lease directory is a symlink')
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


def _validate_lease_record(data):
    if not isinstance(data, dict):
        raise ValueError('invalid lease record')
    schema = data.get('lease_schema')
    if schema is None:
        # Pre-schema records from 2.1.1-rc: accept if remaining fields are valid.
        pass
    elif schema != LEASE_SCHEMA:
        raise ValueError('unexpected lease schema')
    for field in ('client_id', 'service_id', 'token'):
        if not str(data.get(field) or '').strip():
            raise ValueError('lease missing %s' % field)
    try:
        port = int(data.get('remote_port'))
        created = float(data.get('created_at'))
        expires = float(data.get('expires_at'))
    except (TypeError, ValueError):
        raise ValueError('lease has invalid numeric fields') from None
    if not 1 <= port <= 65535:
        raise ValueError('lease remote_port out of range')
    if expires <= created:
        raise ValueError('lease expiry is invalid')
    return data


def _read_lease(path):
    if path.is_symlink():
        raise ValueError('refusing symlink lease file')
    raw = path.read_text(encoding='utf-8')
    data = json.loads(raw)
    return _validate_lease_record(data)


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
    """Remove clearly expired VALID lease records. Never deletes malformed files."""
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
        except (OSError, ValueError, json.JSONDecodeError, TypeError):
            continue
        if float(data.get('expires_at') or 0) <= now:
            try:
                path.unlink(missing_ok=True)
                removed += 1
            except OSError:
                pass
    return removed


def inspect_lease_store(lease_dir, now=None):
    """Return active valid leases or raise LeaseStoreInvalid.

    Used for release-safety and NewProxy capacity. Does not delete corruption.
    """
    now = float(now if now is not None else time.time())
    base = Path(lease_dir)
    if not base.exists():
        return []
    if base.is_symlink() or not base.is_dir():
        raise LeaseStoreInvalid('LEASE_STORE_INVALID: lease store is not a directory')
    try:
        names = list(base.glob('lease-*.json'))
    except OSError as exc:
        raise LeaseStoreInvalid('LEASE_STORE_INVALID: unreadable lease store: %s' % exc) from exc
    active = []
    for path in sorted(names):
        if path.is_symlink():
            raise LeaseStoreInvalid('LEASE_STORE_INVALID: symlink lease file')
        try:
            data = _read_lease(path)
        except (OSError, ValueError, json.JSONDecodeError, TypeError) as exc:
            raise LeaseStoreInvalid(
                'LEASE_STORE_INVALID: malformed lease record %s: %s' % (path.name, exc)
            ) from exc
        if float(data.get('expires_at') or 0) > now:
            active.append(data)
    return active


def _list_active(lease_dir, now=None):
    expire_stale(lease_dir, now=now)
    return inspect_lease_store(lease_dir, now=now)


def has_active_lease(lease_dir, remote_port=None, client_id=None, service_id=None):
    now = time.time()
    for rec in inspect_lease_store(lease_dir, now=now):
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
        active = inspect_lease_store(lease_dir, now=now)
        if len(active) >= MAX_LEASES:
            raise LeaseCapacityExceeded('authorization lease capacity exceeded')
        token = secrets.token_hex(16)
        record = {
            'lease_schema': LEASE_SCHEMA,
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
    except LeaseCapacityExceeded:
        raise
    except LeaseStoreInvalid:
        raise
    except OSError as exc:
        raise LeaseStoreInvalid('LEASE_STORE_INVALID: cannot write lease: %s' % exc) from exc
    finally:
        _release_lock(fd)
