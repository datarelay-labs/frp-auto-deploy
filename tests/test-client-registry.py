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
    if creg.request_source_ip('127.0.0.1', {'X-Forwarded-For': '198.51.100.9'}) != '198.51.100.9':
        fail('loopback trusts XFF')
    if creg.request_source_ip('::1', {'X-Forwarded-For': '2001:db8::1'}) != '2001:db8::1':
        fail('v6 loopback trusts XFF')
    if creg.request_source_ip('127.0.0.1', {'X-Forwarded-For': 'not-an-ip'}) != '127.0.0.1':
        fail('malformed XFF ignored')
    if creg.request_source_ip('::ffff:127.0.0.1', {'X-Forwarded-For': '203.0.113.8'}) != '203.0.113.8':
        fail('mapped loopback')
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
    pass_('LABEL_HOSTNAME_PREFIX_LOOKUP')


def test_seed_does_not_overwrite():
    client = {'label': 'keep-me', 'note': 'keep-note'}
    creg.seed_admin_metadata(client, label='new', note='new-note')
    if client['label'] != 'keep-me' or client['note'] != 'keep-note':
        fail('overwrite', client)
    empty = {}
    creg.seed_admin_metadata(empty, label='seoul-groupware', note='desc')
    if empty.get('label') != 'seoul-groupware':
        fail('seed label')
    pass_('SEED_ADMIN_METADATA')


def main():
    test_source_ip()
    test_display_and_match()
    test_seed_does_not_overwrite()
    print('CLIENT_REGISTRY_HELPERS=PASS')


if __name__ == '__main__':
    main()
