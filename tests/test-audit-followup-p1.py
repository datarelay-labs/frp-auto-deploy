#!/usr/bin/env python3
"""Focused regressions for final pre-e2e audit follow-up (lock, lease, release, proof).

Upstream FRP 0.70.1 PluginManager.NewProxy: when a plugin returns reject/error,
RegisterProxy is not called (plugin failure is fail-closed for that NewProxy).
Temporary rejection is compatible with client retry.
"""
from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load_mod(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


DPA = load_mod('frp_data_plane_auth', ROOT / 'lib' / 'frp_data_plane_auth.py')
LEASES = load_mod('frp_proxy_leases', ROOT / 'lib' / 'frp_proxy_leases.py')
MGMT = load_mod('frp_mgmt_auth', ROOT / 'lib' / 'frp_mgmt_auth.py')
LOCKS = load_mod('frp_control_locks', ROOT / 'lib' / 'frp_control_locks.py')
SCFG = load_mod('frp_server_config', ROOT / 'lib' / 'frp_server_config.py')
LIFE = load_mod('frp_client_lifecycle', ROOT / 'lib' / 'frp_client_lifecycle.py')


def pass_(name):
    print('PASS %s' % name)


def fail(name, detail=''):
    print('FAIL %s %s' % (name, detail), file=sys.stderr)
    raise SystemExit(1)


def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + '\n', encoding='utf-8')


def base_cfg(root, registry, lease_rel=None, strict=True):
    return {
        'deployment_mode': 'direct',
        'frp_transport': 'tcp',
        'port_start': 6000,
        'port_end': 6098,
        'frp_control_listen_port': 7000,
        'frp_control_public_port': 7000,
        'allocator_listen_port': 7500,
        'allocator_public_port': 7500,
        'registry_file': str(registry),
        'proxy_lease_dir': lease_rel or LEASES.DEFAULT_LEASE_DIR,
        'data_plane_auth_strict': strict,
        'frp_plugin_listen_host': '127.0.0.1',
        'frp_plugin_listen_port': 6100,
        'public_host': '203.0.113.10',
    }


def make_client(tmp, mid='aabbccdd00112233445566778899aabb'):
    key = tmp / ('%s.key' % mid)
    pub = tmp / ('%s.pub' % mid)
    MGMT.generate_keypair(key, pub)
    return {
        'hostname': 'edge-1',
        'label': 'edge-1',
        'mgmt_status': 'enrolled',
        'mgmt_pubkey': pub.read_text(encoding='utf-8'),
        'services': {
            'ssh': {
                'id': 'ssh',
                'protocol': 'tcp',
                'preset': 'ssh',
                'enabled': True,
                'local_ip': '127.0.0.1',
                'local_port': 22,
                'remote_port': 6001,
                'ssh_user': 'ubuntu',
            }
        },
    }, key, pub, mid


def new_proxy_content(mid, proof, port=6001, service_id='ssh', run_id='run-1'):
    return {
        'proxy_type': 'tcp',
        'remote_port': port,
        'proxy_name': '%s-%s' % (mid, service_id),
        'user': {
            'run_id': run_id,
            'metas': {
                DPA.META_CLIENT_ID: mid,
                DPA.META_PROOF_SCHEMA: str(DPA.DATA_PLANE_SCHEMA),
                DPA.META_PROOF: proof,
            },
        },
        'metas': {DPA.META_SERVICE_ID: service_id},
    }


def test_lease_capacity_and_corruption():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        lease_dir = root / 'leases'
        os.environ['FRP_DEPLOY_TEST_ROOT'] = str(root)
        now = time.time()
        # Fill to MAX_LEASES with long-lived leases.
        for i in range(LEASES.MAX_LEASES):
            token = 't%04d' % i
            rec = {
                'lease_schema': LEASES.LEASE_SCHEMA,
                'client_id': 'c',
                'service_id': 'ssh',
                'remote_port': 6000 + (i % 50),
                'run_id': 'r',
                'created_at': now,
                'expires_at': now + 3600,
                'token': token,
            }
            path = lease_dir / ('lease-%s.json' % token)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(rec) + '\n', encoding='utf-8')
        before = list(lease_dir.glob('lease-*.json'))
        try:
            LEASES.acquire_lease(str(lease_dir), 'c', 'ssh', 6099, ttl_sec=30)
            fail('LEASE_CAPACITY_FAIL_CLOSED', 'accepted overflow')
        except LEASES.LeaseCapacityExceeded:
            pass
        after = list(lease_dir.glob('lease-*.json'))
        if len(after) != len(before):
            fail('ACTIVE_LEASE_NOT_EVICTED', '%s -> %s' % (len(before), len(after)))
        pass_('LEASE_CAPACITY_FAIL_CLOSED')
        pass_('ACTIVE_LEASE_NOT_EVICTED')

        bad = lease_dir / 'lease-corrupt.json'
        bad.write_text('{not-json\n', encoding='utf-8')
        try:
            LEASES.has_active_lease(str(lease_dir), remote_port=6001)
            fail('MALFORMED_LEASE_RELEASE_BLOCKED', 'accepted corrupt store')
        except LEASES.LeaseStoreInvalid:
            pass
        if not bad.is_file():
            fail('MALFORMED_LEASE_RELEASE_BLOCKED', 'corrupt file deleted')
        pass_('MALFORMED_LEASE_RELEASE_BLOCKED')
        os.environ.pop('FRP_DEPLOY_TEST_ROOT', None)


def test_strict_false_release_tools():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        registry = root / 'var/lib/frp-auto-deploy/registry.json'
        cfg_path = root / 'etc/frp-auto-deploy/config.json'
        client, _key, _pub, mid = make_client(root)
        write_json(registry, {
            'schema_version': 2,
            'reserved': [],
            'groups': {},
            'clients': {mid: client},
        })
        cfg = base_cfg(root, '/var/lib/frp-auto-deploy/registry.json', strict=False)
        write_json(cfg_path, cfg)
        env = os.environ.copy()
        env['FRP_DEPLOY_TEST_ROOT'] = str(root)
        for tool, args in (
            ('frp-release-service', [mid, 'ssh']),
            ('frp-release-client', [mid]),
        ):
            proc = subprocess.run(
                [sys.executable, str(ROOT / 'tools' / tool)] + args,
                input='RELEASE\n',
                text=True,
                capture_output=True,
                env=env,
                check=False,
            )
            if proc.returncode == 0:
                fail('STRICT_FALSE_%s' % tool.upper().replace('-', '_'), 'accepted')
            blob = (proc.stdout or '') + (proc.stderr or '')
            if 'port release is disabled while strict data-plane authorization is not enabled' not in blob:
                fail('STRICT_FALSE_%s' % tool.upper().replace('-', '_'), blob[:400])
        pass_('STRICT_FALSE_RELEASE_SERVICE_BLOCKED')
        pass_('STRICT_FALSE_RELEASE_CLIENT_BLOCKED')

        cfg['data_plane_auth_strict'] = True
        write_json(cfg_path, cfg)
        proc = subprocess.run(
            [sys.executable, str(ROOT / 'tools' / 'frp-release-service'), mid, 'ssh'],
            input='RELEASE\n',
            text=True,
            capture_output=True,
            env=env,
            check=False,
        )
        if proc.returncode != 0:
            fail('STRICT_TRUE_RELEASE_PERMITTED', proc.stderr or proc.stdout)
        state = json.loads(registry.read_text(encoding='utf-8'))
        if mid not in state['clients']:
            fail('STRICT_TRUE_RELEASE_PERMITTED', 'client deleted')
        if 'ssh' in (state['clients'][mid].get('services') or {}):
            fail('STRICT_TRUE_RELEASE_PERMITTED', 'service remained')
        pass_('STRICT_TRUE_OFFLINE_NO_LEASE_PERMITTED')


def test_newproxy_release_lock_races():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        os.environ['FRP_DEPLOY_TEST_ROOT'] = str(root)
        registry = root / 'registry.json'
        lease_dir = Path(LEASES.lease_dir_from_cfg({'proxy_lease_dir': LEASES.DEFAULT_LEASE_DIR}))
        client, key, _pub, mid = make_client(root)
        write_json(registry, {
            'schema_version': 2,
            'reserved': [],
            'groups': {},
            'clients': {mid: client},
        })
        cfg = base_cfg(root, str(registry), strict=True)
        proof = DPA.sign_proof(key, mid)
        content = new_proxy_content(mid, proof)
        marker = root / 'hook.marker'
        results = {}

        def do_newproxy():
            os.environ['FRP_DATA_PLANE_HOOK_AFTER_REGISTRY_AUTH_BEFORE_LEASE'] = '1.5'
            os.environ['FRP_DATA_PLANE_HOOK_MARKER'] = str(marker)
            try:
                code, payload = DPA.handle_plugin_http(
                    'POST',
                    DPA.PLUGIN_PATH,
                    'version=0.1.0&op=NewProxy',
                    json.dumps({'version': '0.1.0', 'op': 'NewProxy', 'content': content}).encode(),
                    lambda: json.loads(registry.read_text(encoding='utf-8')),
                    cfg=cfg,
                )
                results['np'] = (code, payload)
            finally:
                os.environ.pop('FRP_DATA_PLANE_HOOK_AFTER_REGISTRY_AUTH_BEFORE_LEASE', None)
                os.environ.pop('FRP_DATA_PLANE_HOOK_MARKER', None)

        def do_release_while_auth():
            deadline = time.time() + 5
            while time.time() < deadline and not marker.is_file():
                time.sleep(0.05)
            if not marker.is_file():
                results['rel'] = 'no-marker'
                return
            # Release must block on the same registry.lock until NewProxy finishes,
            # then observe the active lease and refuse.
            t0 = time.time()
            with LOCKS.acquire_registry_lock(str(registry)):
                waited = time.time() - t0
                results['waited'] = waited
                try:
                    DPA.assert_port_releasable(6001, cfg=cfg, lease_mod=LEASES)
                    results['rel'] = 'allowed'
                except ValueError as exc:
                    results['rel'] = str(exc)

        t1 = threading.Thread(target=do_newproxy)
        t2 = threading.Thread(target=do_release_while_auth)
        t1.start()
        t2.start()
        t1.join(timeout=10)
        t2.join(timeout=10)
        if results.get('np', (None, {}))[1].get('reject'):
            fail('NEWPROXY_WINS_RACE_RELEASE_BLOCKED', results)
        if results.get('waited', 0) < 0.5:
            fail('NEWPROXY_RELEASE_LOCK_RACE', 'release did not wait for registry lock: %s' % results)
        if 'active authorization lease' not in str(results.get('rel') or ''):
            fail('NEWPROXY_WINS_RACE_RELEASE_BLOCKED', results)
        pass_('NEWPROXY_RELEASE_LOCK_RACE')
        pass_('NEWPROXY_WINS_RACE_RELEASE_BLOCKED')

        # Inverse: release wins — mutate under lock before NewProxy.
        write_json(registry, {
            'schema_version': 2,
            'reserved': [],
            'groups': {},
            'clients': {mid: client},
        })
        for path in lease_dir.glob('lease-*.json'):
            path.unlink()
        marker2 = root / 'release-hold.marker'
        results2 = {}

        def release_first():
            with LOCKS.acquire_registry_lock(str(registry)):
                marker2.write_text('holding\n', encoding='utf-8')
                time.sleep(1.2)
                state = json.loads(registry.read_text(encoding='utf-8'))
                state['clients'][mid]['services'] = {}
                write_json(registry, state)

        def newproxy_second():
            deadline = time.time() + 5
            while time.time() < deadline and not marker2.is_file():
                time.sleep(0.05)
            code, payload = DPA.handle_plugin_http(
                'POST',
                DPA.PLUGIN_PATH,
                'version=0.1.0&op=NewProxy',
                json.dumps({'version': '0.1.0', 'op': 'NewProxy', 'content': content}).encode(),
                lambda: json.loads(registry.read_text(encoding='utf-8')),
                cfg=cfg,
            )
            results2['np'] = (code, payload)
            lease_count = len(list(lease_dir.glob('lease-*.json'))) if lease_dir.is_dir() else 0
            results2['leases'] = lease_count

        t3 = threading.Thread(target=release_first)
        t4 = threading.Thread(target=newproxy_second)
        t3.start()
        t4.start()
        t3.join(timeout=10)
        t4.join(timeout=10)
        payload = results2.get('np', (None, {}))[1]
        if not payload.get('reject'):
            fail('RELEASE_WINS_RACE', payload)
        reason = str(payload.get('reject_reason') or '')
        if 'unknown service' not in reason:
            fail('RELEASE_WINS_RACE', reason)
        if results2.get('leases', 1) != 0:
            fail('RELEASE_WINS_RACE', 'lease created after release')
        pass_('RELEASE_WINS_RACE')
        os.environ.pop('FRP_DEPLOY_TEST_ROOT', None)


def test_strict_boolean_validation():
    cfg = base_cfg(Path('/tmp'), '/tmp/r.json', strict=True)
    try:
        SCFG.validate_server_config(cfg)
    except ValueError as exc:
        fail('DATA_PLANE_STRICT_BOOLEAN_VALIDATION', exc)
    bad = dict(cfg)
    bad['data_plane_auth_strict'] = 'false'
    try:
        SCFG.validate_server_config(bad)
        fail('DATA_PLANE_STRICT_BOOLEAN_VALIDATION', 'accepted string false')
    except ValueError as exc:
        if 'boolean' not in str(exc):
            fail('DATA_PLANE_STRICT_BOOLEAN_VALIDATION', exc)
    bad_host = dict(cfg)
    bad_host['frp_plugin_listen_host'] = True
    try:
        SCFG.validate_server_config(bad_host)
        fail('DATA_PLANE_STRICT_BOOLEAN_VALIDATION', 'accepted bool host')
    except ValueError:
        pass
    pass_('DATA_PLANE_STRICT_BOOLEAN_VALIDATION')


def test_linux_proof_redaction_and_validation():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        os.environ['FRP_DEPLOY_TEST_ROOT'] = str(root)
        mid = 'aabbccdd00112233445566778899aabb'
        key = root / 'k.key'
        pub = root / 'k.pub'
        MGMT.generate_keypair(key, pub)
        proof = DPA.sign_proof(key, mid)
        leak = 'FRP_AD_PROOF_TEST_DO_NOT_LEAK_' + proof[:24]
        toml = '\n'.join([
            'serverAddr = "203.0.113.10"',
            'serverPort = 443',
            'auth.method = "token"',
            'auth.token = "FRP_TOKEN_TEST_SHOULD_REDACT"',
            'clientID = "%s"' % mid,
            'metadatas.frp_ad_client_id = "%s"' % mid,
            'metadatas.frp_ad_proof_schema = "1"',
            'metadatas.frp_ad_proof = "%s"' % leak,
            '',
            '[[proxies]]',
            'name = "host-ssh"',
            'type = "tcp"',
            'localIP = "127.0.0.1"',
            'localPort = 22',
            'remotePort = 6003',
            'metadatas.frp_ad_service_id = "ssh"',
            '',
        ])
        DPA.validate_frpc_data_plane_metadata(
            toml.replace(leak, proof),
            mid,
            {'ssh': {'id': 'ssh', 'remote_port': 6003, 'enabled': True}},
            pub_pem=pub.read_text(encoding='utf-8'),
            host_id='host',
        )
        pass_('LINUX_PROOF_METADATA_VALIDATION')

        redacted = LIFE.redact_toml(toml)
        if leak in redacted or proof[:20] in redacted:
            fail('LINUX_SUPPORT_BUNDLE_PROOF_REDACTED', redacted[:200])
        if 'FRP_TOKEN_TEST_SHOULD_REDACT' in redacted:
            fail('LINUX_SUPPORT_BUNDLE_PROOF_REDACTED', 'token leaked')
        if 'metadatas.frp_ad_proof = "[redacted]"' not in redacted:
            fail('LINUX_SUPPORT_BUNDLE_PROOF_REDACTED', redacted)
        if 'frp_ad_client_id' not in redacted or 'frp_ad_proof_schema' not in redacted:
            fail('LINUX_SUPPORT_BUNDLE_PROOF_REDACTED', 'diagnostic metadata redacted')
        pass_('LINUX_SUPPORT_BUNDLE_PROOF_REDACTED')
        os.environ.pop('FRP_DEPLOY_TEST_ROOT', None)


def test_linux_proof_refresh_shell():
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        env = os.environ.copy()
        env['FRP_CLIENT_TEST_ROOT'] = str(work)
        env['FRP_SKIP_SYSTEMD'] = '1'
        script = work / 'run.sh'
        script.write_text(
            '''#!/usr/bin/env bash
set -euo pipefail
ROOT="%s"
WORKDIR="%s"
export FRP_CLIENT_TEST_ROOT="$WORKDIR"
export FRP_SKIP_SYSTEMD=1
# shellcheck disable=SC1091
. "$ROOT/lib/frp-client-common.sh"
mkdir -p "$WORKDIR/etc/frp" "$WORKDIR/usr/local/lib/frp-auto-deploy"
install -m 0644 "$ROOT/lib/frp_data_plane_auth.py" "$WORKDIR/usr/local/lib/frp-auto-deploy/"
install -m 0644 "$ROOT/lib/frp_mgmt_auth.py" "$WORKDIR/usr/local/lib/frp-auto-deploy/"
python3 "$ROOT/lib/frp_mgmt_auth.py" gen-key \
  "$WORKDIR/etc/frp/client-identity.key" "$WORKDIR/etc/frp/client-identity.pub"
MID=aabbccdd00112233445566778899aabb
python3 - "$WORKDIR/etc/frp/client-state.json" "$MID" <<'PY'
import json,sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
  "schema_version":1,
  "allocator_url":"https://example.test/enroll",
  "frp_server":"203.0.113.10",
  "frp_server_port":443,
  "hostname":"t",
  "machine_id":sys.argv[2],
  "host_id":"t-aabb",
  "services":{"ssh":{"id":"ssh","name":"SSH","preset":"ssh","protocol":"tcp",
    "local_ip":"127.0.0.1","local_port":22,"remote_port":6003,"enabled":True,"ssh_user":"u"}}
}, indent=2)+"\\n")
PY
cat >"$WORKDIR/etc/frp/frpc.toml" <<'EOF'
serverAddr = "203.0.113.10"
serverPort = 443
auth.method = "token"
auth.token = "test-frp-token-do-not-use"
[[proxies]]
name = "t-aabb-ssh"
type = "tcp"
localIP = "127.0.0.1"
localPort = 22
remotePort = 6003
EOF
set +e
frp_client_refresh_data_plane_proof_if_needed
rc=$?
set -e
[[ "$rc" -eq 0 ]] || exit 11
frp_client_validate_data_plane_toml_metadata || exit 12
grep -q 'frp_ad_proof =' "$WORKDIR/etc/frp/frpc.toml" || exit 13
set +e
frp_client_refresh_data_plane_proof_if_needed
rc2=$?
set -e
[[ "$rc2" -eq 10 ]] || exit 14
# Failure: remove token while clearing proof markers so refresh is required.
python3 - "$WORKDIR/etc/frp/frpc.toml" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
text = text.replace('metadatas.frp_ad_proof =', 'metadatas.frp_ad_proof_gone =')
text = text.replace('auth.token = "test-frp-token-do-not-use"', 'auth.token = ""')
p.write_text(text)
PY
set +e
frp_client_refresh_data_plane_proof_if_needed
rc3=$?
set -e
[[ "$rc3" -eq 1 ]] || exit 15
echo LINUX_PROOF_REFRESH_OK
''' % (ROOT, work)
        )
        script.chmod(0o700)
        proc = subprocess.run(['bash', str(script)], capture_output=True, text=True, check=False)
        if proc.returncode != 0 or 'LINUX_PROOF_REFRESH_OK' not in proc.stdout:
            fail('LINUX_PROOF_REFRESH_SUCCESS', proc.stdout + proc.stderr)
        pass_('LINUX_PROOF_REFRESH_SUCCESS')
        pass_('LINUX_PROOF_REFRESH_FAILURE_ROLLBACK')


def main():
    test_lease_capacity_and_corruption()
    test_strict_false_release_tools()
    test_newproxy_release_lock_races()
    test_strict_boolean_validation()
    test_linux_proof_redaction_and_validation()
    test_linux_proof_refresh_shell()
    print('AUDIT_FOLLOWUP_FOCUSED=PASS')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
