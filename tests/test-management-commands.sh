#!/usr/bin/env bash
# Generic registry schema management command tests.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }

TREE="$WORKDIR/tree"
mkdir -p "$TREE/etc/frp-auto-deploy" "$TREE/var/lib/frp-auto-deploy"

python3 - "$TREE/etc/frp-auto-deploy/config.json" "$TREE/var/lib/frp-auto-deploy/registry.json" "$ROOT" <<'PY'
import importlib.util
import json
import sys
import tempfile
from pathlib import Path

root = Path(sys.argv[3])
spec = importlib.util.spec_from_file_location('mgmt', root / 'lib' / 'frp_mgmt_auth.py')
mgmt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mgmt)


def enrolled_fields(machine_id):
    tmp = Path(tempfile.mkdtemp())
    key = tmp / 'key.pem'
    pub = tmp / 'pub.pem'
    mgmt.generate_keypair(key, pub)
    pem = pub.read_text(encoding='utf-8')
    return {
        'mgmt_status': 'enrolled',
        'mgmt_pubkey': pem,
        'mgmt_alg': mgmt.MGMT_ALG,
        'mgmt_fingerprint': mgmt.pubkey_fingerprint(pem),
        'mgmt_mac_key': mgmt.derive_mac_key('test-mgmt-secret', machine_id),
    }


cfg_path, reg_path = Path(sys.argv[1]), Path(sys.argv[2])
cfg_path.write_text(json.dumps({
  "public_ip": "203.0.113.10",
  "control_port": 443,
  "port_start": 6000,
  "port_end": 6098,
  "listen_port": 6099,
  "registry_file": str(reg_path),
}, indent=2)+"\n")
reg_path.write_text(json.dumps({
  "schema_version": 2,
  "reserved": [6000],
  "clients": {
    "aabbccdd": {
      "hostname": "dev-dp-mirror",
      "created_at": "2026-08-26T00:00:00Z",
      "last_enrolled_at": "2026-08-26T01:00:00Z",
      **enrolled_fields('aabbccdd'),
      "services": {
        "ssh": {
          "name": "SSH",
          "protocol": "tcp",
          "local_ip": "127.0.0.1",
          "local_port": 22,
          "remote_port": 6002,
          "preset": "ssh",
          "ssh_user": "aella",
          "enabled": True,
        },
        "grafana": {
          "name": "Grafana",
          "protocol": "tcp",
          "local_ip": "127.0.0.1",
          "local_port": 3000,
          "remote_port": 6003,
          "preset": "custom",
          "enabled": True,
        },
        "api": {
          "name": "Internal API",
          "protocol": "tcp",
          "local_ip": "10.10.20.30",
          "local_port": 8080,
          "remote_port": 6004,
          "preset": "custom",
          "enabled": False,
        },
      },
    },
    "eeff0011": {
      "hostname": "client-b",
      "created_at": "2026-08-26T00:00:00Z",
      "last_enrolled_at": "2026-08-26T02:00:00Z",
      **enrolled_fields('eeff0011'),
      "services": {
        "http": {
          "name": "HTTP",
          "protocol": "tcp",
          "local_ip": "127.0.0.1",
          "local_port": 80,
          "remote_port": 6005,
          "preset": "http",
          "enabled": True,
        },
      },
    },
  },
}, indent=2, sort_keys=True)+"\n")
PY
chmod 600 "$TREE/var/lib/frp-auto-deploy/registry.json"

export FRP_DEPLOY_TEST_ROOT="$TREE"

OUT="$WORKDIR/clients.out"
python3 "$ROOT/tools/frp-clients" >"$OUT"
grep -q 'dev-dp-mirror' "$OUT" || fail "clients hostname"
grep -q 'client-b' "$OUT" || fail "clients second host"
grep -q 'ssh:6002' "$OUT" || fail "clients ssh summary"
grep -q 'grafana:6003' "$OUT" || fail "clients grafana summary"
grep -q 'api:6004 (reserved)' "$OUT" || fail "clients reserved service"
grep -q 'http:6005' "$OUT" || fail "clients http summary"
grep -q 'Use CLIENT ID for set/unset/revoke/release.' "$OUT" || fail "clients mutation footer"
grep -q 'show/info only' "$OUT" || fail "clients read-only shortcut footer"
if grep -qE 'ssh_port|https_port' "$OUT"; then
  fail "clients leaked legacy fields"
fi
pass "frp-clients generic"

INFO="$WORKDIR/info.out"
python3 "$ROOT/tools/frp-client-info" aabbccdd >"$INFO"
grep -q 'Hostname' "$INFO" || fail "info hostname field"
grep -q 'dev-dp-mirror' "$INFO" || fail "info hostname"
grep -q 'Service count' "$INFO" || fail "info service count"
grep -q '2' "$INFO" || fail "info enabled count"
if grep -q '127.0.0.1:22' "$INFO"; then
  fail "overview dumped service detail"
fi
python3 "$ROOT/tools/frp-client-info" aabbccdd services >"$WORKDIR/info-svc.out"
grep -q '127.0.0.1:22' "$WORKDIR/info-svc.out" || fail "info ssh target"
grep -q '203.0.113.10:6002' "$WORKDIR/info-svc.out" || fail "info ssh public"
grep -q 'ssh -p 6002 aella@203.0.113.10' "$WORKDIR/info-svc.out" || fail "info ssh connect"
grep -q '127.0.0.1:3000' "$WORKDIR/info-svc.out" || fail "info grafana target"
if grep -q '6004' "$WORKDIR/info-svc.out"; then
  fail "info should omit disabled service"
fi
# read-only still accepts hostname
python3 "$ROOT/tools/frp-client-info" dev-dp-mirror >"$WORKDIR/info-host.out"
grep -q 'aabbccdd' "$WORKDIR/info-host.out" || fail "read-only hostname shortcut"
pass "frp-client-info generic"

cp "$TREE/var/lib/frp-auto-deploy/registry.json" "$WORKDIR/registry.before"
printf 'nope\n' | python3 "$ROOT/tools/frp-release-client" eeff0011 >"$WORKDIR/cancel.out" 2>"$WORKDIR/cancel.err" && fail "cancel should fail"
python3 - "$TREE/var/lib/frp-auto-deploy/registry.json" "$WORKDIR/registry.before" <<'PY'
import sys
from pathlib import Path
assert Path(sys.argv[1]).read_bytes() == Path(sys.argv[2]).read_bytes()
PY
printf 'RELEASE\n' | python3 "$ROOT/tools/frp-release-client" eeff0011 >"$WORKDIR/release.out"
python3 - "$TREE/var/lib/frp-auto-deploy/registry.json" <<'PY' || fail "release client must keep record"
import json,sys
from pathlib import Path
state=json.loads(Path(sys.argv[1]).read_text())
assert 'eeff0011' in state['clients']
client=state['clients']['eeff0011']
assert client['services'] == {}
assert client.get('mgmt_status')=='enrolled'
assert client.get('mgmt_pubkey')
assert client.get('mgmt_fingerprint')
assert client.get('mgmt_mac_key')
assert 'aabbccdd' in state['clients']
assert state['clients']['aabbccdd']['services']['ssh']['remote_port']==6002
assert state['clients']['aabbccdd']['services']['api']['remote_port']==6004
PY
grep -q 'http: 6005' "$WORKDIR/release.out" || fail "release listed service port"
pass "frp-release-client keeps identity"

printf 'nope\n' | python3 "$ROOT/tools/frp-release-service" aabbccdd grafana >"$WORKDIR/svc-cancel.out" 2>"$WORKDIR/svc-cancel.err" && fail "service release cancel should fail"
python3 - "$TREE/var/lib/frp-auto-deploy/registry.json" <<'PY' || fail "cancel mutated grafana"
import json,sys
from pathlib import Path
state=json.loads(Path(sys.argv[1]).read_text())
assert 'grafana' in state['clients']['aabbccdd']['services']
PY
printf 'RELEASE\n' | python3 "$ROOT/tools/frp-release-service" aabbccdd grafana >"$WORKDIR/svc-release.out"
python3 - "$TREE/var/lib/frp-auto-deploy/registry.json" <<'PY' || fail "release one of multiple services"
import json,sys
from pathlib import Path
state=json.loads(Path(sys.argv[1]).read_text())
client=state['clients']['aabbccdd']
svc=client['services']
assert 'grafana' not in svc
assert svc['ssh']['remote_port']==6002
assert svc['api']['remote_port']==6004
assert client.get('mgmt_status')=='enrolled'
assert client.get('mgmt_pubkey')
assert client.get('mgmt_fingerprint')
assert client.get('mgmt_mac_key')
PY
grep -q 'service grafana' "$WORKDIR/svc-release.out" || fail "service release output"
pass "frp-release-service preserves others"

# Release remaining services one by one → last service leaves empty services
printf 'RELEASE\n' | python3 "$ROOT/tools/frp-release-service" aabbccdd ssh >"$WORKDIR/svc-ssh.out"
printf 'RELEASE\n' | python3 "$ROOT/tools/frp-release-service" aabbccdd api >"$WORKDIR/svc-api.out"
python3 - "$TREE/var/lib/frp-auto-deploy/registry.json" <<'PY' || fail "release last service keeps record"
import json,sys
from pathlib import Path
state=json.loads(Path(sys.argv[1]).read_text())
assert 'aabbccdd' in state['clients']
client=state['clients']['aabbccdd']
assert client['services'] == {}
assert client.get('mgmt_status')=='enrolled'
assert client.get('mgmt_pubkey')
assert client.get('mgmt_fingerprint')
assert client.get('mgmt_mac_key')
PY
pass "frp-release-service last keeps identity"

# Restore services for revoke coverage
python3 - "$TREE/var/lib/frp-auto-deploy/registry.json" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1])
state=json.loads(p.read_text())
state['clients']['aabbccdd']['services']={
  'ssh':{'name':'SSH','protocol':'tcp','local_ip':'127.0.0.1','local_port':22,'remote_port':6002,'preset':'ssh','ssh_user':'aella','enabled':True},
  'api':{'name':'API','protocol':'tcp','local_ip':'127.0.0.1','local_port':8080,'remote_port':6004,'preset':'custom','enabled':False},
}
p.write_text(json.dumps(state, indent=2, sort_keys=True)+'\n')
PY

printf 'REVOKE\n' | python3 "$ROOT/tools/frp-revoke-client" aabbccdd >"$WORKDIR/revoke.out"
python3 - "$TREE/var/lib/frp-auto-deploy/registry.json" <<'PY' || fail "revoke"
import json,sys
from pathlib import Path
state=json.loads(Path(sys.argv[1]).read_text())
client=state['clients']['aabbccdd']
assert client.get('mgmt_status')=='revoked'
assert client.get('mgmt_mac_key') is None
assert client.get('mgmt_pubkey')
assert client.get('mgmt_fingerprint')
assert client['services']['ssh']['remote_port']==6002
assert client['services']['api']['remote_port']==6004
PY
grep -q 'Revoking management identity' "$WORKDIR/revoke.out" || fail "revoke header"
grep -q 'ssh: 6002' "$WORKDIR/revoke.out" || fail "revoke listed reservation"
if grep -qi 'private key\|mgmt_mac_key\|BEGIN PUBLIC' "$WORKDIR/revoke.out"; then
  fail "revoke leaked identity material"
fi
pass "frp-revoke-client keeps reservations"

printf 'RELEASE\n' | python3 "$ROOT/tools/frp-release-client" aabbccdd >"$WORKDIR/revoke-release.out"
python3 - "$TREE/var/lib/frp-auto-deploy/registry.json" <<'PY' || fail "release after revoke"
import json,sys
from pathlib import Path
state=json.loads(Path(sys.argv[1]).read_text())
assert 'aabbccdd' in state['clients']
client=state['clients']['aabbccdd']
assert client['services'] == {}
assert client.get('mgmt_status')=='revoked'
assert client.get('mgmt_pubkey')
assert client.get('mgmt_fingerprint')
PY
pass "admin release still works after revoke"

# Restore clients for legacy / status coverage
python3 - "$TREE/var/lib/frp-auto-deploy/registry.json" "$ROOT" <<'PY'
import importlib.util
import json
import sys
import tempfile
from pathlib import Path

root = Path(sys.argv[2])
spec = importlib.util.spec_from_file_location('mgmt', root / 'lib' / 'frp_mgmt_auth.py')
mgmt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mgmt)
tmp = Path(tempfile.mkdtemp())
key = tmp / 'key.pem'
pub = tmp / 'pub.pem'
mgmt.generate_keypair(key, pub)
pem = pub.read_text(encoding='utf-8')
fields = {
  'mgmt_status': 'enrolled',
  'mgmt_pubkey': pem,
  'mgmt_alg': mgmt.MGMT_ALG,
  'mgmt_fingerprint': mgmt.pubkey_fingerprint(pem),
  'mgmt_mac_key': mgmt.derive_mac_key('test-mgmt-secret', 'aabbccdd'),
}
p=Path(sys.argv[1])
state=json.loads(p.read_text())
state['clients']['aabbccdd']={
  'hostname':'dev-dp-mirror',
  **fields,
  'services':{
    'ssh':{'name':'SSH','protocol':'tcp','local_ip':'127.0.0.1','local_port':22,'remote_port':6002,'preset':'ssh','ssh_user':'aella','enabled':True},
    'api':{'name':'API','protocol':'tcp','local_ip':'127.0.0.1','local_port':8080,'remote_port':6004,'preset':'custom','enabled':False},
  },
}
state['clients']['legacy00aa']={
  'hostname':'legacy-ssh',
  'services':{
    'ssh':{'id':'ssh','name':'SSH','protocol':'tcp','local_ip':'127.0.0.1','local_port':22,'remote_port':6010,'preset':'ssh','ssh_user':'legacyuser','enabled':True},
  },
}
# drop empty eeff0011 so status counts stay simple
state['clients'].pop('eeff0011', None)
p.write_text(json.dumps(state, indent=2, sort_keys=True)+'\n')
PY

python3 "$ROOT/tools/frp-clients" >"$WORKDIR/legacy-clients.out"
grep -q 'legacyuser' "$WORKDIR/legacy-clients.out" || fail "legacy SSH user display"
python3 "$ROOT/tools/frp-client-info" legacy-ssh services >"$WORKDIR/legacy-info.out"
grep -q 'legacyuser' "$WORKDIR/legacy-info.out" || fail "legacy SSH info display"
python3 - "$TREE/var/lib/frp-auto-deploy/registry.json" <<'PY' || fail "list mutated legacy record"
import json,sys
from pathlib import Path
state=json.loads(Path(sys.argv[1]).read_text())
assert 'legacy00aa' in state['clients']
assert 'aabbccdd' in state['clients']
assert state['clients']['aabbccdd']['services']['ssh']['remote_port']==6002
assert state['clients']['legacy00aa']['services']['ssh']['remote_port']==6010
assert state['clients']['legacy00aa']['services']['ssh']['ssh_user']=='legacyuser'
PY
cp "$TREE/var/lib/frp-auto-deploy/registry.json" "$WORKDIR/legacy.before"
printf 'nope\n' | python3 "$ROOT/tools/frp-release-client" legacy00aa \
  >"$WORKDIR/legacy-cancel.out" 2>"$WORKDIR/legacy-cancel.err" && fail "legacy cancel should fail"
cmp -s "$TREE/var/lib/frp-auto-deploy/registry.json" "$WORKDIR/legacy.before" ||
  fail "cancelled legacy release mutated registry"
pass "legacy SSH readable without auto-release"

printf 'RELEASE\n' | python3 "$ROOT/tools/frp-release-service" legacy00aa ssh \
  >"$WORKDIR/legacy-svc-release.out"
python3 - "$TREE/var/lib/frp-auto-deploy/registry.json" <<'PY' || fail "explicit legacy service release"
import json,sys
from pathlib import Path
state=json.loads(Path(sys.argv[1]).read_text())
assert 'legacy00aa' in state['clients']
assert state['clients']['legacy00aa']['services'] == {}
assert state['clients']['aabbccdd']['services']['ssh']['remote_port']==6002
assert all(
    svc.get('remote_port') != 6010
    for client in state['clients'].values()
    for svc in (client.get('services') or {}).values()
    if isinstance(svc, dict)
)
PY
pass "legacy explicit service release reclaims port"

python3 - "$TREE/var/lib/frp-auto-deploy/registry.json" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1])
state=json.loads(p.read_text())
state['clients']['legacy00aa']={
  'hostname':'legacy-ssh',
  'services':{
    'ssh':{'id':'ssh','name':'SSH','protocol':'tcp','local_ip':'127.0.0.1','local_port':22,'remote_port':6010,'preset':'ssh','ssh_user':'legacyuser','enabled':True},
  },
}
p.write_text(json.dumps(state, indent=2, sort_keys=True)+'\n')
PY
printf 'RELEASE\n' | python3 "$ROOT/tools/frp-release-client" legacy00aa \
  >"$WORKDIR/legacy-client-release.out"
python3 - "$TREE/var/lib/frp-auto-deploy/registry.json" <<'PY' || fail "legacy client release"
import json,sys
from pathlib import Path
state=json.loads(Path(sys.argv[1]).read_text())
assert 'legacy00aa' in state['clients']
assert state['clients']['legacy00aa']['services'] == {}
assert 'aabbccdd' in state['clients']
assert state['clients']['aabbccdd']['services']['ssh']['remote_port']==6002
assert all(
    svc.get('remote_port') != 6010
    for client in state['clients'].values()
    for svc in (client.get('services') or {}).values()
    if isinstance(svc, dict)
)
PY
pass "legacy client release reclaims port"

# Mutation selector rejects label/hostname
set +e
printf 'RELEASE\n' | python3 "$ROOT/tools/frp-release-client" dev-dp-mirror \
  >"$WORKDIR/mut-host.out" 2>"$WORKDIR/mut-host.err"
host_rc=$?
set -e
[[ "$host_rc" -ne 0 ]] || fail "release by hostname should fail"
grep -q 'mutation commands require immutable CLIENT ID' "$WORKDIR/mut-host.err" \
  || fail "hostname mutation error"
pass "mutation rejects hostname"

# shellcheck source=../lib/frp-common.sh
. "$ROOT/lib/frp-common.sh"
MARKER="$WORKDIR/harness.marker"
printf '%s' "$FRP_TEST_HARNESS_MAGIC" >"$MARKER"
STATUS_OUT="$WORKDIR/status.out"
if ! env \
  FRP_UPDATE_TEST_HARNESS=1 \
  FRP_UPDATE_TEST_MARKER="$MARKER" \
  FRP_DEPLOY_TEST_ROOT="$TREE" \
  FRP_UPDATE_ROOT="$TREE" \
  FRP_UPDATE_HOOK_SKIP_SYSTEMD=1 \
  FRP_STATUS_SKIP_UPSTREAM=1 \
  "$ROOT/tools/frp-server-status" >"$STATUS_OUT"; then
  fail "status exited non-zero"
fi
# aabbccdd (with services) + legacy00aa (empty services after release) = 2
grep -q 'Clients         : 2' "$STATUS_OUT" || fail "status client count after release"
# reserved 6000 + ssh 6002 + api 6004 = 3 (legacy port released)
grep -q 'Reserved ports  : 3' "$STATUS_OUT" || fail "status reserved ports"
pass "frp-server-status generic"

echo
echo "MANAGEMENT_COMMAND_TEST=PASS"
