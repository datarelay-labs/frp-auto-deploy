#!/usr/bin/env python3
import sys
if sys.version_info < (3, 7):
    sys.stderr.write('ERROR: python 3.7 or newer is required\n')
    raise SystemExit(1)
import argparse
import hashlib
import hmac
import importlib.util
import ipaddress
import json
import os
import re
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
MGMT_NONCE_TTL = 900
MAX_NONCES_PER_CLIENT = 256
REGISTRY_SCHEMA_VERSION = 2
SERVICE_ID_RE = re.compile(r'^[a-z0-9][a-z0-9._-]{0,31}$')
MAX_SERVICES = 32
MAX_NAME_LEN = 64
MAX_HOST_LEN = 253
ALLOWED_PRESETS = ('ssh', 'http', 'https', 'custom')
ALLOWED_PROTOCOLS = ('tcp',)
NONCE_RE = re.compile(r'^[0-9a-f]{64}$')


def _load_mgmt_auth():
    candidates = [
        Path(__file__).resolve().parent / 'frp_mgmt_auth.py',
        Path(__file__).resolve().parent.parent / 'lib' / 'frp_mgmt_auth.py',
    ]
    for path in candidates:
        if path.is_file():
            spec = importlib.util.spec_from_file_location('frp_mgmt_auth', path)
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            return mod
    raise RuntimeError('missing frp_mgmt_auth.py')


MGMT = _load_mgmt_auth()


def unsupported_registry_message(state=None):
    version = None
    if isinstance(state, dict) and 'schema_version' in state:
        version = state.get('schema_version')
    shown = 1 if version is None else version
    return (
        f'unsupported registry schema version {shown}. '
        'This release requires registry schema version 2. '
        'Back up the existing registry and redeploy/reset it explicitly before continuing.'
    )


class RegistrySchemaError(ValueError):
    pass


class ServiceValidationError(ValueError):
    pass


def utc_now_iso():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace('+00:00', 'Z')


def empty_registry():
    return {
        'schema_version': REGISTRY_SCHEMA_VERSION,
        'reserved': [],
        'clients': {},
    }


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
    return MGMT.encrypt_token_pbkdf2(token, secret)


def coerce_port(value):
    if value is None or isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value if 1 <= value <= 65535 else None
    text = str(value).strip()
    if not text or not re.fullmatch(r'[0-9]+', text):
        return None
    port = int(text)
    if 1 <= port <= 65535:
        return port
    return None


def require_registry_v2(state):
    if not isinstance(state, dict):
        raise RegistrySchemaError(unsupported_registry_message(state))
    version = state.get('schema_version')
    if version != REGISTRY_SCHEMA_VERSION:
        raise RegistrySchemaError(unsupported_registry_message(state))
    clients = state.get('clients', {})
    if clients is None:
        clients = {}
    if not isinstance(clients, dict):
        raise RegistrySchemaError(unsupported_registry_message(state))
    for client in clients.values():
        if not isinstance(client, dict):
            raise RegistrySchemaError(unsupported_registry_message(state))
        if 'ssh_port' in client or 'https_port' in client:
            raise RegistrySchemaError(
                'unsupported registry schema version 2. '
                'Legacy SSH/HTTPS fields are present. '
                'Back up the existing registry and redeploy/reset it explicitly before continuing.'
            )
        services = client.get('services', {})
        if services is None:
            services = {}
        if not isinstance(services, dict):
            raise RegistrySchemaError(unsupported_registry_message(state))
    reserved = state.get('reserved', [])
    if reserved is None:
        reserved = []
    if not isinstance(reserved, list):
        raise RegistrySchemaError(unsupported_registry_message(state))
    return state


def used_ports_from_state(state):
    used = set()
    for item in state.get('reserved') or []:
        port = coerce_port(item)
        if port is not None:
            used.add(port)
    for client in (state.get('clients') or {}).values():
        if not isinstance(client, dict):
            continue
        services = client.get('services') or {}
        if not isinstance(services, dict):
            continue
        for svc in services.values():
            if not isinstance(svc, dict):
                continue
            port = coerce_port(svc.get('remote_port'))
            if port is not None:
                used.add(port)
    return used


def valid_local_ip(value):
    text = str(value).strip()
    if not text or len(text) > MAX_HOST_LEN:
        return False
    if any(c in text for c in ' \t\r\n/\\;|&$`\'"<>'):
        return False
    try:
        ipaddress.ip_address(text)
        return True
    except ValueError:
        pass
    if text.lower() == 'localhost':
        return True
    if re.fullmatch(r'[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?', text):
        return True
    return False


def normalize_service(raw):
    if not isinstance(raw, dict):
        raise ServiceValidationError('each service must be an object')

    sid = str(raw.get('id', '')).strip().lower()
    if not sid:
        raise ServiceValidationError('service id is required')
    if not SERVICE_ID_RE.fullmatch(sid):
        raise ServiceValidationError(
            'invalid service id; use [a-z0-9][a-z0-9._-]{0,31}'
        )

    protocol = str(raw.get('protocol', 'tcp') or 'tcp').strip().lower()
    if protocol not in ALLOWED_PROTOCOLS:
        raise ServiceValidationError('only tcp services are supported')

    preset = str(raw.get('preset', 'custom') or 'custom').strip().lower()
    if preset not in ALLOWED_PRESETS:
        raise ServiceValidationError('invalid service preset')

    default_name = {
        'ssh': 'SSH',
        'http': 'HTTP',
        'https': 'HTTPS',
    }.get(preset, sid)
    name = str(raw.get('name', '') or default_name).strip() or default_name
    if len(name) > MAX_NAME_LEN:
        raise ServiceValidationError('service name is too long')
    if any(c in name for c in '\r\n'):
        raise ServiceValidationError('service name contains invalid characters')

    local_ip = str(raw.get('local_ip', '') or '').strip()
    if not local_ip:
        raise ServiceValidationError('local_ip is required')
    if not valid_local_ip(local_ip):
        raise ServiceValidationError('invalid local_ip')

    local_port = coerce_port(raw.get('local_port'))
    if local_port is None:
        raise ServiceValidationError('invalid local_port; must be an integer 1-65535')

    service = {
        'id': sid,
        'name': name,
        'protocol': 'tcp',
        'local_ip': local_ip,
        'local_port': local_port,
        'preset': preset,
    }
    if preset == 'ssh':
        ssh_user = str(raw.get('ssh_user', '') or '').strip() or 'root'
        if not re.fullmatch(r'[A-Za-z0-9._@-]{1,32}', ssh_user):
            raise ServiceValidationError('invalid ssh_user')
        service['ssh_user'] = ssh_user
    return service


def normalize_services(raw_services):
    if raw_services is None:
        raise ServiceValidationError('services is required')
    if not isinstance(raw_services, list):
        raise ServiceValidationError('services must be a list')
    if not raw_services:
        raise ServiceValidationError('at least one service must be configured')
    if len(raw_services) > MAX_SERVICES:
        raise ServiceValidationError('too many services in one enrollment request')

    normalized = []
    seen = set()
    for item in raw_services:
        service = normalize_service(item)
        if service['id'] in seen:
            raise ServiceValidationError(f'duplicate service id: {service["id"]}')
        seen.add(service['id'])
        normalized.append(service)
    return normalized


class Allocator:
    def __init__(self, config_path):
        self.config_path = config_path
        self.cfg = load_json(config_path)
        self.registry_file = self.cfg['registry_file']
        self.enrollments_dir = Path(self.cfg['enrollments_dir'])
        self.enrollments_dir.mkdir(parents=True, exist_ok=True)
        self.token_file = self.cfg['token_file']
        self.nonce_file = Path(self.registry_file).resolve().parent / 'mgmt-nonces.json'

    def load_registry(self):
        if not Path(self.registry_file).exists():
            return empty_registry()
        try:
            state = load_json(self.registry_file)
        except (OSError, json.JSONDecodeError) as exc:
            raise RegistrySchemaError('unable to read an existing FRP registry') from exc
        return require_registry_v2(state)

    def save_registry(self, state):
        state = dict(state)
        state['schema_version'] = REGISTRY_SCHEMA_VERSION
        require_registry_v2(state)
        atomic_write_json(self.registry_file, state)

    def used_ports(self, state):
        return used_ports_from_state(state)

    def protected_ports(self):
        protected = set()
        for key in ('listen_port', 'control_port'):
            port = coerce_port(self.cfg.get(key))
            if port is not None:
                protected.add(port)
        return protected

    def allocate_port(self, used):
        protected = self.protected_ports()
        start = int(self.cfg['port_start'])
        end = int(self.cfg['port_end'])
        for port in range(start, end + 1):
            if port in used or port in protected:
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
        self.expire_nonces(now)

    def load_nonces(self):
        path = self.nonce_file
        if not path.exists():
            return {'schema_version': 1, 'nonces': {}}
        try:
            data = load_json(path)
        except (OSError, json.JSONDecodeError):
            return {'schema_version': 1, 'nonces': {}}
        if not isinstance(data, dict):
            return {'schema_version': 1, 'nonces': {}}
        nonces = data.get('nonces')
        if not isinstance(nonces, dict):
            nonces = {}
        return {'schema_version': 1, 'nonces': nonces}

    def save_nonces(self, data):
        atomic_write_json(self.nonce_file, data)

    def expire_nonces(self, now=None):
        now = int(now if now is not None else time.time())
        data = self.load_nonces()
        nonces = data['nonces']
        changed = False
        for key, exp in list(nonces.items()):
            try:
                expiry = int(exp)
            except (TypeError, ValueError):
                nonces.pop(key, None)
                changed = True
                continue
            if expiry < now:
                nonces.pop(key, None)
                changed = True
        if changed:
            self.save_nonces(data)
        return data

    def consume_nonce(self, machine_id, nonce, now):
        """Replay defense: a captured signed request cannot be reused.

        Nonces are stored as machine_id:nonce -> expiry. Entries expire after
        MGMT_NONCE_TTL seconds (900), which is longer than MAX_CLOCK_SKEW so a
        request stays non-replayable for its entire accepted timestamp window.
        Per-client count is capped; oldest entries are dropped first.
        """
        if not NONCE_RE.fullmatch(nonce or ''):
            return 'invalid nonce'
        data = self.expire_nonces(now)
        nonces = data['nonces']
        key = f'{machine_id}:{nonce}'
        if key in nonces:
            return 'replayed request'
        prefix = machine_id + ':'
        owned = sorted(
            ((k, nonces[k]) for k in list(nonces) if k.startswith(prefix)),
            key=lambda item: item[1],
        )
        while len(owned) >= MAX_NONCES_PER_CLIENT:
            old_key, _exp = owned.pop(0)
            nonces.pop(old_key, None)
        nonces[key] = now + MGMT_NONCE_TTL
        self.save_nonces(data)
        return None

    @staticmethod
    def mgmt_status(client):
        if not isinstance(client, dict):
            return 'legacy'
        status = client.get('mgmt_status')
        if status in ('enrolled', 'legacy', 'revoked'):
            return status
        if client.get('mgmt_pubkey'):
            return 'enrolled'
        return 'legacy'

    def register_mgmt_identity(self, client, payload, enrollment_secret, machine_id):
        raw = payload.get('mgmt_pubkey')
        if raw in (None, ''):
            if not client.get('mgmt_status'):
                client['mgmt_status'] = self.mgmt_status(client)
            return None, None
        try:
            pem = MGMT.canonicalize_pubkey_pem(raw)
            fingerprint = MGMT.pubkey_fingerprint(pem)
        except Exception:
            return None, 'invalid management public key'
        alg = str(payload.get('mgmt_alg') or MGMT.MGMT_ALG).strip().lower()
        if alg != MGMT.MGMT_ALG:
            return None, 'unsupported management signature algorithm'
        mac = MGMT.derive_mac_key(enrollment_secret, machine_id)
        now_iso = utc_now_iso()
        existing_pem = client.get('mgmt_pubkey')
        status = self.mgmt_status(client)
        same = False
        if status == 'enrolled' and existing_pem:
            try:
                same = MGMT.canonicalize_pubkey_pem(existing_pem) == pem
            except Exception:
                same = False
        client['mgmt_pubkey'] = pem
        client['mgmt_alg'] = MGMT.MGMT_ALG
        client['mgmt_fingerprint'] = fingerprint
        client['mgmt_status'] = 'enrolled'
        client['mgmt_mac_key'] = mac
        if not same:
            client['mgmt_enrolled_at'] = now_iso
        client['mgmt_revoked_at'] = None
        return mac, None

    def verify_mgmt_against_client(self, client, machine_id, headers, body):
        try:
            ts = int(str(headers.get('X-Timestamp') or headers.get('X-Mgmt-Timestamp') or ''))
        except Exception:
            return 'invalid timestamp', None
        nonce = str(headers.get('X-Mgmt-Nonce') or '').strip().lower()
        signature = str(headers.get('X-Mgmt-Signature') or '').strip()
        if not signature:
            return 'missing signature', None
        now = int(time.time())
        if abs(now - ts) > MAX_CLOCK_SKEW:
            return 'request timestamp outside allowed window', None
        if not isinstance(client, dict):
            return 'unknown client identity', None
        status = self.mgmt_status(client)
        if status == 'revoked':
            return (
                "this client's management identity has been revoked. "
                'Run the server enrollment command to create a new Enrollment Code, '
                'then re-enroll this client.'
            ), None
        if status != 'enrolled' or not client.get('mgmt_pubkey'):
            return 'this client does not have a management identity', None
        message = MGMT.signed_message(machine_id, body, ts, nonce)
        try:
            ok = MGMT.verify_signature(client['mgmt_pubkey'], message, signature)
        except ValueError as exc:
            return str(exc), None
        if not ok:
            return 'invalid signature', None
        nonce_error = self.consume_nonce(machine_id, nonce, now)
        if nonce_error:
            return nonce_error, None
        return None, now

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

    def enroll(self, enrollment_id, timestamp, signature, body, headers=None):
        headers = headers or {}
        identity_auth = str(headers.get('X-Mgmt-Auth') or '').strip() == '1'

        record = None
        enroll_path = None
        if not identity_auth:
            record, enroll_path, error = self.verify_request(
                enrollment_id, timestamp, signature, body
            )
            if error:
                return 403, {'error': error}

        try:
            payload = json.loads(body.decode())
        except json.JSONDecodeError:
            return 400, {'error': 'invalid JSON'}
        if not isinstance(payload, dict):
            return 400, {'error': 'invalid JSON'}

        machine_id = str(payload.get('machine_id', '')).strip()
        hostname = str(payload.get('hostname', '')).strip()
        if not machine_id:
            return 400, {'error': 'machine_id is required'}
        if any(c in machine_id for c in '\r\n/\\'):
            return 400, {'error': 'invalid machine_id'}

        try:
            requested = normalize_services(payload.get('services'))
        except ServiceValidationError as exc:
            return 400, {'error': str(exc)}

        issued_mac = None
        if not identity_auth:
            bound_machine_id = record.get('bound_machine_id')
            if bound_machine_id and bound_machine_id != machine_id:
                return 403, {'error': 'enrollment code is already bound to another machine'}

        try:
            with LOCK:
                state = self.load_registry()
                clients = state.setdefault('clients', {})
                client = clients.get(machine_id)
                now_iso = utc_now_iso()

                if identity_auth:
                    error, _now = self.verify_mgmt_against_client(
                        client, machine_id, headers, body
                    )
                    if error:
                        code = 403 if 'invalid JSON' not in error else 400
                        if error.startswith('malformed') or error.startswith('invalid nonce'):
                            code = 403
                        if error.startswith('unknown') or 'revoked' in error or 'does not have' in error:
                            code = 403
                        return code, {'error': error}
                    if payload.get('mgmt_pubkey'):
                        try:
                            presented = MGMT.canonicalize_pubkey_pem(payload.get('mgmt_pubkey'))
                            stored = MGMT.canonicalize_pubkey_pem(client.get('mgmt_pubkey'))
                        except Exception:
                            return 403, {'error': 'invalid management public key'}
                        if presented != stored:
                            return 403, {'error': 'management public key does not match this client'}
                elif client is None:
                    client = {
                        'hostname': hostname,
                        'created_at': now_iso,
                        'last_enrolled_at': now_iso,
                        'mgmt_status': 'legacy',
                        'services': {},
                    }
                    clients[machine_id] = client
                else:
                    client['hostname'] = hostname or client.get('hostname', '')
                    client['last_enrolled_at'] = now_iso
                    if not isinstance(client.get('services'), dict):
                        client['services'] = {}

                if client is None:
                    return 403, {'error': 'unknown client identity'}
                client['hostname'] = hostname or client.get('hostname', '')
                client['last_enrolled_at'] = now_iso
                if not isinstance(client.get('services'), dict):
                    client['services'] = {}

                if not identity_auth:
                    issued_mac, ident_error = self.register_mgmt_identity(
                        client, payload, record['secret'], machine_id
                    )
                    if ident_error:
                        return 400, {'error': ident_error}

                existing_services = dict(client.get('services') or {})
                used = self.used_ports(state)
                updated = {}
                requested_ids = {svc['id'] for svc in requested}

                for sid, rec in existing_services.items():
                    if sid in requested_ids:
                        continue
                    kept = dict(rec)
                    kept['enabled'] = False
                    updated[sid] = kept

                allocated = []
                for spec in requested:
                    sid = spec['id']
                    previous = existing_services.get(sid) or {}
                    remote_port = coerce_port(previous.get('remote_port'))
                    if remote_port is None:
                        remote_port = self.allocate_port(used)
                        used.add(remote_port)
                    stored = {
                        'name': spec['name'],
                        'protocol': 'tcp',
                        'local_ip': spec['local_ip'],
                        'local_port': spec['local_port'],
                        'remote_port': remote_port,
                        'preset': spec['preset'],
                        'enabled': True,
                    }
                    if spec['preset'] == 'ssh':
                        stored['ssh_user'] = spec.get('ssh_user', 'root')
                    updated[sid] = stored
                    allocated.append({
                        'id': sid,
                        'remote_port': remote_port,
                    })

                client['services'] = updated
                self.save_registry(state)

                if record is not None and enroll_path is not None:
                    record['bound_machine_id'] = machine_id
                    record['used_at'] = record.get('used_at') or now_iso
                    record['last_used_at'] = now_iso
                    self.save_enrollment(enroll_path, record)
                response_mac_key = client.get('mgmt_mac_key') if identity_auth else None
        except RegistrySchemaError as exc:
            return 500, {'error': str(exc)}
        except RuntimeError as exc:
            return 500, {'error': str(exc)}

        response_payload = {
            'frp_server': self.cfg['public_ip'],
            'frp_server_port': int(self.cfg['control_port']),
            'services': allocated,
        }
        if identity_auth:
            mac_secret = response_mac_key
            if not mac_secret:
                return 500, {'error': 'management response authentication is not available'}
            response_payload['response_hmac'] = MGMT.hmac_hex(
                mac_secret, canonical_json(response_payload)
            )
            return 200, response_payload

        secret = record['secret']
        token_ciphertext = encrypt_token(read_text(self.token_file), secret)
        response_payload['token_ciphertext'] = token_ciphertext
        if issued_mac:
            response_payload['mgmt_status'] = 'enrolled'
        response_payload['response_hmac'] = hmac_hex(secret, canonical_json(response_payload))
        return 200, response_payload


def make_handler(allocator):
    class Handler(BaseHTTPRequestHandler):
        server_version = 'frp-auto-deploy/1.2'

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
                    headers=self.headers,
                )
                self.send_json(code, result)
            except json.JSONDecodeError:
                self.send_json(400, {'error': 'invalid JSON'})
            except RegistrySchemaError as exc:
                self.send_json(500, {'error': str(exc)})
            except Exception as exc:
                self.send_json(500, {'error': str(exc)})

    return Handler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--config', required=True)
    args = parser.parse_args()

    allocator = Allocator(args.config)
    try:
        allocator.load_registry()
    except RegistrySchemaError as exc:
        raise SystemExit(f'ERROR: {exc}') from exc
    allocator.cleanup_expired_enrollments()
    host = allocator.cfg.get('listen_host', '0.0.0.0')
    port = int(allocator.cfg['listen_port'])
    server = ThreadingHTTPServer((host, port), make_handler(allocator))
    print(f'FRP allocator listening on http://{host}:{port}', flush=True)
    server.serve_forever()


if __name__ == '__main__':
    main()
