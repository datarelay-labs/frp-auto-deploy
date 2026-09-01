#!/usr/bin/env python3
"""Canonical server public-namespace validation regressions."""
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'lib'))
import frp_server_config as scfg  # noqa: E402


def pass_(name):
    print('PASS %s' % name)


def fail(name, detail=''):
    print('FAIL %s %s' % (name, detail), file=sys.stderr)
    raise SystemExit(1)


def base_direct(**overrides):
    cfg = {
        'deployment_mode': 'direct',
        'frp_transport': 'tcp',
        'port_start': 6000,
        'port_end': 6098,
        'frp_control_listen_port': 7000,
        'frp_control_public_port': 7000,
        'allocator_listen_port': 7500,
        'allocator_public_port': 7500,
    }
    cfg.update(overrides)
    return cfg


def base_single443(**overrides):
    cfg = {
        'deployment_mode': 'single443',
        'frp_transport': 'wss',
        'port_start': 6000,
        'port_end': 6098,
        'frp_control_listen_port': 7000,
        'frp_control_public_port': 443,
        'allocator_listen_port': 7500,
        'allocator_public_port': 443,
        'frontend_public_port': 443,
    }
    cfg.update(overrides)
    return cfg


def expect_ok(label, cfg):
    try:
        scfg.validate_server_config(cfg)
    except ValueError as exc:
        fail(label, exc)
    pass_(label)


def expect_fail(label, cfg, needle=None):
    try:
        scfg.validate_server_config(cfg)
        fail(label, 'expected rejection')
    except ValueError as exc:
        if needle and needle not in str(exc):
            fail(label, 'unexpected: %s' % exc)
        pass_(label)


def test_core():
    expect_ok('DIRECT_NORMAL', base_direct())
    expect_ok(
        'NAT_LISTEN_PUBLIC_SPLIT_VALIDATED',
        base_direct(
            frp_control_listen_port=7000,
            frp_control_public_port=8443,
            allocator_listen_port=7500,
            allocator_public_port=9443,
        ),
    )
    expect_fail(
        'PUBLIC_CONTROL_SERVICE_RANGE_COLLISION_REJECTED',
        base_direct(frp_control_public_port=6050),
        'service port range',
    )
    expect_fail(
        'PUBLIC_ALLOCATOR_SERVICE_RANGE_COLLISION_REJECTED',
        base_direct(allocator_public_port=6051),
        'service port range',
    )
    expect_fail(
        'LISTEN_SAFE_PUBLIC_CONFLICT',
        base_direct(
            frp_control_listen_port=7000,
            allocator_listen_port=7500,
            frp_control_public_port=6050,
            allocator_public_port=7500,
        ),
        'service port range',
    )
    expect_ok('SINGLE443_INTENTIONAL_443_SHARING', base_single443())
    expect_fail(
        'SINGLE443_INTERNAL_BACKEND_COLLISION',
        base_single443(allocator_listen_port=443, frp_control_listen_port=7000),
        'frontend',
    )
    expect_fail(
        'PLUGIN_PORT_SERVICE_RANGE_COLLISION_REJECTED',
        base_direct(port_end=6100),
        'frp plugin listen port collides with service port range',
    )
    expect_fail(
        'REVERSED_SERVICE_RANGE',
        base_direct(port_start=6100, port_end=6000),
        'port_start',
    )
    expect_fail(
        'INVALID_TCP_PORT',
        base_direct(frp_control_public_port=0),
        'TCP port',
    )
    expect_fail(
        'UNKNOWN_MODE',
        base_direct(deployment_mode='weird'),
        'deployment_mode',
    )
    expect_fail(
        'DATA_PLANE_STRICT_STRING_FALSE_REJECTED',
        base_direct(data_plane_auth_strict='false'),
        'boolean',
    )
    expect_fail(
        'DATA_PLANE_STRICT_STRING_TRUE_REJECTED',
        base_direct(data_plane_auth_strict='true'),
        'boolean',
    )
    expect_ok('DATA_PLANE_STRICT_BOOL_FALSE_OK', base_direct(data_plane_auth_strict=False))
    expect_ok('DATA_PLANE_STRICT_BOOL_TRUE_OK', base_direct(data_plane_auth_strict=True))
    expect_ok(
        'LEASE_DIR_DEFAULT_CANONICAL',
        base_direct(),
    )
    expect_ok(
        'LEASE_DIR_ABSOLUTE_CANONICAL',
        base_direct(proxy_lease_dir='/run/frp-auto-deploy/proxy-leases'),
    )
    expect_fail(
        'LEASE_DIR_RELATIVE_REJECTED',
        base_direct(proxy_lease_dir='leases'),
        'canonical absolute path',
    )
    expect_fail(
        'LEASE_DIR_TRAVERSAL_REJECTED',
        base_direct(proxy_lease_dir='../leases'),
        'canonical absolute path',
    )
    expect_fail(
        'LEASE_DIR_UNSAFE_LOCATION_REJECTED',
        base_direct(proxy_lease_dir='/tmp/leases'),
        'canonical absolute path',
    )
    expect_fail(
        'PLUGIN_HOST_NON_STRING_REJECTED',
        base_direct(frp_plugin_listen_host=True),
        'frp_plugin_listen_host',
    )
    pass_('DATA_PLANE_STRICT_BOOLEAN_VALIDATION')
    pass_('LEASE_DIR_VALIDATION')


def test_restore_rejects_unsafe():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        payload = root / 'payload'
        for rel in (
            'var/lib/frp-auto-deploy',
            'etc/frp-auto-deploy/pki',
            'etc/frp',
        ):
            (payload / rel).mkdir(parents=True)
        bad = base_direct(frp_control_public_port=6050)
        (payload / 'etc/frp-auto-deploy/config.json').write_text(json.dumps(bad) + '\n')
        (payload / 'var/lib/frp-auto-deploy/registry.json').write_text(
            json.dumps({'schema_version': 2, 'clients': {}, 'reserved': [], 'groups': {}}) + '\n'
        )
        (payload / 'etc/frp/frps.toml').write_text('bindPort = 7000\n')
        # Minimal PKI files so pair validation is reached only after config check.
        for name in ('ca.crt', 'ca.key', 'server.crt', 'server.key'):
            (payload / 'etc/frp-auto-deploy/pki' / name).write_text('x\n')

        # Import restore prevalidate directly.
        import importlib.machinery
        import importlib.util
        restore_path = ROOT / 'tools' / 'frp-restore'
        loader = importlib.machinery.SourceFileLoader(
            'frp_restore_under_test', str(restore_path)
        )
        spec = importlib.util.spec_from_loader(loader.name, loader)
        assert spec is not None and spec.loader is not None, restore_path
        mod = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = mod
        loader.exec_module(mod)
        try:
            mod._semantic_prevalidate_candidate(root)
            fail('RESTORE_UNSAFE_PUBLIC_NAMESPACE_REJECTED', 'accepted unsafe config')
        except mod.RestoreError as exc:
            text = str(exc).lower()
            if 'unsafe' not in text and 'service port range' not in text and 'collides' not in text:
                fail('RESTORE_UNSAFE_PUBLIC_NAMESPACE_REJECTED', exc)
            pass_('RESTORE_UNSAFE_PUBLIC_NAMESPACE_REJECTED')


def main():
    test_core()
    test_restore_rejects_unsafe()
    print('ALL PASS')


if __name__ == '__main__':
    main()
