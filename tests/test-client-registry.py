#!/usr/bin/env python3
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'lib'))
import frp_client_registry as creg  # noqa: E402


def pass_(name):
    print('PASS %s' % name)


def fail(name, detail=''):
    print('FAIL %s %s' % (name, detail), file=sys.stderr)
    raise SystemExit(1)


def test_source_ip():
    if creg.request_source_ip('203.0.113.10', {'X-Forwarded-For': '1.2.3.4'}) != '203.0.113.10':
        fail('direct ignores XFF')
    if creg.request_source_ip('203.0.113.10', {'X-Real-IP': '1.2.3.4'}) != '203.0.113.10':
        fail('direct ignores X-Real-IP')
    if creg.request_source_ip('127.0.0.1', {'X-Forwarded-For': '198.51.100.9'}) != '198.51.100.9':
        fail('loopback trusts XFF')
    if creg.request_source_ip('127.0.0.1', {'X-Real-IP': '198.51.100.11'}) != '198.51.100.11':
        fail('loopback trusts X-Real-IP')
    if creg.request_source_ip(
        '127.0.0.1',
        {'X-Forwarded-For': '198.51.100.9', 'X-Real-IP': '203.0.113.1'},
    ) != '198.51.100.9':
        fail('XFF preferred over X-Real-IP')
    if creg.request_source_ip('::1', {'X-Forwarded-For': '2001:db8::1'}) != '2001:db8::1':
        fail('v6 loopback trusts XFF')
    if creg.request_source_ip('127.0.0.1', {'X-Forwarded-For': 'not-an-ip'}) != '127.0.0.1':
        fail('malformed XFF ignored')
    if creg.request_source_ip('::ffff:127.0.0.1', {'X-Forwarded-For': '203.0.113.8'}) != '203.0.113.8':
        fail('mapped loopback')
    if creg.request_source_ip('10.0.0.5', {'X-Forwarded-For': '198.51.100.9'}) != '10.0.0.5':
        fail('non-loopback private peer ignores XFF')
    pass_('SOURCE_IP_TRUST_BOUNDARY')


def test_display_and_match():
    state = {
        'schema_version': 2,
        'clients': {
            'aabbccdd00112233': {
                'hostname': 'ubuntu',
                'label': 'seoul-web01',
                'note': 'office',
            },
            'ddeeff0011223344': {
                'hostname': 'ubuntu',
                'label': 'busan-backup',
            },
            '0303cedf99999999': {
                'hostname': 'aella',
            },
        },
    }
    if creg.display_name(state['clients']['0303cedf99999999'], '0303cedf99999999') != 'aella':
        fail('fallback hostname')
    mid, client = creg.resolve_client(state, 'seoul-web01')
    if mid != 'aabbccdd00112233':
        fail('label lookup', mid)
    try:
        creg.resolve_client(state, 'ubuntu')
        fail('duplicate hostname should be ambiguous')
    except creg.ClientLookupError as exc:
        if len(exc.matches) != 2:
            fail('ambiguous candidates', exc.matches)
    mid, client = creg.resolve_client(state, '0303cedf')
    if mid != '0303cedf99999999':
        fail('prefix lookup', mid)
    ids = ['abcdabcd11112222', 'abcdabcd99998888', '24cd7856aabbccdd']
    if creg.unique_short_id('24cd7856aabbccdd', ids) != '24cd7856':
        fail('unique short id')
    if creg.unique_short_id('abcdabcd11112222', ids) != 'abcdabcd1':
        fail('longer unique prefix', creg.unique_short_id('abcdabcd11112222', ids))
    amb = {
        'schema_version': 2,
        'clients': {
            'abcdabcd11112222': {'hostname': 'amb-one'},
            'abcdabcd99998888': {'hostname': 'amb-two'},
        },
    }
    try:
        creg.resolve_client(amb, 'abcdabcd')
        fail('ambiguous prefix should fail closed')
    except creg.ClientLookupError as exc:
        if len(exc.matches) != 2:
            fail('ambiguous prefix candidates', exc.matches)
    pass_('LABEL_HOSTNAME_PREFIX_LOOKUP')
    pass_('CLIENT_ID_UNIQUE_SHORT')


def test_mutation_id_only():
    state = {
        'schema_version': 2,
        'clients': {
            'aabbccdd00112233': {
                'hostname': 'ubuntu',
                'label': 'seoul-web01',
            },
            '0303cedf99999999': {
                'hostname': 'aella',
                'label': 'lab',
            },
        },
    }
    mid, _client = creg.resolve_client_id_only(state, 'aabbccdd00112233')
    if mid != 'aabbccdd00112233':
        fail('exact full id', mid)
    mid, _client = creg.resolve_client_id_only(state, 'aabbccdd')
    if mid != 'aabbccdd00112233':
        fail('unique short id', mid)
    for bad in ('seoul-web01', 'ubuntu', 'aella', 'lab', '0303', 'aa'):
        try:
            creg.resolve_client_id_only(state, bad)
            fail('mutation accepted non-id', bad)
        except creg.ClientLookupError:
            pass
    # After label rename, neither old nor new label mutates
    state['clients']['aabbccdd00112233']['label'] = 'production'
    for bad in ('seoul-web01', 'production'):
        try:
            creg.resolve_client_id_only(state, bad)
            fail('label still mutates', bad)
        except creg.ClientLookupError:
            pass
    mid, _client = creg.resolve_client_id_only(state, 'aabbccdd00112233')
    if mid != 'aabbccdd00112233':
        fail('id still works after label change', mid)
    # Read-only shortcuts still work
    mid, _client = creg.resolve_client(state, 'production')
    if mid != 'aabbccdd00112233':
        fail('read-only label', mid)
    mid, _client = creg.resolve_client(state, 'aella')
    if mid != '0303cedf99999999':
        fail('read-only hostname', mid)
    pass_('MUTATION_CLIENT_ID_ONLY')


def test_seed_does_not_overwrite():
    client = {
        'label': 'keep-me',
        'note': 'keep-note',
        'tags': {'customer': 'lotte', 'site': 'seoul'},
        'group_ids': ['grp_deadbeef'],
    }
    creg.seed_admin_metadata(client, label='new', note='new-note')
    if client['label'] != 'keep-me' or client['note'] != 'keep-note':
        fail('overwrite', client)
    if client['tags'] != {'customer': 'lotte', 'site': 'seoul'}:
        fail('tags overwritten', client)
    if client['group_ids'] != ['grp_deadbeef']:
        fail('group_ids overwritten', client)
    empty = {}
    creg.seed_admin_metadata(empty, label='seoul-groupware', note='desc')
    if empty.get('label') != 'seoul-groupware':
        fail('seed label')
    pass_('SEED_ADMIN_METADATA')


def test_groups():
    state = {
        'schema_version': 2,
        'groups': {
            'grp_11111111': {'name': 'customer-acme', 'type': 'manual'},
            'grp_22222222': {'name': 'pilot', 'type': 'manual'},
        },
        'clients': {
            'aaaaaaaa11111111': {'group_ids': ['grp_11111111', 'grp_22222222']},
        },
    }
    gid, group = creg.resolve_group(state, 'customer-acme')
    if gid != 'grp_11111111' or group.get('name') != 'customer-acme':
        fail('resolve by name', gid, group)
    try:
        creg.validate_group_name('all')
        fail('reserved all accepted')
    except ValueError:
        pass
    if not creg.client_matches_group(state['clients']['aaaaaaaa11111111'], 'grp_11111111'):
        fail('client_matches_group')
    pass_('GROUPS')


def test_tags():
    if creg.parse_tag_assignment('customer=lotte') != ('customer', 'lotte'):
        fail('parse tag assignment')
    filters = [('customer', 'lotte'), ('site', 'seoul')]
    if not creg.client_matches_tags(
        {'tags': {'customer': 'lotte', 'site': 'seoul', 'role': 'dp'}},
        filters,
    ):
        fail('tag AND match')
    if creg.client_matches_tags({'tags': {'customer': 'lotte'}}, filters):
        fail('tag AND missing key')
    invalid = [
        'missing-equals',
        '=value',
        'bad key=value',
        'key=',
        'key=bad,value',
        'key=bad\x1bvalue',
        'key=bad\x00value',
        'key=bad\rvalue',
        'key=bad\nvalue',
        ('k' * 65) + '=value',
        'key=' + ('v' * 129),
    ]
    for value in invalid:
        try:
            creg.parse_tag_assignment(value)
            fail('invalid tag accepted', repr(value))
        except ValueError:
            pass
    pass_('CLIENT_TAG_VALIDATION_AND_MATCHING')


def test_validate_machine_id():
    linux = 'aabbccddeeff00112233445566778899'
    if creg.validate_machine_id(linux) != linux:
        fail('linux hex32')
    windows_like = 'DESKTOP-ABC1234.user-01:v1'
    if creg.validate_machine_id(windows_like) != windows_like:
        fail('windows-like')
    maxed = 'A' + ('b' * 127)
    if len(maxed) != 128:
        fail('fixture length')
    if creg.validate_machine_id(maxed) != maxed:
        fail('max 128')
    try:
        creg.validate_machine_id('A' + ('b' * 128))  # 129
        fail('129 accepted')
    except ValueError:
        pass
    for bad in ('has\rreturn', 'has\nline', 'has\x00nul', 'a/b', 'a\\b', '', None, ' '):
        try:
            creg.validate_machine_id(bad)
            fail('bad machine_id accepted', repr(bad))
        except ValueError:
            pass
    pass_('VALIDATE_MACHINE_ID')


def test_enroll_rejects_oversized_machine_id():
    import hashlib
    import hmac
    import importlib.util
    import json
    import tempfile
    import time

    spec = importlib.util.spec_from_file_location(
        'frp_port_allocator', ROOT / 'server' / 'frp-port-allocator.py'
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        registry = root / 'registry.json'
        token = root / 'server_token'
        enrollments = root / 'enrollments'
        enrollments.mkdir()
        token.write_text('tok\n')
        cfg_path = root / 'config.json'
        cfg_path.write_text(json.dumps({
            'public_ip': '203.0.113.10',
            'control_port': 443,
            'port_start': 6000,
            'port_end': 6098,
            'registry_file': str(registry),
            'enrollments_dir': str(enrollments),
            'token_file': str(token),
        }) + '\n')
        mod.atomic_write_json(registry, mod.empty_registry())
        mod.port_is_available = lambda port: True
        alloc = mod.Allocator(str(cfg_path))
        eid = 'aabbccddeeff0099'
        secret = 'f' * 64
        now = int(time.time())
        (enrollments / (eid + '.json')).write_text(json.dumps({
            'id': eid,
            'secret': secret,
            'expires_at': now + 600,
            'bound_machine_id': None,
            'used_at': None,
        }) + '\n')
        oversized = 'x' * 129
        body = json.dumps({
            'machine_id': oversized,
            'hostname': 'too-long',
            'services': [],
        }, separators=(',', ':')).encode()
        ts = str(now)
        sig = hmac.new(
            secret.encode(), (ts + '\n' + body.decode()).encode(), hashlib.sha256
        ).hexdigest()
        code, result = alloc.enroll(eid, ts, sig, body)
        if code != 400:
            fail('oversized machine_id enroll code', '%s %s' % (code, result))
        pass_('ENROLL_REJECTS_OVERSIZED_MACHINE_ID')


def main():
    test_source_ip()
    test_display_and_match()
    test_mutation_id_only()
    test_seed_does_not_overwrite()
    test_tags()
    test_groups()
    test_validate_machine_id()
    test_enroll_rejects_oversized_machine_id()
    print('CLIENT_REGISTRY_HELPERS=PASS')


if __name__ == '__main__':
    main()
