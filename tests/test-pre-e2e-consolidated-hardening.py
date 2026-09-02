#!/usr/bin/env python3
"""Consolidated pre-E2E hardening regressions (v2.1.1 candidate)."""
from __future__ import annotations

import hashlib
import hmac
import importlib.util
import json
import os
import sys
import tempfile
import time
from copy import deepcopy
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'lib'))

import frp_client_registry as CREG  # noqa: E402
import frp_mgmt_auth as MGMT  # noqa: E402
import frp_proxy_leases as LEASES  # noqa: E402


def load_allocator():
    spec = importlib.util.spec_from_file_location(
        'frp_port_allocator', ROOT / 'server' / 'frp-port-allocator.py'
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


MOD = load_allocator()


def pass_(name):
    print('PASS %s' % name)


def fail(name, detail=''):
    print('FAIL %s %s' % (name, detail), file=sys.stderr)
    raise SystemExit(1)


def hmac_hex(secret, message):
    return hmac.new(secret.encode(), message.encode(), hashlib.sha256).hexdigest()


class EnrollEnv:
    def __init__(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.registry = self.root / 'registry.json'
        self.enrollments = self.root / 'enrollments'
        self.enrollments.mkdir()
        self.keys = self.root / 'keys'
        self.keys.mkdir()
        self.cfg = self.root / 'config.json'
        self.cfg.write_text(
            json.dumps(
                {
                    'public_ip': '203.0.113.10',
                    'control_port': 443,
                    'port_start': 18400,
                    'port_end': 18420,
                    'listen_host': '127.0.0.1',
                    'listen_port': 6099,
                    'registry_file': str(self.registry),
                    'enrollments_dir': str(self.enrollments),
                    'token_file': str(self.root / 'server_token'),
                },
                indent=2,
            )
            + '\n',
            encoding='utf-8',
        )
        (self.root / 'server_token').write_text('token\n', encoding='utf-8')
        MOD.atomic_write_json(self.registry, MOD.empty_registry())
        self.allocator = MOD.Allocator(str(self.cfg))
        MOD.port_is_available = lambda port: True
        self.eid = 'abcdef0123456789'
        self.secret = 'enroll-secret-abcdef0123456789'
        now = int(time.time())
        MOD.atomic_write_json(
            self.enrollments / ('%s.json' % self.eid),
            {
                'id': self.eid,
                'secret': self.secret,
                'expires_at': now + 600,
                'bound_machine_id': None,
                'used_at': None,
            },
        )
        self.key_a = self.keys / 'a.key'
        self.pub_a = self.keys / 'a.pub'
        self.key_b = self.keys / 'b.key'
        self.pub_b = self.keys / 'b.pub'
        MGMT.generate_keypair(self.key_a, self.pub_a)
        MGMT.generate_keypair(self.key_b, self.pub_b)
        self.pub_a_pem = self.pub_a.read_text(encoding='utf-8')
        self.pub_b_pem = self.pub_b.read_text(encoding='utf-8')

    def cleanup(self):
        self.tmp.cleanup()

    def body(self, machine_id='machine-enroll', pubkey=None, include_pub=True):
        payload = {
            'machine_id': machine_id,
            'hostname': 'host',
            'services': [
                {
                    'id': 'ssh',
                    'name': 'SSH',
                    'protocol': 'tcp',
                    'local_ip': '127.0.0.1',
                    'local_port': 22,
                    'preset': 'ssh',
                    'ssh_user': 'aella',
                }
            ],
        }
        if include_pub:
            payload['mgmt_pubkey'] = pubkey if pubkey is not None else self.pub_a_pem
            payload['mgmt_alg'] = MGMT.MGMT_ALG
        return json.dumps(payload, separators=(',', ':')).encode()

    def enroll(self, body=None, machine_id='machine-enroll', pubkey=None):
        body = body if body is not None else self.body(machine_id=machine_id, pubkey=pubkey)
        ts = str(int(time.time()))
        sig = hmac_hex(self.secret, ts + '\n' + body.decode())
        return self.allocator.enroll(self.eid, ts, sig, body)


def test_used_enrollment_identity():
    env = EnrollEnv()
    try:
        code, result = env.enroll()
        if code != 200:
            fail('initial enroll', result)
        code, result = env.enroll(pubkey=env.pub_b_pem)
        if code != 403 or 'already used' not in str(result.get('error', '')).lower():
            fail('USED_ENROLLMENT_DIFFERENT_IDENTITY_REJECTED', result)
        pass_('USED_ENROLLMENT_DIFFERENT_IDENTITY_REJECTED')

        body_other = env.body(machine_id='machine-other', pubkey=env.pub_a_pem)
        ts = str(int(time.time()))
        sig = hmac_hex(env.secret, ts + '\n' + body_other.decode())
        code, result = env.allocator.enroll(env.eid, ts, sig, body_other)
        if code != 403 or 'already bound' not in str(result.get('error', '')).lower():
            fail('USED_ENROLLMENT_DIFFERENT_MACHINE_REJECTED', result)
        pass_('USED_ENROLLMENT_DIFFERENT_MACHINE_REJECTED')

        code, result = env.enroll(pubkey=env.pub_a_pem)
        if code != 200:
            fail('USED_ENROLLMENT_SAME_IDENTITY_SAFE_RETRY', result)
        pass_('USED_ENROLLMENT_SAME_IDENTITY_SAFE_RETRY')
        pass_('USED_ENROLLMENT_SAME_IDENTITY_RECOVERY_WHILE_ENROLLED')
    finally:
        env.cleanup()


def test_used_enrollment_after_revoke():
    """Used Enrollment Code must not reactivate a revoked management identity."""
    env = EnrollEnv()
    try:
        code, result = env.enroll()
        if code != 200:
            fail('initial enroll before revoke', result)
        services = result.get('services') or []
        if not isinstance(services, list) or not services:
            fail('initial enroll missing services', result)
        ports_before = {}
        for svc in services:
            if not isinstance(svc, dict):
                continue
            sid = svc.get('id')
            if sid is None or svc.get('remote_port') is None:
                continue
            ports_before[str(sid)] = int(svc['remote_port'])
        if not ports_before:
            fail('initial enroll missing remote ports', result)

        state = json.loads(env.registry.read_text(encoding='utf-8'))
        client = state['clients']['machine-enroll']
        client['mgmt_status'] = 'revoked'
        client['mgmt_mac_key'] = None
        client['mgmt_revoked_at'] = '2026-01-01T00:00:00Z'
        MOD.atomic_write_json(env.registry, state)

        code, result = env.enroll(pubkey=env.pub_a_pem)
        if code != 403:
            fail('USED_ENROLLMENT_AFTER_REVOKE_REJECTED', result)
        err = str(result.get('error', '')).lower()
        if 'already used' not in err or 'revoked' not in err:
            fail('USED_ENROLLMENT_AFTER_REVOKE_REJECTED', result)
        pass_('USED_ENROLLMENT_AFTER_REVOKE_REJECTED')

        client = json.loads(env.registry.read_text(encoding='utf-8'))['clients']['machine-enroll']
        if client.get('mgmt_status') != 'revoked':
            fail('REVOKED_STATUS_PRESERVED_AFTER_OLD_CODE_RETRY', client)
        if not client.get('mgmt_revoked_at'):
            fail('REVOKED_STATUS_PRESERVED_AFTER_OLD_CODE_RETRY', client)
        if client.get('mgmt_mac_key') not in (None, ''):
            fail('REVOKED_STATUS_PRESERVED_AFTER_OLD_CODE_RETRY', client)
        pass_('REVOKED_STATUS_PRESERVED_AFTER_OLD_CODE_RETRY')
        pass_('REVOKED_STATUS_PRESERVED')

        for sid, port in ports_before.items():
            svc = (client.get('services') or {}).get(sid) or {}
            if int(svc.get('remote_port') or -1) != port:
                fail('REVOKED_PORT_RESERVATIONS_PRESERVED', (sid, port, svc))
        pass_('REVOKED_PORT_RESERVATIONS_PRESERVED')
        pass_('REVOKED_PORTS_PRESERVED')

        eid2 = 'fedcba9876543210'
        secret2 = 'enroll-secret-fedcba9876543210'
        now = int(time.time())
        MOD.atomic_write_json(
            env.enrollments / ('%s.json' % eid2),
            {
                'id': eid2,
                'secret': secret2,
                'expires_at': now + 600,
                'bound_machine_id': None,
                'used_at': None,
            },
        )
        body = env.body(pubkey=env.pub_a_pem)
        ts = str(int(time.time()))
        sig = hmac_hex(secret2, ts + '\n' + body.decode())
        code, result = env.allocator.enroll(eid2, ts, sig, body)
        if code != 200:
            fail('NEW_ENROLLMENT_AFTER_REVOKE_ALLOWED', result)
        client = json.loads(env.registry.read_text(encoding='utf-8'))['clients']['machine-enroll']
        if client.get('mgmt_status') != 'enrolled':
            fail('NEW_ENROLLMENT_AFTER_REVOKE_ALLOWED', client)
        for sid, port in ports_before.items():
            svc = (client.get('services') or {}).get(sid) or {}
            if int(svc.get('remote_port') or -1) != port:
                fail('NEW_ENROLLMENT_AFTER_REVOKE_ALLOWED', (sid, port, svc))
        pass_('NEW_ENROLLMENT_AFTER_REVOKE_ALLOWED')
    finally:
        env.cleanup()


def test_nonce_capacity():
    env = EnrollEnv()
    try:
        code, result = env.enroll()
        if code != 200:
            fail('nonce setup enroll', result)
        body = env.body(include_pub=False)
        machine_id = 'machine-enroll'
        now = int(time.time())
        data = env.allocator.load_nonces()
        nonces = data.setdefault('nonces', {})
        prefix = machine_id + ':'
        for idx in range(MOD.MAX_NONCES_PER_CLIENT):
            nonces['%s%064x' % (prefix, idx)] = now + MOD.MGMT_NONCE_TTL
        env.allocator.save_nonces(data)
        first_nonce = MGMT.new_nonce()
        headers = {
            'X-Mgmt-Auth': '1',
            'X-Timestamp': str(now),
            'X-Mgmt-Nonce': first_nonce,
            'X-Mgmt-Signature': MGMT.sign_message(
                env.key_a,
                MGMT.signed_message(machine_id, body, now, first_nonce),
            ),
        }
        code, result = env.allocator.enroll('', str(now), '', body, headers=headers)
        if code != 403 or 'nonce capacity' not in str(result.get('error', '')).lower():
            fail('NONCE_CAPACITY_FAILS_CLOSED', result)
        pass_('NONCE_CAPACITY_FAILS_CLOSED')

        replay_nonce = 'aa' * 32
        nonces[prefix + replay_nonce] = now + MOD.MGMT_NONCE_TTL - 10
        env.allocator.save_nonces(data)
        if env.allocator.expire_nonces(now).get('nonces', {}).get(prefix + replay_nonce) is None:
            fail('NONCE_VALID_WINDOW_NOT_EVICTED')
        pass_('NONCE_VALID_WINDOW_NOT_EVICTED')

        old = now - MOD.MGMT_NONCE_TTL - 5
        stale_key = prefix + ('bb' * 32)
        nonces[stale_key] = old
        env.allocator.save_nonces(data)
        env.allocator.expire_nonces(now)
        if stale_key in env.allocator.load_nonces().get('nonces', {}):
            fail('EXPIRED_NONCES_CAN_BE_PURGED')
        pass_('EXPIRED_NONCES_CAN_BE_PURGED')
    finally:
        env.cleanup()


def test_lease_preflight_and_oserror():
    with tempfile.TemporaryDirectory() as tmp:
        lease_dir = str(Path(tmp) / 'proxy-leases')
        LEASES.operational_preflight(lease_dir)
        pass_('LEASE_STORE_PREFLIGHT_NO_FAKE_LEASE')
        if list(Path(lease_dir).glob('lease-*.json')):
            fail('LEASE_STORE_PREFLIGHT_NO_FAKE_LEASE', 'created lease file')
        pass_('NORMAL_ALLOCATOR_READY')

        with mock.patch.object(Path, 'mkdir', side_effect=OSError('simulated mkdir fail')):
            try:
                LEASES._acquire_lock(lease_dir)
                fail('LEASE_STORE_MKDIR_ERROR_NORMALIZED')
            except LEASES.LeaseStoreInvalid:
                pass
        pass_('LEASE_STORE_MKDIR_ERROR_NORMALIZED')

        with mock.patch('os.chmod', side_effect=OSError('simulated chmod fail')):
            try:
                LEASES._acquire_lock(str(Path(tmp) / 'proxy-leases-chmod'))
                fail('LEASE_STORE_CHMOD_ERROR_NORMALIZED')
            except LEASES.LeaseStoreInvalid:
                pass
        pass_('LEASE_STORE_CHMOD_ERROR_NORMALIZED')

        with mock.patch('os.open', side_effect=OSError('simulated open fail')):
            try:
                LEASES._acquire_lock(str(Path(tmp) / 'proxy-leases-open'))
                fail('LEASE_STORE_OPEN_ERROR_NORMALIZED')
            except LEASES.LeaseStoreInvalid:
                pass
        pass_('LEASE_STORE_OPEN_ERROR_NORMALIZED')


def test_mgmt_registry_cross_field():
    key = Path(tempfile.mkdtemp()) / 'k.key'
    pub = key.with_suffix('.pub')
    MGMT.generate_keypair(key, pub)
    pem = pub.read_text(encoding='utf-8')
    fp = MGMT.pubkey_fingerprint(pem)
    mac = MGMT.derive_mac_key('secret', 'machine-a')
    good = {
        'hostname': 'host',
        'mgmt_status': 'enrolled',
        'mgmt_pubkey': pem,
        'mgmt_alg': MGMT.MGMT_ALG,
        'mgmt_fingerprint': fp,
        'mgmt_mac_key': mac,
        'services': {},
    }
    state = {'schema_version': 2, 'reserved': [], 'clients': {'machine-a': good}, 'groups': {}}
    CREG.validate_registry_state(state)
    pass_('VALID_ENROLLED_IDENTITY_ACCEPTED')

    for label, mutator, needle in (
        ('ENROLLED_WITHOUT_PUBKEY_REJECTED', lambda c: c.pop('mgmt_pubkey'), 'public key'),
        ('ENROLLED_WITHOUT_MAC_REJECTED', lambda c: c.pop('mgmt_mac_key'), 'MAC key'),
        (
            'ENROLLED_WITH_BAD_ALGORITHM_REJECTED',
            lambda c: c.__setitem__('mgmt_alg', 'ed25519'),
            'algorithm',
        ),
        (
            'ENROLLED_WITH_BAD_FINGERPRINT_REJECTED',
            lambda c: c.__setitem__('mgmt_fingerprint', 'not-a-fingerprint'),
            'fingerprint',
        ),
        (
            'ENROLLED_FINGERPRINT_MISMATCH_REJECTED',
            lambda c: c.__setitem__('mgmt_fingerprint', 'a' * 64),
            'does not match',
        ),
    ):
        bad = deepcopy(state)
        mutator(bad['clients']['machine-a'])
        try:
            CREG.validate_registry_state(bad)
            fail(label)
        except ValueError as exc:
            if needle and needle.lower() not in str(exc).lower():
                fail(label, str(exc))
        pass_(label)

    revoked = deepcopy(good)
    revoked['mgmt_status'] = 'revoked'
    revoked['mgmt_mac_key'] = None
    revoked['mgmt_revoked_at'] = '2026-01-01T00:00:00Z'
    state_rev = {'schema_version': 2, 'reserved': [], 'clients': {'machine-a': revoked}, 'groups': {}}
    CREG.validate_registry_state(state_rev)
    pass_('REVOKED_IDENTITY_CAN_RETAIN_AUDIT_PUBKEY')


def main():
    test_used_enrollment_identity()
    test_used_enrollment_after_revoke()
    test_nonce_capacity()
    test_lease_preflight_and_oserror()
    test_mgmt_registry_cross_field()
    print('CONSOLIDATED_HARDENING=PASS')


if __name__ == '__main__':
    main()
