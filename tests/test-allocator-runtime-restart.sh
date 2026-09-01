#!/usr/bin/env bash
# P1-2: changing allocator runtime deps must record restart frp-port-allocator.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/frp-common.sh
. "$ROOT/lib/frp-common.sh"
UPDATE="$ROOT/tools/frp-project-update"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
cat >"$WORKDIR/nginx" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 0755 "$WORKDIR/nginx"
export FRP_NGINX_BIN="$WORKDIR/nginx"

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }

# Canonical SoT must include data-plane closure and exclude non-runtime tools.
python3 - "$ROOT" <<'PY' || fail "runtime SoT"
import sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]) / "lib"))
from frp_project_files import ALLOCATOR_RUNTIME_LIB_BASENAMES, FRONTEND_RUNTIME_LIB_BASENAMES
need = {
    "frp-port-allocator.py", "frp_data_plane_auth.py", "frp_plugin_server.py",
    "frp_proxy_leases.py", "frp_server_config.py", "frp_frontend.py",
    "frp_mgmt_auth.py", "frp_client_registry.py", "frp_control_locks.py",
}
missing = need - set(ALLOCATOR_RUNTIME_LIB_BASENAMES)
assert not missing, missing
assert "frp_release_guard.py" not in ALLOCATOR_RUNTIME_LIB_BASENAMES
assert "frp_pki.py" not in ALLOCATOR_RUNTIME_LIB_BASENAMES
assert "frp_frontend.py" in FRONTEND_RUNTIME_LIB_BASENAMES
print("ok")
PY

upgrade_sh="$ROOT/lib/frp-server-upgrade.sh"
install_sh="$ROOT/install-server.sh"
grep -q 'allocator-runtime-rels' "$upgrade_sh" || fail "upgrade missing allocator-runtime-rels"
grep -q 'frontend-runtime-rels' "$upgrade_sh" || fail "upgrade missing frontend-runtime-rels"
grep -q 'allocator-runtime-rels' "$install_sh" || fail "install-server missing allocator-runtime-rels"
echo "SERVER_RESTART_DEPENDENCY_PARITY=PASS"

setup_tree() {
  local tree="$1"
  rm -rf "$tree"
  mkdir -p \
    "$tree/etc/frp-auto-deploy/pki" "$tree/etc/frp" \
    "$tree/var/lib/frp-auto-deploy/enrollments/client-a" \
    "$tree/var/lib/frp-auto-deploy/bootstrap/client-a" \
    "$tree/usr/local/bin" "$tree/usr/local/lib/frp-auto-deploy" \
    "$tree/usr/local/sbin" "$tree/etc/systemd/system"
  cat >"$tree/usr/local/bin/frps" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && echo "0.70.1"
exit 0
EOF
  chmod 0755 "$tree/usr/local/bin/frps"
  printf 'server-token-preserve\n' >"$tree/etc/frp/server_token"
  printf 'ca-preserve\n' >"$tree/etc/frp-auto-deploy/pki/ca.crt"
  printf 'ca-key-preserve\n' >"$tree/etc/frp-auto-deploy/pki/ca.key"
  printf 'server-cert-preserve\n' >"$tree/etc/frp-auto-deploy/pki/server.crt"
  printf 'server-key-preserve\n' >"$tree/etc/frp-auto-deploy/pki/server.key"
  cat >"$tree/etc/frp/frps.toml" <<'EOF'
bindPort = 7000
auth.tokenSource.file.path = "/etc/frp/server_token"
allowPorts = [{ start = 6000, end = 6098 }]
EOF
  cat >"$tree/etc/frp-auto-deploy/config.json" <<'EOF'
{
  "public_host": "server.example",
  "deployment_mode": "single443",
  "frp_control_public_port": 443,
  "frp_control_listen_port": 7000,
  "allocator_public_port": 443,
  "allocator_listen_port": 6099,
  "allocator_public_url": "https://server.example/enroll",
  "port_start": 6000,
  "port_end": 6098,
  "client_installer_url": "https://updates.example/client.sh"
}
EOF
  printf 'events {}\nhttp {\n  server {\n    listen 443 ssl;\n  }\n}\n' \
    >"$tree/etc/frp-auto-deploy/frontend.conf"
  cat >"$tree/var/lib/frp-auto-deploy/registry.json" <<'EOF'
{"schema_version": 2, "reserved": [], "clients": {}}
EOF
  cat >"$tree/etc/frp-auto-deploy/version" <<'EOF'
PROJECT_VERSION=2.0.0
FRP_VERSION=0.70.1
RELEASE_CHANNEL=stable
SOURCE_REF=v2.1.1
BUNDLE_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF
  # Install current project files as the "old" baseline.
  env FRP_SERVER_TEST_ROOT="$tree" FRP_RELEASE_CHANNEL=stable \
    "$UPDATE" --source "$ROOT" >/dev/null
  chmod 600 "$tree/etc/frp/server_token" "$tree/var/lib/frp-auto-deploy/registry.json"
}

run_from_source() {
  local tree="$1" source="$2"
  rm -f "$tree/var/lib/frp-auto-deploy/install-actions.log"
  env FRP_SERVER_TEST_ROOT="$tree" FRP_RELEASE_CHANNEL=stable \
    "$UPDATE" --source "$source"
}

# --- data-plane auth only ---
TREE="$WORKDIR/dp"
SRC="$WORKDIR/src-dp"
setup_tree "$TREE"
cp -a "$ROOT" "$SRC"
printf '\n# marker-data-plane-auth\n' >>"$SRC/lib/frp_data_plane_auth.py"
run_from_source "$TREE" "$SRC" >"$WORKDIR/dp.out"
grep -q 'restart frp-port-allocator' "$TREE/var/lib/frp-auto-deploy/install-actions.log" \
  || fail "data-plane change did not restart allocator"
grep -q 'marker-data-plane-auth' "$TREE/usr/local/lib/frp-auto-deploy/frp_data_plane_auth.py" \
  || fail "data-plane file not installed"
echo "DATA_PLANE_AUTH_CHANGE_RESTART=PASS"
echo "ALLOCATOR_RUNTIME_DEP_CHANGE_RESTART=PASS"

# --- plugin server only ---
TREE2="$WORKDIR/plugin"
SRC2="$WORKDIR/src-plugin"
setup_tree "$TREE2"
cp -a "$ROOT" "$SRC2"
printf '\n# marker-plugin-server\n' >>"$SRC2/lib/frp_plugin_server.py"
run_from_source "$TREE2" "$SRC2" >"$WORKDIR/plugin.out"
grep -q 'restart frp-port-allocator' "$TREE2/var/lib/frp-auto-deploy/install-actions.log" \
  || fail "plugin-server change did not restart allocator"
echo "PLUGIN_SERVER_CHANGE_RESTART=PASS"

# --- non-runtime file only (release_guard + unrelated) ---
TREE3="$WORKDIR/nort"
SRC3="$WORKDIR/src-nort"
setup_tree "$TREE3"
cp -a "$ROOT" "$SRC3"
printf '\n# marker-release-guard\n' >>"$SRC3/lib/frp_release_guard.py"
run_from_source "$TREE3" "$SRC3" >"$WORKDIR/nort.out"
if grep -q 'restart frp-port-allocator' "$TREE3/var/lib/frp-auto-deploy/install-actions.log" 2>/dev/null; then
  fail "non-runtime release_guard falsely restarted allocator"
fi
grep -q 'marker-release-guard' "$TREE3/usr/local/lib/frp-auto-deploy/frp_release_guard.py" \
  || fail "release_guard not installed"
echo "NON_RUNTIME_FILE_NO_FALSE_RESTART=PASS"

pass "allocator-runtime-restart"
