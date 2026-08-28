#!/usr/bin/env python3
import sys
if sys.version_info < (3, 7):
    sys.stderr.write('ERROR: python 3.7 or newer is required\n')
    raise SystemExit(1)
import argparse
import fcntl
import hashlib
import hmac
import importlib.util
import ipaddress
import json
import os
import re
import secrets
import socket
import ssl
import subprocess
import tempfile
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

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
BOOTSTRAP_TICKET_PREFIX = 'bt1'
BOOTSTRAP_ID_HEX_LEN = 16
BOOTSTRAP_SECRET_HEX_LEN = 64
BOOTSTRAP_TICKET_MAX_LEN = 160
BOOTSTRAP_DUMMY_HASH = '0' * 64
HEX_RE = re.compile(r'^[0-9a-f]+$')
MACHINE_ID_MAX_LEN = 128
HOSTNAME_MAX_LEN = 253


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


class PortRangeExhausted(RuntimeError):
    pass


class FileLock:
    """Exclusive filesystem lock. Released automatically on process death."""

    def __init__(self, path):
        self.path = Path(path)
        self.fd = None

    def __enter__(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.fd = os.open(str(self.path), os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(self.fd, fcntl.LOCK_EX)
        except Exception:
            os.close(self.fd)
            self.fd = None
            raise
        return self

    def __exit__(self, exc_type, exc, tb):
        if self.fd is not None:
            try:
                fcntl.flock(self.fd, fcntl.LOCK_UN)
            except OSError:
                pass
            try:
                os.close(self.fd)
            except OSError:
                pass
            self.fd = None
        return False


def api_error(message, error_class):
    return {'error': str(message), 'error_class': error_class}


def classify_auth_error(error):
    text = str(error or '').lower()
    if 'revoked' in text:
        return 'REVOKED'
    if 'replay' in text:
        return 'REPLAY_REJECTED'
    return 'AUTH_FAILED'


def registry_lock_path(registry_file):
    return Path(registry_file).resolve().parent / 'registry.lock'


def _test_before_registry_write(path):
    """Production no-op. Unit tests may replace this symbol."""
    return None


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
    _test_before_registry_write(str(p))
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


def unlink_quiet(path):
    try:
        Path(path).unlink()
    except OSError:
        pass


def hash_bootstrap_secret(secret):
    return hashlib.sha256(secret.encode('ascii')).hexdigest()


def parse_bootstrap_ticket(raw):
    """Return (ticket_id, secret) or None. Never raises on malformed input."""
    if raw is None:
        return None
    if not isinstance(raw, str):
        return None
    ticket = raw.strip()
    if not ticket or len(ticket) > BOOTSTRAP_TICKET_MAX_LEN:
        return None
    parts = ticket.split('.')
    if len(parts) != 3:
        return None
    prefix, ticket_id, secret = parts
    if prefix != BOOTSTRAP_TICKET_PREFIX:
        return None
    if len(ticket_id) != BOOTSTRAP_ID_HEX_LEN or len(secret) != BOOTSTRAP_SECRET_HEX_LEN:
        return None
    if not HEX_RE.fullmatch(ticket_id) or not HEX_RE.fullmatch(secret):
        return None
    return ticket_id.lower(), secret.lower()


def bootstrap_dir_from_cfg(cfg):
    configured = str((cfg or {}).get('bootstrap_dir') or '').strip()
    if configured:
        return Path(configured)
    enrollments = str((cfg or {}).get('enrollments_dir') or '').strip()
    if enrollments:
        return Path(enrollments).resolve().parent / 'bootstrap'
    return Path('/var/lib/frp-auto-deploy/bootstrap')


def ensure_secret_dir(path, mode=0o700):
    p = Path(path)
    p.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(str(p), mode)
    except OSError:
        pass
    return p


def enrollment_file_path(enrollments_dir, enrollment_id):
    if not enrollment_id or any(c not in '0123456789abcdef' for c in enrollment_id.lower()):
        return None
    return Path(enrollments_dir) / (enrollment_id.lower() + '.json')


def bootstrap_file_path(bootstrap_dir, ticket_id):
    if not ticket_id or not HEX_RE.fullmatch(str(ticket_id).lower()):
        return None
    if len(ticket_id) != BOOTSTRAP_ID_HEX_LEN:
        return None
    return Path(bootstrap_dir) / (ticket_id.lower() + '.json')


def cleanup_expired_bootstrap_tickets(bootstrap_dir, now=None, keep_id=None):
    now = int(now if now is not None else time.time())
    keep_id = (keep_id or '').lower()
    try:
        entries = list(Path(bootstrap_dir).glob('*.json'))
    except OSError:
        return
    for path in entries:
        if keep_id and path.stem.lower() == keep_id:
            continue
        try:
            record = load_json(path)
            if int(record.get('expires_at', 0)) < now:
                unlink_quiet(path)
        except Exception:
            continue


def issue_bootstrap_ticket(enrollments_dir, bootstrap_dir, services, ttl, note=''):
    """Create a hashed bootstrap ticket plus a normal enrollment record.

    Does not allocate a public port. Caller must have already validated
    `services` with normalize_services().
    """
    ttl = int(ttl)
    note = str(note or '')
    enrollment_id = secrets.token_hex(8)
    enroll_secret = secrets.token_hex(32)
    ticket_id = secrets.token_hex(8)
    ticket_secret = secrets.token_hex(32)
    now = int(time.time())
    expires_at = now + ttl
    enroll_record = {
        'id': enrollment_id,
        'secret': enroll_secret,
        'created_at': utc_now_iso(),
        'expires_at': expires_at,
        'expires_at_iso': datetime.fromtimestamp(
            expires_at, timezone.utc
        ).replace(microsecond=0).isoformat().replace('+00:00', 'Z'),
        'bound_machine_id': None,
        'used_at': None,
        'note': note,
    }
    ticket_record = {
        'schema': 1,
        'id': ticket_id,
        'secret_hash': hash_bootstrap_secret(ticket_secret),
        'enrollment_id': enrollment_id,
        'created_at': utc_now_iso(),
        'expires_at': expires_at,
        'bound_machine_id': None,
        'completed_at': None,
        'note': note,
        'services': services,
    }
    enrollments_dir = Path(enrollments_dir)
    bootstrap_dir = ensure_secret_dir(bootstrap_dir, 0o700)
    try:
        os.chmod(str(enrollments_dir), 0o700)
    except OSError:
        enrollments_dir.mkdir(parents=True, exist_ok=True)
        try:
            os.chmod(str(enrollments_dir), 0o700)
        except OSError:
            pass
    cleanup_expired_bootstrap_tickets(bootstrap_dir, now)
    enroll_path = enrollment_file_path(enrollments_dir, enrollment_id)
    ticket_path = bootstrap_file_path(bootstrap_dir, ticket_id)
    if enroll_path is None or ticket_path is None:
        raise RuntimeError('failed to allocate bootstrap ticket paths')
    try:
        atomic_write_json(enroll_path, enroll_record, mode=0o600)
        try:
            os.chmod(str(enroll_path), 0o600)
        except OSError:
            pass
        atomic_write_json(ticket_path, ticket_record, mode=0o600)
        try:
            os.chmod(str(ticket_path), 0o600)
        except OSError:
            pass
    except Exception:
        unlink_quiet(ticket_path)
        unlink_quiet(enroll_path)
        raise
    ticket = '%s.%s.%s' % (BOOTSTRAP_TICKET_PREFIX, ticket_id, ticket_secret)
    return ticket, enroll_record, ticket_record


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


def cfg_public_host(cfg):
    for key in ('public_host', 'public_ip'):
        value = cfg.get(key)
        if value is not None and str(value).strip():
            return str(value).strip()
    raise RuntimeError('public_host is not configured')


def cfg_frp_control_public_port(cfg):
    port = coerce_port(cfg.get('frp_control_public_port'))
    if port is not None:
        return port
    port = coerce_port(cfg.get('control_port'))
    if port is not None:
        return port
    raise RuntimeError('frp_control_public_port is not configured')


def cfg_frp_control_listen_port(cfg):
    port = coerce_port(cfg.get('frp_control_listen_port'))
    if port is not None:
        return port
    port = coerce_port(cfg.get('control_port'))
    if port is not None:
        return port
    return None


def cfg_allocator_listen_port(cfg):
    port = coerce_port(cfg.get('allocator_listen_port'))
    if port is not None:
        return port
    return coerce_port(cfg.get('listen_port'))


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


def validate_registry_invariants(state, cfg=None):
    """Fail closed on severe registry corruption. Do not silently repair."""
    state = require_registry_v2(state)
    seen_ports = {}
    port_start = None
    port_end = None
    protected = set()
    if cfg:
        try:
            port_start = int(cfg.get('port_start'))
            port_end = int(cfg.get('port_end'))
        except (TypeError, ValueError):
            port_start = None
            port_end = None
        for key in ('allocator_listen_port', 'frp_control_listen_port', 'listen_port'):
            port = coerce_port(cfg.get(key))
            if port is not None:
                protected.add(port)
    for item in state.get('reserved') or []:
        port = coerce_port(item)
        if port is not None:
            seen_ports[port] = ('reserved', None)
    for mid, client in (state.get('clients') or {}).items():
        if not isinstance(client, dict):
            raise RegistrySchemaError('REGISTRY_INVALID: client record is not an object')
        status = client.get('mgmt_status')
        if status is not None and status not in ('enrolled', 'legacy', 'revoked'):
            raise RegistrySchemaError('REGISTRY_INVALID: invalid management identity status')
        services = client.get('services') or {}
        if not isinstance(services, dict):
            raise RegistrySchemaError('REGISTRY_INVALID: client services must be a map')
        seen_ids = set()
        for sid, svc in services.items():
            key = str(sid).strip().lower()
            if key in seen_ids:
                raise RegistrySchemaError('REGISTRY_INVALID: duplicate service id for client')
            seen_ids.add(key)
            if not isinstance(svc, dict):
                raise RegistrySchemaError('REGISTRY_INVALID: service record is not an object')
            port = coerce_port(svc.get('remote_port'))
            if port is None:
                continue
            if port in seen_ports:
                raise RegistrySchemaError('REGISTRY_INVALID: duplicate public port ownership')
            seen_ports[port] = (mid, key)
            if port_start is not None and port_end is not None:
                if port < port_start or port > port_end:
                    raise RegistrySchemaError('REGISTRY_INVALID: allocated port outside configured range')
            if port in protected:
                raise RegistrySchemaError('REGISTRY_INVALID: allocated port collides with a reserved control port')
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
        try:
            os.chmod(str(self.enrollments_dir), 0o700)
        except OSError:
            pass
        self.bootstrap_dir = bootstrap_dir_from_cfg(self.cfg)
        ensure_secret_dir(self.bootstrap_dir, 0o700)
        self.token_file = self.cfg['token_file']
        self.nonce_file = Path(self.registry_file).resolve().parent / 'mgmt-nonces.json'

    def registry_lock(self):
        return FileLock(registry_lock_path(self.registry_file))

    def load_registry(self):
        if not Path(self.registry_file).exists():
            return empty_registry()
        try:
            state = load_json(self.registry_file)
        except (OSError, json.JSONDecodeError) as exc:
            raise RegistrySchemaError('unable to read an existing FRP registry') from exc
        require_registry_v2(state)
        return validate_registry_invariants(state, self.cfg)

    def save_registry(self, state):
        state = dict(state)
        state['schema_version'] = REGISTRY_SCHEMA_VERSION
        require_registry_v2(state)
        validate_registry_invariants(state, self.cfg)
        atomic_write_json(self.registry_file, state)

    def used_ports(self, state):
        return used_ports_from_state(state)

    def protected_ports(self):
        protected = set()
        for port in (
            cfg_allocator_listen_port(self.cfg),
            cfg_frp_control_listen_port(self.cfg),
            coerce_port(self.cfg.get('listen_port')),
        ):
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
        raise PortRangeExhausted('No available FRP service ports')

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

    def bootstrap_path(self, ticket_id):
        return bootstrap_file_path(self.bootstrap_dir, ticket_id)

    def load_bootstrap(self, ticket_id):
        path = self.bootstrap_path(ticket_id)
        if path is None or not path.exists():
            return None, path
        try:
            return load_json(path), path
        except (OSError, json.JSONDecodeError):
            return None, path

    def save_bootstrap(self, path, record):
        atomic_write_json(path, record, mode=0o600)

    def cleanup_expired_bootstrap_tickets(self, now=None, keep_id=None):
        cleanup_expired_bootstrap_tickets(self.bootstrap_dir, now, keep_id=keep_id)

    def issue_bootstrap_ticket(self, services, ttl, note=''):
        ensure_secret_dir(self.bootstrap_dir, 0o700)
        return issue_bootstrap_ticket(
            self.enrollments_dir, self.bootstrap_dir, services, ttl, note
        )

    def _invalid_ticket_response(self):
        return 403, api_error('bootstrap ticket is invalid', 'BOOTSTRAP_TICKET_INVALID')

    def redeem_bootstrap(self, body):
        """Bind a bootstrap ticket to the first machine and return enrollment data."""
        try:
            payload = json.loads(body.decode())
        except (json.JSONDecodeError, UnicodeDecodeError, AttributeError):
            return 400, api_error('invalid JSON', 'ZERO_TOUCH_INPUT_INVALID')
        if not isinstance(payload, dict):
            return 400, api_error('invalid JSON', 'ZERO_TOUCH_INPUT_INVALID')

        raw_ticket = payload.get('ticket')
        if raw_ticket is None:
            raw_ticket = payload.get('bootstrap_ticket')
        parsed = parse_bootstrap_ticket(raw_ticket if isinstance(raw_ticket, str) else '')
        machine_id = str(payload.get('machine_id', '') or '').strip()
        hostname = str(payload.get('hostname', '') or '').strip()
        if not machine_id:
            return 400, api_error('machine_id is required', 'ZERO_TOUCH_INPUT_INVALID')
        if len(machine_id) > MACHINE_ID_MAX_LEN or any(c in machine_id for c in '\r\n/\\'):
            return 400, api_error('invalid machine_id', 'ZERO_TOUCH_INPUT_INVALID')
        if len(hostname) > HOSTNAME_MAX_LEN or any(c in hostname for c in '\r\n/\\'):
            return 400, api_error('invalid hostname', 'ZERO_TOUCH_INPUT_INVALID')

        provided_hash = BOOTSTRAP_DUMMY_HASH
        ticket_id = ''
        ticket_secret = ''
        if parsed:
            ticket_id, ticket_secret = parsed
            provided_hash = hash_bootstrap_secret(ticket_secret)

        try:
            with LOCK:
                with self.registry_lock():
                    self.cleanup_expired_bootstrap_tickets(keep_id=ticket_id)
                    record = None
                    path = None
                    stored_hash = BOOTSTRAP_DUMMY_HASH
                    if parsed:
                        record, path = self.load_bootstrap(ticket_id)
                        if record and isinstance(record, dict):
                            candidate = str(record.get('secret_hash') or '')
                            if HEX_RE.fullmatch(candidate) and len(candidate) == 64:
                                stored_hash = candidate
                    match = hmac.compare_digest(provided_hash, stored_hash)
                    if not parsed or record is None or not match:
                        return self._invalid_ticket_response()

                    now = int(time.time())
                    try:
                        expires_at = int(record.get('expires_at', 0))
                    except (TypeError, ValueError):
                        expires_at = 0
                    if now > expires_at:
                        return 410, api_error(
                            'bootstrap ticket has expired',
                            'BOOTSTRAP_TICKET_EXPIRED',
                        )

                    bound = record.get('bound_machine_id')
                    if bound and bound != machine_id:
                        return 409, api_error(
                            'bootstrap ticket is bound to another machine',
                            'BOOTSTRAP_TICKET_BOUND',
                        )

                    enrollment_id = str(record.get('enrollment_id') or '')
                    enroll_record, enroll_path = self.load_enrollment(enrollment_id)
                    if not enroll_record:
                        return self._invalid_ticket_response()
                    try:
                        enroll_expires = int(enroll_record.get('expires_at', 0))
                    except (TypeError, ValueError):
                        enroll_expires = 0
                    if now > enroll_expires:
                        return 410, api_error(
                            'bootstrap ticket has expired',
                            'BOOTSTRAP_TICKET_EXPIRED',
                        )

                    try:
                        services = normalize_services(record.get('services'))
                    except ServiceValidationError:
                        return self._invalid_ticket_response()

                    if not bound:
                        record['bound_machine_id'] = machine_id
                        self.save_bootstrap(path, record)

                    enroll_secret = str(enroll_record.get('secret') or '')
                    if not enroll_secret:
                        return self._invalid_ticket_response()
                    enrollment_code = '%s.%s' % (
                        str(enroll_record.get('id') or enrollment_id),
                        enroll_secret,
                    )
                    return 200, {
                        'enrollment_code': enrollment_code,
                        'services': services,
                        'note': str(record.get('note') or ''),
                    }
        except RegistrySchemaError as exc:
            return 500, api_error(str(exc), 'REGISTRY_INVALID')
        except OSError:
            return 500, api_error(
                'failed to persist bootstrap ticket', 'SERVER_MUTATION_FAILED'
            )

    def complete_bootstrap_for_enrollment(self, enrollment_id, machine_id):
        """Record completed_at without making the ticket unrecoverable."""
        if not enrollment_id:
            return
        try:
            entries = list(self.bootstrap_dir.glob('*.json'))
        except OSError:
            return
        now_iso = utc_now_iso()
        for path in entries:
            try:
                record = load_json(path)
            except Exception:
                continue
            if not isinstance(record, dict):
                continue
            if str(record.get('enrollment_id') or '') != str(enrollment_id):
                continue
            bound = record.get('bound_machine_id')
            if bound and bound != machine_id:
                continue
            if record.get('completed_at'):
                return
            record['completed_at'] = now_iso
            if not bound:
                record['bound_machine_id'] = machine_id
            try:
                self.save_bootstrap(path, record)
            except OSError:
                return
            return

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
        self.cleanup_expired_bootstrap_tickets(now)

    def load_nonces(self):
        path = self.nonce_file
        if not path.exists():
            return {'schema_version': 1, 'nonces': {}}
        try:
            data = load_json(path)
        except (OSError, json.JSONDecodeError) as exc:
            raise RegistrySchemaError('unable to read an existing management nonce store') from exc
        if not isinstance(data, dict):
            raise RegistrySchemaError('unable to read an existing management nonce store')
        nonces = data.get('nonces')
        if not isinstance(nonces, dict):
            raise RegistrySchemaError('unable to read an existing management nonce store')
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

    def check_nonce(self, machine_id, nonce, now):
        """Return an error string if the nonce is unusable. Do not persist yet.

        Persistence happens in commit_nonce() after a successful registry save
        so a failed mutation does not burn a valid signed request.
        """
        if not NONCE_RE.fullmatch(nonce or ''):
            return 'invalid nonce'
        data = self.expire_nonces(now)
        nonces = data['nonces']
        key = f'{machine_id}:{nonce}'
        if key in nonces:
            return 'replayed request'
        return None

    def commit_nonce(self, machine_id, nonce, now):
        """Persist a nonce after the matching mutation has been committed."""
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

    def consume_nonce(self, machine_id, nonce, now):
        """Replay defense: a captured signed request cannot be reused.

        Nonces are stored as machine_id:nonce -> expiry. Entries expire after
        MGMT_NONCE_TTL seconds (900), which is longer than MAX_CLOCK_SKEW so a
        request stays non-replayable for its entire accepted timestamp window.
        Per-client count is capped; oldest entries are dropped first.

        Callers that need check-then-commit around a registry mutation should
        use check_nonce() + commit_nonce() instead.
        """
        error = self.check_nonce(machine_id, nonce, now)
        if error:
            return error
        return self.commit_nonce(machine_id, nonce, now)

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
            return 'invalid timestamp', None, None
        nonce = str(headers.get('X-Mgmt-Nonce') or '').strip().lower()
        signature = str(headers.get('X-Mgmt-Signature') or '').strip()
        if not signature:
            return 'missing signature', None, None
        now = int(time.time())
        if abs(now - ts) > MAX_CLOCK_SKEW:
            return 'request timestamp outside allowed window', None, None
        if not isinstance(client, dict):
            return 'unknown client identity', None, None
        status = self.mgmt_status(client)
        if status == 'revoked':
            return (
                "this client's management identity has been revoked. "
                'Run the server enrollment command to create a new Enrollment Code, '
                'then re-enroll this client.'
            ), None, None
        if status != 'enrolled' or not client.get('mgmt_pubkey'):
            return 'this client does not have a management identity', None, None
        message = MGMT.signed_message(machine_id, body, ts, nonce)
        try:
            ok = MGMT.verify_signature(client['mgmt_pubkey'], message, signature)
        except ValueError as exc:
            return str(exc), None, None
        if not ok:
            return 'invalid signature', None, None
        nonce_error = self.check_nonce(machine_id, nonce, now)
        if nonce_error:
            return nonce_error, None, None
        return None, now, nonce

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
                return 403, api_error(error, classify_auth_error(error))

        try:
            payload = json.loads(body.decode())
        except json.JSONDecodeError:
            return 400, api_error('invalid JSON', 'AUTH_FAILED')
        if not isinstance(payload, dict):
            return 400, api_error('invalid JSON', 'AUTH_FAILED')

        machine_id = str(payload.get('machine_id', '')).strip()
        hostname = str(payload.get('hostname', '')).strip()
        if not machine_id:
            return 400, api_error('machine_id is required', 'AUTH_FAILED')
        if any(c in machine_id for c in '\r\n/\\'):
            return 400, api_error('invalid machine_id', 'AUTH_FAILED')

        try:
            requested = normalize_services(payload.get('services'))
        except ServiceValidationError as exc:
            cls = 'SERVICE_ALREADY_EXISTS' if 'duplicate' in str(exc).lower() else 'AUTH_FAILED'
            return 400, api_error(str(exc), cls)

        issued_mac = None
        pending_nonce = None
        allocated = []
        response_mac_key = None

        try:
            with LOCK:
                with self.registry_lock():
                    if not identity_auth:
                        record, enroll_path = self.load_enrollment(enrollment_id)
                        if not record:
                            return 403, api_error('unknown enrollment id', 'AUTH_FAILED')
                        bound_machine_id = record.get('bound_machine_id')
                        if bound_machine_id and bound_machine_id != machine_id:
                            return 403, api_error(
                                'enrollment code is already bound to another machine',
                                'AUTH_FAILED',
                            )

                    state = self.load_registry()
                    clients = state.setdefault('clients', {})
                    client = clients.get(machine_id)
                    now_iso = utc_now_iso()

                    if identity_auth:
                        error, _now, pending_nonce = self.verify_mgmt_against_client(
                            client, machine_id, headers, body
                        )
                        if error:
                            return 403, api_error(error, classify_auth_error(error))
                        if payload.get('mgmt_pubkey'):
                            try:
                                presented = MGMT.canonicalize_pubkey_pem(payload.get('mgmt_pubkey'))
                                stored = MGMT.canonicalize_pubkey_pem(client.get('mgmt_pubkey'))
                            except Exception:
                                return 403, api_error(
                                    'invalid management public key', 'AUTH_FAILED'
                                )
                            if presented != stored:
                                return 403, api_error(
                                    'management public key does not match this client',
                                    'AUTH_FAILED',
                                )
                    elif client is None:
                        client = {
                            'hostname': hostname,
                            'created_at': now_iso,
                            'last_enrolled_at': now_iso,
                            'mgmt_status': 'legacy',
                            'services': {},
                        }
                        if record is not None and record.get('note'):
                            client['note'] = str(record.get('note') or '')
                        clients[machine_id] = client
                    else:
                        client['hostname'] = hostname or client.get('hostname', '')
                        client['last_enrolled_at'] = now_iso
                        if not isinstance(client.get('services'), dict):
                            client['services'] = {}
                        if record is not None and record.get('note') and not client.get('note'):
                            client['note'] = str(record.get('note') or '')

                    if client is None:
                        return 403, api_error('unknown client identity', 'AUTH_FAILED')
                    client['hostname'] = hostname or client.get('hostname', '')
                    client['last_enrolled_at'] = now_iso
                    if not isinstance(client.get('services'), dict):
                        client['services'] = {}

                    if not identity_auth:
                        issued_mac, ident_error = self.register_mgmt_identity(
                            client, payload, record['secret'], machine_id
                        )
                        if ident_error:
                            return 400, api_error(ident_error, 'AUTH_FAILED')

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

                    if pending_nonce:
                        nonce_error = self.commit_nonce(
                            machine_id, pending_nonce, int(time.time())
                        )
                        if nonce_error:
                            return 403, api_error(
                                nonce_error, classify_auth_error(nonce_error)
                            )

                    if record is not None and enroll_path is not None:
                        record['bound_machine_id'] = machine_id
                        record['used_at'] = record.get('used_at') or now_iso
                        record['last_used_at'] = now_iso
                        self.save_enrollment(enroll_path, record)
                        self.complete_bootstrap_for_enrollment(
                            record.get('id') or enrollment_id, machine_id
                        )
                    response_mac_key = client.get('mgmt_mac_key') if identity_auth else None
        except RegistrySchemaError as exc:
            return 500, api_error(str(exc), 'REGISTRY_INVALID')
        except PortRangeExhausted as exc:
            return 500, api_error(str(exc), 'PORT_RANGE_EXHAUSTED')
        except OSError:
            return 500, api_error(
                'failed to persist registry', 'SERVER_MUTATION_FAILED'
            )
        except RuntimeError as exc:
            return 500, api_error(str(exc), 'SERVER_MUTATION_FAILED')

        response_payload = {
            'frp_server': cfg_public_host(self.cfg),
            'frp_server_port': cfg_frp_control_public_port(self.cfg),
            'services': allocated,
        }
        if identity_auth:
            mac_secret = response_mac_key
            if not mac_secret:
                return 500, api_error(
                    'management response authentication is not available',
                    'SERVER_MUTATION_FAILED',
                )
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

        def _request_path(self):
            parsed = urlparse(self.path)
            return parsed.path or '/'

        def do_GET(self):
            path = self._request_path()
            if path == '/healthz':
                self.send_json(200, {'status': 'ok'})
                return
            if path == '/ca.crt':
                ca_path = allocator.cfg.get('tls_ca_cert')
                if not ca_path or not Path(ca_path).is_file():
                    self.send_json(500, {'error': 'CA certificate is not available'})
                    return
                body = Path(ca_path).read_bytes()
                self.send_response(200)
                self.send_header('Content-Type', 'application/x-pem-file')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            self.send_json(404, {'error': 'not found'})

        def do_POST(self):
            path = self._request_path()
            try:
                length = int(self.headers.get('Content-Length', '0'))
                if length <= 0 or length > 65536:
                    self.send_json(400, {'error': 'invalid request body length'})
                    return
                body = self.rfile.read(length)
            except Exception:
                self.send_json(400, {'error': 'invalid request body length'})
                return
            try:
                if path == '/enroll':
                    code, result = allocator.enroll(
                        self.headers.get('X-Enrollment-ID', ''),
                        self.headers.get('X-Timestamp', ''),
                        self.headers.get('X-Signature', ''),
                        body,
                        headers=self.headers,
                    )
                    self.send_json(code, result)
                    return
                if path == '/bootstrap/redeem':
                    code, result = allocator.redeem_bootstrap(body)
                    self.send_json(code, result)
                    return
                self.send_json(404, {'error': 'not found'})
            except json.JSONDecodeError:
                self.send_json(400, api_error('invalid JSON', 'AUTH_FAILED'))
            except RegistrySchemaError as exc:
                self.send_json(500, api_error(str(exc), 'REGISTRY_INVALID'))
            except PortRangeExhausted as exc:
                self.send_json(500, api_error(str(exc), 'PORT_RANGE_EXHAUSTED'))
            except Exception as exc:
                self.send_json(500, api_error(str(exc), 'SERVER_MUTATION_FAILED'))

    return Handler


def allocator_ssl_context(cfg):
    cert = str(cfg.get('tls_server_cert') or '').strip()
    key = str(cfg.get('tls_server_key') or '').strip()
    if not cert or not key:
        raise SystemExit(
            'ERROR: allocator TLS certificate or key is missing; refusing to start plain HTTP'
        )
    if not Path(cert).is_file() or not Path(key).is_file():
        raise SystemExit(
            'ERROR: allocator TLS certificate or key is missing; refusing to start plain HTTP'
        )
    try:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    except AttributeError:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS)
    if hasattr(ssl, 'TLSVersion'):
        context.minimum_version = ssl.TLSVersion.TLSv1_2
    else:
        context.options |= getattr(ssl, 'OP_NO_SSLv2', 0)
        context.options |= getattr(ssl, 'OP_NO_SSLv3', 0)
        context.options |= getattr(ssl, 'OP_NO_TLSv1', 0)
        context.options |= getattr(ssl, 'OP_NO_TLSv1_1', 0)
    try:
        context.load_cert_chain(certfile=cert, keyfile=key)
    except Exception as exc:
        raise SystemExit('ERROR: allocator TLS configuration is invalid: %s' % exc) from exc
    return context


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
    port = cfg_allocator_listen_port(allocator.cfg)
    if port is None:
        raise SystemExit('ERROR: allocator_listen_port is not configured')
    context = allocator_ssl_context(allocator.cfg)
    server = ThreadingHTTPServer((host, port), make_handler(allocator))
    server.socket = context.wrap_socket(server.socket, server_side=True)
    print(f'FRP allocator listening on https://{host}:{port}', flush=True)
    server.serve_forever()


if __name__ == '__main__':
    main()
