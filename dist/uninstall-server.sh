#!/usr/bin/env bash
set -euo pipefail

PURGE=false
PURGE_YES=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --purge) PURGE=true; shift ;;
    --yes|-y) PURGE_YES=true; shift ;;
    -h|--help)
      cat <<'EOF'
Usage: uninstall-server.sh [--purge] [--yes]

Default uninstall removes FRP server software and runtime units.
Token, private CA, registry, and reservations are preserved.

  --purge   Permanently delete preserved state (token, CA, registry, config)
  --yes     Required with --purge for noninteractive confirmation
EOF
      exit 0
      ;;
    *)
      echo "ERROR: unknown option: $1" >&2
      exit 2
      ;;
  esac
done

if [[ ${EUID} -ne 0 && -z "${FRP_UNINSTALL_TEST_ROOT:-}" ]]; then
  echo 'Run as root' >&2
  exit 1
fi

frp_u_path() {
  local p="$1"
  if [[ -n "${FRP_UNINSTALL_TEST_ROOT:-}" ]]; then
    printf '%s' "${FRP_UNINSTALL_TEST_ROOT}${p}"
  else
    printf '%s' "$p"
  fi
}

frp_u_unsafe_path() {
  local path="${1:-}"
  if [[ -z "$path" || "$path" == "/" || "$path" == "." || "$path" == ".." || "$path" == "//" ]]; then
    return 0
  fi
  case "$path" in
    /*) ;;
    *) return 0 ;;
  esac
  return 1
}

frp_u_safe_rm_rf() {
  local path="${1:-}"
  if frp_u_unsafe_path "$path"; then
    echo "ERROR: refusing unsafe recursive deletion" >&2
    echo "FAILURE_CLASS=PATH_DELETION_REFUSED" >&2
    return 1
  fi
  if [[ -L "$path" ]]; then
    echo "ERROR: refusing to recursively delete through a symlink" >&2
    echo "FAILURE_CLASS=SYMLINK_REFUSED" >&2
    return 1
  fi
  if [[ ! -e "$path" ]]; then
    return 0
  fi
  if [[ ! -d "$path" ]]; then
    echo "ERROR: refusing recursive deletion of a non-directory" >&2
    echo "FAILURE_CLASS=PATH_DELETION_REFUSED" >&2
    return 1
  fi
  rm -rf "$path"
}

frp_u_rm_file() {
  local path="${1:-}"
  if frp_u_unsafe_path "$path"; then
    echo "ERROR: refusing unsafe file deletion" >&2
    echo "FAILURE_CLASS=PATH_DELETION_REFUSED" >&2
    return 1
  fi
  rm -f "$path"
}

SKIP_SYSTEMD=0
if [[ -n "${FRP_UNINSTALL_TEST_ROOT:-}" || "${FRP_UNINSTALL_HOOK_SKIP_SYSTEMD:-}" == "1" ]]; then
  SKIP_SYSTEMD=1
fi

if [[ "$SKIP_SYSTEMD" != "1" ]] && command -v systemctl >/dev/null 2>&1; then
  systemctl stop frp-frontend frp-port-allocator frps 2>/dev/null || true
  systemctl disable frp-frontend frp-port-allocator frps 2>/dev/null || true
fi
# Never enable, start, or unmask distro nginx.service. Uninstall removes
# frp-frontend.service only. If this project installed nginx and disabled
# the distro unit, leave nginx.service disabled. Do not restore unknown
# external nginx configuration.

frp_u_rm_file "$(frp_u_path /etc/systemd/system/frps.service)"
frp_u_rm_file "$(frp_u_path /etc/systemd/system/frp-port-allocator.service)"
frp_u_rm_file "$(frp_u_path /etc/systemd/system/frp-frontend.service)"
frp_u_rm_file "$(frp_u_path /etc/frp-auto-deploy/frontend.conf)"
frp_u_rm_file "$(frp_u_path /usr/local/bin/frps)"
# Keep any distro-installed nginx package; only the project frontend unit
# and project-owned frontend.conf are removed.
for tool in frp-create-client frp-enrollments frp-enrollment-revoke frp-enroll-bulk \
  frp-clients frp-client-info frp-client-set frp-release-client \
  frp-release-service frp-revoke-client frp-set-client-installer-url \
  frp-server-status frp-update frp-upstream frp-project-update frp-backup frp-restore; do
  frp_u_rm_file "$(frp_u_path /usr/local/sbin/${tool})"
done
# Dual-role: keep /usr/local/bin/frpctl (client). Remove server sbin copy.
frp_u_rm_file "$(frp_u_path /usr/local/sbin/frpctl)"

libdir="$(frp_u_path /usr/local/lib/frp-auto-deploy)"
if [[ -d "$libdir" && ! -L "$libdir" ]]; then
  frp_u_rm_file "${libdir}/frp-port-allocator.py"
  frp_u_rm_file "${libdir}/frp_pki.py"
  frp_u_rm_file "${libdir}/frp_frontend.py"
  frp_u_rm_file "${libdir}/frp_client_registry.py"
  if [[ ! -f "$(frp_u_path /etc/frp/client-state.json)" && ! -x "$(frp_u_path /usr/local/bin/frp-client)" ]]; then
    frp_u_rm_file "${libdir}/frp-common.sh"
    frp_u_rm_file "${libdir}/frp_mgmt_auth.py"
    frp_u_rm_file "${libdir}/frp-client-common.sh"
  fi
  rmdir "$libdir" 2>/dev/null || true
elif [[ -L "$libdir" ]]; then
  echo "ERROR: refusing to delete symlink library directory" >&2
  echo "FAILURE_CLASS=SYMLINK_REFUSED" >&2
  echo "FAILURE_CLASS=UNINSTALL_PARTIAL" >&2
  exit 1
fi

if [[ "$SKIP_SYSTEMD" != "1" ]] && command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload
  systemctl reset-failed 2>/dev/null || true
fi

if [[ "$PURGE" == true ]]; then
  if [[ "$PURGE_YES" != true && -z "${FRP_PURGE_CONFIRM:-}" ]]; then
    echo "ERROR: --purge permanently deletes the CA, token, registry, and reservations." >&2
    echo "Re-run with --purge --yes to confirm." >&2
    echo "FAILURE_CLASS=PURGE_CONFIRMATION_REQUIRED" >&2
    exit 1
  fi

  PURGE_FAILED=0
  PURGE_REMAINING=""
  record_remaining() {
    local p="$1"
    PURGE_FAILED=1
    if [[ -n "$PURGE_REMAINING" ]]; then
      PURGE_REMAINING="${PURGE_REMAINING}
${p}"
    else
      PURGE_REMAINING="$p"
    fi
  }

  try_rm_file() {
    local path="$1"
    if [[ -e "$path" || -L "$path" ]]; then
      if [[ "${FRP_UNINSTALL_HOOK_PURGE_FAIL_PATH:-}" == "$path" ]]; then
        record_remaining "$path"
        return 0
      fi
      frp_u_rm_file "$path" || record_remaining "$path"
    fi
  }

  try_rm_rf() {
    local path="$1"
    if [[ "${FRP_UNINSTALL_HOOK_PURGE_FAIL_PATH:-}" == "$path" ]]; then
      record_remaining "$path"
      return 0
    fi
    if [[ -L "$path" ]]; then
      frp_u_rm_file "$path" || record_remaining "$path"
      return 0
    fi
    if [[ -e "$path" ]]; then
      frp_u_safe_rm_rf "$path" || record_remaining "$path"
    fi
  }

  try_rm_file "$(frp_u_path /var/lib/frp-auto-deploy/update-pending.json)"
  try_rm_rf "$(frp_u_path /var/lib/frp-auto-deploy/enrollments)"
  try_rm_rf "$(frp_u_path /var/lib/frp-auto-deploy/bootstrap)"
  try_rm_rf "$(frp_u_path /var/lib/frp-auto-deploy/backups)"
  try_rm_file "$(frp_u_path /var/lib/frp-auto-deploy/registry.json)"
  try_rm_file "$(frp_u_path /var/lib/frp-auto-deploy/mgmt-nonces.json)"
  if [[ -f "$(frp_u_path /etc/frp/client-state.json)" ]]; then
    try_rm_file "$(frp_u_path /etc/frp/server_token)"
    try_rm_file "$(frp_u_path /etc/frp/frps.toml)"
  else
    try_rm_rf "$(frp_u_path /etc/frp)"
  fi
  try_rm_rf "$(frp_u_path /etc/frp-auto-deploy/pki)"
  try_rm_file "$(frp_u_path /etc/frp-auto-deploy/config.json)"
  if [[ ! -f "$(frp_u_path /etc/frp/client-state.json)" && ! -f "$(frp_u_path /etc/frp-auto-deploy/allocator-ca.crt)" ]]; then
    try_rm_file "$(frp_u_path /etc/frp-auto-deploy/version)"
    try_rm_rf "$(frp_u_path /etc/frp-auto-deploy)"
  fi
  try_rm_rf "$(frp_u_path /var/lib/frp-auto-deploy)"

  if [[ "$PURGE_FAILED" == "1" ]]; then
    echo "ERROR: server purge did not complete." >&2
    echo "FAILURE_CLASS=PURGE_PARTIAL" >&2
    echo "Remaining paths:" >&2
    printf '%s\n' "$PURGE_REMAINING" >&2
    exit 1
  fi
  echo 'FRP server removed and state/secrets purged.'
else
  echo 'FRP server binaries/services removed. Configuration, token, and registry were preserved.'
  echo 'Use --purge only if you intentionally want to delete all reservations and secrets.'
  echo 'Reinstalling the server later reuses the same CA, token, and port reservations.'
fi
