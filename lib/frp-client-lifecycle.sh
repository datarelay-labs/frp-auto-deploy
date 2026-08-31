#!/usr/bin/env bash
# Client remote-access lifecycle: pause, resume, restart, test, logs, support-bundle, uninstall.
set -euo pipefail

if [[ -n "${FRP_CLIENT_LIFECYCLE_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
FRP_CLIENT_LIFECYCLE_LOADED=1

_frp_lc_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${FRP_CLIENT_COMMON_LOADED:-}" ]]; then
  if [[ -f "${_frp_lc_dir}/frp-client-common.sh" ]]; then
    # shellcheck source=frp-client-common.sh
    . "${_frp_lc_dir}/frp-client-common.sh"
  elif [[ -f /usr/local/lib/frp-auto-deploy/frp-client-common.sh ]]; then
    # shellcheck disable=SC1091
    . /usr/local/lib/frp-auto-deploy/frp-client-common.sh
  fi
fi

frp_client_pause_marker_path() {
  frp_client_path /etc/frp/remote-access-paused.json
}

frp_client_lifecycle_py() {
  local py="${_frp_lc_dir}/frp_client_lifecycle.py"
  if [[ ! -f "$py" ]]; then
    py="$(frp_client_path /usr/local/lib/frp-auto-deploy/frp_client_lifecycle.py)"
  fi
  PYTHONPATH="$(dirname "$py")${PYTHONPATH:+:$PYTHONPATH}" python3 "$py" "$@"
}

frp_client_autostart_enabled() {
  if [[ "${FRP_SKIP_SYSTEMD:-}" == "1" || -n "${FRP_CLIENT_TEST_ROOT:-}" ]]; then
    [[ "${FRP_CLIENT_LIFECYCLE_AUTOSTART:-}" == "enabled" ]]
    return $?
  fi
  if ! command -v systemctl >/dev/null 2>&1; then
    return 1
  fi
  systemctl is-enabled frpc >/dev/null 2>&1
}

frp_client_stop_frpc() {
  frp_client_hook_log stop
  if [[ "${FRP_CLIENT_HOOK_STOP_FAIL:-}" == "1" ]]; then
    echo "ERROR: simulated frpc stop failure" >&2
    return 1
  fi
  if [[ "${FRP_SKIP_SYSTEMD:-}" == "1" || -n "${FRP_CLIENT_TEST_ROOT:-}" ]]; then
    return 0
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop frpc >/dev/null 2>&1 || true
  fi
  pkill -x frpc 2>/dev/null || true
  if pgrep -x frpc >/dev/null 2>&1; then
    echo "ERROR: frpc is still running" >&2
    return 1
  fi
  return 0
}

frp_client_start_frpc() {
  frp_client_hook_log start
  if [[ "${FRP_CLIENT_HOOK_START_FAIL:-}" == "1" ]]; then
    echo "ERROR: simulated frpc start failure" >&2
    return 1
  fi
  if [[ "${FRP_SKIP_SYSTEMD:-}" == "1" || -n "${FRP_CLIENT_TEST_ROOT:-}" ]]; then
    return 0
  fi
  local cfg
  cfg="$(frp_client_toml_path)"
  frp_client_verify_config "$cfg" || return 1
  systemctl enable frpc >/dev/null 2>&1 || true
  systemctl start frpc
  sleep 1
  if ! systemctl is-active --quiet frpc; then
    echo "ERROR: frpc failed to start" >&2
    return 1
  fi
  return 0
}

frp_client_pause_remote_access() {
  local autostart=0 state
  if [[ ${EUID} -ne 0 && -z "${FRP_CLIENT_TEST_ROOT:-}" ]]; then
    echo "ERROR: run with sudo" >&2
    return 1
  fi
  state="$(frp_client_state_path)"
  [[ -f "$state" ]] || {
    echo "ERROR: no FRP client installation was found." >&2
    return 1
  }
  frp_load_client_state "$state" || return 1
  if frp_client_is_paused; then
    echo "Remote access is already paused."
    return 0
  fi
  if frp_client_autostart_enabled; then
    autostart=1
  fi
  if ! frp_client_stop_frpc; then
    return 1
  fi
  if [[ "${FRP_SKIP_SYSTEMD:-}" != "1" && -z "${FRP_CLIENT_TEST_ROOT:-}" ]] && command -v systemctl >/dev/null 2>&1; then
    systemctl disable frpc >/dev/null 2>&1 || true
  fi
  python3 - "$autostart" "$(frp_client_pause_marker_path)" <<'PY'
import json, os, sys
from datetime import datetime, timezone
from pathlib import Path
autostart = sys.argv[1] == '1'
path = Path(sys.argv[2])
path.parent.mkdir(parents=True, exist_ok=True)
payload = {
    'schema_version': 1,
    'paused': True,
    'paused_at': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'autostart_was_enabled': autostart,
}
tmp = path.with_suffix('.tmp')
tmp.write_text(json.dumps(payload, indent=2, sort_keys=True) + '\n', encoding='utf-8')
os.chmod(tmp, 0o600)
tmp.replace(path)
PY
  echo "Remote access paused."
  echo "Identity, services, and server reservations are preserved."
  echo "Use 'frpctl resume' to reconnect."
  return 0
}

frp_client_resume_remote_access() {
  local autostart=0 marker state
  if [[ ${EUID} -ne 0 && -z "${FRP_CLIENT_TEST_ROOT:-}" ]]; then
    echo "ERROR: run with sudo" >&2
    return 1
  fi
  state="$(frp_client_state_path)"
  [[ -f "$state" ]] || {
    echo "ERROR: no FRP client installation was found." >&2
    return 1
  }
  frp_load_client_state "$state" || return 1
  frp_lifecycle_recover || return 1
  marker="$(frp_client_pause_marker_path)"
  if [[ ! -f "$marker" ]]; then
    echo "Remote access is not paused."
    if frp_client_autostart_enabled; then
      frp_client_start_frpc || return 1
    fi
    return 0
  fi
  autostart="$(python3 - "$marker" <<'PY'
import json, sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
print('1' if data.get('autostart_was_enabled') else '0')
PY
)"
  rm -f "$marker"
  if [[ "$autostart" == "1" ]]; then
    if [[ "${FRP_SKIP_SYSTEMD:-}" != "1" && -z "${FRP_CLIENT_TEST_ROOT:-}" ]] && command -v systemctl >/dev/null 2>&1; then
      systemctl enable frpc >/dev/null 2>&1 || true
    fi
    frp_client_start_frpc || return 1
  else
    echo "Autostart was disabled before pause; frpc was not started."
  fi
  echo "Remote access resumed."
  return 0
}

frp_client_lifecycle_restart() {
  local state
  if [[ ${EUID} -ne 0 && -z "${FRP_CLIENT_TEST_ROOT:-}" ]]; then
    echo "ERROR: run with sudo" >&2
    return 1
  fi
  if frp_client_is_paused; then
    echo "ERROR: client remote access is paused." >&2
    echo "Use 'frpctl resume' to reconnect." >&2
    return 1
  fi
  state="$(frp_client_state_path)"
  [[ -f "$state" ]] || {
    echo "ERROR: no FRP client installation was found." >&2
    return 1
  }
  frp_load_client_state "$state" || return 1
  frp_lifecycle_recover || return 1
  frp_client_stop_frpc || return 1
  frp_client_start_frpc || return 1
  echo "FRP connection restarted."
  return 0
}

frp_client_lifecycle_test() {
  frp_client_lifecycle_py test
}

frp_client_lifecycle_logs() {
  frp_client_lifecycle_py logs "$@"
}

frp_client_lifecycle_support_bundle() {
  if [[ ${EUID} -ne 0 && -z "${FRP_CLIENT_TEST_ROOT:-}" ]]; then
    echo "ERROR: run with sudo" >&2
    return 1
  fi
  frp_client_lifecycle_py support-bundle "$@"
}

frp_client_lifecycle_uninstall() {
  local yes=0 arg
  for arg in "$@"; do
    case "$arg" in
      --yes) yes=1 ;;
      *) echo "ERROR: unknown uninstall option: $arg" >&2; return 1 ;;
    esac
  done
  if [[ ${EUID} -ne 0 && -z "${FRP_CLIENT_TEST_ROOT:-}" && -z "${FRP_UNINSTALL_TEST_ROOT:-}" ]]; then
    echo "ERROR: run with sudo" >&2
    return 1
  fi
  if [[ "$yes" != "1" ]]; then
    cat <<'EOF'
Uninstall FRP Auto Deploy from this client?

This will:
  - stop remote FRP access
  - disable automatic startup
  - remove local FRP software
  - remove local management identity
  - remove local configuration/state

This will NOT:
  - delete the server-side Client record
  - release public port reservations
  - delete server-side Groups/Tags/Audit history

Type "uninstall" to continue:
EOF
    local confirm=""
    read -r confirm || return 1
    if [[ "$confirm" != "uninstall" ]]; then
      echo "Uninstall cancelled."
      return 1
    fi
  fi
  local root="${FRP_UNINSTALL_TEST_ROOT:-${FRP_CLIENT_TEST_ROOT:-}}"
  local script="${_frp_lc_dir}/../uninstall-client.sh"
  if [[ ! -f "$script" ]]; then
    script="$(frp_client_path /usr/local/lib/frp-auto-deploy/../uninstall-client.sh)"
  fi
  if [[ ! -f "$script" ]]; then
    script="/home/aella/frp-auto-deploy-client-lifecycle/uninstall-client.sh"
  fi
  if [[ -n "$root" ]]; then
    FRP_UNINSTALL_TEST_ROOT="$root" bash "$script"
  else
    bash "$script"
  fi
}

frp_client_remote_access_status_line() {
  if frp_client_is_paused; then
    printf '%s\n' 'Remote access : PAUSED'
    printf '%s\n' 'frpc          : stopped'
  else
    printf '%s\n' 'Remote access : ACTIVE'
  fi
}
