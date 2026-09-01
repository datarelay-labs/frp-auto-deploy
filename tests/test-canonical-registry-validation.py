#!/usr/bin/env python3
"""Canonical registry validation and mutation-gate regression tests."""
import json
import os
import subprocess
import sys
import tempfile
from copy import deepcopy
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'lib'))
import frp_client_registry as creg  # noqa: E402

MID = 'aabbccdd00112233445566778899aabb'
CFG = {
    'port_start': 6000,
    'port_end': 6099,
    'allocator_listen_port': 7500,
    'frp_control_listen_port': 6050,
    'allocator_public_port': 7500,
    'frp_control_public_port': 7000,
}


def pass_(name):
    print('PASS %s' % name)


def fail(name, detail=''):
    print('FAIL %s %s' % (name, detail), file=sys.stderr)
    raise SystemExit(1)


def base_service(**overrides):
    svc = {
        'id': 'ssh',
        'protocol': 'tcp',
        'preset': 'ssh',
        'enabled': True,
        'local_ip': '127.0.0.1',
        'local_port': 22,
        'remote_port': 6001,
        'ssh_user': 'ubuntu',
    }
    svc.update(overrides)
    return svc


def base_state(**overrides):
    state = {
        'schema_version': 2,
        'reserved': [],
        'groups': {
            'grp_abcd1234': {
                'name': 'ops',
                'type': 'manual',
                'created_at': '2026-01-01T00:00:00Z',
                'updated_at': '2026-01-01T00:00:00Z',
            }
        },
        'clients': {
            MID: {
                'hostname': 'host1',
                'label': 'edge-1',
                'note': 'lab',
                'tags': {'env': 'prod'},
                'group_ids': ['grp_abcd1234'],
                'mgmt_status': 'enrolled',
                'services': {'ssh': base_service()},
            }
        },
    }
    state.update(overrides)
    return state


def expect_reject(label, mutator, needle=None):
    state = base_state()
    mutator(state)
    try:
        creg.validate_registry_state(state, CFG)
        fail(label, 'expected rejection')
    except ValueError as exc:
        text = str(exc)
        if needle and needle not in text:
            fail(label, 'unexpected message: %s' % text)
        pass_(label)


def test_valid_and_corrupt_ports():
    creg.validate_registry_state(base_state(), CFG)
    pass_('VALID_REGISTRY_STATE')

    expect_reject(
        'CORRUPT_SERVICE_REMOTE_PORT_REJECTED',
        lambda s: s['clients'][MID]['services']['ssh'].__setitem__('remote_port', 'abc'),
        'remote_port',
    )
    expect_reject(
        'CORRUPT_SERVICE_REMOTE_PORT_NULL',
        lambda s: s['clients'][MID]['services']['ssh'].__setitem__('remote_port', None),
        'remote_port',
    )
    expect_reject(
        'CORRUPT_SERVICE_REMOTE_PORT_BOOL',
        lambda s: s['clients'][MID]['services']['ssh'].__setitem__('remote_port', True),
        'remote_port',
    )
    expect_reject(
        'CORRUPT_SERVICE_REMOTE_PORT_OOR',
        lambda s: s['clients'][MID]['services']['ssh'].__setitem__('remote_port', 70000),
        'out of range',
    )


def test_service_identity_and_fields():
    expect_reject(
        'CORRUPT_SERVICE_ID_REJECTED',
        lambda s: (
            s['clients'][MID]['services'].__setitem__(
                'BAD ID!',
                s['clients'][MID]['services'].pop('ssh'),
            )
        ),
        'service map key',
    )
    expect_reject(
        'CORRUPT_SERVICE_KEY_ID_MISMATCH',
        lambda s: s['clients'][MID]['services']['ssh'].__setitem__('id', 'web'),
        'does not match',
    )
    expect_reject(
        'CORRUPT_SERVICE_NONCANONICAL_ID',
        lambda s: (
            s['clients'][MID]['services'].__setitem__(
                'SSH',
                {**s['clients'][MID]['services'].pop('ssh'), 'id': 'SSH'},
            )
        ),
        'noncanonical',
    )
    expect_reject(
        'CORRUPT_SERVICE_TARGET_REJECTED',
        lambda s: s['clients'][MID]['services']['ssh'].__setitem__('local_ip', 'bad host;rm'),
        'local_ip',
    )
    expect_reject(
        'CORRUPT_SERVICE_LOCAL_PORT',
        lambda s: s['clients'][MID]['services']['ssh'].__setitem__('local_port', 'xyz'),
        'local_port',
    )
    expect_reject(
        'CORRUPT_SERVICE_PROTOCOL',
        lambda s: s['clients'][MID]['services']['ssh'].__setitem__('protocol', 'udp'),
        'protocol',
    )
    expect_reject(
        'CORRUPT_SERVICE_PRESET',
        lambda s: s['clients'][MID]['services']['ssh'].__setitem__('preset', 'ftp'),
        'preset',
    )
    expect_reject(
        'CORRUPT_SERVICE_ENABLED',
        lambda s: s['clients'][MID]['services']['ssh'].__setitem__('enabled', 'yes'),
        'enabled',
    )


def test_tags_groups_machine():
    expect_reject(
        'CORRUPT_TAGS_REJECTED',
        lambda s: s['clients'][MID].__setitem__('tags', {'bad key': 'x'}),
        'tag',
    )
    expect_reject(
        'CORRUPT_TAG_VALUE',
        lambda s: s['clients'][MID].__setitem__('tags', {'env': ''}),
        'tag',
    )
    expect_reject(
        'NONCANONICAL_PERSISTED_MACHINE_ID',
        lambda s: s['clients'].__setitem__(
            ' ' + MID,
            s['clients'].pop(MID),
        ),
        'noncanonical machine_id',
    )
    expect_reject(
        'INVALID_GROUP_MEMBERSHIP',
        lambda s: s['clients'][MID].__setitem__('group_ids', ['grp_deadbeef']),
        'nonexistent group',
    )
    expect_reject(
        'DUPLICATE_PORT_OWNERSHIP',
        lambda s: s['clients'].__setitem__(
            'bbccddee11223344556677889900aabb',
            {
                'hostname': 'other',
                'services': {
                    'web': {
                        'id': 'web',
                        'protocol': 'tcp',
                        'preset': 'http',
                        'enabled': True,
                        'local_ip': '127.0.0.1',
                        'local_port': 80,
                        'remote_port': 6001,
                    }
                },
            },
        ),
        'duplicate public port',
    )
    expect_reject(
        'PROTECTED_PORT_OWNERSHIP',
        lambda s: s['clients'][MID]['services']['ssh'].__setitem__('remote_port', 6050),
        'reserved control port',
    )


def test_mutation_gates():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / 'etc/frp-auto-deploy').mkdir(parents=True)
        (root / 'var/lib/frp-auto-deploy').mkdir(parents=True)
        reg = root / 'var/lib/frp-auto-deploy/registry.json'
        cfg_path = root / 'etc/frp-auto-deploy/config.json'
        cfg = dict(CFG)
        cfg.update({
            'public_host': '203.0.113.10',
            'registry_file': str(reg),
            'enrollments_dir': str(root / 'var/lib/frp-auto-deploy/enrollments'),
            'token_file': str(root / 'etc/frp/server_token'),
        })
        cfg_path.write_text(json.dumps(cfg) + '\n')
        good = base_state()
        reg.write_text(json.dumps(good) + '\n')

        env = os.environ.copy()
        env['FRP_DEPLOY_TEST_ROOT'] = str(root)
        tool = str(ROOT / 'tools' / 'frp-client-set')

        proc = subprocess.run(
            [tool, MID, '--note', 'updated-note'],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            universal_newlines=True,
        )
        if proc.returncode != 0:
            fail('REGISTRY_MUTATION_POSTVALIDATION', proc.stderr)
        after = json.loads(reg.read_text())
        if after['clients'][MID].get('note') != 'updated-note':
            fail('REGISTRY_MUTATION_POSTVALIDATION', 'note not written')
        pass_('REGISTRY_MUTATION_PREVALIDATION')
        pass_('REGISTRY_MUTATION_POSTVALIDATION')

        corrupt = deepcopy(good)
        corrupt['clients'][MID]['services']['ssh']['remote_port'] = 'abc'
        before = json.dumps(corrupt, indent=2, sort_keys=True) + '\n'
        reg.write_text(before)
        proc = subprocess.run(
            [tool, MID, '--note', 'should-not-write'],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            universal_newlines=True,
        )
        if proc.returncode == 0:
            fail('REGISTRY_MUTATION_NO_WRITE_ON_CORRUPTION', 'mutator succeeded')
        if 'corrupt' not in proc.stderr.lower() and 'remote_port' not in proc.stderr.lower():
            fail('REGISTRY_MUTATION_NO_WRITE_ON_CORRUPTION', proc.stderr)
        if reg.read_text() != before:
            fail('REGISTRY_MUTATION_NO_WRITE_ON_CORRUPTION', 'registry rewritten')
        pass_('REGISTRY_MUTATION_NO_WRITE_ON_CORRUPTION')


def main():
    test_valid_and_corrupt_ports()
    test_service_identity_and_fields()
    test_tags_groups_machine()
    test_mutation_gates()
    print('ALL PASS')


if __name__ == '__main__':
    main()
