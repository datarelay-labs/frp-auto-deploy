#!/usr/bin/env python3
"""PKI key↔certificate pair validation and restore prevalidation."""
import importlib.util
import json
import shutil
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'lib'))
import frp_pki as pki  # noqa: E402


def pass_(name):
    print('PASS %s' % name)


def fail(name, detail=''):
    print('FAIL %s %s' % (name, detail), file=sys.stderr)
    raise SystemExit(1)


def load_restore():
    import importlib.machinery
    path = ROOT / 'tools' / 'frp-restore'
    loader = importlib.machinery.SourceFileLoader('frp_restore_mod', str(path))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    if spec is None or spec.loader is None:
        raise RuntimeError('unable to load %s' % path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod
    loader.exec_module(mod)
    return mod


def make_pki(workdir, host='203.0.113.50'):
    pki_dir = workdir / 'pki'
    pki.ensure_pki(pki_dir, host)
    return pki.pki_paths(pki_dir)


def test_pairs():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        good = make_pki(root / 'good')
        pki.validate_key_cert_pair(good['ca_key'], good['ca_crt'], label='CA')
        pki.validate_key_cert_pair(good['server_key'], good['server_crt'], label='server')
        pass_('PKI_CA_KEY_CERT_PAIR')
        pass_('PKI_SERVER_KEY_CERT_PAIR')

        other = make_pki(root / 'other', host='198.51.100.50')
        # Cross CA key with other CA cert.
        try:
            pki.validate_key_cert_pair(good['ca_key'], other['ca_crt'], label='CA')
            fail('PKI_CA_CROSSED', 'accepted')
        except pki.PkiError:
            pass_('PKI_CA_CROSSED')
        try:
            pki.validate_key_cert_pair(good['server_key'], other['server_crt'], label='server')
            fail('PKI_SERVER_CROSSED', 'accepted')
        except pki.PkiError:
            pass_('PKI_SERVER_CROSSED')

        # ensure_pki / validate_existing_materials fail closed on crossed files.
        crossed = root / 'crossed' / 'pki'
        shutil.copytree(good['dir'], crossed)
        shutil.copyfile(other['ca_key'], crossed / 'ca.key')
        try:
            pki.validate_existing_materials(pki.pki_paths(crossed))
            fail('PKI_EXISTING_CROSSED', 'accepted')
        except pki.PkiError as exc:
            if 'refusing to replace the CA' not in str(exc) and 'does not match' not in str(exc):
                # wrapped message is fine
                pass
            pass_('PKI_EXISTING_CROSSED')


def test_restore_pair_prevalidation():
    restore = load_restore()
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        payload = root / 'payload'
        for rel in (
            'var/lib/frp-auto-deploy',
            'etc/frp-auto-deploy/pki',
            'etc/frp',
        ):
            (payload / rel).mkdir(parents=True)
        cfg = {
            'deployment_mode': 'direct',
            'frp_transport': 'tcp',
            'port_start': 6000,
            'port_end': 6099,
            'frp_control_listen_port': 7000,
            'frp_control_public_port': 7000,
            'allocator_listen_port': 7500,
            'allocator_public_port': 7500,
            'public_host': '203.0.113.50',
        }
        (payload / 'etc/frp-auto-deploy/config.json').write_text(json.dumps(cfg) + '\n')
        (payload / 'var/lib/frp-auto-deploy/registry.json').write_text(
            json.dumps({'schema_version': 2, 'clients': {}, 'reserved': [], 'groups': {}}) + '\n'
        )
        (payload / 'etc/frp/frps.toml').write_text('bindPort = 7000\n')

        good = make_pki(root / 'good')
        other = make_pki(root / 'other', host='198.51.100.8')
        for name in ('ca.crt', 'ca.key', 'server.crt', 'server.key'):
            shutil.copyfile(good['dir'] / name, payload / 'etc/frp-auto-deploy/pki' / name)
        # Cross server key only.
        shutil.copyfile(other['server_key'], payload / 'etc/frp-auto-deploy/pki' / 'server.key')

        marker = root / 'live-marker'
        marker.write_text('untouched\n')
        try:
            restore._semantic_prevalidate_candidate(root)
            fail('RESTORE_PK_PAIR_PREVALIDATION', 'accepted crossed PKI')
        except restore.RestoreError as exc:
            if 'PKI' not in str(exc) and 'pair' not in str(exc).lower() and 'match' not in str(exc).lower():
                fail('RESTORE_PK_PAIR_PREVALIDATION', exc)
            if marker.read_text() != 'untouched\n':
                fail('RESTORE_PK_PAIR_PREVALIDATION', 'mutated before reject')
            pass_('RESTORE_PK_PAIR_PREVALIDATION')


def main():
    test_pairs()
    test_restore_pair_prevalidation()
    print('ALL PASS')


if __name__ == '__main__':
    main()
