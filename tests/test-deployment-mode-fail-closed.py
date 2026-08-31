#!/usr/bin/env python3
"""Fail-closed deployment_mode / transport normalization."""
import importlib.util
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'lib'))
import frp_frontend as FRONTEND  # noqa: E402


def pass_(name):
    print('PASS %s' % name)


def fail(name, detail=''):
    print('FAIL %s %s' % (name, detail), file=sys.stderr)
    raise SystemExit(1)


def load_allocator():
    spec = importlib.util.spec_from_file_location(
        'frp_port_allocator', ROOT / 'server' / 'frp-port-allocator.py'
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_normalize_aliases():
    for raw, expected in (
        ('direct', 'direct'),
        ('DIRECT', 'direct'),
        ('', 'direct'),
        (None, 'direct'),
        ('single443', 'single443'),
        ('single-443', 'single443'),
        ('single_443', 'single443'),
        ('enterprise', 'single443'),
        ('Enterprise', 'single443'),
        ('enterprise-single-443', 'single443'),
        ('enterprise_single443', 'single443'),
    ):
        got = FRONTEND.normalize_deployment_mode(raw)
        if got != expected:
            fail('alias', '%r -> %r want %r' % (raw, got, expected))
    pass_('DEPLOYMENT_MODE_ALIASES')


def test_typo_and_unknown_fail_closed():
    for bad in ('singel443', 'single444', 'entirprise', 'prod', 'legacy'):
        try:
            FRONTEND.normalize_deployment_mode(bad)
            fail('typo accepted', bad)
        except ValueError:
            pass
    pass_('DEPLOYMENT_MODE_TYPO_FAIL_CLOSED')


def test_transport_fail_closed():
    if FRONTEND.normalize_transport('', 'direct') != 'tcp':
        fail('empty direct transport')
    if FRONTEND.normalize_transport('', 'single443') != 'wss':
        fail('empty single443 transport')
    if FRONTEND.normalize_transport('tcp', 'direct') != 'tcp':
        fail('tcp')
    if FRONTEND.normalize_transport('wss', 'single443') != 'wss':
        fail('wss')
    for bad in ('ws', 'https', 'quic', 'udp'):
        try:
            FRONTEND.normalize_transport(bad, 'direct')
            fail('bad transport accepted', bad)
        except ValueError:
            pass
    pass_('TRANSPORT_FAIL_CLOSED')


def test_allocator_cfg_deployment_mode():
    mod = load_allocator()
    if mod.cfg_deployment_mode({}) != 'direct':
        fail('empty cfg')
    if mod.cfg_deployment_mode({'deployment_mode': ''}) != 'direct':
        fail('blank mode')
    if mod.cfg_deployment_mode({'deployment_mode': 'enterprise'}) != 'single443':
        fail('enterprise alias')
    if mod.cfg_deployment_mode({'deployment_mode': 'direct'}) != 'direct':
        fail('direct')
    try:
        mod.cfg_deployment_mode({'deployment_mode': 'singel443'})
        fail('allocator accepted typo as silent direct')
    except ValueError:
        pass
    try:
        mod.cfg_frp_transport({'deployment_mode': 'direct', 'frp_transport': 'ws'})
        fail('allocator accepted unknown transport')
    except ValueError:
        pass
    pass_('ALLOCATOR_CFG_DEPLOYMENT_MODE_FAIL_CLOSED')


def main():
    test_normalize_aliases()
    test_typo_and_unknown_fail_closed()
    test_transport_fail_closed()
    test_allocator_cfg_deployment_mode()
    print('DEPLOYMENT_MODE_FAIL_CLOSED=PASS')


if __name__ == '__main__':
    main()
