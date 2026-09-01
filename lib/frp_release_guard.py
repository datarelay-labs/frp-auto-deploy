#!/usr/bin/env python3
"""Shared release guards for registry port release operations."""
from __future__ import annotations

import importlib.util
import os
from pathlib import Path


def _load_dpa():
    root = os.environ.get('FRP_DEPLOY_TEST_ROOT', '')
    candidates = [
        Path(__file__).resolve().parent.parent / 'lib' / 'frp_data_plane_auth.py',
        Path('/usr/local/lib/frp-auto-deploy/frp_data_plane_auth.py'),
    ]
    if root:
        candidates.insert(0, Path(root) / 'usr/local/lib/frp-auto-deploy/frp_data_plane_auth.py')
    for path in candidates:
        if path.is_file():
            spec = importlib.util.spec_from_file_location('frp_data_plane_auth', str(path))
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            return mod
    raise RuntimeError('missing frp_data_plane_auth.py')


STRICT_RELEASE_DISABLED = (
    'port release is disabled while strict data-plane authorization is not enabled.\n'
    '\n'
    'Upgrade all clients to data-plane-proof capable builds and complete the '
    'strict authorization cutover before releasing reservations.'
)


def data_plane_auth_strict_enabled(cfg):
    return (cfg or {}).get('data_plane_auth_strict', True) is True


def ensure_strict_release_enabled(cfg=None):
    if not data_plane_auth_strict_enabled(cfg):
        raise ValueError(STRICT_RELEASE_DISABLED)


def ensure_port_releasable(remote_port, cfg=None, force=False):
    if force:
        raise ValueError(
            'unsafe --force release is not supported; stop publishing and wait for authorization leases to expire'
        )
    ensure_strict_release_enabled(cfg)
    if remote_port is None:
        return
    mod = _load_dpa()
    mod.assert_port_releasable(int(remote_port), cfg=cfg)
