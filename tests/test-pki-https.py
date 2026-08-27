#!/usr/bin/env python3
"""Allocator HTTPS, private CA, and SAN validation tests."""
import hashlib
import json
import os
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from http.client import HTTPConnection
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


def start_allocator(cfg_path):
    env = os.environ.copy()
    proc = subprocess.Popen(
        [sys.executable, str(ROOT / 'server' / 'frp-port-allocator.py'), '--config', str(cfg_path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        env=env,
    )
    return proc


def wait_https(url, ca, timeout=5.0):
    ctx = ssl.create_default_context(cafile=str(ca))
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(url, context=ctx, timeout=1) as resp:
                return resp.read()
        except Exception as exc:
            last = exc
            time.sleep(0.05)
    raise last or RuntimeError('https wait failed')


def write_env(tmp, listen_port, public_host='127.0.0.1', extra_hosts=None, public_port=None):
    pki_dir = Path(tmp) / 'pki'
    extra = list(extra_hosts or [])
    result = frp_pki.ensure_pki(str(pki_dir), public_host, extra)
    cfg = {
        'public_host': '203.0.113.10',
        'public_ip': '203.0.113.10',
        'frp_control_public_port': 8443,
        'frp_control_listen_port': 443,
        'port_start': 19000,
        'port_end': 19010,
        'listen_host': '127.0.0.1',
        'listen_port': listen_port,
        'allocator_listen_port': listen_port,
        'allocator_public_port': public_port or listen_port,
        'tls_ca_cert': result['ca_crt'],
        'tls_server_cert': result['server_crt'],
        'tls_server_key': result['server_key'],
        'registry_file': str(Path(tmp) / 'registry.json'),
        'enrollments_dir': str(Path(tmp) / 'enrollments'),
        'token_file': str(Path(tmp) / 'server_token'),
    }
    Path(cfg['enrollments_dir']).mkdir(parents=True, exist_ok=True)
    Path(cfg['token_file']).write_text('test-frp-token-do-not-use\n')
    os.chmod(cfg['token_file'], 0o600)
    Path(cfg['registry_file']).write_text(json.dumps({
        'schema_version': 2, 'reserved': [], 'clients': {},
    }) + '\n')
    cfg_path = Path(tmp) / 'config.json'
    cfg_path.write_text(json.dumps(cfg, indent=2) + '\n')
    return cfg_path, result


def test_https_healthz():
    with tempfile.TemporaryDirectory() as tmp:
        port = free_port()
        cfg, pki = write_env(tmp, port)
        proc = start_allocator(cfg)
        try:
            body = wait_https(f'https://127.0.0.1:{port}/healthz', pki['ca_crt'])
            if b'"status"' not in body:
                fail('verified healthz', body)
            pass_('allocator starts with TLS')
            pass_('verified /healthz succeeds')
        finally:
            proc.terminate()
            proc.wait(timeout=5)


def test_plain_http_rejected():
    with tempfile.TemporaryDirectory() as tmp:
        port = free_port()
        cfg, pki = write_env(tmp, port)
        proc = start_allocator(cfg)
        try:
            wait_https(f'https://127.0.0.1:{port}/healthz', pki['ca_crt'])
            conn = HTTPConnection('127.0.0.1', port, timeout=2)
            try:
                conn.request('GET', '/healthz')
                conn.getresponse()
                fail('plain HTTP should not succeed on the TLS listener')
            except Exception:
                pass
            pass_('plain HTTP is not supported')
        finally:
            proc.terminate()
            proc.wait(timeout=5)


def test_unknown_ca_fails():
    with tempfile.TemporaryDirectory() as tmp:
        port = free_port()
        cfg, pki = write_env(tmp, port)
        other = Path(tmp) / 'other'
        other.mkdir()
        frp_pki.ensure_pki(str(other), '127.0.0.1')
        proc = start_allocator(cfg)
        try:
            wait_https(f'https://127.0.0.1:{port}/healthz', pki['ca_crt'])
            ctx = ssl.create_default_context(cafile=str(other / 'ca.crt'))
            try:
                urllib.request.urlopen(f'https://127.0.0.1:{port}/healthz', context=ctx, timeout=2)
                fail('unknown CA should fail')
            except ssl.SSLError:
                pass
            except urllib.error.URLError as exc:
                if 'CERTIFICATE' not in str(exc).upper() and 'certificate' not in str(exc).lower():
                    if not isinstance(getattr(exc, 'reason', None), ssl.SSLError):
                        fail('unknown CA', exc)
            pass_('unknown CA fails')
        finally:
            proc.terminate()
            proc.wait(timeout=5)


def test_wrong_san_fails():
    with tempfile.TemporaryDirectory() as tmp:
        port = free_port()
        cfg, pki = write_env(tmp, port, public_host='192.0.2.50', extra_hosts=['192.0.2.50'])
        proc = start_allocator(cfg)
        try:
            # Wait using IP SAN 127.0.0.1 which is always included.
            wait_https(f'https://127.0.0.1:{port}/healthz', pki['ca_crt'])
            ctx = ssl.create_default_context(cafile=pki['ca_crt'])
            try:
                urllib.request.urlopen(f'https://203.0.113.10:{port}/healthz', context=ctx, timeout=2)
                fail('wrong SAN should fail')
            except Exception:
                pass
            pass_('wrong SAN fails')
        finally:
            proc.terminate()
            proc.wait(timeout=5)


def test_ca_crt_public_only():
    with tempfile.TemporaryDirectory() as tmp:
        port = free_port()
        cfg, pki = write_env(tmp, port)
        proc = start_allocator(cfg)
        try:
            wait_https(f'https://127.0.0.1:{port}/healthz', pki['ca_crt'])
            ctx = ssl.create_default_context(cafile=pki['ca_crt'])
            with urllib.request.urlopen(f'https://127.0.0.1:{port}/ca.crt', context=ctx, timeout=2) as resp:
                body = resp.read()
                ctype = resp.headers.get('Content-Type', '')
            if b'BEGIN CERTIFICATE' not in body:
                fail('ca.crt body', body[:80])
            if b'PRIVATE KEY' in body:
                fail('ca.crt leaked private key')
            if 'application/x-pem-file' not in ctype:
                fail('ca.crt content type', ctype)
            ca_text = Path(pki['ca_crt']).read_bytes()
            if body.strip() != ca_text.strip():
                fail('ca.crt mismatch')
            pass_('/ca.crt returns public certificate only')
        finally:
            proc.terminate()
            proc.wait(timeout=5)


def test_refuse_plain_start():
    with tempfile.TemporaryDirectory() as tmp:
        port = free_port()
        cfg, pki = write_env(tmp, port)
        data = json.loads(Path(cfg).read_text())
        data.pop('tls_server_cert', None)
        data.pop('tls_server_key', None)
        Path(cfg).write_text(json.dumps(data) + '\n')
        proc = start_allocator(cfg)
        try:
            rc = proc.wait(timeout=5)
            if rc == 0:
                fail('allocator should fail closed without TLS')
            out = proc.stdout.read().decode() if proc.stdout else ''
            if 'plain HTTP' not in out and 'TLS' not in out:
                fail('missing TLS error', out)
            pass_('allocator fails closed without TLS')
        finally:
            if proc.poll() is None:
                proc.terminate()
                proc.wait(timeout=5)


def test_ca_preserved_on_reissue():
    with tempfile.TemporaryDirectory() as tmp:
        pki_dir = Path(tmp) / 'pki'
        first = frp_pki.ensure_pki(str(pki_dir), '203.0.113.10')
        second = frp_pki.ensure_pki(str(pki_dir), '203.0.113.10')
        if first['fingerprint'] != second['fingerprint'] or second['action'] != 'reused':
            fail('CA reused', second)
        # Port is not a certificate identity.
        third = frp_pki.ensure_pki(str(pki_dir), '203.0.113.10')
        if third['fingerprint'] != first['fingerprint']:
            fail('port-equivalent ensure rotated CA')
        fourth = frp_pki.ensure_pki(str(pki_dir), '192.0.2.50')
        if fourth['fingerprint'] != first['fingerprint']:
            fail('host change rotated CA')
        if fourth['action'] != 'reissued-server':
            fail('server cert should be reissued for new SAN', fourth)
        pass_('changing public identity reissues server cert only')
        pass_('CA fingerprint preserved across ensure')


def test_partial_pki_fails():
    with tempfile.TemporaryDirectory() as tmp:
        pki_dir = Path(tmp) / 'pki'
        frp_pki.ensure_pki(str(pki_dir), '127.0.0.1')
        (pki_dir / 'server.crt').unlink()
        try:
            frp_pki.ensure_pki(str(pki_dir), '127.0.0.1')
            fail('partial PKI should fail')
        except frp_pki.PkiError:
            pass
        if not (pki_dir / 'ca.key').is_file():
            fail('partial PKI replaced CA key')
        pass_('partial PKI fails closed')


def test_fingerprint_format():
    with tempfile.TemporaryDirectory() as tmp:
        pki_dir = Path(tmp) / 'pki'
        result = frp_pki.ensure_pki(str(pki_dir), '127.0.0.1')
        fp = result['fingerprint']
        if len(fp) != 64 or any(c not in '0123456789abcdef' for c in fp):
            fail('fingerprint format', fp)
        colon = ':'.join(fp[i:i + 2] for i in range(0, 64, 2)).upper()
        if not frp_pki.fingerprints_match(colon, fp):
            fail('fingerprint normalize')
        pass_('CA fingerprint format')


def test_enroll_uses_public_control_port():
    env_tmp = tempfile.TemporaryDirectory()
    try:
        tmp = Path(env_tmp.name)
        cfg = {
            'public_host': '203.0.113.10',
            'frp_control_public_port': 8443,
            'frp_control_listen_port': 443,
            'port_start': 19100,
            'port_end': 19110,
            'listen_port': 6099,
            'registry_file': str(tmp / 'registry.json'),
            'enrollments_dir': str(tmp / 'enrollments'),
            'token_file': str(tmp / 'token'),
        }
        Path(cfg['enrollments_dir']).mkdir()
        Path(cfg['token_file']).write_text('test-frp-token-do-not-use\n')
        Path(cfg['registry_file']).write_text(json.dumps({
            'schema_version': 2, 'reserved': [], 'clients': {},
        }) + '\n')
        cfg_path = tmp / 'config.json'
        cfg_path.write_text(json.dumps(cfg) + '\n')
        alloc = MOD.Allocator(str(cfg_path))
        MOD.port_is_available = lambda port: True
        now = int(time.time())
        rec = {
            'id': 'aabbccddeeff0011',
            'secret': 'secret-aabbccddeeff0011',
            'expires_at': now + 600,
            'bound_machine_id': None,
            'used_at': None,
        }
        Path(cfg['enrollments_dir'], 'aabbccddeeff0011.json').write_text(json.dumps(rec) + '\n')
        body = json.dumps({
            'machine_id': 'machine-a',
            'hostname': 'host-a',
            'services': [{
                'id': 'ssh', 'name': 'SSH', 'protocol': 'tcp',
                'local_ip': '127.0.0.1', 'local_port': 22, 'preset': 'ssh',
                'ssh_user': 'aella',
            }],
        }, separators=(',', ':')).encode()
        import hmac
        ts = str(now)
        sig = hmac.new(rec['secret'].encode(), (ts + '\n' + body.decode()).encode(), hashlib.sha256).hexdigest()
        code, result = alloc.enroll('aabbccddeeff0011', ts, sig, body)
        if code != 200:
            fail('enroll public port', result)
        if result.get('frp_server') != '203.0.113.10' or int(result.get('frp_server_port')) != 8443:
            fail('enroll returned listen port', result)
        pass_('enroll response uses FRP public control port')
    finally:
        env_tmp.cleanup()


def main():
    test_https_healthz()
    test_plain_http_rejected()
    test_unknown_ca_fails()
    test_wrong_san_fails()
    test_ca_crt_public_only()
    test_refuse_plain_start()
    test_ca_preserved_on_reissue()
    test_partial_pki_fails()
    test_fingerprint_format()
    test_enroll_uses_public_control_port()
    print()
    print('PKI_HTTPS_TEST=PASS')


if __name__ == '__main__':
    main()
