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

python3 - "$TREE/etc/frp-auto-deploy/config.json" "$TREE/var/lib/frp-auto-deploy/registry.json" <<'PY'
import json,sys
from pathlib import Path
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
if grep -qE 'ssh_port|https_port' "$OUT"; then
  fail "clients leaked legacy fields"
fi
pass "frp-clients generic"

INFO="$WORKDIR/info.out"
python3 "$ROOT/tools/frp-client-info" dev-dp-mirror >"$INFO"
grep -q 'Hostname' "$INFO" || fail "info hostname field"
grep -q 'dev-dp-mirror' "$INFO" || fail "info hostname"
grep -q 'Services' "$INFO" || fail "info services field"
grep -q '2' "$INFO" || fail "info enabled count"
grep -q '127.0.0.1:22' "$INFO" || fail "info ssh target"
grep -q '203.0.113.10:6002' "$INFO" || fail "info ssh public"
grep -q 'ssh -p 6002 aella@203.0.113.10' "$INFO" || fail "info ssh connect"
grep -q '127.0.0.1:3000' "$INFO" || fail "info grafana target"
if grep -q '6004' "$INFO"; then
  fail "info should omit disabled service"
fi
pass "frp-client-info generic"

cp "$TREE/var/lib/frp-auto-deploy/registry.json" "$WORKDIR/registry.before"
printf 'nope\n' | python3 "$ROOT/tools/frp-release-client" client-b >"$WORKDIR/cancel.out" 2>"$WORKDIR/cancel.err" && fail "cancel should fail"
python3 - "$TREE/var/lib/frp-auto-deploy/registry.json" "$WORKDIR/registry.before" <<'PY'
import sys
from pathlib import Path
assert Path(sys.argv[1]).read_bytes() == Path(sys.argv[2]).read_bytes()
PY
printf 'RELEASE\n' | python3 "$ROOT/tools/frp-release-client" client-b >"$WORKDIR/release.out"
python3 - "$TREE/var/lib/frp-auto-deploy/registry.json" <<'PY' || fail "release did not drop client-b"
import json,sys
from pathlib import Path
state=json.loads(Path(sys.argv[1]).read_text())
assert 'eeff0011' not in state['clients']
assert 'aabbccdd' in state['clients']
assert state['clients']['aabbccdd']['services']['ssh']['remote_port']==6002
assert state['clients']['aabbccdd']['services']['api']['remote_port']==6004
PY
grep -q 'http: 6005' "$WORKDIR/release.out" || fail "release listed service port"
pass "frp-release-client generic"

printf 'nope\n' | python3 "$ROOT/tools/frp-release-service" dev-dp-mirror grafana >"$WORKDIR/svc-cancel.out" 2>"$WORKDIR/svc-cancel.err" && fail "service release cancel should fail"
python3 - "$TREE/var/lib/frp-auto-deploy/registry.json" <<'PY' || fail "cancel mutated grafana"
import json,sys
from pathlib import Path
state=json.loads(Path(sys.argv[1]).read_text())
assert 'grafana' in state['clients']['aabbccdd']['services']
PY
printf 'RELEASE\n' | python3 "$ROOT/tools/frp-release-service" dev-dp-mirror grafana >"$WORKDIR/svc-release.out"
python3 - "$TREE/var/lib/frp-auto-deploy/registry.json" <<'PY' || fail "service release"
import json,sys
from pathlib import Path
state=json.loads(Path(sys.argv[1]).read_text())
svc=state['clients']['aabbccdd']['services']
assert 'grafana' not in svc
assert svc['ssh']['remote_port']==6002
assert svc['api']['remote_port']==6004
PY
grep -q 'service grafana' "$WORKDIR/svc-release.out" || fail "service release output"
pass "frp-release-service generic"

printf 'REVOKE\n' | python3 "$ROOT/tools/frp-revoke-client" dev-dp-mirror >"$WORKDIR/revoke.out"
python3 - "$TREE/var/lib/frp-auto-deploy/registry.json" <<'PY' || fail "revoke"
import json,sys
from pathlib import Path
state=json.loads(Path(sys.argv[1]).read_text())
client=state['clients']['aabbccdd']
assert client.get('mgmt_status')=='revoked'
assert client['services']['ssh']['remote_port']==6002
assert client['services']['api']['remote_port']==6004
assert 'grafana' not in client['services']
PY
grep -q 'Revoking management identity' "$WORKDIR/revoke.out" || fail "revoke header"
grep -q 'ssh: 6002' "$WORKDIR/revoke.out" || fail "revoke listed reservation"
if grep -qi 'private key\|mgmt_mac_key\|BEGIN PUBLIC' "$WORKDIR/revoke.out"; then
  fail "revoke leaked identity material"
fi
pass "frp-revoke-client keeps reservations"

printf 'RELEASE\n' | python3 "$ROOT/tools/frp-release-client" dev-dp-mirror --force >"$WORKDIR/revoke-release.out"
python3 - "$TREE/var/lib/frp-auto-deploy/registry.json" <<'PY' || fail "release after revoke"
import json,sys
from pathlib import Path
state=json.loads(Path(sys.argv[1]).read_text())
assert 'aabbccdd' not in state['clients']
PY
pass "admin release still works after revoke"

# Restore a client so status still has one remaining host (client-b was already released).
python3 - "$TREE/var/lib/frp-auto-deploy/registry.json" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1])
state=json.loads(p.read_text())
state['clients']['aabbccdd']={
  'hostname':'dev-dp-mirror',
  'services':{
    'ssh':{'name':'SSH','protocol':'tcp','local_ip':'127.0.0.1','local_port':22,'remote_port':6002,'preset':'ssh','ssh_user':'aella','enabled':True},
    'api':{'name':'API','protocol':'tcp','local_ip':'127.0.0.1','local_port':8080,'remote_port':6004,'preset':'custom','enabled':False},
  },
}
p.write_text(json.dumps(state, indent=2, sort_keys=True)+'\n')
PY

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
grep -q 'Clients         : 1' "$STATUS_OUT" || fail "status client count after release"
# reserved 6000 + ssh 6002 + api 6004 = 3 (grafana released)
grep -q 'Reserved ports  : 3' "$STATUS_OUT" || fail "status reserved ports"
pass "frp-server-status generic"

echo
echo "MANAGEMENT_COMMAND_TEST=PASS"
