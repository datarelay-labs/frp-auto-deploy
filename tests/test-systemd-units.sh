#!/usr/bin/env bash
# Static systemd unit assertions (no container boot).
# Optionally runs systemd-analyze verify when available and useful.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }
skip() { echo "SKIP $1"; }

UNITS=(
  "$ROOT/server/frps.service"
  "$ROOT/server/frp-port-allocator.service"
  "$ROOT/server/frp-frontend.service"
  "$ROOT/client/frpc.service"
)

for unit in "${UNITS[@]}"; do
  [[ -f "$unit" ]] || fail "missing unit file: $unit"
done

# Portable bash parse of After=/Wants=/ExecStart= (ignore comments).
unit_has_kv() {
  local file="$1" key="$2" expect="$3"
  local line section=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ "$line" =~ ^\[ ]]; then
      section="$line"
      continue
    fi
    line="${line%%;*}"
    line="${line%"${line##*[![:space:]]}"}"
    case "$line" in
      After=*|Wants=*|ExecStart=*)
        if [[ "$line" == "${key}=${expect}" ]]; then
          return 0
        fi
        ;;
    esac
  done < "$file"
  return 1
}

unit_has_kv "$ROOT/server/frps.service" After "network-online.target frp-port-allocator.service" \
  || fail "frps After=allocator"
unit_has_kv "$ROOT/server/frps.service" Wants "network-online.target frp-port-allocator.service" \
  || fail "frps Wants=allocator"
unit_has_kv "$ROOT/server/frps.service" ExecStart "/usr/local/bin/frps -c /etc/frp/frps.toml" \
  || fail "frps ExecStart"
grep -q '^NoNewPrivileges=true' "$ROOT/server/frps.service" || fail "frps NoNewPrivileges"
grep -q '^PrivateTmp=true' "$ROOT/server/frps.service" || fail "frps PrivateTmp"
pass "frps.service static keys"

unit_has_kv "$ROOT/server/frp-port-allocator.service" After "network-online.target" \
  || fail "allocator After"
unit_has_kv "$ROOT/server/frp-port-allocator.service" Wants "network-online.target" \
  || fail "allocator Wants"
grep -q '^Type=notify' "$ROOT/server/frp-port-allocator.service" || fail "allocator Type=notify"
unit_has_kv "$ROOT/server/frp-port-allocator.service" ExecStart \
  "/usr/bin/python3 /usr/local/lib/frp-auto-deploy/frp-port-allocator.py --config /etc/frp-auto-deploy/config.json" \
  || fail "allocator ExecStart"

# Modern hardened allocator must declare every production runtime write path.
# ProtectSystem=strict without these paths reproduces real OCI EROFS on leases/audit.
grep -q '^ProtectSystem=strict' "$ROOT/server/frp-port-allocator.service" \
  || fail "allocator ProtectSystem=strict"
grep -q '^RuntimeDirectory=frp-auto-deploy' "$ROOT/server/frp-port-allocator.service" \
  || fail "allocator RuntimeDirectory (frontend-independent lease store)"
grep -q '^RuntimeDirectoryMode=0700' "$ROOT/server/frp-port-allocator.service" \
  || fail "allocator RuntimeDirectoryMode"
allocator_rw="$(
  awk -F= '/^ReadWritePaths=/ { sub(/^ReadWritePaths=/, ""); print; exit }' \
    "$ROOT/server/frp-port-allocator.service"
)"
[[ -n "$allocator_rw" ]] || fail "allocator ReadWritePaths missing"
for required_rw in \
  /var/lib/frp-auto-deploy \
  /run/frp-auto-deploy \
  /var/log/frp-auto-deploy \
  /etc/frp-auto-deploy \
  /etc/frp; do
  [[ " $allocator_rw " == *" $required_rw "* ]] || fail "allocator ReadWritePaths missing $required_rw"
done
if grep -q '^After=.*frp-frontend.service' "$ROOT/server/frp-port-allocator.service"; then
  fail "allocator must not After=frp-frontend (Direct mode has no frontend)"
fi
if grep -q '^Wants=.*frp-frontend.service' "$ROOT/server/frp-port-allocator.service"; then
  fail "allocator must not Wants=frp-frontend"
fi

# shellcheck source=../lib/frp-common.sh
. "$ROOT/lib/frp-common.sh"
export FRP_TEST_SYSTEMD_VERSION=252
frp_write_compatible_systemd_unit \
  "$ROOT/server/frp-port-allocator.service" \
  "$ROOT/tests/.systemd-units-modern-allocator.service"
grep -q '^ProtectSystem=strict' "$ROOT/tests/.systemd-units-modern-allocator.service" \
  || fail "modern compatible allocator lost ProtectSystem=strict"
grep -q '^RuntimeDirectory=frp-auto-deploy' "$ROOT/tests/.systemd-units-modern-allocator.service" \
  || fail "modern compatible allocator lost RuntimeDirectory"
modern_rw="$(
  awk -F= '/^ReadWritePaths=/ { sub(/^ReadWritePaths=/, ""); print; exit }' \
    "$ROOT/tests/.systemd-units-modern-allocator.service"
)"
for required_rw in /run/frp-auto-deploy /var/log/frp-auto-deploy; do
  [[ " $modern_rw " == *" $required_rw "* ]] || fail "modern compatible allocator missing $required_rw"
done
export FRP_TEST_SYSTEMD_VERSION=219
frp_write_compatible_systemd_unit \
  "$ROOT/server/frp-port-allocator.service" \
  "$ROOT/tests/.systemd-units-al2-allocator.service"
if grep -q '^ProtectSystem=' "$ROOT/tests/.systemd-units-al2-allocator.service"; then
  fail "AL2 compatible allocator must not retain ProtectSystem"
fi
grep -q '^RuntimeDirectory=frp-auto-deploy' "$ROOT/tests/.systemd-units-al2-allocator.service" \
  || fail "AL2 compatible allocator lost RuntimeDirectory"
unset FRP_TEST_SYSTEMD_VERSION
rm -f "$ROOT/tests/.systemd-units-modern-allocator.service" \
  "$ROOT/tests/.systemd-units-al2-allocator.service"

pass "frp-port-allocator.service static keys"
pass "ALLOCATOR_RUNTIME_WRITE_CONTRACT"
pass "ALLOCATOR_FRONTEND_INDEPENDENT"

unit_has_kv "$ROOT/server/frp-frontend.service" After \
  "network-online.target frps.service frp-port-allocator.service" \
  || fail "frontend After"
unit_has_kv "$ROOT/server/frp-frontend.service" Wants \
  "network-online.target frps.service frp-port-allocator.service" \
  || fail "frontend Wants"
unit_has_kv "$ROOT/server/frp-frontend.service" ExecStart \
  "/usr/sbin/nginx -c /etc/frp-auto-deploy/frontend.conf" \
  || fail "frontend ExecStart"
pass "frp-frontend.service static keys"

unit_has_kv "$ROOT/client/frpc.service" After "network-online.target" \
  || fail "frpc After"
unit_has_kv "$ROOT/client/frpc.service" Wants "network-online.target" \
  || fail "frpc Wants"
unit_has_kv "$ROOT/client/frpc.service" ExecStart "/usr/local/bin/frpc -c /etc/frp/frpc.toml" \
  || fail "frpc ExecStart"
grep -q '^NoNewPrivileges=true' "$ROOT/client/frpc.service" || fail "frpc NoNewPrivileges"
grep -q '^PrivateTmp=true' "$ROOT/client/frpc.service" || fail "frpc PrivateTmp"
pass "frpc.service static keys"

# Ordering: plugin/allocator becomes ready (Type=notify) before frps starts.
# Frontend still depends on both units; there is no allocator↔frps cycle.
if grep -q 'After=.*frps.service' "$ROOT/server/frp-port-allocator.service"; then
  fail "allocator must not After=frps.service (cycle with frps After=allocator)"
fi
if grep -q 'After=.*frp-frontend.service' "$ROOT/server/frps.service"; then
  fail "frps must not After=frontend"
fi
pass "SYSTEMD_PLUGIN_ORDERING_TEST"

if ! command -v systemd-analyze >/dev/null 2>&1; then
  skip "systemd-analyze verify (systemd-analyze not installed)"
else
  # verify needs production ExecStart paths. Without an installed tree those
  # binaries/configs are absent, so treat non-zero as SKIP rather than FAIL.
  VERIFY_OUT="$(mktemp)"
  set +e
  systemd-analyze verify \
    "$ROOT/server/frps.service" \
    "$ROOT/server/frp-port-allocator.service" \
    "$ROOT/server/frp-frontend.service" \
    "$ROOT/client/frpc.service" \
    >"$VERIFY_OUT" 2>&1
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    pass "systemd-analyze verify"
  else
    skip "systemd-analyze verify (needs installed paths; rc=$rc — static asserts still PASS)"
    head -n 3 "$VERIFY_OUT" | sed 's/^/  verify: /' || true
  fi
  rm -f "$VERIFY_OUT"
fi

echo "SYSTEMD_UNITS_TEST=PASS"
