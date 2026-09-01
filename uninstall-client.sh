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

_frp_u_project_files_py() {
  local here candidate
  if [[ -n "${FRP_PROJECT_FILES_PY:-}" && -f "${FRP_PROJECT_FILES_PY}" ]]; then
    printf '%s' "$FRP_PROJECT_FILES_PY"
    return 0
  fi
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  for candidate in \
    "${here}/lib/frp_project_files.py" \
    "$(frp_u_path /usr/local/lib/frp-auto-deploy/frp_project_files.py)" \
    /usr/local/lib/frp-auto-deploy/frp_project_files.py; do
    if [[ -f "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  # uninstall-client.sh is often installed under the libdir itself.
  if [[ -f "${here}/frp_project_files.py" ]]; then
    printf '%s' "${here}/frp_project_files.py"
    return 0
  fi
  return 1
}

frp_u_server_present() {
  [[ -f "$(frp_u_path /etc/frp-auto-deploy/config.json)" ]]
}

SKIP_SYSTEMD=0
if [[ -n "${FRP_UNINSTALL_TEST_ROOT:-}" || -n "${FRP_CLIENT_TEST_ROOT:-}" || "${FRP_UNINSTALL_HOOK_SKIP_SYSTEMD:-}" == "1" ]]; then
  SKIP_SYSTEMD=1
fi

echo 'Local software will be removed.'
echo 'Server-side reservations remain.'
echo 'Use an explicit server release command if ports should be freed.'
echo

frp_u_project_frpc_pids() {
  local cfg bin pid cmdline exe
  cfg="$(frp_u_path /etc/frp/frpc.toml)"
  bin="$(frp_u_path /usr/local/bin/frpc)"
  for pid in $(pgrep -x frpc 2>/dev/null || true); do
    [[ -r "/proc/${pid}/cmdline" ]] || continue
    cmdline="$(tr '\0' ' ' <"/proc/${pid}/cmdline" 2>/dev/null || true)"
    if [[ "$cmdline" == *frpc* && "$cmdline" == *"$cfg"* ]]; then
      if [[ -r "/proc/${pid}/exe" ]]; then
        exe="$(readlink -f "/proc/${pid}/exe" 2>/dev/null || true)"
        if [[ -n "$exe" && "$exe" != "$bin" && "$exe" != *'/frpc' ]]; then
          continue
        fi
      fi
      printf '%s\n' "$pid"
    fi
  done
}

frp_u_kill_project_frpc() {
  local pid
  while read -r pid; do
    [[ -n "$pid" ]] || continue
    kill "$pid" 2>/dev/null || true
  done < <(frp_u_project_frpc_pids)
  sleep 0.2
  while read -r pid; do
    [[ -n "$pid" ]] || continue
    kill -9 "$pid" 2>/dev/null || true
  done < <(frp_u_project_frpc_pids)
}

if [[ "$SKIP_SYSTEMD" != "1" ]] && command -v systemctl >/dev/null 2>&1; then
  systemctl stop frpc 2>/dev/null || true
  systemctl disable frpc 2>/dev/null || true
fi
# Prefer unit stop; never pkill -x frpc globally (unrelated frpc must survive).
if [[ "$SKIP_SYSTEMD" != "1" ]]; then
  frp_u_kill_project_frpc
fi

PROJECT_FILES_PY=""
CLIENT_MANIFEST_OK=0
if PROJECT_FILES_PY="$(_frp_u_project_files_py)"; then
  CLIENT_MANIFEST_OK=1
fi

KEEP_SHARED=0
if frp_u_server_present; then
  KEEP_SHARED=1
fi

declare -A FRP_U_KEEP_LIBS=()
if [[ "$KEEP_SHARED" == "1" && "$CLIENT_MANIFEST_OK" == "1" ]]; then
  while IFS= read -r base; do
    [[ -n "$base" ]] || continue
    FRP_U_KEEP_LIBS["$base"]=1
  done < <(python3 "$PROJECT_FILES_PY" dual-role-shared-libs)
fi

if [[ "$CLIENT_MANIFEST_OK" == "1" ]]; then
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    case "$rel" in
      usr/local/lib/frp-auto-deploy/*)
        base="${rel##*/}"
        if [[ "$KEEP_SHARED" == "1" && -n "${FRP_U_KEEP_LIBS[$base]:-}" ]]; then
          continue
        fi
        ;;
    esac
    frp_u_rm_file "$(frp_u_path "/${rel}")"
  done < <(python3 "$PROJECT_FILES_PY" client-uninstall-rels)
  # Runtime binary (manifest binary class; not in managed uninstall-rels).
  frp_u_rm_file "$(frp_u_path /usr/local/bin/frpc)"
else
  # Fallback when the helper is already gone (idempotent re-run).
  frp_u_rm_file "$(frp_u_path /etc/systemd/system/frpc.service)"
  frp_u_rm_file "$(frp_u_path /usr/local/bin/frpc)"
  frp_u_rm_file "$(frp_u_path /usr/local/bin/frp-client)"
  frp_u_rm_file "$(frp_u_path /usr/local/bin/frpctl)"
  frp_u_rm_file "$(frp_u_path /usr/local/bin/frpcli)"
  libdir="$(frp_u_path /usr/local/lib/frp-auto-deploy)"
  if [[ -d "$libdir" && ! -L "$libdir" ]]; then
    # Client-only fallback removals. Shared dual-role libs stay when KEEP_SHARED=1.
    for f in frp-client-common.sh frp-client-lifecycle.sh frp_client_lifecycle.py \
      uninstall-client.sh; do
      frp_u_rm_file "${libdir}/${f}"
    done
    if [[ "$KEEP_SHARED" != "1" ]]; then
      for f in frp_ctl_grammar.py frp_ctl_repl.py \
        frp_clock_sync.py frp-doctor-common.sh frp_doctor.py \
        frp_mgmt_auth.py frp-common.sh; do
        frp_u_rm_file "${libdir}/${f}"
      done
    fi
  fi
fi

libdir="$(frp_u_path /usr/local/lib/frp-auto-deploy)"
if [[ -d "$libdir" && ! -L "$libdir" ]]; then
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
# Dual-role: only delete client-owned update-pending markers. Preserve
# server/restore/unknown/corrupt markers so a later server recovery is not lost.
pending_marker="$(frp_u_path /var/lib/frp-auto-deploy/update-pending.json)"
if [[ -e "$pending_marker" || -L "$pending_marker" ]]; then
  if python3 - "$pending_marker" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
CLIENT_OWNED = {"client-update"}
try:
    raw = path.read_text(encoding="utf-8")
    data = json.loads(raw)
except Exception:
    print(
        "WARNING: preserving update-pending.json (unreadable or corrupt); "
        "not removing during client uninstall.",
        file=sys.stderr,
    )
    raise SystemExit(2)
if not isinstance(data, dict):
    print(
        "WARNING: preserving update-pending.json (unexpected shape); "
        "not removing during client uninstall.",
        file=sys.stderr,
    )
    raise SystemExit(2)
operation = str(data.get("operation") or "").strip()
if operation in CLIENT_OWNED:
    raise SystemExit(0)
print(
    "WARNING: preserving update-pending.json (operation=%s); "
    "not a client-owned marker." % (operation or "unknown"),
    file=sys.stderr,
)
raise SystemExit(2)
PY
  then
    frp_u_rm_file "$pending_marker"
  fi
fi
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
