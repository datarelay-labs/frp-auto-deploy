#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ -f "$BASE_DIR/lib/frp-common.sh" ]] || { echo "ERROR: missing project file: $BASE_DIR/lib/frp-common.sh" >&2; exit 1; }
# shellcheck source=lib/frp-common.sh
. "$BASE_DIR/lib/frp-common.sh"

for f in \
  "$BASE_DIR/VERSION" \
  "$BASE_DIR/server/frp-port-allocator.py" \
  "$BASE_DIR/server/migrate_token.py" \
  "$BASE_DIR/server/frps.service" \
  "$BASE_DIR/server/frp-port-allocator.service" \
  "$BASE_DIR/lib/frp_mgmt_auth.py" \
  "$BASE_DIR/lib/frp_pki.py" \
  "$BASE_DIR/tools/frp-create-client" \
  "$BASE_DIR/tools/frp-clients" \
  "$BASE_DIR/tools/frp-client-info" \
  "$BASE_DIR/tools/frp-release-client" \
  "$BASE_DIR/tools/frp-release-service" \
  "$BASE_DIR/tools/frp-revoke-client" \
  "$BASE_DIR/tools/frp-set-client-installer-url" \
  "$BASE_DIR/tools/frp-server-status" \
  "$BASE_DIR/tools/frp-update" \
  "$BASE_DIR/tools/frpctl"; do
  [[ -f "$f" ]] || { echo "ERROR: missing project file: $f" >&2; exit 1; }
done

DEFAULT_CLIENT_INSTALLER_URL="https://raw.githubusercontent.com/datarelay-labs/frp-auto-deploy/main/dist/bootstrap-client.sh"
# Historical owner/repo, concatenated only to recognize the obsolete project URL.
LEGACY_CLIENT_INSTALLER_OWNER='RickLee-kr'
LEGACY_CLIENT_INSTALLER_REPO='frp-auto-deploy'

frp_legacy_client_installer_url() {
  printf 'https://raw.githubusercontent.com/%s/%s/main/dist/bootstrap-client.sh' \
    "$LEGACY_CLIENT_INSTALLER_OWNER" "$LEGACY_CLIENT_INSTALLER_REPO"
}

frp_migrate_legacy_client_installer_url() {
  local legacy
  legacy="$(frp_legacy_client_installer_url)"
  if [[ "${CLIENT_INSTALLER_URL:-}" == "$legacy" ]]; then
    CLIENT_INSTALLER_URL="$DEFAULT_CLIENT_INSTALLER_URL"
  fi
}

frp_server_config_path() {
  printf '%s' "${FRP_SERVER_CONFIG:-/etc/frp-auto-deploy/config.json}"
}

frp_valid_https_url() {
  local url="${1:-}"
  case "$url" in
    https://?*) ;;
    *) return 1 ;;
  esac
  if [[ "$url" == *$'\n'* || "$url" == *$'\r'* || "$url" == *$'\t'* || "$url" == *' '* ]]; then
    return 1
  fi
  local rest="${url#https://}"
  local hostport="${rest%%/*}"
  [[ -n "$hostport" ]]
}

frp_valid_http_url() {
  # Historical name kept for sourced tests; allocator URLs must be HTTPS.
  frp_valid_https_url "$@"
}

frp_valid_tcp_port() {
  local port="${1:-}"
  [[ "$port" =~ ^[1-9][0-9]*$ ]] || return 1
  (( 10#$port >= 1 && 10#$port <= 65535 ))
}

frp_format_https_url() {
  local host="$1" port="$2" path="${3:-/enroll}"
  if [[ "$port" == "443" ]]; then
    printf 'https://%s%s' "$host" "$path"
  else
    printf 'https://%s:%s%s' "$host" "$port" "$path"
  fi
}

frp_pki_dir() {
  printf '%s' "${FRP_PKI_DIR:-/etc/frp-auto-deploy/pki}"
}

frp_valid_public_host() {
  local host="${1:-}"
  [[ -n "$host" ]] || return 1
  if [[ "$host" == *$'\n'* || "$host" == *$'\r'* || "$host" == *$'\t'* || "$host" == *' '* ]]; then
    return 1
  fi
  if [[ "$host" == *';'* || "$host" == *'|'* || "$host" == *'&'* || "$host" == *'$'* || "$host" == *'`'* || "$host" == *'<'* || "$host" == *'>'* || "$host" == *"'"* || "$host" == *'"'* || "$host" == *'\\'* || "$host" == *'/'* ]]; then
    return 1
  fi
  return 0
}

frp_has_tty() {
  [[ -e /dev/tty && -r /dev/tty && -w /dev/tty ]] || return 1
  { true </dev/tty >/dev/tty; } 2>/dev/null || return 1
  return 0
}

prompt() {
  local label="$1" default="$2" var="$3"
  local current="${!var:-}"
  if [[ -n "$current" ]]; then return 0; fi
  local value=""
  if frp_has_tty; then
    if [[ -n "$default" ]]; then
      read -r -p "$label [$default]: " value </dev/tty || true
    else
      read -r -p "$label: " value </dev/tty || true
    fi
  fi
  printf -v "$var" '%s' "${value:-$default}"
}

require_value() {
  local var="$1" label="$2"
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: ${label} is required." >&2
    echo "Set ${var} for non-interactive install, or enter it when prompted." >&2
    exit 1
  fi
}

# Overridable wrappers so installer tests can mock systemd/curl/sleep.
frp_server_systemctl() {
  systemctl "$@"
}

frp_server_curl() {
  curl "$@"
}

frp_server_journalctl() {
  journalctl "$@"
}

frp_server_sleep() {
  sleep "$@"
}

frp_allocator_ready_timeout_sec() {
  local timeout="${FRP_ALLOCATOR_READY_TIMEOUT_SEC:-30}"
  if [[ ! "$timeout" =~ ^[1-9][0-9]*$ ]]; then
    timeout=30
  fi
  printf '%s' "$timeout"
}

frp_allocator_ready_interval_sec() {
  local interval="${FRP_ALLOCATOR_READY_INTERVAL_SEC:-1}"
  if [[ ! "$interval" =~ ^[0-9]+([.][0-9]+)?$ ]] || [[ "$interval" == "0" || "$interval" == "0.0" ]]; then
    interval=1
  fi
  printf '%s' "$interval"
}

frp_print_unit_diagnostics() {
  local unit="$1"
  echo >&2
  echo "----- systemctl status ${unit} -----" >&2
  frp_server_systemctl status "$unit" --no-pager -l >&2 || true
  echo >&2
  echo "----- journalctl -u ${unit} -----" >&2
  frp_server_journalctl -u "$unit" -n 50 --no-pager >&2 || true
}

frp_wait_unit_active() {
  local unit="$1"
  local timeout interval start now
  timeout="$(frp_allocator_ready_timeout_sec)"
  interval="$(frp_allocator_ready_interval_sec)"
  start="$(date +%s)"
  while true; do
    if frp_server_systemctl is-active --quiet "$unit"; then
      return 0
    fi
    now="$(date +%s)"
    if (( now - start >= timeout )); then
      echo "ERROR: ${unit} did not become active within ${timeout} seconds" >&2
      frp_print_unit_diagnostics "$unit"
      return 1
    fi
    frp_server_sleep "$interval"
  done
}

frp_wait_allocator_ready() {
  local port="${1:-${FRP_ALLOCATOR_LISTEN_PORT:-${FRP_ALLOCATOR_PORT:-6099}}}"
  local timeout interval start now url announced=0 ca
  timeout="$(frp_allocator_ready_timeout_sec)"
  interval="$(frp_allocator_ready_interval_sec)"
  url="https://127.0.0.1:${port}/healthz"
  ca="${FRP_ALLOCATOR_READY_CA:-$(frp_pki_dir)/ca.crt}"
  start="$(date +%s)"

  while true; do
    if ! frp_server_systemctl is-active --quiet frp-port-allocator; then
      echo "ERROR: frp-port-allocator.service stopped before becoming ready" >&2
      frp_print_unit_diagnostics frp-port-allocator
      return 1
    fi
    if frp_server_curl -fsS --cacert "$ca" "$url" >/dev/null 2>&1; then
      return 0
    fi
    now="$(date +%s)"
    if (( now - start >= timeout )); then
      echo "ERROR: FRP allocator did not become ready within ${timeout} seconds" >&2
      frp_print_unit_diagnostics frp-port-allocator
      return 1
    fi
    if [[ "$announced" == "0" ]]; then
      echo "Waiting for FRP allocator HTTPS listener on ${url} ..."
      announced=1
    fi
    frp_server_sleep "$interval"
  done
}

frp_server_prepare_host() {
  frp_require_bash || exit 1
  frp_detect_architecture || exit 1
  frp_detect_platform
  frp_detect_package_manager
  frp_print_detected_linux
  echo
  frp_require_systemd || exit 1
  FRP_DEPENDENCY_ROLE=server
  ensure_dependencies || exit 1
  frp_require_python || exit 1
}

load_existing_server_config() {
  local path
  path="$(frp_server_config_path)"
  EXISTING_PUBLIC_IP=""
  EXISTING_CONTROL_PORT=""
  EXISTING_CONTROL_PUBLIC_PORT=""
  EXISTING_CONTROL_LISTEN_PORT=""
  EXISTING_PORT_START=""
  EXISTING_PORT_END=""
  EXISTING_ALLOCATOR_PORT=""
  EXISTING_ALLOCATOR_PUBLIC_PORT=""
  EXISTING_ALLOCATOR_LISTEN_PORT=""
  EXISTING_ALLOCATOR_URL=""
  EXISTING_CLIENT_INSTALLER_URL=""
  [[ -r "$path" ]] || return 0
  eval "$(python3 - "$path" <<'PY'
import json, shlex, sys
from pathlib import Path
path = Path(sys.argv[1])
try:
    cfg = json.loads(path.read_text(encoding='utf-8'))
except Exception:
    raise SystemExit(0)
if not isinstance(cfg, dict):
    raise SystemExit(0)
mapping = {
    'public_host': 'EXISTING_PUBLIC_IP',
    'public_ip': 'EXISTING_PUBLIC_IP',
    'control_port': 'EXISTING_CONTROL_PORT',
    'frp_control_public_port': 'EXISTING_CONTROL_PUBLIC_PORT',
    'frp_control_listen_port': 'EXISTING_CONTROL_LISTEN_PORT',
    'port_start': 'EXISTING_PORT_START',
    'port_end': 'EXISTING_PORT_END',
    'listen_port': 'EXISTING_ALLOCATOR_LISTEN_PORT',
    'allocator_listen_port': 'EXISTING_ALLOCATOR_LISTEN_PORT',
    'allocator_public_port': 'EXISTING_ALLOCATOR_PUBLIC_PORT',
    'client_installer_url': 'EXISTING_CLIENT_INSTALLER_URL',
}
# public_host wins over public_ip when both exist.
order = [
    'public_ip', 'public_host',
    'control_port', 'frp_control_public_port', 'frp_control_listen_port',
    'port_start', 'port_end',
    'listen_port', 'allocator_listen_port', 'allocator_public_port',
    'client_installer_url',
]
seen = {}
for key in order:
    envname = mapping[key]
    value = cfg.get(key)
    if value is None or value == '':
        continue
    seen[envname] = str(value)
for envname, value in seen.items():
    print(f'{envname}={shlex.quote(value)}')
url = str(cfg.get('allocator_public_url') or '').strip()
if url.lower().startswith('https://'):
    print('EXISTING_ALLOCATOR_URL=' + shlex.quote(url))
PY
)"
}

resolve_server_settings() {
  if [[ -z "${FRP_PUBLIC_IP:-}" && -n "${FRP_PUBLIC_HOST:-}" ]]; then
    FRP_PUBLIC_IP="$FRP_PUBLIC_HOST"
  fi
  if [[ -z "${FRP_ALLOCATOR_PUBLIC_URL:-}" && -n "${FRP_ALLOCATOR_URL:-}" ]]; then
    FRP_ALLOCATOR_PUBLIC_URL="$FRP_ALLOCATOR_URL"
  fi

  FRP_PUBLIC_IP="${FRP_PUBLIC_IP:-${EXISTING_PUBLIC_IP:-}}"
  FRP_PUBLIC_HOST="${FRP_PUBLIC_HOST:-$FRP_PUBLIC_IP}"
  FRP_INTERNAL_IP="${FRP_INTERNAL_IP:-}"
  FRP_PORT_START="${FRP_PORT_START:-${EXISTING_PORT_START:-}}"
  FRP_PORT_END="${FRP_PORT_END:-${EXISTING_PORT_END:-}}"
  CLIENT_INSTALLER_URL="${FRP_CLIENT_INSTALLER_URL:-${EXISTING_CLIENT_INSTALLER_URL:-$DEFAULT_CLIENT_INSTALLER_URL}}"
  frp_migrate_legacy_client_installer_url

  # Public vs listen: dedicated vars win; a single legacy FRP_CONTROL_PORT or
  # existing control_port is used for both only when the split was never set
  # (pre-P2.8 they were always equal).
  if [[ -z "${FRP_CONTROL_PUBLIC_PORT:-}" ]]; then
    FRP_CONTROL_PUBLIC_PORT="${EXISTING_CONTROL_PUBLIC_PORT:-}"
  fi
  if [[ -z "${FRP_CONTROL_LISTEN_PORT:-}" ]]; then
    FRP_CONTROL_LISTEN_PORT="${EXISTING_CONTROL_LISTEN_PORT:-}"
  fi
  if [[ -z "${FRP_CONTROL_PUBLIC_PORT:-}" && -z "${FRP_CONTROL_LISTEN_PORT:-}" ]]; then
    FRP_CONTROL_PUBLIC_PORT="${FRP_CONTROL_PORT:-${EXISTING_CONTROL_PORT:-}}"
    FRP_CONTROL_LISTEN_PORT="${FRP_CONTROL_PORT:-${EXISTING_CONTROL_PORT:-}}"
  fi
  if [[ -z "${FRP_CONTROL_PUBLIC_PORT:-}" && -n "${FRP_CONTROL_LISTEN_PORT:-}" ]]; then
    FRP_CONTROL_PUBLIC_PORT="$FRP_CONTROL_LISTEN_PORT"
  fi
  if [[ -z "${FRP_CONTROL_LISTEN_PORT:-}" && -n "${FRP_CONTROL_PUBLIC_PORT:-}" ]]; then
    FRP_CONTROL_LISTEN_PORT="$FRP_CONTROL_PUBLIC_PORT"
  fi

  if [[ -z "${FRP_ALLOCATOR_LISTEN_PORT:-}" ]]; then
    FRP_ALLOCATOR_LISTEN_PORT="${FRP_ALLOCATOR_PORT:-${EXISTING_ALLOCATOR_LISTEN_PORT:-${EXISTING_ALLOCATOR_PORT:-}}}"
  fi
  if [[ -z "${FRP_ALLOCATOR_PUBLIC_PORT:-}" ]]; then
    FRP_ALLOCATOR_PUBLIC_PORT="${EXISTING_ALLOCATOR_PUBLIC_PORT:-}"
  fi

  local detected_public="${DETECTED_PUBLIC_IP:-}"
  local detected_internal="${DETECTED_INTERNAL_IP:-}"

  echo
  echo "FRP Auto Deploy Server Setup"
  echo "============================"
  echo

  if [[ -z "$FRP_PUBLIC_IP" ]]; then
    if frp_has_tty; then
      prompt "Public hostname or IP" "$detected_public" FRP_PUBLIC_IP
    fi
  fi
  require_value FRP_PUBLIC_IP "Public hostname or IP (FRP_PUBLIC_HOST or FRP_PUBLIC_IP)"
  if ! frp_valid_public_host "$FRP_PUBLIC_IP"; then
    echo "ERROR: Public hostname or IP contains invalid characters" >&2
    exit 1
  fi
  FRP_PUBLIC_HOST="$FRP_PUBLIC_IP"

  local internal_default="${FRP_INTERNAL_IP:-${detected_internal:-}}"
  prompt "Internal FRP server IP (display only)" "$internal_default" FRP_INTERNAL_IP

  echo
  echo "FRP Control"
  echo "-----------"
  prompt "Public control port" "${FRP_CONTROL_PUBLIC_PORT:-443}" FRP_CONTROL_PUBLIC_PORT
  prompt "Internal listen port" "${FRP_CONTROL_LISTEN_PORT:-${FRP_CONTROL_PUBLIC_PORT:-443}}" FRP_CONTROL_LISTEN_PORT

  echo
  echo "Enrollment / Management HTTPS"
  echo "-----------------------------"
  prompt "Public HTTPS port" "${FRP_ALLOCATOR_PUBLIC_PORT:-${FRP_ALLOCATOR_LISTEN_PORT:-6099}}" FRP_ALLOCATOR_PUBLIC_PORT
  prompt "Internal listen port" "${FRP_ALLOCATOR_LISTEN_PORT:-${FRP_ALLOCATOR_PUBLIC_PORT:-6099}}" FRP_ALLOCATOR_LISTEN_PORT

  echo
  echo "Published Service Ports"
  echo "-----------------------"
  prompt "Range start" "${FRP_PORT_START:-6000}" FRP_PORT_START
  prompt "Range end" "${FRP_PORT_END:-6098}" FRP_PORT_END

  FRP_CONTROL_PORT="$FRP_CONTROL_LISTEN_PORT"
  FRP_ALLOCATOR_PORT="$FRP_ALLOCATOR_LISTEN_PORT"
  if [[ -z "${FRP_ALLOCATOR_PUBLIC_PORT:-}" ]]; then
    FRP_ALLOCATOR_PUBLIC_PORT="$FRP_ALLOCATOR_LISTEN_PORT"
  fi
  if [[ -z "${FRP_ALLOCATOR_LISTEN_PORT:-}" ]]; then
    FRP_ALLOCATOR_LISTEN_PORT="$FRP_ALLOCATOR_PUBLIC_PORT"
  fi

  local derived_url
  derived_url="$(frp_format_https_url "$FRP_PUBLIC_HOST" "$FRP_ALLOCATOR_PUBLIC_PORT" /enroll)"
  if [[ -n "${FRP_ALLOCATOR_PUBLIC_URL:-}" ]]; then
    if [[ "${FRP_ALLOCATOR_PUBLIC_URL,,}" == http://* ]]; then
      echo "ERROR: allocator public URL must be HTTPS; plain HTTP is not supported" >&2
      exit 1
    fi
  elif [[ -n "${EXISTING_ALLOCATOR_URL:-}" ]]; then
    FRP_ALLOCATOR_PUBLIC_URL="$EXISTING_ALLOCATOR_URL"
  else
    if frp_has_tty; then
      prompt "Allocator public URL" "$derived_url" FRP_ALLOCATOR_PUBLIC_URL
    else
      FRP_ALLOCATOR_PUBLIC_URL="$derived_url"
    fi
  fi
  require_value FRP_ALLOCATOR_PUBLIC_URL "Allocator public URL (FRP_ALLOCATOR_PUBLIC_URL or FRP_ALLOCATOR_URL)"
  if [[ "${FRP_ALLOCATOR_PUBLIC_URL,,}" == http://* ]]; then
    echo "ERROR: allocator public URL must be HTTPS; plain HTTP is not supported" >&2
    exit 1
  fi
  if ! frp_valid_https_url "$FRP_ALLOCATOR_PUBLIC_URL"; then
    echo "ERROR: Allocator public URL must be an https:// URL with a host" >&2
    exit 1
  fi

  local port_name
  for port_name in FRP_CONTROL_PUBLIC_PORT FRP_CONTROL_LISTEN_PORT \
    FRP_ALLOCATOR_PUBLIC_PORT FRP_ALLOCATOR_LISTEN_PORT FRP_PORT_START FRP_PORT_END; do
    if ! frp_valid_tcp_port "${!port_name}"; then
      echo "ERROR: ${port_name} must be an integer TCP port between 1 and 65535" >&2
      exit 1
    fi
  done
  if (( 10#$FRP_PORT_START > 10#$FRP_PORT_END )); then
    echo "ERROR: invalid service port range" >&2
    exit 1
  fi
  if (( 10#$FRP_CONTROL_LISTEN_PORT == 10#$FRP_ALLOCATOR_LISTEN_PORT )); then
    echo "ERROR: local port collision: FRP control listen port and allocator listen port cannot share ${FRP_CONTROL_LISTEN_PORT}" >&2
    exit 1
  fi
  if (( 10#$FRP_ALLOCATOR_LISTEN_PORT >= 10#$FRP_PORT_START && 10#$FRP_ALLOCATOR_LISTEN_PORT <= 10#$FRP_PORT_END )); then
    echo "ERROR: allocator listen port must be outside the FRP service port range" >&2
    exit 1
  fi
  if (( 10#$FRP_CONTROL_LISTEN_PORT >= 10#$FRP_PORT_START && 10#$FRP_CONTROL_LISTEN_PORT <= 10#$FRP_PORT_END )); then
    echo "ERROR: FRP control listen port must be outside the FRP service port range" >&2
    exit 1
  fi
  if [[ "$FRP_CONTROL_PUBLIC_PORT" == "$FRP_ALLOCATOR_PUBLIC_PORT" ]]; then
    echo "WARNING: FRP control and allocator public ports are both ${FRP_CONTROL_PUBLIC_PORT}." >&2
    echo "WARNING: two distinct raw TCP services cannot normally share the same public IP:port without an external proxy." >&2
  fi
}

write_server_config() {
  local path pki
  path="$(frp_server_config_path)"
  pki="$(frp_pki_dir)"
  mkdir -p "$(dirname "$path")"
  python3 - "$path" \
    "$FRP_PUBLIC_HOST" \
    "$FRP_CONTROL_PUBLIC_PORT" \
    "$FRP_CONTROL_LISTEN_PORT" \
    "$FRP_PORT_START" \
    "$FRP_PORT_END" \
    "$FRP_ALLOCATOR_PUBLIC_PORT" \
    "$FRP_ALLOCATOR_LISTEN_PORT" \
    "$FRP_ALLOCATOR_PUBLIC_URL" \
    "$CLIENT_INSTALLER_URL" \
    "$pki" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
pki = sys.argv[11]
host = sys.argv[2]
cfg = {
    'public_host': host,
    'public_ip': host,
    'frp_control_public_port': int(sys.argv[3]),
    'frp_control_listen_port': int(sys.argv[4]),
    'port_start': int(sys.argv[5]),
    'port_end': int(sys.argv[6]),
    'listen_host': '0.0.0.0',
    'allocator_public_port': int(sys.argv[7]),
    'allocator_listen_port': int(sys.argv[8]),
    'listen_port': int(sys.argv[8]),
    'allocator_public_url': sys.argv[9],
    'registry_file': '/var/lib/frp-auto-deploy/registry.json',
    'enrollments_dir': '/var/lib/frp-auto-deploy/enrollments',
    'token_file': '/etc/frp/server_token',
    'client_installer_url': sys.argv[10],
    'tls_ca_cert': pki.rstrip('/') + '/ca.crt',
    'tls_server_cert': pki.rstrip('/') + '/server.crt',
    'tls_server_key': pki.rstrip('/') + '/server.key',
}
path.write_text(json.dumps(cfg, indent=2, sort_keys=True) + '\n', encoding='utf-8')
PY
  chmod 600 "$path"
}

frp_ensure_server_pki() {
  local pki url_host extra
  pki="$(frp_pki_dir)"
  mkdir -p "$pki"
  chmod 700 "$pki"
  url_host="$(python3 - "$FRP_ALLOCATOR_PUBLIC_URL" <<'PY'
import sys
url = sys.argv[1].strip()
if not url.lower().startswith('https://'):
    raise SystemExit(1)
rest = url[8:]
rest = rest.split('/', 1)[0]
if rest.startswith('['):
    end = rest.find(']')
    print(rest[1:end])
elif ':' in rest:
    print(rest.rsplit(':', 1)[0])
else:
    print(rest)
PY
)"
  extra=()
  if [[ -n "$url_host" && "$url_host" != "$FRP_PUBLIC_HOST" ]]; then
    extra+=(--url-host "$url_host")
  fi
  if ((${#extra[@]} > 0)); then
    python3 "$BASE_DIR/lib/frp_pki.py" ensure \
      --pki-dir "$pki" \
      --public-host "$FRP_PUBLIC_HOST" \
      "${extra[@]}"
  else
    python3 "$BASE_DIR/lib/frp_pki.py" ensure \
      --pki-dir "$pki" \
      --public-host "$FRP_PUBLIC_HOST"
  fi
}

frp_print_nat_summary() {
  local control_target alloc_target
  if [[ -n "${FRP_INTERNAL_IP:-}" ]]; then
    control_target="${FRP_INTERNAL_IP}:${FRP_CONTROL_LISTEN_PORT}"
    alloc_target="${FRP_INTERNAL_IP}:${FRP_ALLOCATOR_LISTEN_PORT}"
  else
    control_target="this FRP server (TCP/${FRP_CONTROL_LISTEN_PORT})"
    alloc_target="this FRP server (TCP/${FRP_ALLOCATOR_LISTEN_PORT})"
  fi
  cat <<EOF2

Network / NAT Requirements
==========================

FRP Control
  Public:
    TCP ${FRP_PUBLIC_HOST}:${FRP_CONTROL_PUBLIC_PORT}

  Forward to:
    ${control_target}


Enrollment HTTPS
  Public:
    TCP ${FRP_PUBLIC_HOST}:${FRP_ALLOCATOR_PUBLIC_PORT}
    ${FRP_ALLOCATOR_PUBLIC_URL}

  Forward to:
    ${alloc_target}


Published Services
  Public:
    TCP ${FRP_PORT_START}-${FRP_PORT_END}

  Forward to:
    same TCP port numbers on this FRP server (1:1)

EOF2
  if [[ -z "${FRP_INTERNAL_IP:-}" ]]; then
    echo "Local bind address could not be detected automatically."
    echo "FRP control target listen port: ${FRP_CONTROL_LISTEN_PORT}"
    echo "Allocator target listen port: ${FRP_ALLOCATOR_LISTEN_PORT}"
    echo "Forward those ports to this FRP server."
    echo
  fi
  if [[ "$FRP_CONTROL_PUBLIC_PORT" == "$FRP_CONTROL_LISTEN_PORT" && "$FRP_ALLOCATOR_PUBLIC_PORT" == "$FRP_ALLOCATOR_LISTEN_PORT" ]]; then
    echo "Public and internal ports match; no NAT remapping is required for FRP or the allocator."
    echo
  fi
}

frp_server_main() {
  if [[ ${EUID} -ne 0 ]]; then
    echo "ERROR: run with sudo" >&2
    exit 1
  fi

  frp_server_prepare_host

  DETECTED_PUBLIC_IP="$(curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)"
  DETECTED_INTERNAL_IP="$(frp_detect_internal_ip)"

  load_existing_server_config
  resolve_server_settings

  if [[ -z "${FRP_ARCH:-}" ]]; then
    frp_detect_architecture || exit 1
  fi

  # Capture existing listeners before restarting an existing frps. On first migration,
  # this preserves ports such as 6000/6001 already used by unmanaged clients.
  ACTIVE_PORTS="$(frp_listening_tcp_ports_in_range "$FRP_PORT_START" "$FRP_PORT_END")"

  TMPDIR="$(mktemp -d)"
  trap 'rm -rf "$TMPDIR"' EXIT
  ARCHIVE="$TMPDIR/frp.tar.gz"
  URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_${FRP_ARCH}.tar.gz"
  echo "Downloading official FRP ${FRP_VERSION} (${FRP_ARCH}) ..."
  curl -fL --retry 3 -o "$ARCHIVE" "$URL"
  printf '%s  %s\n' "$EXPECTED_SHA" "$ARCHIVE" | sha256sum -c -
  tar xzf "$ARCHIVE" -C "$TMPDIR"
  install -m 0755 "$TMPDIR/frp_${FRP_VERSION}_linux_${FRP_ARCH}/frps" /usr/local/bin/frps

  mkdir -p /etc/frp /etc/frp-auto-deploy /var/lib/frp-auto-deploy/enrollments /var/lib/frp-auto-deploy/backups /usr/local/lib/frp-auto-deploy
  chmod 700 /etc/frp /etc/frp-auto-deploy /var/lib/frp-auto-deploy /var/lib/frp-auto-deploy/enrollments /var/lib/frp-auto-deploy/backups
  frp_write_version_file /etc/frp-auto-deploy/version

  TOKEN_ACTION=""
  TOKEN_PRESERVED="N/A"
  TOKEN_BACKUP=""
  migrate_out="$(python3 "$BASE_DIR/server/migrate_token.py" ensure --etc-dir /etc/frp --backup)"
  while IFS= read -r line; do
    case "$line" in
      TOKEN_ACTION=*|TOKEN_PRESERVED=*|TOKEN_BACKUP=*)
        printf -v "${line%%=*}" '%s' "${line#*=}"
        ;;
    esac
  done <<< "$migrate_out"
  [[ -s /etc/frp/server_token ]] || { echo "ERROR: FRP server token is missing after migration" >&2; exit 1; }
  chmod 600 /etc/frp/server_token

  cat >/etc/frp/frps.toml <<EOF2
bindPort = ${FRP_CONTROL_LISTEN_PORT}

auth.method = "token"
auth.tokenSource.type = "file"
auth.tokenSource.file.path = "/etc/frp/server_token"

transport.tls.force = true

allowPorts = [
  { start = ${FRP_PORT_START}, end = ${FRP_PORT_END} }
]
EOF2
  chmod 600 /etc/frp/frps.toml
  /usr/local/bin/frps verify -c /etc/frp/frps.toml

  write_server_config
  pki_out="$(frp_ensure_server_pki)"
  CA_FINGERPRINT=""
  PKI_ACTION=""
  while IFS= read -r line; do
    case "$line" in
      PKI_ACTION=*|CA_FINGERPRINT=*|TLS_CA_CERT=*|TLS_SERVER_CERT=*|TLS_SERVER_KEY=*)
        printf -v "${line%%=*}" '%s' "${line#*=}"
        ;;
    esac
  done <<< "$pki_out"
  [[ -n "$CA_FINGERPRINT" ]] || { echo "ERROR: allocator CA fingerprint is missing" >&2; exit 1; }

  REGISTRY_ACTION=""
  MIGRATED_CLIENTS="0"
  PRESERVED_PORTS="0"
  registry_out="$(python3 "$BASE_DIR/server/migrate_token.py" init-registry \
    --registry /var/lib/frp-auto-deploy/registry.json \
    --ports "$ACTIVE_PORTS" \
    --port-start "$FRP_PORT_START" \
    --port-end "$FRP_PORT_END" \
    --allocator-port "$FRP_ALLOCATOR_PORT")"
  while IFS= read -r line; do
    case "$line" in
      REGISTRY_ACTION=*|MIGRATED_CLIENTS=*|PRESERVED_PORTS=*)
        printf -v "${line%%=*}" '%s' "${line#*=}"
        ;;
    esac
  done <<< "$registry_out"
  [[ -f /var/lib/frp-auto-deploy/registry.json ]] || { echo "ERROR: registry.json is missing" >&2; exit 1; }
  chmod 600 /var/lib/frp-auto-deploy/registry.json

  install -m 0700 "$BASE_DIR/server/frp-port-allocator.py" /usr/local/lib/frp-auto-deploy/frp-port-allocator.py
  install -m 0644 "$BASE_DIR/lib/frp_mgmt_auth.py" /usr/local/lib/frp-auto-deploy/frp_mgmt_auth.py
  install -m 0644 "$BASE_DIR/lib/frp_pki.py" /usr/local/lib/frp-auto-deploy/frp_pki.py
  install -m 0644 "$BASE_DIR/lib/frp-common.sh" /usr/local/lib/frp-auto-deploy/frp-common.sh
  install -m 0644 "$BASE_DIR/server/frps.service" /etc/systemd/system/frps.service
  frp_write_compatible_systemd_unit \
    "$BASE_DIR/server/frp-port-allocator.service" \
    /etc/systemd/system/frp-port-allocator.service
  for tool in frp-create-client frp-clients frp-client-info frp-release-client frp-release-service frp-revoke-client frp-set-client-installer-url frp-server-status frp-update frpctl; do
    install -m 0755 "$BASE_DIR/tools/$tool" "/usr/local/sbin/$tool"
  done

  systemctl daemon-reload
  systemctl enable frps frp-port-allocator >/dev/null
  systemctl restart frps
  systemctl restart frp-port-allocator

  frp_wait_unit_active frps || exit 1
  frp_wait_allocator_ready "$FRP_ALLOCATOR_LISTEN_PORT" || exit 1

  cat <<EOF2

============================================================
 FRP Auto Deploy server installation complete
============================================================

Project version   : ${PROJECT_VERSION}
FRP version       : ${FRP_VERSION}
Public host       : ${FRP_PUBLIC_HOST}
FRP control public: TCP/${FRP_CONTROL_PUBLIC_PORT}
FRP control listen: TCP/${FRP_CONTROL_LISTEN_PORT}
Allocator public  : ${FRP_ALLOCATOR_PUBLIC_URL}
Allocator listen  : TCP/${FRP_ALLOCATOR_LISTEN_PORT}
Service range     : TCP/${FRP_PORT_START}-${FRP_PORT_END}
TLS CA SHA256     : ${CA_FINGERPRINT}
EOF2
  if [[ -n "$ACTIVE_PORTS" ]]; then
    echo "Preserved existing ports as reserved: $ACTIVE_PORTS"
  fi
  if [[ "$TOKEN_PRESERVED" == "PASS" ]]; then
    echo "Existing FRP authentication token preserved: TOKEN_PRESERVED=PASS"
  elif [[ "$TOKEN_ACTION" == "generated" ]]; then
    echo "Generated a new FRP authentication token for this fresh install."
  fi
  if [[ -n "$TOKEN_BACKUP" ]]; then
    echo "Existing frps.toml backed up with mode 600"
  fi
  if [[ "${PKI_ACTION:-}" == "reused" ]]; then
    echo "Existing allocator CA preserved."
  elif [[ "${PKI_ACTION:-}" == "reissued-server" ]]; then
    echo "Reissued allocator server certificate using the existing CA."
  elif [[ "${PKI_ACTION:-}" == "generated" ]]; then
    echo "Generated a new allocator private CA and server certificate."
  fi
  frp_print_nat_summary
  cat <<EOF2
Create a client enrollment:
  sudo frpctl create-client
  sudo frp-create-client

Everyday command (remember this one):
  sudo frpctl
  Then type help inside the CLI.

Check schema v2 deployment readiness:
  sudo frpctl status
  sudo frp-server-status
  sudo frp-server-status --check

Update FRP to the tested version:
  sudo frpctl update
  sudo frp-update

List clients:
  sudo frp-clients

============================================================
EOF2
}

if [[ "${FRP_SERVER_SOURCED:-}" != "1" ]]; then
  frp_server_main "$@"
fi
