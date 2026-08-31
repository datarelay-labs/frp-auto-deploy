#!/usr/bin/env bash
# Server fleet visibility & diagnostics (P0/P1).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }

export FRP_SKIP_SYSTEMD=1
export FRP_CTL_BIN_DIR="$ROOT/tools"
export HOME="$WORKDIR/home"
mkdir -p "$HOME"

SERVER="$WORKDIR/server"
mkdir -p \
  "$SERVER/etc/frp-auto-deploy" \
  "$SERVER/etc/frp" \
  "$SERVER/var/lib/frp-auto-deploy" \
  "$SERVER/var/log/frp-auto-deploy" \
  "$SERVER/usr/local/lib/frp-auto-deploy" \
  "$SERVER/usr/local/sbin" \
  "$SERVER/usr/local/bin"

install_server_tree() {
  for f in frp_client_registry.py frp_audit.py frp_fleet.py frp_server_lifecycle.py \
    frp_doctor.py frp_ctl_grammar.py; do
    install -m 0644 "$ROOT/lib/$f" "$SERVER/usr/local/lib/frp-auto-deploy/"
  done
  install -m 0755 "$ROOT/tools/frpctl" "$SERVER/usr/local/bin/frpctl"
  install -m 0755 "$ROOT/tools/frp-clients" "$SERVER/usr/local/sbin/frp-clients"
  install -m 0755 "$ROOT/tools/frp-client-info" "$SERVER/usr/local/sbin/frp-client-info"
}

cat >"$SERVER/etc/frp-auto-deploy/config.json" <<'EOF'
{
  "registry_file": "/var/lib/frp-auto-deploy/registry.json",
  "port_start": 6000,
  "port_end": 6004,
  "client_stale_days": 30,
  "deployment_mode": "direct",
  "public_host": "203.0.113.10",
  "enrollments_dir": "/var/lib/frp-auto-deploy/enrollments",
  "bootstrap_dir": "/var/lib/frp-auto-deploy/bootstrap",
  "tls_server_cert": "/etc/frp-auto-deploy/pki/server.crt"
}
EOF

cat >"$SERVER/etc/frp-auto-deploy/version" <<'EOF'
PROJECT_VERSION=2.1.1
RELEASE_CHANNEL=stable
SOURCE_REF=abc123
BUNDLE_SHA256=deadbeef
FRP_VERSION=0.70.1
EOF

cat >"$SERVER/var/lib/frp-auto-deploy/registry.json" <<'EOF'
{
  "schema_version": 2,
  "clients": {
    "11111111111111111111111111111111": {
      "hostname": "recent-host",
      "label": "recent",
      "mgmt_status": "enrolled",
      "last_mgmt_seen_at": "2099-01-01T00:00:00Z",
      "reported_project_version": "2.1.1",
      "reported_frp_version": "0.70.1",
      "build_reported_at": "2099-01-01T00:00:00Z",
      "services": {
        "ssh": {
          "remote_port": 6000,
          "enabled": true,
          "protocol": "tcp",
          "local_ip": "127.0.0.1",
          "local_port": 22
        }
      }
    },
    "22222222222222222222222222222222": {
      "hostname": "stale-host",
      "label": "stale",
      "mgmt_status": "enrolled",
      "last_mgmt_seen_at": "2020-01-01T00:00:00Z",
      "services": {
        "ssh": {
          "remote_port": 6001,
          "enabled": true,
          "protocol": "tcp",
          "local_ip": "127.0.0.1",
          "local_port": 22
        }
      }
    },
    "33333333333333333333333333333333": {
      "hostname": "unknown-host",
      "label": "unknown",
      "mgmt_status": "enrolled",
      "services": {
        "web": {
          "remote_port": 6002,
          "enabled": false,
          "protocol": "tcp",
          "local_ip": "127.0.0.1",
          "local_port": 8080
        }
      }
    },
    "44444444444444444444444444444444": {
      "hostname": "drift-host",
      "label": "drift",
      "mgmt_status": "enrolled",
      "last_mgmt_seen_at": "2099-01-01T00:00:00Z",
      "reported_project_version": "2.0.0",
      "build_reported_at": "2099-01-01T00:00:00Z",
      "services": {
        "ssh": {
          "remote_port": 6003,
          "enabled": true,
          "protocol": "tcp",
          "local_ip": "127.0.0.1",
          "local_port": 22
        }
      }
    },
    "55555555555555555555555555555555": {
      "hostname": "revoked-host",
      "label": "revoked",
      "mgmt_status": "revoked",
      "last_mgmt_seen_at": "2020-01-01T00:00:00Z",
      "services": {
        "ssh": {
          "remote_port": 6004,
          "enabled": true,
          "protocol": "tcp",
          "local_ip": "127.0.0.1",
          "local_port": 22
        }
      }
    }
  },
  "reserved": [6004]
}
EOF
chmod 600 "$SERVER/var/lib/frp-auto-deploy/registry.json"
echo 'token-fixture-not-real' >"$SERVER/etc/frp/server_token"

install_server_tree

run_ctl() {
  FRP_CTL_TEST_ROOT="$SERVER" FRP_DEPLOY_TEST_ROOT="$SERVER" \
    "$ROOT/tools/frpctl" "$@"
}

PYTHONPATH="$ROOT/lib" FRP_DEPLOY_TEST_ROOT="$SERVER" python3 - <<'PY'
import frp_client_registry as creg
from datetime import datetime, timezone, timedelta

client = {'mgmt_status': 'enrolled', 'last_mgmt_seen_at': datetime.now(timezone.utc).isoformat()}
if creg.mgmt_activity_class(client, 30 * 86400) != 'recent':
    raise SystemExit('recent class failed')
stale = {'mgmt_status': 'enrolled', 'last_mgmt_seen_at': '2020-01-01T00:00:00Z'}
if creg.mgmt_activity_class(stale, 30 * 86400) != 'stale':
    raise SystemExit('stale class failed')
unknown = {'mgmt_status': 'enrolled'}
if creg.mgmt_activity_class(unknown, 30 * 86400) != 'unknown':
    raise SystemExit('unknown class failed')
rev = {'mgmt_status': 'revoked', 'last_mgmt_seen_at': '2020-01-01T00:00:00Z'}
if creg.mgmt_activity_class(rev, 30 * 86400) != 'revoked':
    raise SystemExit('revoked class failed')
expected = {'PROJECT_VERSION': '2.1.1', 'FRP_VERSION': '0.70.1'}
cur = {'reported_project_version': '2.1.1', 'build_reported_at': '2099-01-01T00:00:00Z'}
if creg.build_drift_class(cur, expected) != 'current':
    raise SystemExit('current build failed')
dr = {'reported_project_version': '2.0.0', 'build_reported_at': '2099-01-01T00:00:00Z'}
if creg.build_drift_class(dr, expected) != 'drift':
    raise SystemExit('drift build failed')
if creg.build_drift_class({}, expected) != 'unknown':
    raise SystemExit('unknown build failed')
print('PASS registry semantics')
PY

run_ctl show fleet >"$WORKDIR/fleet.out" || fail "show fleet"
grep -q 'FRP Fleet Overview' "$WORKDIR/fleet.out" || fail "fleet header"
grep -q 'Mgmt recent' "$WORKDIR/fleet.out" || fail "fleet mgmt recent"
grep -q 'Mgmt stale' "$WORKDIR/fleet.out" || fail "fleet mgmt stale"
grep -q 'not FRP tunnel activity' "$WORKDIR/fleet.out" || fail "fleet mgmt note"

run_ctl show ports >"$WORKDIR/ports.out" || fail "show ports"
grep -q 'Public Port Inventory' "$WORKDIR/ports.out" || fail "ports header"
grep -q '6002' "$WORKDIR/ports.out" || fail "disabled port listed"
grep -q 'reserved' "$WORKDIR/ports.out" || fail "disabled reservation"
grep -q '6004' "$WORKDIR/ports.out" || fail "revoked reservation"

run_ctl show clients --stale >"$WORKDIR/stale.out" || fail "show clients --stale"
grep -q 'Management-stale clients' "$WORKDIR/stale.out" || fail "stale title"
grep -q 'stale-host' "$WORKDIR/stale.out" || fail "stale client listed"
grep -q 'not FRP tunnel state' "$WORKDIR/stale.out" || fail "stale semantics note"

run_ctl show clients --build-drift >"$WORKDIR/drift.out" || fail "show clients --build-drift"
grep -q 'drift-host' "$WORKDIR/drift.out" || fail "drift client"

run_ctl test >"$WORKDIR/test.out" || true
grep -q 'FRP Server Test' "$WORKDIR/test.out" || fail "server test header"
grep -q 'RESULT=' "$WORKDIR/test.out" || fail "server test result"
grep -q 'NOT TESTED' "$WORKDIR/test.out" || fail "external reachability not claimed"

python3 - "$SERVER/var/log/frp-auto-deploy/audit.jsonl" <<'PY'
import json, sys
from pathlib import Path
from datetime import datetime, timezone, timedelta
p = Path(sys.argv[1])
p.parent.mkdir(parents=True, exist_ok=True)
now = datetime.now(timezone.utc)
rows = [
    {"ts": now.isoformat(), "event": "client.updated", "actor": "test", "client_id": "11111111", "meta": {"client_id": "11111111"}},
    {"ts": (now - timedelta(days=10)).isoformat(), "event": "group.created", "actor": "test", "meta": {"group": "prod"}},
]
p.write_text('\n'.join(json.dumps(r) for r in rows) + '\n')
PY

run_ctl show audit --since 7d --format json >"$WORKDIR/audit.json" || fail "audit json"
grep -q 'client.updated' "$WORKDIR/audit.json" || fail "audit filter since"
grep -qi 'secret\|token\|password' "$WORKDIR/audit.json" && fail "audit secret leak" || true

run_ctl support-bundle >"$WORKDIR/bundle.out" 2>&1 || fail "support bundle"
grep -q 'Support bundle written' "$WORKDIR/bundle.out" || fail "bundle path"
bundle_path="$(sed -n 's/^Support bundle written to: //p' "$WORKDIR/bundle.out" | tail -1)"
[[ -n "$bundle_path" && -f "$bundle_path" ]] || fail "bundle file"
perm="$(stat -c '%a' "$bundle_path")"
[[ "$perm" == "600" ]] || fail "bundle permission $perm"
tar -tzf "$bundle_path" | grep -q 'fleet.txt' || fail "bundle fleet"
tar -tzf "$bundle_path" | grep -q 'ports.txt' || fail "bundle ports"
tar -xOzf "$bundle_path" registry-summary.redacted.json 2>/dev/null | grep -qi 'private_key' && fail "registry secret" || true

pass "server fleet visibility suite"
