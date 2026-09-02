#!/usr/bin/env bash
# Server default uninstall clears server-owned update-pending markers only.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }

TREE="$WORKDIR/tree"
mkdir -p "$TREE/var/lib/frp-auto-deploy" \
  "$TREE/usr/local/lib/frp-auto-deploy" \
  "$TREE/usr/local/sbin" \
  "$TREE/etc/frp-auto-deploy" \
  "$TREE/etc/frp"

# Minimal managed file so uninstall-rels has something to remove.
echo x >"$TREE/usr/local/sbin/frp-clients"
echo cfg >"$TREE/etc/frp-auto-deploy/config.json"
echo tok >"$TREE/etc/frp/server_token"

export FRP_UNINSTALL_TEST_ROOT="$TREE"
export FRP_PROJECT_FILES_PY="$ROOT/lib/frp_project_files.py"

# Server-owned install marker must be cleared.
printf '%s\n' '{"schema_version":2,"operation":"install","phase":"commit"}' \
  >"$TREE/var/lib/frp-auto-deploy/update-pending.json"
"$ROOT/uninstall-server.sh" >"$WORKDIR/out1" 2>"$WORKDIR/err1" || fail "uninstall with install marker"
[[ ! -f "$TREE/var/lib/frp-auto-deploy/update-pending.json" ]] \
  || fail "install marker remained after default uninstall"
pass "SERVER_UNINSTALL_CLEARS_INSTALL_MARKER"

# project-update marker cleared
printf '%s\n' '{"schema_version":2,"operation":"project-update","phase":"commit"}' \
  >"$TREE/var/lib/frp-auto-deploy/update-pending.json"
"$ROOT/uninstall-server.sh" >"$WORKDIR/out2" 2>"$WORKDIR/err2" || fail "uninstall with project-update marker"
[[ ! -f "$TREE/var/lib/frp-auto-deploy/update-pending.json" ]] \
  || fail "project-update marker remained"
pass "SERVER_UNINSTALL_CLEARS_PROJECT_UPDATE_MARKER"

# client-owned marker preserved (dual-role safety)
printf '%s\n' '{"schema_version":2,"operation":"client-update","phase":"commit"}' \
  >"$TREE/var/lib/frp-auto-deploy/update-pending.json"
"$ROOT/uninstall-server.sh" >"$WORKDIR/out3" 2>"$WORKDIR/err3" || fail "uninstall with client marker"
[[ -f "$TREE/var/lib/frp-auto-deploy/update-pending.json" ]] \
  || fail "client-update marker deleted"
grep -qi 'preserving update-pending' "$WORKDIR/err3" || fail "client preserve warning missing"
pass "SERVER_UNINSTALL_PRESERVES_CLIENT_MARKER"

# corrupt marker preserved
printf 'not-json{{{' >"$TREE/var/lib/frp-auto-deploy/update-pending.json"
"$ROOT/uninstall-server.sh" >"$WORKDIR/out4" 2>"$WORKDIR/err4" || fail "uninstall with corrupt marker"
[[ -f "$TREE/var/lib/frp-auto-deploy/update-pending.json" ]] \
  || fail "corrupt marker deleted"
grep -qi 'preserving update-pending' "$WORKDIR/err4" || fail "corrupt preserve warning missing"
pass "SERVER_UNINSTALL_PRESERVES_CORRUPT_MARKER"

echo "ALL PASS test-server-uninstall-pending-marker"
