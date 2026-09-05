#!/usr/bin/env python3
"""Post-v2.1.3 core correctness: retention lock, one-time enrollment, tombstones."""
from __future__ import annotations

import fcntl
import hashlib
import hmac
import importlib.util
import json
import os
import signal
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


MOD = load('frp_port_allocator', ROOT / 'server' / 'frp-port-allocator.py')
ELC = load('frp_enrollment_lifecycle', ROOT / 'lib' / 'frp_enrollment_lifecycle.py')
MGMT = load('frp_mgmt_auth', ROOT / 'lib' / 'frp_mgmt_auth.py')


def pass_(name):
    print(f'PASS {name}')


def fail(name, detail=''):
    print(f'FAIL {name} {detail}'.rstrip(), file=sys.stderr)
    raise SystemExit(1)


def hmac_hex(secret, message):
    return hmac.new(secret.encode(), message.encode(), hashlib.sha256).hexdigest()


class Timeout(Exception):
    pass


def with_alarm(seconds, fn):
    def handler(signum, frame):
        raise Timeout()
    old = signal.signal(signal.SIGALRM, handler)
    signal.alarm(seconds)
    try:
        return fn()
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, old)


def test_retention_nested_lock():
    td = tempfile.mkdtemp()
    root = Path(td)
    registry = root / 'registry.json'
    registry.write_text('{}\n')
    enrollments = root / 'enrollments'
    bootstrap = root / 'bootstrap'
    enrollments.mkdir()
    bootstrap.mkdir()
    now = int(time.time())
    eid = 'aabbccddeeff0011'
    (enrollments / f'{eid}.json').write_text(json.dumps({
        'id': eid,
        'secret': 'a' * 64,
        'expires_at': now - 100,
        'used_at': '2020-01-01T00:00:00Z',
        'bound_machine_id': 'machine-old',
    }) + '\n')

    lock_path = root / 'registry.lock'
    fd = os.open(str(lock_path), os.O_CREAT | os.O_RDWR, 0o600)
    fcntl.flock(fd, fcntl.LOCK_EX)
    try:
        try:
            with_alarm(2, lambda: ELC.run_retention_cleanup(
                enrollments, bootstrap, registry, 1, now=now
            ))
            fail('nested lock should deadlock before fix path')
        except Timeout:
            pass_('RETENTION_NESTED_LOCK_REPRODUCED')

        # Seed another eligible row for the locked path.
        eid2 = 'aabbccddeeff0022'
        (enrollments / f'{eid2}.json').write_text(json.dumps({
            'id': eid2,
            'secret': 'b' * 64,
            'expires_at': now - 100,
            'used_at': '2020-01-01T00:00:00Z',
            'bound_machine_id': 'machine-old',
        }) + '\n')
        try:
            result = with_alarm(2, lambda: ELC.run_retention_cleanup_locked(
                enrollments, bootstrap, registry, 1, now=now
            ))
        except Timeout:
            fail('locked cleanup timed out')
        if result.get('purged', 0) < 1:
            fail('locked cleanup purged nothing', result)
        pass_('RETENTION_NESTED_LOCK_FIXED')
    finally:
        os.close(fd)


def test_retention_tombstone_transaction():
    td = tempfile.mkdtemp()
    root = Path(td)
    enrollments = root / 'enrollments'
    bootstrap = root / 'bootstrap'
    enrollments.mkdir()
    bootstrap.mkdir()
    eid = 'ccddeeff00112233'
    tid = 'ddeeff0011223344'
    enroll_path = enrollments / f'{eid}.json'
    ticket_path = bootstrap / f'{tid}.json'
    enroll_path.write_text(json.dumps({'id': eid}) + '\n')
    ticket_path.write_text(json.dumps({'id': tid, 'enrollment_id': eid}) + '\n')
    row = {
        'id': tid,
        'type': 'zero-touch',
        'state': 'completed',
        'enroll_path': enroll_path,
        'ticket_path': ticket_path,
    }

    # Failure before commit (second rename fails): restore both.
    real_replace = os.replace
    calls = {'n': 0}

    def flaky_replace(src, dst):
        calls['n'] += 1
        if calls['n'] == 2:
            raise OSError('simulated rename failure')
        return real_replace(src, dst)

    os.replace = flaky_replace
    try:
        try:
            ELC._delete_targets(row)
            fail('expected rename failure')
        except OSError:
            pass
    finally:
        os.replace = real_replace
    if not enroll_path.is_file() or not ticket_path.is_file():
        fail('pre-commit rename failure did not restore originals')
    pass_('tombstone pre-commit rollback')

    # Post-commit unlink failure must leave tombstones, not restore half.
    enroll_path.write_text(json.dumps({'id': eid}) + '\n')
    ticket_path.write_text(json.dumps({'id': tid, 'enrollment_id': eid}) + '\n')
    real_unlink = Path.unlink
    unlinks = {'n': 0}

    def flaky_unlink(self, *args, **kwargs):
        unlinks['n'] += 1
        if unlinks['n'] == 1:
            real_unlink(self, *args, **kwargs)
            return
        raise OSError('simulated unlink failure')

    Path.unlink = flaky_unlink
    try:
        ELC._delete_targets(row)
    finally:
        Path.unlink = real_unlink
    if enroll_path.is_file() or ticket_path.is_file():
        fail('post-commit should not restore originals')
    tombs = list(enrollments.glob('*.purging')) + list(bootstrap.glob('*.purging'))
    if not tombs:
        # first unlink succeeded; second failed — at least one tombstone remains
        fail('expected remaining .purging tombstone after partial unlink')
    removed = ELC.reconcile_stale_tombstones(enrollments, bootstrap)
    if removed < 1:
        fail('tombstone reconciliation removed nothing')
    if list(enrollments.glob('*.purging')) or list(bootstrap.glob('*.purging')):
        fail('tombstones remain after reconciliation')
    pass_('RETENTION_PAIR_DELETE_TRANSACTION')
    pass_('RETENTION_TOMBSTONE_RECOVERY')


class EnrollEnv:
    def __init__(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.registry = self.root / 'registry.json'
        self.token = self.root / 'server_token'
        self.enrollments = self.root / 'enrollments'
        self.enrollments.mkdir()
        self.keys = self.root / 'keys'
        self.keys.mkdir()
        self.token.write_text('test-enroll-token-do-not-use\n')
        self.token.chmod(0o600)
        self.cfg = self.root / 'config.json'
        self.cfg.write_text(json.dumps({
            'public_ip': '203.0.113.10',
            'control_port': 443,
            'port_start': 18300,
            'port_end': 18320,
            'listen_host': '127.0.0.1',
            'listen_port': 6099,
            'registry_file': str(self.registry),
            'enrollments_dir': str(self.enrollments),
            'token_file': str(self.token),
        }, indent=2) + '\n')
        MOD.atomic_write_json(self.registry, MOD.empty_registry())
        self.allocator = MOD.Allocator(str(self.cfg))
        MOD.port_is_available = lambda port: True
        self.eid = 'abcdef0123456789'
        self.secret = 'enroll-secret-abcdef0123456789'
        now = int(time.time())
        MOD.atomic_write_json(self.enrollments / f'{self.eid}.json', {
            'id': self.eid,
            'secret': self.secret,
            'expires_at': now + 600,
            'bound_machine_id': None,
            'used_at': None,
        })
        self.key = self.keys / 'id.key'
        self.pub = self.keys / 'id.pub'
        MGMT.generate_keypair(self.key, self.pub)
        self.pub_pem = self.pub.read_text(encoding='utf-8')
        self.alt_key = self.keys / 'alt.key'
        self.alt_pub = self.keys / 'alt.pub'
        MGMT.generate_keypair(self.alt_key, self.alt_pub)
        self.alt_pem = self.alt_pub.read_text(encoding='utf-8')

    def cleanup(self):
        self.tmp.cleanup()

    def body(self, machine_id='machine-one', services=None, pubkey=None):
        payload = {
            'machine_id': machine_id,
            'hostname': 'host-one',
            'services': services or [{
                'id': 'ssh',
                'name': 'SSH',
                'protocol': 'tcp',
                'local_ip': '127.0.0.1',
                'local_port': 22,
                'preset': 'ssh',
                'ssh_user': 'aella',
            }],
            'mgmt_pubkey': pubkey if pubkey is not None else self.pub_pem,
            'mgmt_alg': MGMT.MGMT_ALG,
        }
        return json.dumps(payload, separators=(',', ':')).encode()

    def enroll(self, body=None, machine_id=None):
        body = body if body is not None else self.body(machine_id=machine_id or 'machine-one')
        ts = str(int(time.time()))
        sig = hmac_hex(self.secret, ts + '\n' + body.decode())
        return self.allocator.enroll(self.eid, ts, sig, body)


def test_enrollment_one_time():
    env = EnrollEnv()
    try:
        code, result = env.enroll()
        if code != 200:
            fail('fresh first enrollment', result)
        first_ports = {s['id']: s['remote_port'] for s in result['services']}
        fingerprint = env.allocator.load_registry()['clients']['machine-one']['mgmt_fingerprint']
        pass_('fresh code first enrollment')

        # Different machine
        code, result = env.enroll(env.body(machine_id='machine-other'))
        if code != 403 or 'already bound' not in result.get('error', ''):
            fail('used code different machine', result)
        pass_('USED_CODE_DIFFERENT_MACHINE_REJECT')

        # New mgmt key same machine
        code, result = env.enroll(env.body(pubkey=env.alt_pem))
        if code != 403 or 'already used' not in result.get('error', ''):
            fail('used code new mgmt key', result)
        stored_fp = env.allocator.load_registry()['clients']['machine-one']['mgmt_fingerprint']
        if stored_fp != fingerprint:
            fail('mgmt identity replaced with used code')
        pass_('USED_CODE_NEW_MGMT_KEY_REJECT')
        pass_('MGMT_IDENTITY_REPLACEMENT_WITH_USED_CODE_REJECTED')

        # Changed services
        code, result = env.enroll(env.body(services=[{
            'id': 'web',
            'name': 'Web',
            'protocol': 'tcp',
            'local_ip': '127.0.0.1',
            'local_port': 8080,
            'preset': 'custom',
        }]))
        if code != 403 or 'already used' not in result.get('error', ''):
            fail('used code changed services', result)
        pass_('USED_CODE_CHANGED_SERVICES_REJECT')

        # Exact lost-response retry
        code, result = env.enroll()
        if code != 200:
            fail('idempotent lost-response retry', result)
        retry_ports = {s['id']: s['remote_port'] for s in result['services']}
        if retry_ports != first_ports:
            fail('idempotent ports changed', (first_ports, retry_ports))
        if env.allocator.load_registry()['clients']['machine-one']['mgmt_fingerprint'] != fingerprint:
            fail('idempotent retry changed identity')
        pass_('IDEMPOTENT_RETRY')
        pass_('ENROLLMENT_TRUE_ONE_TIME')
    finally:
        env.cleanup()


def test_redeem_nested_lock_bounded():
    """Reach real redeem lock order with eligible retention work."""
    td = tempfile.mkdtemp()
    root = Path(td)
    registry = root / 'registry.json'
    MOD.atomic_write_json(registry, MOD.empty_registry())
    enrollments = root / 'enrollments'
    bootstrap = root / 'bootstrap'
    enrollments.mkdir()
    bootstrap.mkdir()
    token = root / 'server_token'
    token.write_text('tok\n')
    cfg_path = root / 'config.json'
    cfg = {
        'public_ip': '203.0.113.10',
        'control_port': 443,
        'port_start': 18400,
        'port_end': 18410,
        'listen_host': '127.0.0.1',
        'listen_port': 6099,
        'registry_file': str(registry),
        'enrollments_dir': str(enrollments),
        'bootstrap_dir': str(bootstrap),
        'token_file': str(token),
        'enrollment_retention_days': 1,
    }
    cfg_path.write_text(json.dumps(cfg) + '\n')
    now = int(time.time())
    old_eid = '1122334455667788'
    old_tid = '2233445566778899'
    (enrollments / f'{old_eid}.json').write_text(json.dumps({
        'id': old_eid,
        'secret': 'c' * 64,
        'expires_at': now - 10,
        'used_at': '2020-01-01T00:00:00Z',
        'bound_machine_id': 'old',
    }) + '\n')
    (bootstrap / f'{old_tid}.json').write_text(json.dumps({
        'id': old_tid,
        'enrollment_id': old_eid,
        'secret_hash': 'd' * 64,
        'expires_at': now - 10,
        'completed_at': '2020-01-01T00:00:00Z',
        'bound_machine_id': 'old',
    }) + '\n')

    allocator = MOD.Allocator(str(cfg_path))
    MOD.port_is_available = lambda port: True

    # Hold registry.lock and run already_locked cleanup (redeem lock order).
    with allocator.registry_lock():
        try:
            result = with_alarm(3, lambda: allocator.cleanup_expired_bootstrap_tickets(
                force=True, already_locked=True
            ))
        except Timeout:
            fail('already_locked cleanup timed out under registry.lock')
    if (enrollments / f'{old_eid}.json').exists():
        fail('retention under lock did not purge eligible row', result)
    pass_('redeem-path retention already_locked')


def main():
    test_retention_nested_lock()
    test_retention_tombstone_transaction()
    test_enrollment_one_time()
    test_redeem_nested_lock_bounded()
    print()
    print('CORE_CORRECTNESS_P1_TEST=PASS')


if __name__ == '__main__':
    main()
