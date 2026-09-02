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
  return 1
}

frp_u_client_present() {
  [[ -f "$(frp_u_path /etc/frp/client-state.json)" ]] || \
    [[ -x "$(frp_u_path /usr/local/bin/frp-client)" ]]
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

PROJECT_FILES_PY=""
if ! PROJECT_FILES_PY="$(_frp_u_project_files_py)"; then
  echo "ERROR: frp_project_files.py is unavailable; cannot derive uninstall file list" >&2
  echo "FAILURE_CLASS=UNINSTALL_MANIFEST_MISSING" >&2
  exit 1
fi

KEEP_SHARED=0
if frp_u_client_present; then
  KEEP_SHARED=1
fi

declare -A FRP_U_KEEP_LIBS=()
if [[ "$KEEP_SHARED" == "1" ]]; then
  while IFS= read -r base; do
    [[ -n "$base" ]] || continue
    FRP_U_KEEP_LIBS["$base"]=1
  done < <(python3 "$PROJECT_FILES_PY" dual-role-shared-libs)
  # Client-only shared helper historically preserved with dual-role installs.
  FRP_U_KEEP_LIBS["frp-client-common.sh"]=1
fi

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
done < <(python3 "$PROJECT_FILES_PY" uninstall-rels)

# Runtime binary (not in managed project/optional/unit set).
frp_u_rm_file "$(frp_u_path /usr/local/bin/frps)"
# Keep any distro-installed nginx package; only the project frontend unit
# is removed via the manifest. Generated frontend.conf is software-owned and
# must leave with the unit on non-purge uninstall (purge still clears secrets).
frp_u_rm_file "$(frp_u_path /etc/frp-auto-deploy/frontend.conf)"

libdir="$(frp_u_path /usr/local/lib/frp-auto-deploy)"
if [[ -d "$libdir" && ! -L "$libdir" ]]; then
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

# Default uninstall: clear only server-owned update-pending markers so a later
# reinstall is not blocked by a stale install/project-update transaction.
# Preserve client-owned / corrupt / unknown markers (transaction safety).
if [[ "$PURGE" != true ]]; then
  pending_marker="$(frp_u_path /var/lib/frp-auto-deploy/update-pending.json)"
  if [[ -e "$pending_marker" || -L "$pending_marker" ]]; then
    if python3 - "$pending_marker" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
SERVER_OWNED = {"install", "project-update", "frp-update"}
try:
    raw = path.read_text(encoding="utf-8")
    data = json.loads(raw)
except Exception:
    print(
        "WARNING: preserving update-pending.json (unreadable or corrupt); "
        "not removing during server uninstall.",
        file=sys.stderr,
    )
    raise SystemExit(2)
if not isinstance(data, dict):
    print(
        "WARNING: preserving update-pending.json (unexpected shape); "
        "not removing during server uninstall.",
        file=sys.stderr,
    )
    raise SystemExit(2)
operation = str(data.get("operation") or "").strip()
if operation in SERVER_OWNED:
    raise SystemExit(0)
print(
    "WARNING: preserving update-pending.json (operation=%s); "
    "not a server-owned marker." % (operation or "unknown"),
    file=sys.stderr,
)
raise SystemExit(2)
PY
    then
      frp_u_rm_file "$pending_marker"
    fi
  fi
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
  try_rm_file "$(frp_u_path /etc/frp-auto-deploy/frontend.conf)"
  try_rm_file "$(frp_u_path /var/lib/frp-auto-deploy/nginx-ownership)"
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
