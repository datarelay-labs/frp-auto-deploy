#!/usr/bin/env python3
"""Enrollment security regression for generic multi-service requests."""
import hashlib
import hmac
import json
import sys
import tempfile
import time
import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load_mod():
    spec = importlib.util.spec_from_file_location(
        'frp_port_allocator', ROOT / 'server' / 'frp-port-allocator.py'
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


MOD = load_mod()


def pass_(name):
    print(f'PASS {name}')


def fail(name, detail=''):
    print(f'FAIL {name} {detail}'.rstrip(), file=sys.stderr)
    raise SystemExit(1)


def hmac_hex(secret, message):
    return hmac.new(secret.encode(), message.encode(), hashlib.sha256).hexdigest()


class Env:
    def __init__(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.registry = self.root / 'registry.json'
        self.token = self.root / 'server_token'
        self.enrollments = self.root / 'enrollments'
        self.enrollments.mkdir()
        self.token.write_text('test-enroll-token-do-not-use\n')
        self.token.chmod(0o600)
        self.cfg = self.root / 'config.json'
        self.cfg.write_text(json.dumps({
            'public_ip': '203.0.113.10',
            'control_port': 443,
            'port_start': 18200,
            'port_end': 18210,
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

    def cleanup(self):
        self.tmp.cleanup()

    def body(self, machine_id='machine-sec', extra=None):
        payload = {
            'machine_id': machine_id,
            'hostname': 'sec-host',
            'services': [{
                'id': 'grafana',
                'name': 'Grafana',
                'protocol': 'tcp',
                'local_ip': '127.0.0.1',
                'local_port': 3000,
                'preset': 'custom',
            }],
        }
        if extra:
            payload.update(extra)
        return json.dumps(payload, separators=(',', ':')).encode()

    def enroll(self, body=None, signature=None, timestamp=None, enrollment_id=None):
        body = body if body is not None else self.body()
        ts = str(timestamp if timestamp is not None else int(time.time()))
        if signature is None:
            signature = hmac_hex(self.secret, ts + '\n' + body.decode())
        return self.allocator.enroll(enrollment_id or self.eid, ts, signature, body)


def main():
    env = Env()
    try:
        code, result = env.enroll(signature='deadbeef')
        if code != 403 or 'invalid signature' not in result.get('error', ''):
            fail('bad HMAC', result)
        pass_('bad HMAC rejected')

        code, result = env.enroll(timestamp=int(time.time()) - 10_000)
        if code != 403:
            fail('expired/skew', result)
        pass_('expired enrollment rejected')

        expired_id = 'fedcba9876543210'
        MOD.atomic_write_json(env.enrollments / f'{expired_id}.json', {
            'id': expired_id,
            'secret': env.secret,
            'expires_at': int(time.time()) - 30,
            'bound_machine_id': None,
        })
        body = env.body()
        ts = str(int(time.time()))
        sig = hmac_hex(env.secret, ts + '\n' + body.decode())
        code, result = env.allocator.enroll(expired_id, ts, sig, body)
        if code != 403 or 'expired' not in result.get('error', ''):
            fail('expired code', result)
        pass_('expired enrollment code rejected')

        code, result = env.enroll()
        if code != 200:
            fail('first enroll', result)
        if 'response_hmac' not in result:
            fail('response HMAC missing')
        received = result.pop('response_hmac')
        expected = hmac_hex(env.secret, MOD.canonical_json(result))
        if not hmac.compare_digest(received, expected):
            fail('response HMAC mismatch')
        result['response_hmac'] = received
        pass_('response HMAC present')

        if 'token_ciphertext' not in result or not result['token_ciphertext']:
            fail('token missing')
        if 'test-enroll-token-do-not-use' in json.dumps(result):
            fail('token plaintext exposed')
        pass_('token encrypted')
        pass_('token plaintext not exposed')

        body2 = env.body(machine_id='machine-other')
        ts = str(int(time.time()))
        sig = hmac_hex(env.secret, ts + '\n' + body2.decode())
        code, result = env.allocator.enroll(env.eid, ts, sig, body2)
        if code != 403 or 'already bound' not in result.get('error', ''):
            fail('machine-id reuse', result)
        pass_('wrong machine-id reuse rejected')
    finally:
        env.cleanup()

    print()
    print('ENROLLMENT_SECURITY_TEST=PASS')


if __name__ == '__main__':
    main()
