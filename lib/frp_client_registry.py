#!/usr/bin/env python3
"""Client registry identity helpers.

Immutable identity is machine_id. Hostname is observed from the client.
label/note/tags/group_ids are server-owned and must survive re-enrollment.
"""
import ipaddress
import json
import os
import re
import secrets
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
GROUP_NAME_MAX_LEN = 64
GROUP_DESCRIPTION_MAX_LEN = 1024
GROUP_ID_PREFIX = 'grp_'
GROUP_ID_HEX_LEN = 8
RESERVED_GROUP_NAMES = frozenset({'all', 'ungrouped'})
SYSTEM_GROUP_ALL = 'all'
SYSTEM_GROUP_UNGROUPED = 'ungrouped'
LABEL_RE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._ -]{0,63}$')
TAG_KEY_RE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')
TAG_VALUE_RE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._:/@+ -]{0,127}$')
GROUP_NAME_RE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')
GROUP_ID_RE = re.compile(r'^grp_[0-9a-f]{8}$')


class ClientLookupError(Exception):
    def __init__(self, message, matches=None):
        super().__init__(message)
        self.matches = list(matches or [])


class GroupLookupError(Exception):
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


def unique_short_id(machine_id, all_ids, min_len=SHORT_MACHINE_ID_LEN):
    """Shortest unique prefix of machine_id, at least min_len characters."""
    text = str(machine_id or '')
    if not text:
        return ''
    others = [str(item) for item in (all_ids or []) if str(item)]
    length = min(max(int(min_len), 1), len(text))
    while length <= len(text):
        prefix = text[:length]
        matches = [item for item in others if item.startswith(prefix)]
        if len(matches) == 1:
            return prefix
        length += 1
    return text


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
        '%-10s %-18s %s' % ('CLIENT ID', 'LABEL', 'HOSTNAME'),
    ]
    mids = [item[0] for item in matches]
    for mid, client in matches:
        cid = sanitize_display(unique_short_id(mid, mids), 16)
        label = sanitize_display(client.get('label') or '-', 18)
        host = sanitize_display(client.get('hostname') or '-', 12)
        lines.append('%-10s %-18s %s' % (cid, label, host))
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


def resolve_client_id_only(state, query):
    """Resolve by immutable CLIENT ID only (exact registry key or unique short id).

    Labels, hostnames, and arbitrary machine-id prefixes are rejected. Mutation
    tools must use this; read-only tools may keep resolve_client shortcuts.
    """
    query = '' if query is None else str(query).strip()
    if not query:
        raise ClientLookupError('client identifier is required')
    clients = sorted_clients(state)
    by_id = {mid: client for mid, client in clients}
    if query in by_id:
        return query, by_id[query]
    all_mids = list(by_id)
    short_matches = [
        (mid, by_id[mid])
        for mid in all_mids
        if unique_short_id(mid, all_mids) == query
    ]
    if len(short_matches) == 1:
        return short_matches[0]
    raise ClientLookupError('mutation requires immutable client id')


def resolve_client_or_exit(state, query):
    try:
        return resolve_client(state, query)
    except ClientLookupError as exc:
        if exc.matches:
            sys.stderr.write('ERROR: multiple clients matched.\n\n')
            sys.stderr.write(format_candidate_table(exc.matches))
            sys.stderr.write('\nUse a longer CLIENT ID prefix.\n')
        elif str(exc) == 'client not found':
            shown = sanitize_display(query, 128)
            sys.stderr.write('ERROR: client not found: %s\n' % shown)
            sys.stderr.write('\nUse a CLIENT ID, unique label, or unique hostname.\n')
            sys.stderr.write('Run:\n  show clients\n\nor:\n  show client ?\n')
        else:
            sys.stderr.write('ERROR: %s\n' % exc)
        raise SystemExit(1)


def resolve_client_id_only_or_exit(state, query):
    try:
        return resolve_client_id_only(state, query)
    except ClientLookupError:
        sys.stderr.write('ERROR: mutation commands require immutable CLIENT ID.\n')
        sys.stderr.write("Use 'show clients' to find the CLIENT ID.\n")
        raise SystemExit(1)


def seed_admin_metadata(client, label=None, note=None):
    """Set label/note only when empty; never modify server-owned tags or groups."""
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


def is_system_group_selector(query):
    return str(query or '').strip().lower() in (SYSTEM_GROUP_ALL, SYSTEM_GROUP_UNGROUPED)


def system_group_meta(name):
    text = str(name or '').strip().lower()
    return {'name': text, 'type': 'system'}


def group_record_type(group):
    gtype = str((group or {}).get('type') or 'manual').strip().lower()
    if gtype in ('manual', 'dynamic', 'system'):
        return gtype
    return 'manual'


def normalize_match_tags(value):
    if value is None:
        return {}
    if isinstance(value, dict):
        items = list(value.items())
    elif isinstance(value, list):
        items = []
        for item in value:
            if isinstance(item, dict) and 'key' in item:
                items.append((item.get('key'), item.get('value')))
            else:
                raise ValueError('invalid dynamic group selector')
    else:
        raise ValueError('match_tags must be an object')
    out = {}
    for key, val in items:
        tag_key, tag_value = validate_tag_key(key), validate_tag_value(val)
        if tag_key in out and out[tag_key] != tag_value:
            raise ValueError('duplicate conflicting tag selector for %s' % tag_key)
        out[tag_key] = tag_value
    return out


def client_matches_dynamic_group(client, group):
    try:
        filters = normalize_match_tags((group or {}).get('match_tags'))
    except ValueError:
        return False
    if not filters:
        return False
    return client_matches_tags(client, list(filters.items()))


def client_in_any_manual_group(state, client):
    return bool(client_group_ids(client))


def client_in_any_dynamic_group(state, client):
    for _gid, group in sorted_groups(state):
        if group_record_type(group) == 'dynamic' and client_matches_dynamic_group(client, group):
            return True
    return False


def client_is_ungrouped(state, client):
    return (
        not client_in_any_manual_group(state, client)
        and not client_in_any_dynamic_group(state, client)
    )


def client_matches_group_selector(state, client, selector):
    if selector == SYSTEM_GROUP_ALL:
        return True
    if selector == SYSTEM_GROUP_UNGROUPED:
        return client_is_ungrouped(state, client)
    groups = ensure_groups_map(state)
    group = groups.get(selector)
    if not isinstance(group, dict):
        return False
    if group_record_type(group) == 'dynamic':
        return client_matches_dynamic_group(client, group)
    try:
        return validate_group_id(selector) in normalize_group_ids((client or {}).get('group_ids'))
    except ValueError:
        return False


def client_group_memberships(state, client):
    manual = []
    dynamic = []
    groups = ensure_groups_map(state)
    for gid in client_group_ids(client):
        group = groups.get(gid)
        if isinstance(group, dict):
            manual.append((gid, group))
    for gid, group in sorted_groups(state):
        if group_record_type(group) == 'dynamic' and client_matches_dynamic_group(client, group):
            dynamic.append((gid, group))
    return manual, dynamic


def validate_assigned_group_ids(state, group_ids):
    ids = normalize_group_ids(group_ids)
    groups = ensure_groups_map(state)
    for gid in ids:
        if gid not in groups:
            raise ValueError('group not found: %s' % gid)
        if group_record_type(groups[gid]) != 'manual':
            raise ValueError('only manual groups may be assigned at enrollment')
    return ids


def resolve_group_ids_for_assignment(state, queries):
    out = []
    seen = set()
    for query in queries or []:
        gid, group = resolve_group(state, query)
        if gid in (SYSTEM_GROUP_ALL, SYSTEM_GROUP_UNGROUPED):
            raise ValueError('system groups cannot be assigned at enrollment')
        if group_record_type(group) != 'manual':
            raise ValueError('only manual groups may be assigned at enrollment')
        if gid not in seen:
            seen.add(gid)
            out.append(gid)
    return out


def merge_client_group_ids(client, new_ids):
    existing = normalize_group_ids(client.get('group_ids'))
    added = []
    merged = list(existing)
    for gid in normalize_group_ids(new_ids):
        if gid not in merged:
            merged.append(gid)
            added.append(gid)
    set_client_group_ids(client, merged)
    return merged, added


def resolve_mutable_group(state, query):
    gid, group = resolve_group(state, query)
    if gid in (SYSTEM_GROUP_ALL, SYSTEM_GROUP_UNGROUPED) or group_record_type(group) == 'system':
        raise GroupLookupError('system groups cannot be modified')
    return gid, group


def resolve_mutable_group_or_exit(state, query):
    try:
        return resolve_mutable_group(state, query)
    except GroupLookupError as exc:
        sys.stderr.write('ERROR: %s\n' % exc)
        raise SystemExit(1)


def resolve_manual_group(state, query):
    gid, group = resolve_group(state, query)
    if gid in (SYSTEM_GROUP_ALL, SYSTEM_GROUP_UNGROUPED):
        raise GroupLookupError('system groups cannot be used for membership assignment')
    if group_record_type(group) != 'manual':
        raise GroupLookupError('only manual groups support explicit membership')
    return gid, group


def resolve_manual_group_or_exit(state, query):
    try:
        return resolve_manual_group(state, query)
    except GroupLookupError as exc:
        if exc.matches:
            sys.stderr.write('ERROR: multiple groups matched.\n\n')
            sys.stderr.write(format_group_candidate_table(exc.matches))
        else:
            sys.stderr.write('ERROR: %s\n' % exc)
        raise SystemExit(1)


def is_reserved_group_name(name):
    text = '' if name is None else str(name).strip().lower()
    return text in RESERVED_GROUP_NAMES


def validate_group_name(value, required=True):
    text = '' if value is None else str(value).strip()
    if not text:
        if required:
            raise ValueError('group name is required')
        return ''
    if any(ord(ch) < 32 or 127 <= ord(ch) <= 159 for ch in text):
        raise ValueError('group name must not contain control characters')
    if len(text) > GROUP_NAME_MAX_LEN:
        raise ValueError('group name must be at most %s characters' % GROUP_NAME_MAX_LEN)
    if not GROUP_NAME_RE.fullmatch(text):
        raise ValueError(
            'group name must start with an alphanumeric character '
            'and may contain letters, digits, ".", "_" and "-"'
        )
    if is_reserved_group_name(text):
        raise ValueError('group name %r is reserved for system groups' % text)
    return text


def validate_group_description(value):
    return validate_text_field(value, 'group description', GROUP_DESCRIPTION_MAX_LEN)


def validate_group_id(value, required=True):
    text = '' if value is None else str(value).strip()
    if not text:
        if required:
            raise ValueError('group id is required')
        return ''
    if not GROUP_ID_RE.fullmatch(text):
        raise ValueError('group id must match grp_<8 lowercase hex>')
    return text


def ensure_groups_map(state):
    """Return the groups map, normalizing a missing key to {} without writing."""
    if not isinstance(state, dict):
        return {}
    groups = state.get('groups')
    if groups is None:
        return {}
    if not isinstance(groups, dict):
        raise ValueError('registry groups must be an object')
    return groups


def normalize_group_ids(value):
    """Return a de-duplicated list of group ids; raise on malformed input."""
    if value is None:
        return []
    if not isinstance(value, list):
        raise ValueError('client group_ids must be a list')
    out = []
    seen = set()
    for item in value:
        gid = validate_group_id(item)
        if gid in seen:
            continue
        seen.add(gid)
        out.append(gid)
    return out


def client_group_ids(client):
    try:
        return normalize_group_ids((client or {}).get('group_ids'))
    except ValueError:
        return []


def generate_group_id(existing_ids=None):
    existing = set(str(item) for item in (existing_ids or []))
    for _ in range(64):
        gid = '%s%s' % (GROUP_ID_PREFIX, secrets.token_hex(GROUP_ID_HEX_LEN // 2))
        if gid not in existing:
            return gid
    raise RuntimeError('unable to allocate unique group id')


def sorted_groups(state):
    groups = ensure_groups_map(state)
    items = []
    for gid, group in groups.items():
        if not isinstance(group, dict):
            continue
        items.append((str(gid), group))
    items.sort(key=lambda kv: (str(kv[1].get('name') or '').lower(), kv[0]))
    return items


def format_group_candidate_table(matches):
    lines = [
        '%-14s %-24s %s' % ('GROUP ID', 'NAME', 'TYPE'),
    ]
    for gid, group in matches:
        name = sanitize_display((group or {}).get('name') or '-', 24)
        gtype = sanitize_display((group or {}).get('type') or 'manual', 12)
        lines.append('%-14s %-24s %s' % (
            sanitize_display(gid, 14),
            name,
            gtype,
        ))
    return '\n'.join(lines) + '\n'


def resolve_group(state, query):
    """Resolve by GROUP ID (exact), unique group name, or system group. Ambiguous => fail closed."""
    query = '' if query is None else str(query).strip()
    if not query:
        raise GroupLookupError('group identifier is required')
    lower = query.lower()
    if lower in (SYSTEM_GROUP_ALL, SYSTEM_GROUP_UNGROUPED):
        return lower, system_group_meta(lower)
    groups = sorted_groups(state)
    by_id = {gid: group for gid, group in groups}
    if query in by_id:
        return query, by_id[query]

    name_matches = [
        item for item in groups
        if str(item[1].get('name') or '').strip() == query
    ]
    if len(name_matches) == 1:
        return name_matches[0]
    if len(name_matches) > 1:
        raise GroupLookupError('multiple groups matched', name_matches)

    raise GroupLookupError('group not found')


def resolve_group_or_exit(state, query):
    try:
        return resolve_group(state, query)
    except GroupLookupError as exc:
        if exc.matches:
            sys.stderr.write('ERROR: multiple groups matched.\n\n')
            sys.stderr.write(format_group_candidate_table(exc.matches))
            sys.stderr.write('\nUse an immutable GROUP ID.\n')
        elif str(exc) == 'group not found':
            shown = sanitize_display(query, 128)
            sys.stderr.write('ERROR: group not found: %s\n' % shown)
            sys.stderr.write('\nUse a GROUP ID or unique group name.\n')
            sys.stderr.write('Run:\n  show groups\n')
        else:
            sys.stderr.write('ERROR: %s\n' % exc)
        raise SystemExit(1)


def find_group_id_by_name(state, name, exclude_id=None):
    """Return existing group id with the same exact name, or None."""
    want = '' if name is None else str(name).strip()
    if not want:
        return None
    for gid, group in sorted_groups(state):
        if exclude_id is not None and gid == exclude_id:
            continue
        if str(group.get('name') or '').strip() == want:
            return gid
    return None


def clients_in_group(state, group_selector):
    query = str(group_selector or '').strip()
    if is_system_group_selector(query):
        selector = query.lower()
    else:
        try:
            selector = validate_group_id(query)
        except ValueError:
            gid, _group = resolve_group(state, query)
            selector = gid
    out = []
    for mid, client in sorted_clients(state):
        if client_matches_group_selector(state, client, selector):
            out.append((mid, client))
    return out


def client_matches_group(client, group_id):
    """Manual membership only (legacy helper). Prefer client_matches_group_selector()."""
    try:
        return validate_group_id(group_id) in normalize_group_ids((client or {}).get('group_ids'))
    except ValueError:
        return False


def group_member_count(state, group_selector):
    return len(clients_in_group(state, group_selector))


def set_client_group_ids(client, group_ids):
    ids = normalize_group_ids(group_ids)
    if ids:
        client['group_ids'] = ids
    else:
        client.pop('group_ids', None)
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


def apply_mgmt_seen(client, seen_at=None):
    """Record successful authenticated management communication (server clock)."""
    if not isinstance(client, dict):
        return client
    client['last_mgmt_seen_at'] = seen_at or utc_now_iso()
    return client


BUILD_REPORT_KEYS = (
    'reported_project_version',
    'reported_release_channel',
    'reported_source_ref',
    'reported_bundle_sha256',
    'reported_frp_version',
)


def apply_build_report(client, payload, seen_at=None):
    """Store client-reported build metadata from an authenticated request."""
    if not isinstance(client, dict) or not isinstance(payload, dict):
        return client
    when = seen_at or utc_now_iso()
    updated = False
    for key in BUILD_REPORT_KEYS:
        short = key.replace('reported_', '')
        val = payload.get(key)
        if val is None:
            val = payload.get(short)
        if val is None:
            continue
        text = str(val).strip()
        if not text:
            continue
        client[key] = text
        updated = True
    if updated:
        client['build_reported_at'] = when
    return client


def parse_iso_timestamp(value):
    text = str(value or '').strip()
    if not text:
        return None
    if text.endswith('Z'):
        text = text[:-1] + '+00:00'
    try:
        dt = datetime.fromisoformat(text)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


DURATION_RE = re.compile(r'^([0-9]+)([hd])$', re.IGNORECASE)


def parse_duration(value):
    text = str(value or '').strip().lower()
    if not text:
        raise ValueError('duration required')
    match = DURATION_RE.fullmatch(text)
    if not match:
        raise ValueError('invalid duration; use 24h or 30d')
    amount = int(match.group(1))
    unit = match.group(2).lower()
    if amount < 1:
        raise ValueError('duration must be positive')
    if unit == 'h':
        if amount > 8760:
            raise ValueError('duration too large')
        return amount * 3600
    if unit == 'd':
        if amount > 3650:
            raise ValueError('duration too large')
        return amount * 86400
    raise ValueError('invalid duration unit')


def mgmt_activity_class(client, stale_seconds):
    """Classify management activity: recent, stale, unknown. Not tunnel state."""
    if not isinstance(client, dict):
        return 'unknown'
    if mgmt_status(client) == 'revoked':
        return 'revoked'
    ts = parse_iso_timestamp(client.get('last_mgmt_seen_at'))
    if ts is None:
        return 'unknown'
    age = (datetime.now(timezone.utc) - ts).total_seconds()
    if age <= stale_seconds:
        return 'recent'
    return 'stale'


def load_server_version_metadata(root=None):
    root = root if root is not None else os.environ.get('FRP_DEPLOY_TEST_ROOT', '')
    path = Path(str(root) + '/etc/frp-auto-deploy/version')
    out = {}
    if not path.is_file():
        return out
    for line in path.read_text(encoding='utf-8').splitlines():
        if '=' not in line:
            continue
        key, val = line.split('=', 1)
        out[key.strip()] = val.strip()
    return out


def build_drift_class(client, expected=None):
    """Compare reported client build to server expected build metadata."""
    if not isinstance(client, dict):
        return 'unknown'
    reported_at = client.get('build_reported_at')
    project = str(client.get('reported_project_version') or '').strip()
    if not project and not reported_at:
        return 'unknown'
    expected = expected or load_server_version_metadata()
    exp_project = str(expected.get('PROJECT_VERSION') or '').strip()
    exp_channel = str(expected.get('RELEASE_CHANNEL') or '').strip()
    exp_ref = str(expected.get('SOURCE_REF') or '').strip()
    exp_bundle = str(expected.get('BUNDLE_SHA256') or '').strip()
    exp_frp = str(expected.get('FRP_VERSION') or '').strip()
    if not exp_project:
        return 'unknown' if project else 'unknown'
    drift = False
    if project and exp_project and project != exp_project:
        drift = True
    channel = str(client.get('reported_release_channel') or '').strip()
    if channel and exp_channel and channel != exp_channel:
        drift = True
    ref = str(client.get('reported_source_ref') or '').strip()
    if ref and exp_ref and ref != exp_ref:
        drift = True
    bundle = str(client.get('reported_bundle_sha256') or '').strip()
    if bundle and exp_bundle and bundle != exp_bundle:
        drift = True
    frp = str(client.get('reported_frp_version') or '').strip()
    if frp and exp_frp and frp != exp_frp:
        drift = True
    if drift:
        return 'drift'
    if project:
        return 'current'
    return 'unknown'


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
