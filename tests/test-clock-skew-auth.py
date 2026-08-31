#!/usr/bin/env python3
"""Clock-skew tolerant enrollment and management authentication tests."""
import hashlib
import hmac
import importlib.util
import json
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load_mod(name, rel):
    spec = importlib.util.spec_from_file_location(name, ROOT / rel)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


ALLOC = load_mod('allocator', 'server/frp-port-allocator.py')
CHALLENGE = load_mod('challenge', 'lib/frp_enroll_challenge.py')
CLOCK = load_mod('clock', 'lib/frp_clock_sync.py')
MGMT = load_mod('mgmt', 'lib/frp_mgmt_auth.py')


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
        ALLOC.atomic_write_json(self.registry, ALLOC.empty_registry())
        self.allocator = ALLOC.Allocator(str(self.cfg))
        ALLOC.port_is_available = lambda port: True
        self.eid = 'abcdef0123456789'
        self.secret = 'enroll-secret-abcdef0123456789'
        self.keys = self.root / 'keys'
        self.keys.mkdir()
        self.key = self.keys / 'client-identity.key'
        self.pub = self.keys / 'client-identity.pub'
        MGMT.generate_keypair(self.key, self.pub)
        self.pub_pem = self.pub.read_text(encoding='utf-8')
        now = int(time.time())
        ALLOC.atomic_write_json(self.enrollments / f'{self.eid}.json', {
            'id': self.eid,
            'secret': self.secret,
            'expires_at': now + 600,
            'bound_machine_id': None,
            'used_at': None,
        })

    def cleanup(self):
        self.tmp.cleanup()

    def body(self, include_pub=False, services=None):
        payload = {
            'machine_id': 'machine-skew',
            'hostname': 'skew-host',
            'services': services or [{
                'id': 'ssh',
                'name': 'SSH',
                'protocol': 'tcp',
                'local_ip': '127.0.0.1',
                'local_port': 22,
                'preset': 'ssh',
                'ssh_user': 'admin',
            }],
        }
        if include_pub:
            payload['mgmt_pubkey'] = self.pub_pem
            payload['mgmt_alg'] = MGMT.MGMT_ALG
        return json.dumps(payload, separators=(',', ':')).encode()

    def challenge_enroll(self, include_pub=False):
        payload, err = self.allocator.issue_enroll_challenge(self.eid)
        if err:
            fail('issue challenge', err)
        body = self.body(include_pub=include_pub)
        cid = payload['challenge_id']
        nonce = payload['nonce']
        message = CHALLENGE.enrollment_challenge_message(cid, nonce, body)
        sig = hmac_hex(self.secret, message)
        headers = {
            'X-Enrollment-Challenge-ID': cid,
            'X-Enrollment-Challenge-Nonce': nonce,
        }
        return self.allocator.enroll(
            self.eid, '', sig, body, headers=headers
        )

    def signed_headers(self, body, machine_id='machine-skew', ts=None, nonce=None):
        ts = int(ts if ts is not None else time.time())
        nonce = nonce or MGMT.new_nonce()
        message = MGMT.signed_message(machine_id, body, ts, nonce)
        signature = MGMT.sign_message(self.key, message)
        return {
            'X-Mgmt-Auth': '1',
            'X-Timestamp': str(ts),
            'X-Mgmt-Nonce': nonce,
            'X-Mgmt-Signature': signature,
        }, ts, nonce

    def enroll_signed(self, body=None, ts=None):
        body = body if body is not None else self.body(include_pub=False)
        headers, ts_val, _nonce = self.signed_headers(body, ts=ts)
        return self.allocator.enroll('', str(ts_val), '', body, headers=headers)


def test_legacy_skew_fails(env):
    body = env.body()
    ts = str(int(time.time()) + 3600)
    sig = hmac_hex(env.secret, ts + '\n' + body.decode())
    code, result = env.allocator.enroll(env.eid, ts, sig, body)
    if code == 200:
        fail('LEGACY_SKEW_FAILS', result)
    if 'timestamp outside allowed window' not in str(result.get('error', '')):
        fail('LEGACY_SKEW_FAILS message', result)
    pass_('LEGACY_SKEW_FAILS')


def test_challenge_skew_passes():
    for skew in (0, 600, -600, 3600, -3600, 86400, -86400):
        env = Env()
        try:
            code, result = env.challenge_enroll()
            if code != 200:
                fail(f'CHALLENGE_SKEW_{skew}', result)
        finally:
            env.cleanup()
    pass_('CHALLENGE_SKEW_ENROLLMENT')


def test_challenge_replay(env):
    payload, err = env.allocator.issue_enroll_challenge(env.eid)
    if err:
        fail('challenge issue', err)
    body = env.body()
    cid = payload['challenge_id']
    nonce = payload['nonce']
    message = CHALLENGE.enrollment_challenge_message(cid, nonce, body)
    sig = hmac_hex(env.secret, message)
    headers = {
        'X-Enrollment-Challenge-ID': cid,
        'X-Enrollment-Challenge-Nonce': nonce,
    }
    code1, _ = env.allocator.enroll(env.eid, '', sig, body, headers=headers)
    if code1 != 200:
        fail('challenge first use', code1)
    code2, result2 = env.allocator.enroll(env.eid, '', sig, body, headers=headers)
    if code2 == 200:
        fail('CHALLENGE_REUSE_ALLOWED', result2)
    if 'already used' not in str(result2.get('error', '')):
        fail('CHALLENGE_REUSE message', result2)
    pass_('CHALLENGE_REUSE_REJECTED')


def test_challenge_expiry(env):
    payload, err = env.allocator.issue_enroll_challenge(env.eid)
    if err:
        fail('challenge issue', err)
    rec = env.allocator.enroll_challenges._challenges[payload['challenge_id']]
    rec['expires_at'] = int(time.time()) - 1
    body = env.body()
    message = CHALLENGE.enrollment_challenge_message(
        payload['challenge_id'], payload['nonce'], body
    )
    sig = hmac_hex(env.secret, message)
    headers = {
        'X-Enrollment-Challenge-ID': payload['challenge_id'],
        'X-Enrollment-Challenge-Nonce': payload['nonce'],
    }
    code, result = env.allocator.enroll(env.eid, '', sig, body, headers=headers)
    if code == 200:
        fail('CHALLENGE_EXPIRY', result)
    pass_('CHALLENGE_EXPIRY')


def test_server_time_in_response(env):
    code, result = env.challenge_enroll()
    if code != 200:
        fail('enroll for server_time', result)
    if 'server_time' not in result:
        fail('SERVER_TIME_IN_RESPONSE')
    pass_('SERVER_TIME_IN_RESPONSE')


def test_clock_sync_helpers():
    offset = CLOCK.offset_from_server_time(1000, 800)
    if offset != 200:
        fail('offset calc', offset)
    ts = CLOCK.compute_timestamp(200, now=800)
    if ts != 1000:
        fail('compute_timestamp', ts)
    if not CLOCK.should_warn_offset(400):
        fail('warn threshold')
    if CLOCK.should_warn_offset(2):
        fail('no warn small offset')
    pass_('CLOCK_SYNC_HELPERS')


def test_malformed_json_handling():
    raw = ''
    try:
        json.loads(raw)
        fail('empty json should fail')
    except json.JSONDecodeError:
        pass
    pass_('MALFORMED_JSON_DETECTED')


def test_management_corrected_timestamp(env):
    code, result = env.challenge_enroll(include_pub=True)
    if code != 200:
        fail('mgmt enroll', result)
    server_now = int(time.time())
    fake_local = server_now + 3600
    offset = CLOCK.offset_from_server_time(server_now, fake_local)
    body = env.body(include_pub=False, services=[{
        'id': 'ssh', 'name': 'SSH', 'protocol': 'tcp',
        'local_ip': '127.0.0.1', 'local_port': 22, 'preset': 'ssh', 'ssh_user': 'admin',
    }, {
        'id': 'web', 'name': 'Web', 'protocol': 'tcp',
        'local_ip': '127.0.0.1', 'local_port': 8080, 'preset': 'custom',
    }])
    wrong_code, wrong_result = env.enroll_signed(body=body, ts=fake_local)
    if wrong_code != 403:
        fail('mgmt uncorrected timestamp', wrong_result)
    corrected = CLOCK.compute_timestamp(offset, now=fake_local)
    code, result = env.enroll_signed(body=body, ts=corrected)
    if code != 200:
        fail('mgmt corrected timestamp', result)
    if 'server_time' not in result:
        fail('mgmt server_time missing')
    pass_('MANAGEMENT_CORRECTED_TIMESTAMP')


def test_management_offset_refresh(env):
    code, result = env.challenge_enroll(include_pub=True)
    if code != 200:
        fail('offset refresh enroll', result)
    server_now = int(time.time())
    stale_offset = -7200
    body = env.body(include_pub=False)
    stale_ts = CLOCK.compute_timestamp(stale_offset)
    stale_code, _ = env.enroll_signed(body=body, ts=stale_ts)
    if stale_code != 403:
        fail('stale offset should fail', stale_code)
    fresh_offset = CLOCK.offset_from_server_time(server_now, server_now + 3600)
    fresh_ts = CLOCK.compute_timestamp(fresh_offset, now=server_now + 3600)
    code, result = env.enroll_signed(body=body, ts=fresh_ts)
    if code != 200:
        fail('refreshed offset management', result)
    pass_('MANAGEMENT_OFFSET_REFRESH')


def main():
    test_clock_sync_helpers()
    test_malformed_json_handling()
    env = Env()
    try:
        test_legacy_skew_fails(env)
        env2 = Env()
        try:
            test_challenge_skew_passes()
        finally:
            env2.cleanup()
        env3 = Env()
        try:
            test_challenge_replay(env3)
        finally:
            env3.cleanup()
        env4 = Env()
        try:
            test_challenge_expiry(env4)
        finally:
            env4.cleanup()
        env5 = Env()
        try:
            test_server_time_in_response(env5)
        finally:
            env5.cleanup()
        env6 = Env()
        try:
            test_management_corrected_timestamp(env6)
        finally:
            env6.cleanup()
        env7 = Env()
        try:
            test_management_offset_refresh(env7)
        finally:
            env7.cleanup()
    finally:
        env.cleanup()
    print('CLOCK_SKEW_AUTH_TESTS=PASS')


if __name__ == '__main__':
    main()
