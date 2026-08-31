#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 && -z "${FRP_UNINSTALL_TEST_ROOT:-}" && -z "${FRP_CLIENT_TEST_ROOT:-}" ]]; then
  echo 'Run as root' >&2
  exit 1
fi

frp_u_path() {
  local p="$1"
  local root="${FRP_UNINSTALL_TEST_ROOT:-${FRP_CLIENT_TEST_ROOT:-}}"
  if [[ -n "$root" ]]; then
    printf '%s' "${root}${p}"
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
if [[ -n "${FRP_UNINSTALL_TEST_ROOT:-}" || -n "${FRP_CLIENT_TEST_ROOT:-}" || "${FRP_UNINSTALL_HOOK_SKIP_SYSTEMD:-}" == "1" ]]; then
  SKIP_SYSTEMD=1
fi

echo 'Local software will be removed.'
echo 'Server-side reservations remain.'
echo 'Use an explicit server release command if ports should be freed.'
echo

if [[ "$SKIP_SYSTEMD" != "1" ]] && command -v systemctl >/dev/null 2>&1; then
  systemctl stop frpc 2>/dev/null || true
  systemctl disable frpc 2>/dev/null || true
fi
if [[ "$SKIP_SYSTEMD" != "1" ]]; then
  pkill -x frpc 2>/dev/null || true
fi

frp_u_rm_file "$(frp_u_path /etc/systemd/system/frpc.service)"
frp_u_rm_file "$(frp_u_path /usr/local/bin/frpc)"
frp_u_rm_file "$(frp_u_path /usr/local/bin/frp-client)"
frp_u_rm_file "$(frp_u_path /usr/local/bin/frpctl)"
frp_u_rm_file "$(frp_u_path /usr/local/bin/frpcli)"

libdir="$(frp_u_path /usr/local/lib/frp-auto-deploy)"
if [[ -d "$libdir" && ! -L "$libdir" ]]; then
  frp_u_rm_file "${libdir}/frp-client-common.sh"
  frp_u_rm_file "${libdir}/frp-client-lifecycle.sh"
  frp_u_rm_file "${libdir}/frp_client_lifecycle.py"
  if [[ ! -f "$(frp_u_path /etc/frp-auto-deploy/config.json)" ]]; then
    frp_u_rm_file "${libdir}/frp_mgmt_auth.py"
    frp_u_rm_file "${libdir}/frp-common.sh"
  fi
  rmdir "$libdir" 2>/dev/null || true
elif [[ -L "$libdir" ]]; then
  echo "ERROR: refusing to delete symlink library directory" >&2
  echo "FAILURE_CLASS=SYMLINK_REFUSED" >&2
  echo "FAILURE_CLASS=UNINSTALL_PARTIAL" >&2
  exit 1
fi

etc_frp="$(frp_u_path /etc/frp)"
if [[ -L "$etc_frp" ]]; then
  echo "ERROR: refusing to delete through a symlink at ${etc_frp}" >&2
  echo "FAILURE_CLASS=SYMLINK_REFUSED" >&2
  echo "FAILURE_CLASS=UNINSTALL_PARTIAL" >&2
  exit 1
fi

if [[ -d "$etc_frp" ]]; then
  for f in client-state.json frpc.toml access-info.txt client-id \
    client-identity.key client-identity.pub client-identity.mac \
    apply-pending.json remote-access-paused.json; do
    frp_u_rm_file "${etc_frp}/${f}"
  done
  frp_u_safe_rm_rf "${etc_frp}/backups"
  frp_u_safe_rm_rf "${etc_frp}/client-manage.lock"
  if [[ -f "${etc_frp}/server_token" || -f "${etc_frp}/frps.toml" ]]; then
    :
  else
    frp_u_safe_rm_rf "$etc_frp"
  fi
fi

frp_u_rm_file "$(frp_u_path /etc/frp-auto-deploy/allocator-ca.crt)"
frp_u_rm_file "$(frp_u_path /var/lib/frp-auto-deploy/update-pending.json)"
frp_u_rm_file "$(frp_u_path /var/lib/frp-auto-deploy/client-draft.json)"
frp_u_safe_rm_rf "$(frp_u_path /var/lib/frp-auto-deploy/client-upgrades)"

# Dual-role guard: if [[ ! -f /etc/frp-auto-deploy/config.json ]]
if [[ ! -f "$(frp_u_path /etc/frp-auto-deploy/config.json)" ]]; then
  frp_u_rm_file "$(frp_u_path /etc/frp-auto-deploy/version)"
  rmdir "$(frp_u_path /etc/frp-auto-deploy)" 2>/dev/null || true
fi

if [[ "$SKIP_SYSTEMD" != "1" ]] && command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload
  systemctl reset-failed 2>/dev/null || true
fi

echo 'FRP client removed locally. The central port reservation is intentionally preserved.'
echo 'This uninstall does not contact the server and does not release ports.'
