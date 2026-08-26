#!/usr/bin/env python3
import argparse
import hashlib
import hmac
import json
import os
import socket
import subprocess
import tempfile
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

LOCK = threading.Lock()
MAX_CLOCK_SKEW = 300


def utc_now_iso():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace('+00:00', 'Z')


def load_json(path, default=None):
    p = Path(path)
    if not p.exists():
        if default is None:
            raise FileNotFoundError(path)
        return default
    with p.open('r', encoding='utf-8') as f:
        return json.load(f)


def atomic_write_json(path, data, mode=0o600):
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=p.name + '.', suffix='.tmp', dir=str(p.parent))
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            json.dump(data, f, indent=2, sort_keys=True)
            f.write('\n')
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, p)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def read_text(path):
    return Path(path).read_text(encoding='utf-8').strip()


def canonical_json(data):
    return json.dumps(data, sort_keys=True, separators=(',', ':'), ensure_ascii=False)


def hmac_hex(secret, message):
    return hmac.new(secret.encode(), message.encode(), hashlib.sha256).hexdigest()


def port_is_available(port):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(('0.0.0.0', int(port)))
        return True
    except OSError:
        return False
    finally:
        s.close()


def encrypt_token(token, secret):
    env = os.environ.copy()
    env['FRP_ENROLL_SECRET'] = secret
    proc = subprocess.run(
        [
            'openssl', 'enc', '-aes-256-cbc', '-pbkdf2', '-iter', '200000',
            '-md', 'sha256', '-salt', '-a', '-A', '-pass', 'env:FRP_ENROLL_SECRET'
        ],
        input=token.encode(),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
        check=True,
    )
    return proc.stdout.decode().strip()


class Allocator:
    def __init__(self, config_path):
        self.config_path = config_path
        self.cfg = load_json(config_path)
        self.registry_file = self.cfg['registry_file']
        self.enrollments_dir = Path(self.cfg['enrollments_dir'])
        self.enrollments_dir.mkdir(parents=True, exist_ok=True)
        self.token_file = self.cfg['token_file']

    def load_registry(self):
        return load_json(self.registry_file, {'reserved': [], 'clients': {}})

    def save_registry(self, state):
        atomic_write_json(self.registry_file, state)

    def used_ports(self, state):
        used = {int(x) for x in state.get('reserved', [])}
        for client in state.get('clients', {}).values():
            for key in ('ssh_port', 'https_port'):
                value = client.get(key)
                if value:
                    used.add(int(value))
        return used

    def next_port(self, state):
        used = self.used_ports(state)
        for port in range(int(self.cfg['port_start']), int(self.cfg['port_end']) + 1):
            if port in used:
                continue
            if not port_is_available(port):
                continue
            return port
        raise RuntimeError('No available FRP service ports')

    def enrollment_path(self, enrollment_id):
        if not enrollment_id or any(c not in '0123456789abcdef' for c in enrollment_id.lower()):
            return None
        return self.enrollments_dir / f'{enrollment_id.lower()}.json'

    def load_enrollment(self, enrollment_id):
        path = self.enrollment_path(enrollment_id)
        if path is None or not path.exists():
            return None, path
        return load_json(path), path

    def save_enrollment(self, path, record):
        atomic_write_json(path, record)

    def cleanup_expired_enrollments(self):
        now = int(time.time())
        for path in self.enrollments_dir.glob('*.json'):
            try:
                record = load_json(path)
                if int(record.get('expires_at', 0)) < now - 86400:
                    path.unlink(missing_ok=True)
            except Exception:
                continue

    def verify_request(self, enrollment_id, timestamp, signature, body):
        record, path = self.load_enrollment(enrollment_id)
        if not record:
            return None, None, 'unknown enrollment id'

        now = int(time.time())
        try:
            ts = int(timestamp)
        except Exception:
            return None, None, 'invalid timestamp'

        if abs(now - ts) > MAX_CLOCK_SKEW:
            return None, None, 'request timestamp outside allowed window'
        if now > int(record.get('expires_at', 0)):
            return None, None, 'enrollment code expired'

        secret = record.get('secret', '')
        expected = hmac_hex(secret, timestamp + '\n' + body.decode())
        if not hmac.compare_digest(expected, signature or ''):
            return None, None, 'invalid signature'
        return record, path, None

    def enroll(self, enrollment_id, timestamp, signature, body):
        record, enroll_path, error = self.verify_request(enrollment_id, timestamp, signature, body)
        if error:
            return 403, {'error': error}

        payload = json.loads(body.decode())
        machine_id = str(payload.get('machine_id', '')).strip()
        hostname = str(payload.get('hostname', '')).strip()
        ssh_user = str(payload.get('ssh_user', '')).strip() or 'root'
        want_https = bool(payload.get('want_https'))
        https_ip = str(payload.get('https_ip', '')).strip() if want_https else ''
        if not machine_id:
            return 400, {'error': 'machine_id is required'}

        bound_machine_id = record.get('bound_machine_id')
        if bound_machine_id and bound_machine_id != machine_id:
            return 403, {'error': 'enrollment code is already bound to another machine'}

        with LOCK:
            state = self.load_registry()
            clients = state.setdefault('clients', {})
            client = clients.get(machine_id)
            now_iso = utc_now_iso()

            if client is None:
                client = {
                    'hostname': hostname,
                    'ssh_user': ssh_user,
                    'ssh_port': self.next_port(state),
                    'https_port': None,
                    'https_enabled': False,
                    'https_ip': '',
                    'created_at': now_iso,
                    'last_enrolled_at': now_iso,
                }
                clients[machine_id] = client
            else:
                client['hostname'] = hostname or client.get('hostname', '')
                client['ssh_user'] = ssh_user or client.get('ssh_user', 'root')
                client['last_enrolled_at'] = now_iso

            if want_https:
                if not client.get('https_port'):
                    client['https_port'] = self.next_port(state)
                client['https_enabled'] = True
                client['https_ip'] = https_ip
            else:
                client['https_enabled'] = False
                client['https_ip'] = ''

            self.save_registry(state)

            record['bound_machine_id'] = machine_id
            record['used_at'] = record.get('used_at') or now_iso
            record['last_used_at'] = now_iso
            self.save_enrollment(enroll_path, record)

        secret = record['secret']
        token_ciphertext = encrypt_token(read_text(self.token_file), secret)
        response_payload = {
            'frp_server': self.cfg['public_ip'],
            'frp_server_port': int(self.cfg['control_port']),
            'ssh_port': int(client['ssh_port']),
            'https_port': int(client['https_port']) if want_https and client.get('https_port') else None,
            'token_ciphertext': token_ciphertext,
        }
        response_payload['response_hmac'] = hmac_hex(secret, canonical_json(response_payload))
        return 200, response_payload


def make_handler(allocator):
    class Handler(BaseHTTPRequestHandler):
        server_version = 'frp-auto-deploy/1.0'

        def log_message(self, fmt, *args):
            print('%s - %s' % (self.address_string(), fmt % args), flush=True)

        def send_json(self, code, data):
            body = json.dumps(data).encode()
            self.send_response(code)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path == '/healthz':
                self.send_json(200, {'status': 'ok'})
            else:
                self.send_json(404, {'error': 'not found'})

        def do_POST(self):
            if self.path != '/enroll':
                self.send_json(404, {'error': 'not found'})
                return
            try:
                length = int(self.headers.get('Content-Length', '0'))
                if length <= 0 or length > 65536:
                    self.send_json(400, {'error': 'invalid request body length'})
                    return
                body = self.rfile.read(length)
                code, result = allocator.enroll(
                    self.headers.get('X-Enrollment-ID', ''),
                    self.headers.get('X-Timestamp', ''),
                    self.headers.get('X-Signature', ''),
                    body,
                )
                self.send_json(code, result)
            except json.JSONDecodeError:
                self.send_json(400, {'error': 'invalid JSON'})
            except Exception as exc:
                self.send_json(500, {'error': str(exc)})

    return Handler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--config', required=True)
    args = parser.parse_args()

    allocator = Allocator(args.config)
    allocator.cleanup_expired_enrollments()
    host = allocator.cfg.get('listen_host', '0.0.0.0')
    port = int(allocator.cfg['listen_port'])
    server = ThreadingHTTPServer((host, port), make_handler(allocator))
    print(f'FRP allocator listening on http://{host}:{port}', flush=True)
    server.serve_forever()


if __name__ == '__main__':
    main()
