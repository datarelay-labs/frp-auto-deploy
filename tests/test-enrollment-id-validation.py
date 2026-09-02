#!/usr/bin/env python3
"""Enrollment ID length validation on public allocator endpoints."""
import json
import os
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'lib'))
import frp_pki  # noqa: E402
import importlib.util


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


def free_port():
    sock = socket.socket()
    sock.bind(('127.0.0.1', 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


def wait_https(url, ca, timeout=5.0):
    ctx = ssl.create_default_context(cafile=str(ca))
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(url, context=ctx, timeout=1) as resp:
                return resp.status, resp.read()
        except urllib.error.HTTPError as exc:
            return exc.code, exc.read()
        except Exception as exc:
            last = exc
            time.sleep(0.05)
    raise last or RuntimeError('https wait failed')


def write_env(tmp, listen_port):
    pki_dir = Path(tmp) / 'pki'
    result = frp_pki.ensure_pki(str(pki_dir), '127.0.0.1', [])
    enrollments = Path(tmp) / 'enrollments'
    enrollments.mkdir(parents=True, exist_ok=True)
    token = Path(tmp) / 'server_token'
    token.write_text('test-frp-token-do-not-use\n')
    os.chmod(token, 0o600)
    registry = Path(tmp) / 'registry.json'
    registry.write_text(json.dumps({
        'schema_version': 2, 'reserved': [], 'clients': {},
    }) + '\n')
    cfg = {
        'public_host': '203.0.113.10',
        'public_ip': '203.0.113.10',
        'frp_control_public_port': 8443,
        'frp_control_listen_port': 443,
        'port_start': 19100,
        'port_end': 19110,
        'listen_host': '127.0.0.1',
        'listen_port': listen_port,
        'allocator_listen_port': listen_port,
        'allocator_public_port': listen_port,
        'tls_ca_cert': result['ca_crt'],
        'tls_server_cert': result['server_crt'],
        'tls_server_key': result['server_key'],
        'registry_file': str(registry),
        'enrollments_dir': str(enrollments),
        'token_file': str(token),
    }
    cfg_path = Path(tmp) / 'config.json'
    cfg_path.write_text(json.dumps(cfg, indent=2) + '\n')
    valid_eid = 'abcdef0123456789'
    MOD.atomic_write_json(enrollments / f'{valid_eid}.json', {
        'id': valid_eid,
        'secret': 'secret-abcdef0123456789',
        'expires_at': int(time.time()) + 600,
        'bound_machine_id': None,
        'used_at': None,
    })
    return cfg_path, result, valid_eid, enrollments


def post_challenge(port, ca, enrollment_id):
    url = f'https://127.0.0.1:{port}/enroll/challenge'
    ctx = ssl.create_default_context(cafile=str(ca))
    req = urllib.request.Request(url, method='POST', headers={
        'X-Enrollment-ID': enrollment_id,
    })
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=2) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read()


def post_enroll(port, ca, enrollment_id):
    url = f'https://127.0.0.1:{port}/enroll'
    ctx = ssl.create_default_context(cafile=str(ca))
    body = b'{"machine_id":"machine-eid-test","hostname":"eid-host","services":[]}'
    req = urllib.request.Request(
        url,
        data=body,
        method='POST',
        headers={
            'Content-Type': 'application/json',
            'X-Enrollment-ID': enrollment_id,
            'X-Timestamp': '1',
            'X-Signature': 'deadbeef',
        },
    )
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=2) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read()


def assert_4xx(code, body, label):
    if code < 400 or code >= 500:
        fail(label, f'expected 4xx got {code}: {body!r}')


def test_normalize_enrollment_id():
    cases = {
        '': None,
        'abcdef012345678': None,
        'abcdef0123456789': 'abcdef0123456789',
        'abcdef01234567890': None,
        'abcdef012345678g': None,
        'a' * 300: None,
        'b' * 10000: None,
    }
    for raw, expected in cases.items():
        got = MOD.normalize_enrollment_id(raw)
        if got != expected:
            fail('normalize_enrollment_id', f'{raw!r} -> {got!r} expected {expected!r}')
    pass_('NORMALIZE_ENROLLMENT_ID')


def test_public_endpoints():
    with tempfile.TemporaryDirectory() as tmp:
        port = free_port()
        cfg_path, pki, valid_eid, enrollments = write_env(tmp, port)
        proc = subprocess.Popen(
            [sys.executable, str(ROOT / 'server' / 'frp-port-allocator.py'),
             '--config', str(cfg_path)],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        try:
            wait_https(f'https://127.0.0.1:{port}/healthz', pki['ca_crt'])
            before = set(enrollments.glob('*.json'))

            bad_ids = [
                ('', 'empty'),
                ('abcdef012345678', '15 hex'),
                ('abcdef01234567890', '17 hex'),
                ('abcdef012345678g', 'non-hex'),
                ('a' * 300, '300 hex'),
                ('f' * 10000, 'very large hex'),
            ]
            for eid, label in bad_ids:
                code, body = post_challenge(port, pki['ca_crt'], eid)
                assert_4xx(code, body, f'challenge {label}')
                code, body = post_enroll(port, pki['ca_crt'], eid)
                assert_4xx(code, body, f'enroll {label}')

            code, body = post_challenge(port, pki['ca_crt'], valid_eid)
            if code != 200:
                fail('valid challenge', f'{code} {body!r}')
            after_bad = set(enrollments.glob('*.json'))
            if after_bad != before:
                fail('malformed ids mutated enrollment files')

            code, _ = wait_https(f'https://127.0.0.1:{port}/healthz', pki['ca_crt'])
            if code != 200:
                fail('healthz after malformed ids', code)
            pass_('MALFORMED_ENROLLMENT_IDS_REJECTED')
            pass_('ENROLLMENT_STATE_UNCHANGED')
            pass_('HEALTHZ_AFTER_MALFORMED_IDS')
        finally:
            proc.terminate()
            proc.wait(timeout=5)


def main():
    test_normalize_enrollment_id()
    test_public_endpoints()
    print()
    print('ENROLLMENT_ID_VALIDATION_TEST=PASS')


if __name__ == '__main__':
    main()
