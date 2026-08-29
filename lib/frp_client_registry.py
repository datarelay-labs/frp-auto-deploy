#!/usr/bin/env python3
"""Client registry identity helpers.

Immutable identity is machine_id. Hostname is observed from the client.
label/note/tags are server-owned and must survive re-enrollment.
"""
import ipaddress
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

LABEL_MAX_LEN = 64
NOTE_MAX_LEN = 1024
HOSTNAME_MAX_LEN = 253
TAG_KEY_MAX_LEN = 64
TAG_VALUE_MAX_LEN = 128
SHORT_MACHINE_ID_LEN = 8
LABEL_RE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._ -]{0,63}$')
TAG_KEY_RE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')
TAG_VALUE_RE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._:/@+ -]{0,127}$')


class ClientLookupError(Exception):
    def __init__(self, message, matches=None):
        super().__init__(message)
        self.matches = list(matches or [])


def utc_now_iso():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace('+00:00', 'Z')


def header_get(headers, name):
    if headers is None:
        return ''
    getter = getattr(headers, 'get', None)
    if getter is None:
        return ''
    value = getter(name)
    if value is None:
        try:
            value = getter(name.lower())
        except Exception:
            value = None
    if value is None:
        return ''
    if isinstance(value, (list, tuple)):
        value = value[0] if value else ''
    return str(value).strip()


def normalize_ip(value):
    if value is None:
        return None
    text = str(value).strip()
    if not text:
        return None
    if text.startswith('[') and ']' in text:
        text = text[1:text.index(']')]
    if '%' in text:
        text = text.split('%', 1)[0]
    try:
        ip = ipaddress.ip_address(text)
    except ValueError:
        return None
    if isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped is not None:
        ip = ip.ipv4_mapped
    return str(ip)


def is_loopback_ip(value):
    parsed = normalize_ip(value)
    if parsed is None:
        return False
    return ipaddress.ip_address(parsed).is_loopback


def first_forwarded_ip(value):
    if value is None:
        return None
    for part in str(value).split(','):
        parsed = normalize_ip(part)
        if parsed is not None:
            return parsed
    return None


def request_source_ip(peer_host, headers=None):
    """Return the observed request source IP.

    Trust X-Forwarded-For only when the TCP peer is loopback (nginx on
    single443). Otherwise use the socket peer. Never use source IP as
    identity.
    """
    peer = normalize_ip(peer_host)
    if peer is not None and is_loopback_ip(peer):
        forwarded = first_forwarded_ip(header_get(headers, 'X-Forwarded-For'))
        if forwarded is None:
            forwarded = first_forwarded_ip(header_get(headers, 'X-Real-IP'))
        if forwarded is not None:
            return forwarded
    return peer


def sanitize_display(value, max_len=None):
    text = '' if value is None else str(value)
    cleaned = []
    for ch in text:
        if ord(ch) < 32 or 127 <= ord(ch) <= 159:
            cleaned.append(' ')
        else:
            cleaned.append(ch)
    out = ''.join(cleaned).strip()
    if max_len is not None and len(out) > int(max_len):
        out = out[: int(max_len)]
    return out


def validate_text_field(value, field, max_len, required=False):
    """Validate stored/displayed text while preserving normal Unicode."""
    text = '' if value is None else str(value).strip()
    if not text:
        if required:
            raise ValueError('%s is required' % field)
        return ''
    if len(text) > int(max_len):
        raise ValueError('%s must be at most %s characters' % (field, max_len))
    if any(ord(ch) < 32 or 127 <= ord(ch) <= 159 for ch in text):
        raise ValueError('%s must not contain control characters' % field)
    return text


def validate_hostname(value, required=False):
    return validate_text_field(value, 'hostname', HOSTNAME_MAX_LEN, required=required)


def ssh_user_display(service):
    user = sanitize_display((service or {}).get('ssh_user') or '', 32)
    return user if user else 'legacy / unspecified'


def passive_listening_ports():
    """Return (ports, known) from ss without connecting to any socket."""
    binary = shutil.which('ss')
    if not binary:
        return set(), False
    for args in ([binary, '-H', '-lnt'], [binary, '-lnt']):
        try:
            proc = subprocess.run(
                args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                timeout=5, check=False, universal_newlines=True,
            )
        except (OSError, subprocess.TimeoutExpired):
            continue
        if proc.returncode != 0:
            continue
        ports = set()
        for line in proc.stdout.splitlines():
            fields = line.split()
            if not fields or fields[0] in ('State', 'Netid'):
                continue
            for field in fields:
                match = re.search(r':(\d+)$', field.rstrip(']'))
                if match:
                    port = int(match.group(1))
                    if 1 <= port <= 65535:
                        ports.add(port)
                    break
        return ports, True
    return set(), False


def passive_port_state(port, snapshot=None):
    try:
        port = int(port)
    except (TypeError, ValueError):
        return 'unknown'
    ports, known = snapshot if snapshot is not None else passive_listening_ports()
    if not known:
        return 'unknown'
    return 'online' if port in ports else 'offline'


def validate_label(value, required=False):
    text = '' if value is None else str(value).strip()
    if not text:
        if required:
            raise ValueError('client name/label is required')
        return ''
    if any(ord(c) < 32 or 127 <= ord(c) <= 159 for c in text):
        raise ValueError('client name/label must not contain control characters')
    if len(text) > LABEL_MAX_LEN:
        raise ValueError('client name/label must be at most %s characters' % LABEL_MAX_LEN)
    if not LABEL_RE.fullmatch(text):
        raise ValueError(
            'client name/label must start with an alphanumeric character '
            'and may contain letters, digits, space, ".", "_" and "-"'
        )
    return text


def validate_note(value):
    return validate_text_field(value, 'note', NOTE_MAX_LEN)


def validate_tag_key(value):
    text = '' if value is None else str(value).strip()
    if not text:
        raise ValueError('tag key is required')
    if any(ord(ch) < 32 or 127 <= ord(ch) <= 159 for ch in text):
        raise ValueError('tag key must not contain control characters')
    if len(text) > TAG_KEY_MAX_LEN:
        raise ValueError('tag key must be at most %s characters' % TAG_KEY_MAX_LEN)
    if not TAG_KEY_RE.fullmatch(text):
        raise ValueError(
            'tag key must start with an alphanumeric character '
            'and may contain letters, digits, ".", "_" and "-"'
        )
    return text


def validate_tag_value(value):
    text = '' if value is None else str(value).strip()
    if not text:
        raise ValueError('tag value is required')
    if any(ord(ch) < 32 or 127 <= ord(ch) <= 159 for ch in text):
        raise ValueError('tag value must not contain control characters')
    if len(text) > TAG_VALUE_MAX_LEN:
        raise ValueError('tag value must be at most %s characters' % TAG_VALUE_MAX_LEN)
    if not TAG_VALUE_RE.fullmatch(text):
        raise ValueError(
            'tag value must start with an alphanumeric character and may contain '
            'letters, digits, space, ".", "_", ":", "/", "@", "+", and "-"'
        )
    return text


def parse_tag_assignment(value):
    text = '' if value is None else str(value)
    if '=' not in text:
        raise ValueError('tag must use key=value format')
    key, tag_value = text.split('=', 1)
    return validate_tag_key(key), validate_tag_value(tag_value)


def client_matches_tags(client, filters):
    tags = (client or {}).get('tags') or {}
    if not isinstance(tags, dict):
        return False
    return all(tags.get(key) == value for key, value in filters)


def short_machine_id(machine_id, length=SHORT_MACHINE_ID_LEN):
    text = str(machine_id or '')
    if len(text) <= length:
        return text
    return text[:length]


def display_name(client, machine_id):
    if not isinstance(client, dict):
        client = {}
    label = str(client.get('label') or '').strip()
    if label:
        return label
    hostname = str(client.get('hostname') or '').strip()
    if hostname:
        return hostname
    return short_machine_id(machine_id)


def mgmt_status(client):
    if not isinstance(client, dict):
        return 'legacy'
    status = client.get('mgmt_status')
    if status in ('enrolled', 'legacy', 'revoked'):
        return status
    if client.get('mgmt_pubkey'):
        return 'enrolled'
    return 'legacy'


def enabled_services(client):
    services = (client or {}).get('services') or {}
    if not isinstance(services, dict):
        return []
    items = []
    for sid, svc in services.items():
        if not isinstance(svc, dict):
            continue
        if svc.get('enabled', True) is False:
            continue
        items.append((sid, svc))
    return sorted(
        items,
        key=lambda kv: (
            kv[1].get('remote_port') is None,
            kv[1].get('remote_port') or 0,
            kv[0],
        ),
    )


def first_ssh_service(client):
    for sid, svc in enabled_services(client):
        if str(svc.get('preset') or '').strip().lower() == 'ssh':
            return sid, svc
    return None, None


def sorted_clients(state):
    items = []
    for mid, client in ((state or {}).get('clients') or {}).items():
        if not isinstance(client, dict):
            continue
        items.append((str(mid), client))
    items.sort(key=lambda kv: (display_name(kv[1], kv[0]).lower(), kv[0]))
    return items


def format_candidate_table(matches):
    lines = [
        '%-18s %-12s %s' % ('LABEL', 'HOSTNAME', 'CLIENT ID'),
    ]
    for mid, client in matches:
        label = sanitize_display(client.get('label') or '-', 18)
        host = sanitize_display(client.get('hostname') or '-', 12)
        lines.append('%-18s %-12s %s' % (label, host, short_machine_id(mid)))
    return '\n'.join(lines) + '\n'


def resolve_client(state, query):
    query = '' if query is None else str(query).strip()
    if not query:
        raise ClientLookupError('client identifier is required')
    clients = sorted_clients(state)

    label_matches = [
        item for item in clients
        if str(item[1].get('label') or '').strip() == query
    ]
    if len(label_matches) == 1:
        return label_matches[0]
    if len(label_matches) > 1:
        raise ClientLookupError('multiple clients matched', label_matches)

    host_matches = [
        item for item in clients
        if str(item[1].get('hostname') or '').strip() == query
    ]
    if len(host_matches) == 1:
        return host_matches[0]
    if len(host_matches) > 1:
        raise ClientLookupError('multiple clients matched', host_matches)

    mid_matches = [
        item for item in clients
        if item[0] == query or item[0].startswith(query)
    ]
    if len(mid_matches) == 1:
        return mid_matches[0]
    if len(mid_matches) > 1:
        raise ClientLookupError('multiple clients matched', mid_matches)

    raise ClientLookupError('client not found')


def resolve_client_or_exit(state, query):
    try:
        return resolve_client(state, query)
    except ClientLookupError as exc:
        if exc.matches:
            sys.stderr.write('ERROR: multiple clients matched.\n\n')
            sys.stderr.write(format_candidate_table(exc.matches))
            sys.stderr.write('\nUse the label or a longer machine-id prefix.\n')
        elif str(exc) == 'client not found':
            sys.stderr.write('ERROR: client not found.\n')
        else:
            sys.stderr.write('ERROR: %s\n' % exc)
        raise SystemExit(1)


def seed_admin_metadata(client, label=None, note=None):
    """Set label/note only when empty; never modify server-owned tags."""
    if not isinstance(client, dict):
        return client
    incoming_label = str(label or '').strip()
    incoming_note = str(note or '').strip()
    existing_label = str(client.get('label') or '').strip()
    existing_note = str(client.get('note') or '').strip()
    if incoming_label and not existing_label:
        client['label'] = incoming_label
    if incoming_note and not existing_note:
        client['note'] = incoming_note
    return client


def apply_observed_fields(client, hostname=None, source_ip=None, seen_at=None):
    if not isinstance(client, dict):
        return client
    host = validate_hostname(hostname)
    if host:
        client['hostname'] = host
    when = seen_at or utc_now_iso()
    client['last_seen_at'] = when
    ip = normalize_ip(source_ip) if source_ip else None
    if ip:
        if not str(client.get('first_seen_ip') or '').strip():
            client['first_seen_ip'] = ip
        client['last_source_ip'] = ip
    return client


def atomic_write_json(path, data, mode=0o600):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=path.name + '.', suffix='.tmp', dir=str(path.parent))
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as fh:
            json.dump(data, fh, indent=2, sort_keys=True)
            fh.write('\n')
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            try:
                os.unlink(tmp)
            except OSError:
                pass
    try:
        path.chmod(mode)
    except OSError:
        pass


def load_server_registry(root=None):
    if root is None:
        root = os.environ.get('FRP_DEPLOY_TEST_ROOT', '')
    cfg_path = Path(str(root) + '/etc/frp-auto-deploy/config.json')
    cfg = json.loads(cfg_path.read_text(encoding='utf-8'))
    path = Path(cfg['registry_file'])
    if root and not str(path).startswith(str(root)):
        path = Path(str(root) + str(path))
    state = json.loads(path.read_text(encoding='utf-8')) if path.exists() else {
        'schema_version': 2,
        'clients': {},
    }
    return cfg, path, state
