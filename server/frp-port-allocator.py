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
ALLOWED_PRESETS = ('ssh', 'http', 'https', 'rdp', 'custom')
ALLOWED_PROTOCOLS = ('tcp',)
NONCE_RE = re.compile(r'^[0-9a-f]{64}$')
BOOTSTRAP_TICKET_PREFIX = 'bt1'
ENROLLMENT_ID_HEX_LEN = 16
BOOTSTRAP_ID_HEX_LEN = 16
BOOTSTRAP_SECRET_HEX_LEN = 64
BOOTSTRAP_TICKET_MAX_LEN = 160
BOOTSTRAP_DUMMY_HASH = '0' * 64
HEX_RE = re.compile(r'^[0-9a-f]+$')
ENROLLMENT_ID_RE = re.compile(r'^[0-9a-f]{16}$')
MACHINE_ID_MAX_LEN = 128
HOSTNAME_MAX_LEN = 253
# Request body already caps at 64KiB; also bound idle reads and fan-out.
ALLOCATOR_REQUEST_TIMEOUT_SEC = 30
ALLOCATOR_MAX_CONCURRENT = 32
_REQUEST_SLOTS = threading.BoundedSemaphore(ALLOCATOR_MAX_CONCURRENT)


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


def _load_client_registry():
    candidates = [
        Path(__file__).resolve().parent / 'frp_client_registry.py',
        Path(__file__).resolve().parent.parent / 'lib' / 'frp_client_registry.py',
        Path('/usr/local/lib/frp-auto-deploy/frp_client_registry.py'),
    ]
    for path in candidates:
        if path.is_file():
            spec = importlib.util.spec_from_file_location('frp_client_registry', path)
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            return mod
    raise RuntimeError('missing frp_client_registry.py')


def _load_lib_module(name, filename):
    candidates = [
        Path(__file__).resolve().parent / filename,
        Path(__file__).resolve().parent.parent / 'lib' / filename,
        Path('/usr/local/lib/frp-auto-deploy') / filename,
    ]
    for path in candidates:
        if path.is_file():
            spec = importlib.util.spec_from_file_location(name, path)
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            return mod
    return None


CREG = _load_client_registry()
FRONTEND = _load_lib_module('frp_frontend', 'frp_frontend.py')
SCFG = _load_lib_module('frp_server_config', 'frp_server_config.py')


def _load_enrollment_lifecycle():
    candidates = [
        Path(__file__).resolve().parent / 'frp_enrollment_lifecycle.py',
        Path(__file__).resolve().parent.parent / 'lib' / 'frp_enrollment_lifecycle.py',
        Path('/usr/local/lib/frp-auto-deploy/frp_enrollment_lifecycle.py'),
    ]
    for path in candidates:
        if path.is_file():
            spec = importlib.util.spec_from_file_location('frp_enrollment_lifecycle', path)
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            return mod
    return None


ELC = _load_enrollment_lifecycle()


def _load_enroll_challenge():
    candidates = [
        Path(__file__).resolve().parent / 'frp_enroll_challenge.py',
        Path(__file__).resolve().parent.parent / 'lib' / 'frp_enroll_challenge.py',
        Path('/usr/local/lib/frp-auto-deploy/frp_enroll_challenge.py'),
    ]
    for path in candidates:
        if path.is_file():
            spec = importlib.util.spec_from_file_location('frp_enroll_challenge', path)
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            return mod
    return None


ENROLL_CHALLENGE = _load_enroll_challenge()


def _try_audit(event, **kwargs):
    try:
        candidates = [
            Path(__file__).resolve().parent.parent / 'lib' / 'frp_audit.py',
            Path('/usr/local/lib/frp-auto-deploy/frp_audit.py'),
        ]
        root = os.environ.get('FRP_DEPLOY_TEST_ROOT', '')
        if root:
            candidates.insert(0, Path(root) / 'usr/local/lib/frp-auto-deploy/frp_audit.py')
        for path in candidates:
            if path.is_file():
                spec = importlib.util.spec_from_file_location('frp_audit', str(path))
                audit = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(audit)
                audit.try_emit(event, **kwargs)
                return
    except Exception:
        pass


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
        'groups': {},
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


def normalize_enrollment_id(enrollment_id):
    eid = str(enrollment_id or '').strip().lower()
    if not ENROLLMENT_ID_RE.fullmatch(eid):
        return None
    return eid


def enrollment_file_path(enrollments_dir, enrollment_id):
    eid = normalize_enrollment_id(enrollment_id)
    if eid is None:
        return None
    return Path(enrollments_dir) / (eid + '.json')


def bootstrap_file_path(bootstrap_dir, ticket_id):
    if not ticket_id or not HEX_RE.fullmatch(str(ticket_id).lower()):
        return None
    if len(ticket_id) != BOOTSTRAP_ID_HEX_LEN:
        return None
    return Path(bootstrap_dir) / (ticket_id.lower() + '.json')


def cleanup_expired_bootstrap_tickets(bootstrap_dir, now=None, keep_id=None, cfg=None):
    """Pair-aware retention cleanup for terminal enrollment metadata."""
    del keep_id  # retained for call-site compatibility; purge never targets active rows
    if ELC is None or not cfg:
        return
    try:
        ELC.maybe_run_retention_cleanup(cfg, force=False, audit_emit=ELC.load_audit_emit(), now=now)
    except Exception:
        return


def issue_bootstrap_ticket(enrollments_dir, bootstrap_dir, services, ttl, note='', label='', assigned_group_ids=None, cfg=None):
    """Create a hashed bootstrap ticket plus a normal enrollment record.

    Does not allocate a public port. Caller must have already validated
    `services` with normalize_services() and `assigned_group_ids` when present.

    When ``cfg`` is provided, retention cleanup honors ``enrollment_retention_days``
    from that authoritative server config (same policy as manual issuance / startup).
    """
    ttl = int(ttl)
    note = str(note or '')
    label = str(label or '')
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
        'label': label,
    }
    if assigned_group_ids:
        enroll_record['assigned_group_ids'] = list(assigned_group_ids)
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
        'label': label,
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
    # Paths come from call args (already remapped by CLI/allocator). Copy only
    # retention policy from authoritative cfg so production path keys cannot
    # override the remapped directories.
    cleanup_cfg = {
        'enrollments_dir': str(enrollments_dir),
        'bootstrap_dir': str(bootstrap_dir),
        'registry_file': str(Path(enrollments_dir).parent / 'registry.json'),
    }
    if isinstance(cfg, dict):
        if 'enrollment_retention_days' in cfg:
            cleanup_cfg['enrollment_retention_days'] = cfg['enrollment_retention_days']
        if cfg.get('registry_file'):
            cand = Path(str(cfg['registry_file']))
            if cand.parent == Path(enrollments_dir).parent:
                cleanup_cfg['registry_file'] = str(cand)
    # Single force cleanup; honor enrollment_retention_days from authoritative cfg.
    if ELC is not None:
        try:
            ELC.maybe_run_retention_cleanup(
                cleanup_cfg,
                force=True,
                audit_emit=ELC.load_audit_emit(),
                now=now,
            )
        except Exception:
            pass
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


def cfg_deployment_mode(cfg):
    """Fail closed on unknown deployment_mode — never silently become direct."""
    if FRONTEND is None:
        raise RuntimeError('frp_frontend.py is unavailable')
    raw = cfg.get('deployment_mode')
    if raw is None or (isinstance(raw, str) and not str(raw).strip()):
        return 'direct'
    return FRONTEND.normalize_deployment_mode(raw)


def cfg_frp_transport(cfg):
    """Fail closed on unknown frp_transport — empty inherits from mode."""
    if FRONTEND is None:
        raise RuntimeError('frp_frontend.py is unavailable')
    mode = cfg_deployment_mode(cfg)
    return FRONTEND.normalize_transport(cfg.get('frp_transport'), mode)


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
    try:
        return CREG.validate_registry_state(state, cfg)
    except ValueError as exc:
        raise RegistrySchemaError('REGISTRY_INVALID: %s' % exc) from exc


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
        'rdp': 'RDP',
    }.get(preset, sid)
    name = str(raw.get('name', '') or default_name).strip() or default_name
    try:
        name = CREG.validate_text_field(name, 'service name', MAX_NAME_LEN, required=True)
    except ValueError as exc:
        raise ServiceValidationError(str(exc))

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
        ssh_user = str(raw.get('ssh_user', '') or '').strip()
        if not ssh_user:
            raise ServiceValidationError('ssh_user is required for ssh services')
        if not re.fullmatch(r'[A-Za-z0-9._@-]{1,32}', ssh_user):
            raise ServiceValidationError('invalid ssh_user')
        service['ssh_user'] = ssh_user
    return service


def normalize_services(raw_services):
    if raw_services is None:
        raise ServiceValidationError('services is required')
    if not isinstance(raw_services, list):
        raise ServiceValidationError('services must be a list')
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
        self.enroll_challenges = (
            ENROLL_CHALLENGE.EnrollChallengeStore() if ENROLL_CHALLENGE else None
        )

    def issue_enroll_challenge(self, enrollment_id):
        if self.enroll_challenges is None:
            return None, 'enrollment challenge support is unavailable'
        record, _path = self.load_enrollment(enrollment_id)
        if not record:
            return None, 'unknown enrollment id'
        now = int(time.time())
        if record.get('revoked_at'):
            return None, 'enrollment code revoked'
        if now > int(record.get('expires_at', 0)):
            return None, 'enrollment code expired'
        try:
            return self.enroll_challenges.issue(enrollment_id, now), None
        except ValueError as exc:
            return None, str(exc)

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
        if os.environ.get('FRP_ALLOCATOR_HOOK_REGISTRY_PERSIST_FAIL') == '1':
            raise OSError('simulated registry persist failure')
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
        eid = normalize_enrollment_id(enrollment_id)
        if eid is None:
            return None
        return self.enrollments_dir / f'{eid}.json'

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

    def cleanup_expired_bootstrap_tickets(self, now=None, keep_id=None, force=False):
        if ELC is None:
            return
        try:
            ELC.maybe_run_retention_cleanup(
                self.cfg,
                force=force,
                audit_emit=ELC.load_audit_emit(),
                now=now,
            )
        except Exception:
            return

    def issue_bootstrap_ticket(self, services, ttl, note='', label='', assigned_group_ids=None):
        ensure_secret_dir(self.bootstrap_dir, 0o700)
        return issue_bootstrap_ticket(
            self.enrollments_dir,
            self.bootstrap_dir,
            services,
            ttl,
            note,
            label=label,
            assigned_group_ids=assigned_group_ids,
            cfg=self.cfg,
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
        try:
            machine_id = CREG.validate_machine_id(machine_id)
        except ValueError:
            return 400, api_error('invalid machine_id', 'ZERO_TOUCH_INPUT_INVALID')
        try:
            hostname = CREG.validate_hostname(hostname)
        except ValueError:
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
                    self.cleanup_expired_bootstrap_tickets(keep_id=ticket_id, force=False)
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

                    if record.get('revoked_at'):
                        return 403, api_error(
                            'bootstrap ticket has been revoked',
                            'BOOTSTRAP_TICKET_REVOKED',
                        )

                    if record.get('completed_at'):
                        return 409, api_error(
                            'bootstrap ticket has already completed enrollment',
                            'BOOTSTRAP_TICKET_USED',
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
        except RegistrySchemaError:
            return 500, api_error(
                'registry schema is invalid', 'REGISTRY_INVALID'
            )
        except OSError:
            return 500, api_error(
                'failed to persist bootstrap ticket', 'SERVER_MUTATION_FAILED'
            )

    def complete_bootstrap_for_enrollment(self, enrollment_id, machine_id):
        """Mark the matching bootstrap ticket completed/consumed after enrollment.

        Same-machine redeem remains allowed until this runs. After
        completed_at is set, further redeem attempts fail with
        BOOTSTRAP_TICKET_USED.

        OSError while listing or saving bootstrap state propagates to the
        enroll path so the mutation fails closed (ticket is not left
        incorrectly reusable after a successful-looking enroll).
        """
        if not enrollment_id:
            return
        entries = list(self.bootstrap_dir.glob('*.json'))
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
            self.save_bootstrap(path, record)
            return

    def cleanup_expired_enrollments(self):
        now = int(time.time())
        self.expire_nonces(now)
        self.cleanup_expired_bootstrap_tickets(now, force=True)

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

        Management enroll consumes the nonce via commit_nonce() immediately
        after signature verification and *before* registry mutation (fail
        closed). check_nonce() is for read-only validation; callers that
        mutate must durably commit_nonce() first and must not revert it if
        a later registry write fails — the client retries with a new nonce.
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
        """Durably consume a nonce before the matching registry mutation.

        Fail-closed ordering: once this returns success the nonce stays
        consumed even if a later save_registry() fails. Do not revert.
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
        if os.environ.get('FRP_ALLOCATOR_HOOK_NONCE_PERSIST_FAIL') == '1':
            raise OSError('simulated nonce persist failure')
        nonces[key] = now + MGMT_NONCE_TTL
        self.save_nonces(data)
        return None

    def consume_nonce(self, machine_id, nonce, now):
        """Replay defense: a captured signed request cannot be reused.

        Nonces are stored as machine_id:nonce -> expiry. Entries expire after
        MGMT_NONCE_TTL seconds (900), which is longer than MAX_CLOCK_SKEW so a
        request stays non-replayable for its entire accepted timestamp window.
        Per-client count is capped; oldest entries are dropped first.

        Prefer commit_nonce() alone when the caller already validated the
        nonce shape/window, or check_nonce() + commit_nonce() for an explicit
        two-step. Management enroll commits before registry mutation.
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
        # Consume nonce immediately after signature verify (before registry
        # mutation). If a later persist fails, the nonce stays burned.
        nonce_error = self.commit_nonce(machine_id, nonce, now)
        if nonce_error:
            return nonce_error, None, None
        return None, now, nonce

    def verify_request(self, enrollment_id, timestamp, signature, body, headers=None):
        headers = headers or {}
        record, path = self.load_enrollment(enrollment_id)
        if not record:
            return None, None, 'unknown enrollment id'

        now = int(time.time())
        if record.get('revoked_at'):
            return None, None, 'enrollment code revoked'
        if now > int(record.get('expires_at', 0)):
            return None, None, 'enrollment code expired'

        secret = record.get('secret', '')
        challenge_id = str(headers.get('X-Enrollment-Challenge-ID') or '').strip().lower()
        challenge_nonce = str(headers.get('X-Enrollment-Challenge-Nonce') or '').strip().lower()

        if challenge_id:
            if self.enroll_challenges is None:
                return None, None, 'enrollment challenge support is unavailable'
            err = self.enroll_challenges.consume(
                challenge_id, enrollment_id, challenge_nonce, now
            )
            if err:
                return None, None, err
            message = ENROLL_CHALLENGE.enrollment_challenge_message(
                challenge_id, challenge_nonce, body
            )
            expected = hmac_hex(secret, message)
            if not hmac.compare_digest(expected, signature or ''):
                return None, None, 'invalid signature'
            return record, path, None

        try:
            ts = int(timestamp)
        except Exception:
            return None, None, 'invalid timestamp'

        if abs(now - ts) > MAX_CLOCK_SKEW:
            return None, None, 'request timestamp outside allowed window'

        expected = hmac_hex(secret, timestamp + '\n' + body.decode())
        if not hmac.compare_digest(expected, signature or ''):
            return None, None, 'invalid signature'
        return record, path, None

    def enroll(self, enrollment_id, timestamp, signature, body, headers=None, peer_host=None):
        headers = headers or {}
        identity_auth = str(headers.get('X-Mgmt-Auth') or '').strip() == '1'
        source_ip = CREG.request_source_ip(peer_host, headers)

        record = None
        enroll_path = None
        if not identity_auth:
            record, enroll_path, error = self.verify_request(
                enrollment_id, timestamp, signature, body, headers=headers
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
        try:
            machine_id = CREG.validate_machine_id(machine_id)
        except ValueError:
            return 400, api_error('invalid machine_id', 'AUTH_FAILED')
        try:
            hostname = CREG.validate_hostname(hostname)
        except ValueError:
            return 400, api_error('invalid hostname', 'AUTH_FAILED')

        try:
            requested = normalize_services(payload.get('services'))
        except ServiceValidationError as exc:
            cls = 'SERVICE_ALREADY_EXISTS' if 'duplicate' in str(exc).lower() else 'AUTH_FAILED'
            return 400, api_error(str(exc), cls)

        issued_mac = None
        allocated = []
        response_mac_key = None

        try:
            with LOCK:
                with self.registry_lock():
                    now_iso = utc_now_iso()
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
                        # Bind Enrollment Code to this machine before any registry
                        # mutation. If registry persist fails later, Machine A may
                        # retry; Machine B remains rejected. Do not unbind.
                        # Bootstrap ticket completion stays AFTER successful
                        # registry save so a failed mutation does not burn the
                        # zero-touch ticket while enrollment remains bound.
                        record['bound_machine_id'] = machine_id
                        record['used_at'] = record.get('used_at') or now_iso
                        record['last_used_at'] = now_iso
                        self.save_enrollment(enroll_path, record)

                    state = self.load_registry()
                    clients = state.setdefault('clients', {})
                    client = clients.get(machine_id)

                    if identity_auth:
                        error, _now, _nonce = self.verify_mgmt_against_client(
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
                        CREG.seed_admin_metadata(
                            client,
                            label=(record or {}).get('label'),
                            note=(record or {}).get('note'),
                        )
                        clients[machine_id] = client
                    else:
                        client['hostname'] = hostname or client.get('hostname', '')
                        client['last_enrolled_at'] = now_iso
                        if not isinstance(client.get('services'), dict):
                            client['services'] = {}
                    CREG.seed_admin_metadata(
                        client,
                        label=(record or {}).get('label'),
                        note=(record or {}).get('note'),
                    )

                    if record is not None and not identity_auth:
                        assigned = record.get('assigned_group_ids')
                        if assigned:
                            try:
                                validated = CREG.validate_assigned_group_ids(state, assigned)
                            except ValueError:
                                return 403, api_error(
                                    'enrollment references a group that no longer exists',
                                    'AUTH_FAILED',
                                )
                            _merged, added = CREG.merge_client_group_ids(client, validated)
                            for gid in added:
                                group = (state.get('groups') or {}).get(gid) or {}
                                _try_audit(
                                    'group.member_added',
                                    group_id=gid,
                                    group_name=group.get('name'),
                                    client_id=machine_id,
                                )

                    if client is None:
                        return 403, api_error('unknown client identity', 'AUTH_FAILED')
                    client['hostname'] = hostname or client.get('hostname', '')
                    client['last_enrolled_at'] = now_iso
                    if not isinstance(client.get('services'), dict):
                        client['services'] = {}
                    CREG.apply_observed_fields(
                        client,
                        hostname=hostname,
                        source_ip=source_ip,
                        seen_at=now_iso,
                    )
                    # last_mgmt_seen_at: only successful authenticated management
                    # (identity auth). Enrollment-only and failed auth must not refresh it.
                    if identity_auth:
                        CREG.apply_mgmt_seen(client, seen_at=now_iso)
                        CREG.apply_build_report(client, payload, seen_at=now_iso)
                    else:
                        # Seed build metadata on first enrollment when provided;
                        # subsequent updates happen on identity-auth management calls.
                        CREG.apply_build_report(client, payload, seen_at=now_iso)
                    CREG.seed_admin_metadata(
                        client,
                        label=(record or {}).get('label'),
                        note=(record or {}).get('note'),
                    )

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
                            'id': sid,
                            'name': spec['name'],
                            'protocol': 'tcp',
                            'local_ip': spec['local_ip'],
                            'local_port': spec['local_port'],
                            'remote_port': remote_port,
                            'preset': spec['preset'],
                            'enabled': True,
                        }
                        if spec['preset'] == 'ssh':
                            stored['ssh_user'] = spec['ssh_user']
                        updated[sid] = stored
                        allocated.append({
                            'id': sid,
                            'remote_port': remote_port,
                        })

                    client['services'] = updated
                    self.save_registry(state)
                    if record is not None and not identity_auth:
                        self.complete_bootstrap_for_enrollment(
                            record.get('id') or enrollment_id, machine_id
                        )
                    response_mac_key = client.get('mgmt_mac_key') if identity_auth else None
        except RegistrySchemaError as exc:
            print('allocator registry error: %s' % exc, flush=True)
            return 500, api_error(
                'registry schema is invalid', 'REGISTRY_INVALID'
            )
        except PortRangeExhausted as exc:
            print('allocator port range exhausted: %s' % exc, flush=True)
            return 500, api_error(
                'no free ports remain in the configured range',
                'PORT_RANGE_EXHAUSTED',
            )
        except OSError as exc:
            print('allocator persist error: %s' % exc, flush=True)
            return 500, api_error(
                'failed to persist registry', 'SERVER_MUTATION_FAILED'
            )
        except RuntimeError as exc:
            print('allocator runtime error: %s' % exc, flush=True)
            return 500, api_error(
                'internal server error', 'SERVER_MUTATION_FAILED'
            )

        response_payload = {
            'frp_server': cfg_public_host(self.cfg),
            'frp_server_port': cfg_frp_control_public_port(self.cfg),
            'frp_transport': cfg_frp_transport(self.cfg),
            'services': allocated,
            'server_time': int(time.time()),
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
        timeout = ALLOCATOR_REQUEST_TIMEOUT_SEC
        protocol_version = 'HTTP/1.1'

        def setup(self):
            super().setup()
            try:
                self.request.settimeout(ALLOCATOR_REQUEST_TIMEOUT_SEC)
            except OSError:
                pass

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

        def _with_slot(self, fn):
            acquired = _REQUEST_SLOTS.acquire(blocking=False)
            if not acquired:
                self.send_json(
                    503,
                    api_error('server is busy; retry later', 'SERVER_BUSY'),
                )
                return
            try:
                return fn()
            finally:
                _REQUEST_SLOTS.release()

        def do_GET(self):
            def _handle():
                path = self._request_path()
                if path == '/healthz':
                    self.send_json(200, {'status': 'ok'})
                    return
                if path == '/time':
                    self.send_json(200, {'server_time': int(time.time())})
                    return
                if path == '/ca.crt':
                    ca_path = allocator.cfg.get('tls_ca_cert')
                    if not ca_path or not Path(ca_path).is_file():
                        self.send_json(
                            500, {'error': 'CA certificate is not available'}
                        )
                        return
                    body = Path(ca_path).read_bytes()
                    self.send_response(200)
                    self.send_header('Content-Type', 'application/x-pem-file')
                    self.send_header('Content-Length', str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                    return
                self.send_json(404, {'error': 'not found'})

            self._with_slot(_handle)

        def do_POST(self):
            def _handle():
                path = self._request_path()
                if path == '/enroll/challenge':
                    enrollment_id = str(
                        self.headers.get('X-Enrollment-ID') or ''
                    ).strip()
                    payload, error = allocator.issue_enroll_challenge(
                        enrollment_id
                    )
                    if error:
                        self.send_json(
                            403,
                            api_error(error, classify_auth_error(error)),
                        )
                        return
                    self.send_json(200, payload)
                    return
                try:
                    length = int(self.headers.get('Content-Length', '0'))
                    if length <= 0 or length > 65536:
                        self.send_json(
                            400, {'error': 'invalid request body length'}
                        )
                        return
                    body = self.rfile.read(length)
                except Exception:
                    self.send_json(
                        400, {'error': 'invalid request body length'}
                    )
                    return
                try:
                    if path == '/enroll':
                        peer_host = ''
                        try:
                            peer_host = self.client_address[0]
                        except Exception:
                            peer_host = ''
                        code, result = allocator.enroll(
                            self.headers.get('X-Enrollment-ID', ''),
                            self.headers.get('X-Timestamp', ''),
                            self.headers.get('X-Signature', ''),
                            body,
                            headers=self.headers,
                            peer_host=peer_host,
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
                    print('allocator registry error: %s' % exc, flush=True)
                    self.send_json(
                        500,
                        api_error(
                            'registry schema is invalid', 'REGISTRY_INVALID'
                        ),
                    )
                except PortRangeExhausted as exc:
                    print(
                        'allocator port range exhausted: %s' % exc, flush=True
                    )
                    self.send_json(
                        500,
                        api_error(
                            'no free ports remain in the configured range',
                            'PORT_RANGE_EXHAUSTED',
                        ),
                    )
                except Exception as exc:
                    print('allocator request error: %s' % exc, flush=True)
                    self.send_json(
                        500,
                        api_error(
                            'internal server error', 'SERVER_MUTATION_FAILED'
                        ),
                    )

            self._with_slot(_handle)

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
    if SCFG is None:
        raise SystemExit('ERROR: frp_server_config.py is unavailable; refusing to start with unvalidated config')
    try:
        SCFG.validate_server_config(allocator.cfg)
    except ValueError as exc:
        raise SystemExit('ERROR: server configuration is unsafe: %s' % exc) from exc
    try:
        allocator.load_registry()
    except RegistrySchemaError as exc:
        raise SystemExit(f'ERROR: {exc}') from exc
    allocator.cleanup_expired_enrollments()
    plugin_srv = None
    plugin_mod = _load_lib_module('frp_plugin_server', 'frp_plugin_server.py')
    strict = allocator.cfg.get('data_plane_auth_strict', True) is True
    if strict and plugin_mod is None:
        raise SystemExit('ERROR: frp_plugin_server.py is unavailable; refusing strict data-plane auth')
    if plugin_mod is not None:
        try:
            phost, pport = plugin_mod.plugin_listen_from_cfg(allocator.cfg)
            plugin_srv, _plugin_thread = plugin_mod.start_plugin_server(
                allocator.load_registry,
                allocator.cfg,
                host=phost,
                port=pport,
            )
            print(
                'FRP data-plane authorizer listening on http://%s:%s/handler'
                % (phost, pport),
                flush=True,
            )
        except Exception as exc:
            if strict:
                raise SystemExit('ERROR: failed to start data-plane authorizer: %s' % exc) from exc
            print('WARNING: data-plane authorizer not started: %s' % exc, flush=True)
    host = allocator.cfg.get('listen_host', '0.0.0.0')
    port = cfg_allocator_listen_port(allocator.cfg)
    if port is None:
        raise SystemExit('ERROR: allocator_listen_port is not configured')
    # P3-AA: ThreadingHTTPServer still spawns a thread per accepted connection
    # before _REQUEST_SLOTS. Application concurrency, body size, and socket
    # timeouts remain bounded; a fully admission-controlled server is deferred
    # hardening (compatibility risk) rather than a P1 blocker.
    context = allocator_ssl_context(allocator.cfg)
    server = ThreadingHTTPServer((host, port), make_handler(allocator))
    server.socket = context.wrap_socket(server.socket, server_side=True)
    print(f'FRP allocator listening on https://{host}:{port}', flush=True)
    if plugin_mod is not None and hasattr(plugin_mod, 'systemd_notify_ready'):
        plugin_mod.systemd_notify_ready()
    server.serve_forever()


if __name__ == '__main__':
    main()
