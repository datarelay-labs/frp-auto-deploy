#!/usr/bin/env bash
# Installed-artifact smoke: bootstrap-server → isolated root (no live services).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }

ensure_bundle() {
  local bundle="$ROOT/dist/bootstrap-server.sh"
  local need=0
  if [[ ! -x "$bundle" ]]; then
    need=1
  elif [[ "$ROOT/scripts/build-bundles.py" -nt "$bundle" ]] ||
       [[ "$ROOT/lib/frp_fleet.py" -nt "$bundle" ]] ||
       [[ "$ROOT/lib/frp_server_lifecycle.py" -nt "$bundle" ]] ||
       [[ "$ROOT/tools/frpctl" -nt "$bundle" ]] ||
       [[ "$ROOT/tools/frpcli" -nt "$bundle" ]]; then
    need=1
  elif ! grep -q 'frp_fleet.py' "$bundle"; then
    need=1
  elif ! grep -q 'frpcli' "$bundle"; then
    need=1
  elif ! grep -q 'frp_data_plane_auth.py' "$bundle"; then
    need=1
  fi
  if [[ "$need" == "1" ]]; then
    bash "$ROOT/scripts/build-bundles.sh" >/dev/null
  fi
  [[ -x "$bundle" ]] || fail "bootstrap-server.sh missing after build"
  grep -q 'frp_fleet.py' "$bundle" || fail "bundle missing frp_fleet.py"
  grep -q 'frp_server_lifecycle.py' "$bundle" || fail "bundle missing server lifecycle"
  grep -q 'tools/frpcli' "$bundle" || fail "bundle missing frpcli"
  grep -q 'frp_data_plane_auth.py' "$bundle" || fail "bundle missing frp_data_plane_auth.py"
  grep -q 'frp_proxy_leases.py' "$bundle" || fail "bundle missing frp_proxy_leases.py"
  grep -q 'frp_plugin_server.py' "$bundle" || fail "bundle missing frp_plugin_server.py"
  grep -q 'frp_release_guard.py' "$bundle" || fail "bundle missing frp_release_guard.py"
}

setup_server_tree() {
  local tree="$1"
  mkdir -p \
    "$tree/etc/frp-auto-deploy/pki" "$tree/etc/frp" \
    "$tree/var/lib/frp-auto-deploy" "$tree/var/log/frp-auto-deploy" \
    "$tree/usr/local/bin" "$tree/usr/local/lib/frp-auto-deploy" \
    "$tree/usr/local/sbin" "$tree/etc/systemd/system"
  cat >"$tree/usr/local/bin/frps" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && echo "0.70.1"
exit 0
EOF
  chmod 0755 "$tree/usr/local/bin/frps"
  printf 'token-fixture-not-real\n' >"$tree/etc/frp/server_token"
  chmod 0600 "$tree/etc/frp/server_token"
  printf 'ca-fixture\n' >"$tree/etc/frp-auto-deploy/pki/ca.crt"
  printf 'bindPort = 7000\n' >"$tree/etc/frp/frps.toml"
  cat >"$tree/etc/frp-auto-deploy/config.json" <<'EOF'
{
  "public_host": "203.0.113.10",
  "deployment_mode": "direct",
  "frp_control_public_port": 443,
  "frp_control_listen_port": 7000,
  "allocator_listen_port": 6099,
  "allocator_public_url": "https://203.0.113.10:6099/enroll",
  "registry_file": "/var/lib/frp-auto-deploy/registry.json",
  "port_start": 6000,
  "port_end": 6004,
  "client_stale_days": 30,
  "enrollments_dir": "/var/lib/frp-auto-deploy/enrollments",
  "bootstrap_dir": "/var/lib/frp-auto-deploy/bootstrap",
  "tls_server_cert": "/etc/frp-auto-deploy/pki/server.crt"
}
EOF
  cat >"$tree/var/lib/frp-auto-deploy/registry.json" <<'EOF'
{
  "schema_version": 2,
  "groups": {
    "grp_aaaa1111": {
      "name": "fleet-manual",
      "type": "manual",
      "description": "manual fixture",
      "created_at": "2026-01-01T00:00:00Z"
    }
  },
  "clients": {
    "11111111111111111111111111111111": {
      "hostname": "recent-host",
      "label": "recent",
      "mgmt_status": "enrolled",
      "last_mgmt_seen_at": "2099-01-01T00:00:00Z",
      "reported_project_version": "2.1.1",
      "reported_frp_version": "0.70.1",
      "build_reported_at": "2099-01-01T00:00:00Z",
      "group_ids": ["grp_aaaa1111"],
      "tags": {"env": "prod"},
      "services": {
        "ssh": {
          "id": "ssh",
          "preset": "ssh",
          "remote_port": 6000,
          "enabled": true,
          "protocol": "tcp",
          "local_ip": "127.0.0.1",
          "local_port": 22,
          "ssh_user": "ubuntu"
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
          "id": "ssh",
          "preset": "ssh",
          "remote_port": 6001,
          "enabled": true,
          "protocol": "tcp",
          "local_ip": "127.0.0.1",
          "local_port": 22,
          "ssh_user": "ubuntu"
        }
      }
    }
  },
  "reserved": []
}
EOF
  chmod 0600 "$tree/var/lib/frp-auto-deploy/registry.json"
  cat >"$tree/etc/frp-auto-deploy/version" <<'EOF'
PROJECT_VERSION=2.1.0
FRP_VERSION=0.70.1
RELEASE_CHANNEL=stable
SOURCE_REF=v2.1.0
EOF
}

scan_tree_no_home() {
  local tree="$1"
  if grep -RInF '/home/aella' \
    --include='*.sh' --include='*.py' --include='frpctl' --include='frpcli' \
    "$tree/usr/local" 2>/dev/null; then
    fail "installed tree contains /home/aella path"
  fi
}

ensure_bundle
# shellcheck source=../VERSION
. "$ROOT/VERSION"
BUNDLE_SHA="$(sha256sum "$ROOT/dist/bootstrap-server.sh" | awk '{print $1}')"
SERVER="$WORKDIR/server"
setup_server_tree "$SERVER"

FRP_SERVER_TEST_ROOT="$SERVER" FRP_DEPLOY_TEST_ROOT="$SERVER" FRP_SKIP_SYSTEMD=1 \
  FRP_BUNDLE_SHA256="$BUNDLE_SHA" FRP_RELEASE_CHANNEL=stable \
  bash "$ROOT/dist/bootstrap-server.sh" --upgrade \
  >"$WORKDIR/install.out" 2>"$WORKDIR/install.err" \
  || fail "bootstrap-server --upgrade failed: $(tail -30 "$WORKDIR/install.err" "$WORKDIR/install.out")"

[[ -x "$SERVER/usr/local/sbin/frpctl" ]] || fail "installed frpctl missing"
[[ -x "$SERVER/usr/local/sbin/frpcli" ]] || fail "installed frpcli missing"
[[ -f "$SERVER/usr/local/lib/frp-auto-deploy/frp_fleet.py" ]] || fail "fleet module missing"
[[ -f "$SERVER/usr/local/lib/frp-auto-deploy/frp_server_lifecycle.py" ]] \
  || fail "server lifecycle missing"
[[ -f "$SERVER/usr/local/lib/frp-auto-deploy/frp_data_plane_auth.py" ]] \
  || fail "installed frp_data_plane_auth.py missing"
[[ -f "$SERVER/usr/local/lib/frp-auto-deploy/frp_proxy_leases.py" ]] \
  || fail "installed frp_proxy_leases.py missing"
[[ -f "$SERVER/usr/local/lib/frp-auto-deploy/frp_plugin_server.py" ]] \
  || fail "installed frp_plugin_server.py missing"
[[ -f "$SERVER/usr/local/lib/frp-auto-deploy/frp_release_guard.py" ]] \
  || fail "installed frp_release_guard.py missing"
pass "INSTALLED_FILES"
pass "INSTALLED_DATA_PLANE_MODULES"

export PATH="$SERVER/usr/local/sbin:$SERVER/usr/local/bin:/usr/bin:/bin"
unset FRP_CTL_BIN_DIR || true
export FRP_SERVER_TEST_ROOT="$SERVER"
export FRP_DEPLOY_TEST_ROOT="$SERVER"
export FRP_CTL_TEST_ROOT="$SERVER"
export FRP_SKIP_SYSTEMD=1
export HOME="$WORKDIR/home"
mkdir -p "$HOME"

command -v frpctl | grep -q "$SERVER/usr/local/sbin/frpctl" || fail "frpctl not from installed sbin"
command -v frpcli | grep -q "$SERVER/usr/local/sbin/frpcli" || fail "frpcli not from installed sbin"

frpctl help >"$WORKDIR/help.out" 2>&1 || fail "frpctl help"
pass "HELP"

frpctl show fleet >"$WORKDIR/fleet.out" 2>&1 || fail "show fleet"
grep -q 'FRP Fleet Overview' "$WORKDIR/fleet.out" || fail "fleet header"
pass "SHOW_FLEET"

frpctl show ports >"$WORKDIR/ports.out" 2>&1 || fail "show ports"
grep -q 'Public Port Inventory' "$WORKDIR/ports.out" || fail "ports header"
pass "SHOW_PORTS"

python3 - "$SERVER/var/log/frp-auto-deploy/audit.jsonl" <<'PY'
import json, sys
from pathlib import Path
from datetime import datetime, timezone, timedelta
p = Path(sys.argv[1])
p.parent.mkdir(parents=True, exist_ok=True)
now = datetime.now(timezone.utc)
rows = [
    {"ts": now.isoformat(), "event": "client.updated", "actor": "test",
     "client_id": "11111111", "meta": {"client_id": "11111111"}},
    {"ts": (now - timedelta(days=10)).isoformat(), "event": "group.created",
     "actor": "test", "meta": {"group": "prod"}},
]
p.write_text('\n'.join(json.dumps(r) for r in rows) + '\n')
PY

frpctl show audit --since 7d --format json >"$WORKDIR/audit.json" 2>&1 || fail "show audit"
grep -q 'client.updated' "$WORKDIR/audit.json" || fail "audit filter"
pass "SHOW_AUDIT"

frpctl test >"$WORKDIR/test.out" 2>&1 || true
grep -q 'RESULT=' "$WORKDIR/test.out" || fail "server test RESULT"
pass "TEST"

frpctl support-bundle --output "$WORKDIR/bundle.tar.gz" >"$WORKDIR/bundle.out" 2>&1 \
  || fail "support-bundle"
[[ -f "$WORKDIR/bundle.tar.gz" ]] || fail "bundle file"
tar -tzf "$WORKDIR/bundle.tar.gz" | grep -q 'fleet.txt' || fail "bundle fleet.txt"
pass "SUPPORT_BUNDLE"

scan_tree_no_home "$SERVER"
pass "NO_HOME_AELLA_IN_INSTALLED_TREE"

echo "INSTALLED_SERVER_ARTIFACT_TEST=PASS"
