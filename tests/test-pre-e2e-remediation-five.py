#!/usr/bin/env python3
"""Focused regressions for the five final pre-E2E remediation findings."""
from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'lib'))

import frp_data_plane_auth as DPA  # noqa: E402
import frp_mgmt_auth as MGMT  # noqa: E402
import frp_project_files as PFILES  # noqa: E402
import frp_proxy_leases as LEASES  # noqa: E402
import frp_server_config as SCFG  # noqa: E402


def pass_(name):
    print('PASS %s' % name)


def fail(name, detail=''):
    print('FAIL %s %s' % (name, detail), file=sys.stderr)
    raise SystemExit(1)


def sha256(path: Path) -> str:
    if not path.is_file():
        return ''
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path: Path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + '\n', encoding='utf-8')


def run_bash(script: str, env=None):
    proc = subprocess.run(
        ['bash', '-c', script],
        cwd=str(ROOT),
        env=env or os.environ.copy(),
        capture_output=True,
        text=True,
        check=False,
    )
    return proc


def server_cfg(strict=True, **overrides):
    cfg = {
        'public_host': '203.0.113.10',
        'deployment_mode': 'direct',
        'frp_transport': 'tcp',
        'frp_control_public_port': 7000,
        'frp_control_listen_port': 7000,
        'allocator_public_port': 7500,
        'allocator_listen_port': 7500,
        'allocator_public_url': 'https://203.0.113.10:7500/enroll',
        'port_start': 6000,
        'port_end': 6098,
        'data_plane_auth_strict': strict,
        'proxy_lease_dir': LEASES.DEFAULT_LEASE_DIR,
        'frp_plugin_listen_host': '127.0.0.1',
        'frp_plugin_listen_port': 6100,
        'client_installer_url': 'https://example.test/client.sh',
        'windows_client_installer_url': 'https://example.test/windows.ps1',
    }
    cfg.update(overrides)
    return cfg


def seed_server_tree(tree: Path, strict=True, clients=None):
    for rel in (
        'etc/frp-auto-deploy/pki',
        'etc/frp',
        'var/lib/frp-auto-deploy',
        'usr/local/bin',
        'usr/local/lib/frp-auto-deploy',
        'usr/local/sbin',
        'etc/systemd/system',
    ):
        (tree / rel).mkdir(parents=True, exist_ok=True)
    write_json(tree / 'etc/frp-auto-deploy/config.json', server_cfg(strict=strict))
    (tree / 'etc/frp/server_token').write_text('server-token-preserve\n', encoding='utf-8')
    (tree / 'etc/frp/server_token').chmod(0o600)
    (tree / 'etc/frp/frps.toml').write_text('bindPort = 7000\n', encoding='utf-8')
    for name in ('ca.crt', 'ca.key', 'server.crt', 'server.key'):
        (tree / 'etc/frp-auto-deploy/pki' / name).write_text('%s\n' % name, encoding='utf-8')
    reg = {
        'schema_version': 2,
        'clients': clients if clients is not None else {
            'aabbccdd00112233445566778899aabb': {
                'hostname': 'edge',
                'services': {
                    'ssh': {
                        'id': 'ssh',
                        'protocol': 'tcp',
                        'remote_port': 6001,
                        'enabled': True,
                    }
                },
            }
        },
        'reserved': [6001],
        'groups': {},
    }
    write_json(tree / 'var/lib/frp-auto-deploy/registry.json', reg)
    (tree / 'etc/frp-auto-deploy/version').write_text(
        'PROJECT_VERSION=2.1.1\nFRP_VERSION=0.70.1\n', encoding='utf-8'
    )
    frps = tree / 'usr/local/bin/frps'
    frps.write_text('#!/bin/sh\n[ "$1" = verify ] && exit 0\necho 0.70.1\nexit 0\n', encoding='utf-8')
    frps.chmod(0o755)


def resolve_strict_via_install(tree: Path, confirm=None, unset_confirm=True):
    env = os.environ.copy()
    env['FRP_SERVER_TEST_ROOT'] = str(tree)
    env['FRP_SERVER_SOURCED'] = '1'
    env['FRP_INSTALL_HOOK_SKIP_SYSTEMD'] = '1'
    if confirm is not None:
        env['FRP_CONFIRM_DATA_PLANE_AUTH_CUTOVER'] = confirm
    elif unset_confirm:
        env.pop('FRP_CONFIRM_DATA_PLANE_AUTH_CUTOVER', None)
    script = r'''
set -euo pipefail
export FRP_SERVER_SOURCED=1
BASE_DIR="%s"
# shellcheck disable=SC1090
. "$BASE_DIR/install-server.sh"
existing_install=1
registry_file="$(frp_server_fs /var/lib/frp-auto-deploy/registry.json)"
frp_resolve_data_plane_auth_strict "$registry_file" "$existing_install"
printf 'STRICT=%%s\n' "${FRP_DATA_PLANE_AUTH_STRICT}"
''' % ROOT
    proc = run_bash(script, env)
    if proc.returncode != 0:
        return None, proc.stdout + proc.stderr
    for line in proc.stdout.splitlines():
        if line.startswith('STRICT='):
            return line.split('=', 1)[1].strip(), proc.stdout + proc.stderr
    return None, proc.stdout + proc.stderr


def test_strict_one_way_cutover():
    with tempfile.TemporaryDirectory() as tmp:
        base = Path(tmp)

        # Fresh install default true via resolve when existing_install=0
        fresh = base / 'fresh'
        fresh.mkdir()
        env = os.environ.copy()
        env['FRP_SERVER_TEST_ROOT'] = str(fresh)
        env.pop('FRP_CONFIRM_DATA_PLANE_AUTH_CUTOVER', None)
        script = r'''
set -euo pipefail
export FRP_SERVER_SOURCED=1
BASE_DIR="%s"
. "$BASE_DIR/install-server.sh"
existing_install=0
frp_resolve_data_plane_auth_strict "$(frp_server_fs /var/lib/frp-auto-deploy/registry.json)" "$existing_install"
printf 'STRICT=%%s\n' "${FRP_DATA_PLANE_AUTH_STRICT}"
''' % ROOT
        proc = run_bash(script, env)
        if proc.returncode != 0 or 'STRICT=1' not in proc.stdout:
            fail('STRICT_FRESH_INSTALL_DEFAULT_TRUE', proc.stdout + proc.stderr)
        pass_('STRICT_FRESH_INSTALL_DEFAULT_TRUE')

        # Legacy false + clients + no confirm → stays false
        legacy = base / 'legacy'
        seed_server_tree(legacy, strict=False)
        val, out = resolve_strict_via_install(legacy, confirm=None)
        if val != '0':
            fail('LEGACY_EXISTING_CLIENTS_NO_CONFIRM_STAYS_FALSE', out)
        pass_('LEGACY_EXISTING_CLIENTS_NO_CONFIRM_STAYS_FALSE')

        # Legacy false + clients + confirm → true
        val, out = resolve_strict_via_install(legacy, confirm='yes')
        if val != '1':
            fail('LEGACY_EXISTING_CLIENTS_CONFIRM_CUTOVER_TRUE', out)
        pass_('LEGACY_EXISTING_CLIENTS_CONFIRM_CUTOVER_TRUE')

        # Already strict=true without confirm stays true
        already = base / 'already'
        seed_server_tree(already, strict=True)
        val, out = resolve_strict_via_install(already, confirm=None)
        if val != '1':
            fail('EXISTING_STRICT_TRUE_WITHOUT_CONFIRM_STAYS_TRUE', out)
        pass_('EXISTING_STRICT_TRUE_WITHOUT_CONFIRM_STAYS_TRUE')
        pass_('STRICT_TRUE_NEVER_DOWNGRADED')

        # Actual project-update path preserves strict=true in config.json
        upd = base / 'proj-upd'
        seed_server_tree(upd, strict=True)
        (upd / 'etc/frp-auto-deploy/version').write_text(
            'PROJECT_VERSION=2.0.0\n'
            'FRP_VERSION=0.70.1\n'
            'RELEASE_CHANNEL=stable\n'
            'SOURCE_REF=v2.1.1\n'
            'BUNDLE_SHA256='
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n',
            encoding='utf-8',
        )
        frps = upd / 'usr/local/bin/frps'
        frps.write_text(
            '#!/bin/sh\n[[ "${1:-}" = "--version" ]] && echo 0.70.1\nexit 0\n',
            encoding='utf-8',
        )
        frps.chmod(0o755)
        (upd / 'usr/local/lib/frp-auto-deploy/frp-port-allocator.py').write_text(
            'print("old-allocator")\n', encoding='utf-8'
        )
        (upd / 'etc/systemd/system/frp-port-allocator.service').write_text(
            'old-unit\n', encoding='utf-8'
        )
        (upd / 'var/lib/frp-auto-deploy/enrollments').mkdir(parents=True, exist_ok=True)
        (upd / 'var/lib/frp-auto-deploy/bootstrap').mkdir(parents=True, exist_ok=True)
        proc = subprocess.run(
            ['bash', str(ROOT / 'install-server.sh'), '--upgrade', '--source', str(ROOT)],
            env={
                **os.environ,
                'FRP_SERVER_TEST_ROOT': str(upd),
                'FRP_INSTALL_HOOK_SKIP_SYSTEMD': '1',
                'FRP_SKIP_SYSTEMD': '1',
                'FRP_RELEASE_CHANNEL': 'stable',
            },
            capture_output=True,
            text=True,
            check=False,
        )
        if proc.returncode != 0:
            fail(
                'STRICT_ACTUAL_PROJECT_UPDATE_SUCCESS',
                'upgrade failed rc=%s\nstdout:\n%s\nstderr:\n%s'
                % (proc.returncode, proc.stdout, proc.stderr),
            )
        pass_('STRICT_ACTUAL_PROJECT_UPDATE_SUCCESS')
        cfg = json.loads((upd / 'etc/frp-auto-deploy/config.json').read_text(encoding='utf-8'))
        if cfg.get('data_plane_auth_strict') is not True:
            fail('EXISTING_STRICT_TRUE_PROJECT_UPDATE_STAYS_TRUE', cfg)
        pass_('EXISTING_STRICT_TRUE_PROJECT_UPDATE_STAYS_TRUE')

        # Reinstall path (write_server_config) must not downgrade
        reinstall = base / 'reinstall'
        seed_server_tree(reinstall, strict=True)
        # Force reinstall by invoking resolve + write_server_config with env from resolve
        env = os.environ.copy()
        env['FRP_SERVER_TEST_ROOT'] = str(reinstall)
        env['FRP_SERVER_SOURCED'] = '1'
        env['FRP_INSTALL_HOOK_SKIP_SYSTEMD'] = '1'
        env['FRP_PUBLIC_HOST'] = '203.0.113.10'
        env['FRP_CONTROL_PUBLIC_PORT'] = '7000'
        env['FRP_CONTROL_LISTEN_PORT'] = '7000'
        env['FRP_ALLOCATOR_PUBLIC_PORT'] = '7500'
        env['FRP_ALLOCATOR_LISTEN_PORT'] = '7500'
        env['FRP_PORT_START'] = '6000'
        env['FRP_PORT_END'] = '6098'
        env['FRP_ALLOCATOR_PUBLIC_URL'] = 'https://203.0.113.10:7500/enroll'
        env['CLIENT_INSTALLER_URL'] = 'https://example.test/client.sh'
        env['WINDOWS_CLIENT_INSTALLER_URL'] = 'https://example.test/windows.ps1'
        env.pop('FRP_CONFIRM_DATA_PLANE_AUTH_CUTOVER', None)
        script = r'''
set -euo pipefail
export FRP_SERVER_SOURCED=1
BASE_DIR="%s"
. "$BASE_DIR/install-server.sh"
existing_install=1
load_existing_server_config
frp_resolve_data_plane_auth_strict "$(frp_server_fs /var/lib/frp-auto-deploy/registry.json)" "$existing_install"
CLIENT_INSTALLER_URL="${CLIENT_INSTALLER_URL}"
WINDOWS_CLIENT_INSTALLER_URL="${WINDOWS_CLIENT_INSTALLER_URL}"
write_server_config
python3 - "$(frp_server_config_path)" <<'PY'
import json,sys
from pathlib import Path
cfg=json.loads(Path(sys.argv[1]).read_text())
assert cfg.get("data_plane_auth_strict") is True, cfg
print("REINSTALL_STRICT_OK")
PY
''' % ROOT
        proc = run_bash(script, env)
        if proc.returncode != 0 or 'REINSTALL_STRICT_OK' not in proc.stdout:
            fail('EXISTING_STRICT_TRUE_PROJECT_UPDATE_STAYS_TRUE', proc.stdout + proc.stderr)
        pass_('STRICT_ALREADY_ENABLED_UPDATE_TEST')
        pass_('STRICT_DOWNGRADE_PREVENTION_TEST')


def test_fresh_client_manifest_and_helper():
    with tempfile.TemporaryDirectory() as tmp:
        tree = Path(tmp) / 'client'
        env = os.environ.copy()
        env['FRP_CLIENT_TEST_ROOT'] = str(tree)
        env['FRP_SKIP_SYSTEMD'] = '1'
        script = r'''
set -euo pipefail
ROOT="%s"
export FRP_CLIENT_TEST_ROOT="%s"
export FRP_SKIP_SYSTEMD=1
. "$ROOT/lib/frp-client-common.sh"
mkdir -p "$FRP_CLIENT_TEST_ROOT"
frp_client_install_management_files "$ROOT"
helper="$(frp_client_path /usr/local/lib/frp-auto-deploy/frp_data_plane_auth.py)"
[[ -f "$helper" ]] || exit 11
python3 -m py_compile "$helper" || exit 12
echo FRESH_HELPER_OK
python3 - "$ROOT" "$FRP_CLIENT_TEST_ROOT" <<'PY'
import sys
from pathlib import Path
root = Path(sys.argv[1])
tree = Path(sys.argv[2])
sys.path.insert(0, str(root / "lib"))
import frp_project_files as pf
want = {e.dest for e in pf.client_project_entries(source_root=str(root))}
for dest in sorted(want):
    path = tree / dest
    if not path.is_file():
        raise SystemExit("missing installed " + dest)
print("MANIFEST_PARITY_OK")
PY
''' % (ROOT, tree)
        proc = run_bash(script, env)
        if proc.returncode != 0 or 'FRESH_HELPER_OK' not in proc.stdout:
            fail('FRESH_CLIENT_DATA_PLANE_HELPER_INSTALLED', proc.stdout + proc.stderr)
        pass_('FRESH_CLIENT_DATA_PLANE_HELPER_INSTALLED')
        if 'MANIFEST_PARITY_OK' not in proc.stdout:
            fail('FRESH_CLIENT_MANIFEST_PARITY', proc.stdout + proc.stderr)
        pass_('FRESH_CLIENT_MANIFEST_PARITY')

        # Management-only then add service + regenerate proof
        mid = 'aabbccdd00112233445566778899aabb'
        key = tree / 'etc/frp/client-identity.key'
        pub = tree / 'etc/frp/client-identity.pub'
        (tree / 'etc/frp').mkdir(parents=True, exist_ok=True)
        MGMT.generate_keypair(key, pub)
        write_json(
            tree / 'etc/frp/client-state.json',
            {
                'schema_version': 1,
                'allocator_url': 'https://example.test/enroll',
                'frp_server': '203.0.113.10',
                'frp_server_port': 7000,
                'hostname': 'mgmt-only',
                'machine_id': mid,
                'host_id': 'mgmt-only-aabb',
                'services': {},
                'frp_transport': 'tcp',
            },
        )
        # Initial empty toml with token only (management-only)
        (tree / 'etc/frp/frpc.toml').write_text(
            'serverAddr = "203.0.113.10"\n'
            'serverPort = 7000\n'
            'auth.method = "token"\n'
            'auth.token = "test-frp-token-do-not-use"\n'
            'transport.tls.enable = true\n',
            encoding='utf-8',
        )
        # Add one service later without re-enrollment
        state = json.loads((tree / 'etc/frp/client-state.json').read_text(encoding='utf-8'))
        state['services'] = {
            'ssh': {
                'id': 'ssh',
                'name': 'SSH',
                'preset': 'ssh',
                'protocol': 'tcp',
                'local_ip': '127.0.0.1',
                'local_port': 22,
                'remote_port': 6003,
                'enabled': True,
                'ssh_user': 'u',
            }
        }
        write_json(tree / 'etc/frp/client-state.json', state)
        script2 = r'''
set -euo pipefail
ROOT="%s"
export FRP_CLIENT_TEST_ROOT="%s"
export FRP_SKIP_SYSTEMD=1
. "$ROOT/lib/frp-client-common.sh"
# Ensure installed helper is what regenerate finds
frp_regenerate_toml_from_state "test-frp-token-do-not-use" || exit 21
frp_client_validate_data_plane_toml_metadata || exit 22
grep -q 'frp_ad_proof =' "$(frp_client_toml_path)" || exit 23
grep -q 'metadatas.frp_ad_service_id = "ssh"' "$(frp_client_toml_path)" || exit 24
grep -q 'remotePort = 6003' "$(frp_client_toml_path)" || exit 25
echo MANAGEMENT_ADD_OK
''' % (ROOT, tree)
        proc2 = run_bash(script2, env)
        if proc2.returncode != 0 or 'MANAGEMENT_ADD_OK' not in proc2.stdout:
            fail('FRESH_MANAGEMENT_ONLY_THEN_ADD_SERVICE', proc2.stdout + proc2.stderr)
        pass_('FRESH_MANAGEMENT_ONLY_THEN_ADD_SERVICE')
        pass_('FRESH_CLIENT_PROOF_REGENERATION')


def test_lease_dir_canonical():
    SCFG.validate_server_config(server_cfg())
    pass_('LEASE_DIR_DEFAULT_CANONICAL')
    SCFG.validate_server_config(server_cfg(proxy_lease_dir=LEASES.DEFAULT_LEASE_DIR))
    pass_('LEASE_DIR_ABSOLUTE_CANONICAL')
    for label, value in (
        ('LEASE_DIR_RELATIVE_REJECTED', 'leases'),
        ('LEASE_DIR_TRAVERSAL_REJECTED', '../leases'),
        ('LEASE_DIR_UNSAFE_LOCATION_REJECTED', '/tmp/leases'),
    ):
        try:
            SCFG.validate_server_config(server_cfg(proxy_lease_dir=value))
            fail(label, 'accepted')
        except ValueError as exc:
            if 'canonical absolute path' not in str(exc):
                fail(label, exc)
            pass_(label)

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        os.environ['FRP_DEPLOY_TEST_ROOT'] = str(root)
        try:
            cfg = server_cfg()
            resolved = LEASES.lease_dir_from_cfg(cfg)
            expect = str(root / LEASES.DEFAULT_LEASE_DIR.lstrip('/'))
            if resolved != expect:
                fail('LEASE_DIR_TEST_ROOT_MAPPING', '%s != %s' % (resolved, expect))
            # NewProxy and release must resolve identically
            a = LEASES.lease_dir_from_cfg(cfg)
            b = LEASES.lease_dir_from_cfg(cfg)
            if a != b or a != expect:
                fail('NEWPROXY_AND_RELEASE_RESOLVE_SAME_LEASE_STORE', '%s / %s' % (a, b))
            pass_('LEASE_DIR_TEST_ROOT_MAPPING')
            pass_('NEWPROXY_AND_RELEASE_RESOLVE_SAME_LEASE_STORE')
        finally:
            os.environ.pop('FRP_DEPLOY_TEST_ROOT', None)


def _sample_toml(mid, proof, host_id='host1', mapping=None):
    if mapping is None:
        mapping = (
            ('ssh', 6001),
            ('web', 6002),
        )
    lines = [
        'serverAddr = "203.0.113.10"',
        'serverPort = 7000',
        'auth.method = "token"',
        'auth.token = "tok"',
        'clientID = "%s"' % mid,
        'metadatas.frp_ad_client_id = "%s"' % mid,
        'metadatas.frp_ad_proof_schema = "1"',
        'metadatas.frp_ad_proof = "%s"' % proof,
    ]
    for sid, port in mapping:
        lines.extend([
            '',
            '[[proxies]]',
            'name = "%s-%s"' % (host_id, sid),
            'type = "tcp"',
            'localIP = "127.0.0.1"',
            'localPort = 22',
            'remotePort = %s' % port,
            'metadatas.frp_ad_service_id = "%s"' % sid,
        ])
    return '\n'.join(lines) + '\n'


def test_per_proxy_mapping_linux():
    with tempfile.TemporaryDirectory() as tmp:
        mid = 'aabbccdd00112233445566778899aabb'
        key = Path(tmp) / 'k.key'
        pub = Path(tmp) / 'k.pub'
        MGMT.generate_keypair(key, pub)
        proof = DPA.sign_proof(key, mid)
        services = {
            'ssh': {'id': 'ssh', 'remote_port': 6001, 'enabled': True},
            'web': {'id': 'web', 'remote_port': 6002, 'enabled': True},
        }
        good = _sample_toml(mid, proof)
        DPA.validate_frpc_data_plane_metadata(good, mid, services, pub_pem=pub.read_text(), host_id='host1')
        pass_('CORRECT_PROXY_SERVICE_MAPPING')

        swapped = (
            _sample_toml(mid, proof, mapping=())
            + '\n[[proxies]]\n'
            'name = "host1-ssh"\n'
            'type = "tcp"\n'
            'localIP = "127.0.0.1"\n'
            'localPort = 22\n'
            'remotePort = 6001\n'
            'metadatas.frp_ad_service_id = "web"\n'
            '\n[[proxies]]\n'
            'name = "host1-web"\n'
            'type = "tcp"\n'
            'localIP = "127.0.0.1"\n'
            'localPort = 80\n'
            'remotePort = 6002\n'
            'metadatas.frp_ad_service_id = "ssh"\n'
        )
        try:
            DPA.validate_frpc_data_plane_metadata(
                swapped, mid, services, pub_pem=pub.read_text(), host_id='host1'
            )
            fail('SWAPPED_SERVICE_IDS_REJECTED', 'accepted')
        except ValueError:
            pass_('SWAPPED_SERVICE_IDS_REJECTED')

        wrong_port = good.replace('remotePort = 6001', 'remotePort = 6099')
        try:
            DPA.validate_frpc_data_plane_metadata(
                wrong_port, mid, services, pub_pem=pub.read_text(), host_id='host1'
            )
            fail('WRONG_REMOTE_PORT_MAPPING_REJECTED', 'accepted')
        except ValueError:
            pass_('WRONG_REMOTE_PORT_MAPPING_REJECTED')

        dup = good + '\n[[proxies]]\nname = "host1-ssh-dup"\ntype = "tcp"\nlocalIP = "127.0.0.1"\nlocalPort = 22\nremotePort = 6011\nmetadatas.frp_ad_service_id = "ssh"\n'
        try:
            DPA.validate_frpc_data_plane_metadata(
                dup, mid, services, pub_pem=pub.read_text(), host_id='host1'
            )
            fail('DUPLICATE_SERVICE_MAPPING_REJECTED', 'accepted')
        except ValueError:
            pass_('DUPLICATE_SERVICE_MAPPING_REJECTED')

        missing = '\n'.join(
            line for line in good.splitlines() if 'frp_ad_service_id = "web"' not in line
        ) + '\n'
        try:
            DPA.validate_frpc_data_plane_metadata(
                missing, mid, services, pub_pem=pub.read_text(), host_id='host1'
            )
            fail('MISSING_SERVICE_MAPPING_REJECTED', 'accepted')
        except ValueError:
            pass_('MISSING_SERVICE_MAPPING_REJECTED')

        partial = {
            'ssh': {'id': 'ssh', 'remote_port': 6001, 'enabled': True},
            'web': {'id': 'web', 'remote_port': 6002, 'enabled': False},
        }
        only_ssh = _sample_toml(mid, proof, mapping=(('ssh', 6001),))
        DPA.validate_frpc_data_plane_metadata(
            only_ssh, mid, partial, pub_pem=pub.read_text(), host_id='host1'
        )
        pass_('DISABLED_SERVICE_NOT_REQUIRED')

        empty = _sample_toml(mid, proof, mapping=())
        DPA.validate_frpc_data_plane_metadata(empty, mid, {}, pub_pem=pub.read_text(), host_id='host1')
        pass_('MANAGEMENT_ONLY_ZERO_PROXY_VALID')


def test_proof_refresh_full_update_rollback():
    with tempfile.TemporaryDirectory() as tmp:
        tree = Path(tmp) / 'client'
        mid = 'aabbccdd00112233445566778899aabb'
        env = os.environ.copy()
        env['FRP_CLIENT_TEST_ROOT'] = str(tree)
        env['FRP_SKIP_SYSTEMD'] = '1'
        # Old management files without data-plane helper / old common
        for rel in (
            'etc/frp',
            'usr/local/bin',
            'usr/local/lib/frp-auto-deploy',
            'etc/frp-auto-deploy',
        ):
            (tree / rel).mkdir(parents=True, exist_ok=True)
        # Install a subset of "old" files so update is needed
        old_client = tree / 'usr/local/bin/frp-client'
        old_client.write_text('#!/bin/sh\necho old-client\n', encoding='utf-8')
        old_client.chmod(0o755)
        (tree / 'usr/local/lib/frp-auto-deploy/frp-client-common.sh').write_text(
            '# old common\n', encoding='utf-8'
        )
        (tree / 'usr/local/lib/frp-auto-deploy/frp_mgmt_auth.py').write_text(
            'print("old")\n', encoding='utf-8'
        )
        (tree / 'etc/frp-auto-deploy/version').write_text(
            'PROJECT_VERSION=2.1.0\nFRP_VERSION=0.70.1\n', encoding='utf-8'
        )
        key = tree / 'etc/frp/client-identity.key'
        pub = tree / 'etc/frp/client-identity.pub'
        MGMT.generate_keypair(key, pub)
        (tree / 'etc/frp/client-identity.mac').write_text(('a' * 64) + '\n', encoding='utf-8')
        write_json(
            tree / 'etc/frp/client-state.json',
            {
                'schema_version': 1,
                'allocator_url': 'https://example.test/enroll',
                'frp_server': '203.0.113.10',
                'frp_server_port': 7000,
                'hostname': 'edge',
                'machine_id': mid,
                'host_id': 'edge-aabb',
                'services': {
                    'ssh': {
                        'id': 'ssh',
                        'name': 'SSH',
                        'preset': 'ssh',
                        'protocol': 'tcp',
                        'local_ip': '127.0.0.1',
                        'local_port': 22,
                        'remote_port': 6003,
                        'enabled': True,
                        'ssh_user': 'u',
                    }
                },
                'frp_transport': 'tcp',
            },
        )
        toml = tree / 'etc/frp/frpc.toml'
        toml.write_text(
            'serverAddr = "203.0.113.10"\n'
            'serverPort = 7000\n'
            'auth.method = "token"\n'
            'auth.token = "test-frp-token-do-not-use"\n'
            'transport.tls.enable = true\n'
            '\n'
            '[[proxies]]\n'
            'name = "edge-aabb-ssh"\n'
            'type = "tcp"\n'
            'localIP = "127.0.0.1"\n'
            'localPort = 22\n'
            'remotePort = 6003\n',
            encoding='utf-8',
        )
        toml.chmod(0o600)
        pause = tree / 'etc/frp/remote-access-paused.json'
        write_json(pause, {'paused': True, 'reason': 'test'})
        # Dummy frpc for verify
        frpc = tree / 'usr/local/bin/frpc'
        frpc.write_text('#!/bin/sh\n[ "$1" = verify ] && exit 0\necho 0.70.1\n', encoding='utf-8')
        frpc.chmod(0o755)

        before = {
            'toml': sha256(toml),
            'state': sha256(tree / 'etc/frp/client-state.json'),
            'key': sha256(key),
            'pub': sha256(pub),
            'mac': sha256(tree / 'etc/frp/client-identity.mac'),
            'common': sha256(tree / 'usr/local/lib/frp-auto-deploy/frp-client-common.sh'),
            'client': sha256(old_client),
            'version': (tree / 'etc/frp-auto-deploy/version').read_text(encoding='utf-8'),
            'pause': sha256(pause),
            'toml_bytes': toml.read_bytes(),
        }

        env['FRP_CLIENT_UPGRADE_HOOK_FAIL'] = 'proof-refresh'
        proc = subprocess.run(
            [str(ROOT / 'tools/frp-client'), 'update', '--source', str(ROOT)],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        out = proc.stdout + proc.stderr
        if proc.returncode == 0:
            fail('LINUX_PROOF_REFRESH_FULL_UPDATE_ROLLBACK', 'update unexpectedly succeeded\n' + out)
        if 'UPGRADE_ROLLBACK=PASS' not in out:
            fail('LINUX_PROOF_REFRESH_FULL_UPDATE_ROLLBACK', 'missing rollback marker\n' + out)
        if sha256(toml) != before['toml'] or toml.read_bytes() != before['toml_bytes']:
            fail('LINUX_PROOF_REFRESH_FULL_UPDATE_ROLLBACK', 'frpc.toml not restored byte-for-byte')
        if sha256(tree / 'etc/frp/client-state.json') != before['state']:
            fail('LINUX_PROOF_REFRESH_FULL_UPDATE_ROLLBACK', 'state changed')
        if sha256(key) != before['key'] or sha256(pub) != before['pub']:
            fail('LINUX_PROOF_REFRESH_FULL_UPDATE_ROLLBACK', 'identity changed')
        if sha256(tree / 'etc/frp/client-identity.mac') != before['mac']:
            fail('LINUX_PROOF_REFRESH_FULL_UPDATE_ROLLBACK', 'mac changed')
        if sha256(old_client) != before['client']:
            fail('LINUX_PROOF_REFRESH_FULL_UPDATE_ROLLBACK', 'frp-client not restored')
        if sha256(tree / 'usr/local/lib/frp-auto-deploy/frp-client-common.sh') != before['common']:
            fail('LINUX_PROOF_REFRESH_FULL_UPDATE_ROLLBACK', 'common not restored')
        if (tree / 'etc/frp-auto-deploy/version').read_text(encoding='utf-8') != before['version']:
            fail('LINUX_PROOF_REFRESH_FULL_UPDATE_ROLLBACK', 'version advanced')
        if sha256(pause) != before['pause']:
            fail('LINUX_PROOF_REFRESH_FULL_UPDATE_ROLLBACK', 'pause state lost')
        state = json.loads((tree / 'etc/frp/client-state.json').read_text(encoding='utf-8'))
        if int(state['services']['ssh']['remote_port']) != 6003:
            fail('LINUX_PROOF_REFRESH_FULL_UPDATE_ROLLBACK', 'remote port changed')
        pass_('LINUX_PROOF_REFRESH_FULL_UPDATE_ROLLBACK')


def main():
    test_strict_one_way_cutover()
    test_fresh_client_manifest_and_helper()
    test_lease_dir_canonical()
    test_per_proxy_mapping_linux()
    test_proof_refresh_full_update_rollback()
    print('PRE_E2E_REMEDIATION_FIVE=PASS')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
