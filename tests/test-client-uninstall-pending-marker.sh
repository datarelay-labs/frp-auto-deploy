#!/usr/bin/env bash
# P1-R: client uninstall only deletes client-owned update-pending markers.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

seed_client_tree() {
  local tree="$1"
  mkdir -p "$tree/etc/frp" "$tree/etc/frp-auto-deploy" "$tree/var/lib/frp-auto-deploy" "$tree/usr/local/bin"
  echo '{"schema_version":1}' >"$tree/etc/frp/client-state.json"
  echo 'token' >"$tree/etc/frp/server_token"
  echo '{"public_host":"203.0.113.10"}' >"$tree/etc/frp-auto-deploy/config.json"
  : >"$tree/usr/local/bin/frpc"
  chmod +x "$tree/usr/local/bin/frpc"
}

# Client-owned marker is removed
CLIENT="$WORKDIR/client-owned"
seed_client_tree "$CLIENT"
printf '{"schema_version":2,"operation":"client-update","phase":"commit"}\n' \
  >"$CLIENT/var/lib/frp-auto-deploy/update-pending.json"
export FRP_UNINSTALL_TEST_ROOT="$CLIENT"
"$ROOT/uninstall-client.sh" >"$WORKDIR/client.out" 2>"$WORKDIR/client.err" || fail "client uninstall"
[[ ! -f "$CLIENT/var/lib/frp-auto-deploy/update-pending.json" ]] || fail "client-owned marker remains"
pass "CLIENT_OWNED_MARKER_DELETED"

# Server project-update marker preserved on dual-role uninstall
PROJ="$WORKDIR/project"
seed_client_tree "$PROJ"
printf '{"schema_version":2,"operation":"project-update","phase":"commit"}\n' \
  >"$PROJ/var/lib/frp-auto-deploy/update-pending.json"
export FRP_UNINSTALL_TEST_ROOT="$PROJ"
"$ROOT/uninstall-client.sh" >"$WORKDIR/proj.out" 2>"$WORKDIR/proj.err" || fail "project uninstall"
[[ -f "$PROJ/var/lib/frp-auto-deploy/update-pending.json" ]] || fail "project marker deleted"
grep -qi 'preserving update-pending' "$WORKDIR/proj.err" || fail "project warn missing"
[[ -f "$PROJ/etc/frp/server_token" ]] || fail "server token deleted"
[[ -f "$PROJ/etc/frp-auto-deploy/config.json" ]] || fail "server config deleted"
pass "PROJECT_UPDATE_MARKER_PRESERVED"

# Restore-owned marker preserved
REST="$WORKDIR/restore"
seed_client_tree "$REST"
printf '{"schema_version":2,"operation":"restore","phase":"commit"}\n' \
  >"$REST/var/lib/frp-auto-deploy/update-pending.json"
export FRP_UNINSTALL_TEST_ROOT="$REST"
"$ROOT/uninstall-client.sh" >"$WORKDIR/rest.out" 2>"$WORKDIR/rest.err" || fail "restore uninstall"
[[ -f "$REST/var/lib/frp-auto-deploy/update-pending.json" ]] || fail "restore marker deleted"
grep -qi 'preserving update-pending' "$WORKDIR/rest.err" || fail "restore warn missing"
pass "RESTORE_MARKER_PRESERVED"

# Unknown / corrupt markers preserved with warning
UNK="$WORKDIR/unknown"
seed_client_tree "$UNK"
printf '{"schema_version":2,"operation":"mystery-op","phase":"commit"}\n' \
  >"$UNK/var/lib/frp-auto-deploy/update-pending.json"
export FRP_UNINSTALL_TEST_ROOT="$UNK"
"$ROOT/uninstall-client.sh" >"$WORKDIR/unk.out" 2>"$WORKDIR/unk.err" || fail "unknown uninstall"
[[ -f "$UNK/var/lib/frp-auto-deploy/update-pending.json" ]] || fail "unknown marker deleted"
pass "UNKNOWN_MARKER_PRESERVED"

BAD="$WORKDIR/corrupt"
seed_client_tree "$BAD"
printf 'not-json{{{' >"$BAD/var/lib/frp-auto-deploy/update-pending.json"
export FRP_UNINSTALL_TEST_ROOT="$BAD"
"$ROOT/uninstall-client.sh" >"$WORKDIR/bad.out" 2>"$WORKDIR/bad.err" || fail "corrupt uninstall"
[[ -f "$BAD/var/lib/frp-auto-deploy/update-pending.json" ]] || fail "corrupt marker deleted"
grep -qi 'preserving update-pending' "$WORKDIR/bad.err" || fail "corrupt warn missing"
pass "CORRUPT_MARKER_PRESERVED"

echo "CLIENT_UNINSTALL_PENDING_MARKER=PASS"
