#!/usr/bin/env bash
# Role-aware frpctl dispatcher. Uses fixtures; does not mutate a live host.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }

chmod +x "$ROOT/tools/frpctl" "$ROOT/tools/frp-client"

CTL="$ROOT/tools/frpctl"
export FRP_CTL_BIN_DIR="$ROOT/tools"
export FRP_CLIENT_LIB="$ROOT/lib/frp-client-common.sh"
export FRP_SKIP_SYSTEMD=1

write_client_tree() {
  local tree="$1"
  mkdir -p "$tree/etc/frp" "$tree/etc/frp-auto-deploy"
  python3 - "$tree/etc/frp/client-state.json" <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
    "schema_version": 1,
    "allocator_url": "http://127.0.0.1:9/enroll",
    "frp_server": "203.0.113.10",
    "frp_server_port": 443,
    "hostname": "ctl-client",
    "machine_id": "00112233445566778899aabbccddeeff",
    "host_id": "ctl-client-00112233",
    "services": {
        "ssh": {
            "id": "ssh", "name": "SSH", "preset": "ssh", "protocol": "tcp",
            "local_ip": "127.0.0.1", "local_port": 22, "remote_port": 6002,
            "enabled": True, "ssh_user": "aella",
        }
    },
}, indent=2, sort_keys=True) + "\n")
PY
  cat >"$tree/etc/frp-auto-deploy/version" <<'EOF'
PROJECT_VERSION=1.2.0
FRP_VERSION=0.70.1
EOF
}

write_server_tree() {
  local tree="$1"
  mkdir -p "$tree/etc/frp-auto-deploy" "$tree/var/lib/frp-auto-deploy"
  python3 - "$tree/etc/frp-auto-deploy/config.json" <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
    "public_ip": "203.0.113.10",
    "control_port": 443,
    "port_start": 6000,
    "port_end": 6098,
    "listen_port": 6099,
    "allocator_public_url": "http://203.0.113.10/enroll",
}, indent=2, sort_keys=True) + "\n")
PY
  cat >"$tree/etc/frp-auto-deploy/version" <<'EOF'
PROJECT_VERSION=1.2.0
FRP_VERSION=0.70.1
EOF
}

CLIENT="$WORKDIR/client"
SERVER="$WORKDIR/server"
BOTH="$WORKDIR/both"
write_client_tree "$CLIENT"
write_server_tree "$SERVER"
write_client_tree "$BOTH"
write_server_tree "$BOTH"

# --- Help / unknown
"$CTL" help >"$WORKDIR/help.out"
grep -q 'only command you need to remember' "$WORKDIR/help.out" || fail "help remember line"
grep -q 'sudo frpctl' "$WORKDIR/help.out" || fail "help sudo frpctl"
grep -q 'frps' "$WORKDIR/help.out" || fail "help mentions frps"
grep -q 'frpc' "$WORKDIR/help.out" || fail "help mentions frpc"
"$CTL" --help >"$WORKDIR/help2.out"
grep -q 'Usage: frpctl' "$WORKDIR/help2.out" || fail "--help usage"
if "$CTL" definitely-not-a-command >"$WORKDIR/unknown.out" 2>"$WORKDIR/unknown.err"; then
  fail "unknown command should fail"
fi
grep -q 'unknown command' "$WORKDIR/unknown.err" || fail "unknown error"
grep -q 'Usage: frpctl' "$WORKDIR/unknown.err" || fail "unknown usage"
pass "FRPCTL_HELP"
pass "FRPCTL_UNKNOWN_COMMAND_RECOVERY"

# --- Client role
export FRP_CTL_TEST_ROOT="$CLIENT"
export FRP_CLIENT_TEST_ROOT="$CLIENT"
FRP_CTL_TEST_MENU=1 "$CTL" >"$WORKDIR/client-menu.out"
grep -q 'Role            : Client' "$WORKDIR/client-menu.out" || fail "client role"
grep -q 'Project version : 1.2.0' "$WORKDIR/client-menu.out" || fail "client menu version"
grep -q '1) Manage services' "$WORKDIR/client-menu.out" || fail "client menu manage"
grep -q '4) Update FRP Auto Deploy' "$WORKDIR/client-menu.out" || fail "client menu update"
pass "FRPCTL_CLIENT_DETECTION"

"$CTL" status >"$WORKDIR/client-status.out"
grep -q 'FRP Client' "$WORKDIR/client-status.out" || fail "client status header"
grep -q 'Hostname        : ctl-client' "$WORKDIR/client-status.out" || fail "client status hostname"
pass "FRPCTL_CLIENT_STATUS"

export FRP_CTL_DRY_RUN=1
"$CTL" manage >"$WORKDIR/client-manage.out"
grep -qx 'DISPATCH frp-client' "$WORKDIR/client-manage.out" || fail "manage dispatch"
"$CTL" update >"$WORKDIR/client-update.out"
grep -qx 'DISPATCH frp-client update' "$WORKDIR/client-update.out" || fail "client update dispatch"
"$CTL" info >"$WORKDIR/client-info.out"
grep -qx 'DISPATCH frp-client info' "$WORKDIR/client-info.out" || fail "info dispatch"
unset FRP_CTL_DRY_RUN
pass "FRPCTL_CLIENT_MANAGE_DISPATCH"
pass "FRPCTL_CLIENT_UPDATE_DISPATCH"

# Client-only host must not dispatch server mutations.
if "$CTL" clients >"$WORKDIR/client-clients.out" 2>"$WORKDIR/client-clients.err"; then
  fail "client host should reject server clients command"
fi
grep -q 'installed FRP server' "$WORKDIR/client-clients.err" || fail "client reject server command"

# --- Server role
unset FRP_CLIENT_TEST_ROOT
export FRP_CTL_TEST_ROOT="$SERVER"
FRP_CTL_TEST_MENU=1 "$CTL" >"$WORKDIR/server-menu.out"
grep -q 'Role            : Server' "$WORKDIR/server-menu.out" || fail "server role"
grep -q '2) List clients' "$WORKDIR/server-menu.out" || fail "server menu clients"
grep -q '5) Revoke management access' "$WORKDIR/server-menu.out" || fail "server menu revoke"
pass "FRPCTL_SERVER_DETECTION"

export FRP_CTL_DRY_RUN=1
export FRP_UPDATE_TEST_HARNESS=0
"$CTL" status >"$WORKDIR/server-status.out"
grep -qx 'DISPATCH frp-server-status' "$WORKDIR/server-status.out" || fail "server status dispatch"
"$CTL" clients >"$WORKDIR/server-clients.out"
grep -qx 'DISPATCH frp-clients' "$WORKDIR/server-clients.out" || fail "clients dispatch"
"$CTL" create-client >"$WORKDIR/server-create.out"
grep -qx 'DISPATCH frp-create-client' "$WORKDIR/server-create.out" || fail "create-client dispatch"
"$CTL" client-info customer-dp >"$WORKDIR/server-info.out"
grep -qx 'DISPATCH frp-client-info customer-dp' "$WORKDIR/server-info.out" || fail "client-info dispatch"
"$CTL" revoke-client customer-dp >"$WORKDIR/server-revoke.out"
grep -qx 'DISPATCH frp-revoke-client customer-dp' "$WORKDIR/server-revoke.out" || fail "revoke dispatch"
"$CTL" release-service customer-dp grafana >"$WORKDIR/server-relsvc.out"
grep -qx 'DISPATCH frp-release-service customer-dp grafana' "$WORKDIR/server-relsvc.out" || fail "release-service dispatch"
"$CTL" release-client customer-dp >"$WORKDIR/server-relcli.out"
grep -qx 'DISPATCH frp-release-client customer-dp' "$WORKDIR/server-relcli.out" || fail "release-client dispatch"
"$CTL" update >"$WORKDIR/server-update.out"
grep -qx 'DISPATCH frp-update' "$WORKDIR/server-update.out" || fail "server update dispatch"
unset FRP_CTL_DRY_RUN
pass "FRPCTL_SERVER_STATUS"
pass "FRPCTL_CLIENTS_DISPATCH"
pass "FRPCTL_CREATE_CLIENT_DISPATCH"
pass "FRPCTL_REVOKE_DISPATCH"
pass "FRPCTL_RELEASE_SERVICE_DISPATCH"

# Existing operator commands still exist.
for cmd in frp-client frp-clients frp-client-info frp-create-client \
  frp-release-client frp-release-service frp-revoke-client \
  frp-server-status frp-update frp-set-client-installer-url; do
  [[ -e "$ROOT/tools/$cmd" ]] || fail "missing command $cmd"
done
pass "EXISTING_COMMANDS_PRESERVED"

# Dual role is not guessed destructively.
export FRP_CTL_TEST_ROOT="$BOTH"
FRP_CTL_TEST_MENU=1 "$CTL" >"$WORKDIR/both-menu.out"
grep -q 'Role            : Client + Server' "$WORKDIR/both-menu.out" || fail "both role"
grep -q '1) Client operations' "$WORKDIR/both-menu.out" || fail "both menu"
export FRP_CTL_DRY_RUN=1
"$CTL" status >"$WORKDIR/both-status.out"
grep -q 'DISPATCH frp-client status' "$WORKDIR/both-status.out" || fail "both status client"
grep -q 'DISPATCH frp-server-status' "$WORKDIR/both-status.out" || fail "both status server"
unset FRP_CTL_DRY_RUN

echo "FRPCTL_TESTS=PASS"
