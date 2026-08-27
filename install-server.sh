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

frp_valid_http_url() {
  local url="${1:-}"
  case "$url" in
    http://?*|https://?*) ;;
    *) return 1 ;;
  esac
  if [[ "$url" == *$'\n'* || "$url" == *$'\r'* || "$url" == *$'\t'* || "$url" == *' '* ]]; then
    return 1
  fi
  local rest="${url#*://}"
  local hostport="${rest%%/*}"
  [[ -n "$hostport" ]]
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

ensure_deps() {
  if ! command -v apt-get >/dev/null 2>&1; then
    echo "ERROR: automatic server installation currently supports Debian/Ubuntu only" >&2
    exit 1
  fi
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq curl openssl python3 ca-certificates tar coreutils iproute2
}

load_existing_server_config() {
  local path
  path="$(frp_server_config_path)"
  EXISTING_PUBLIC_IP=""
  EXISTING_CONTROL_PORT=""
  EXISTING_PORT_START=""
  EXISTING_PORT_END=""
  EXISTING_ALLOCATOR_PORT=""
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
    'public_ip': 'EXISTING_PUBLIC_IP',
    'control_port': 'EXISTING_CONTROL_PORT',
    'port_start': 'EXISTING_PORT_START',
    'port_end': 'EXISTING_PORT_END',
    'listen_port': 'EXISTING_ALLOCATOR_PORT',
    'allocator_public_url': 'EXISTING_ALLOCATOR_URL',
    'client_installer_url': 'EXISTING_CLIENT_INSTALLER_URL',
}
for key, envname in mapping.items():
    value = cfg.get(key)
    if value is None or value == '':
        continue
    print(f'{envname}={shlex.quote(str(value))}')
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
  FRP_INTERNAL_IP="${FRP_INTERNAL_IP:-}"
  FRP_CONTROL_PORT="${FRP_CONTROL_PORT:-${EXISTING_CONTROL_PORT:-}}"
  FRP_PORT_START="${FRP_PORT_START:-${EXISTING_PORT_START:-}}"
  FRP_PORT_END="${FRP_PORT_END:-${EXISTING_PORT_END:-}}"
  FRP_ALLOCATOR_PORT="${FRP_ALLOCATOR_PORT:-${EXISTING_ALLOCATOR_PORT:-}}"
  FRP_ALLOCATOR_PUBLIC_URL="${FRP_ALLOCATOR_PUBLIC_URL:-${EXISTING_ALLOCATOR_URL:-}}"
  CLIENT_INSTALLER_URL="${FRP_CLIENT_INSTALLER_URL:-${EXISTING_CLIENT_INSTALLER_URL:-$DEFAULT_CLIENT_INSTALLER_URL}}"
  frp_migrate_legacy_client_installer_url

  local detected_public="${DETECTED_PUBLIC_IP:-}"
  local detected_internal="${DETECTED_INTERNAL_IP:-}"

  if [[ -z "$FRP_PUBLIC_IP" ]]; then
    if frp_has_tty; then
      prompt "Public IP/hostname" "$detected_public" FRP_PUBLIC_IP
    fi
  fi
  require_value FRP_PUBLIC_IP "Public IP/hostname (FRP_PUBLIC_IP or FRP_PUBLIC_HOST)"
  if ! frp_valid_public_host "$FRP_PUBLIC_IP"; then
    echo "ERROR: Public IP/hostname contains invalid characters" >&2
    exit 1
  fi

  local internal_default="${FRP_INTERNAL_IP:-${detected_internal:-$FRP_PUBLIC_IP}}"
  prompt "Internal FRP server IP (display only)" "$internal_default" FRP_INTERNAL_IP
  FRP_INTERNAL_IP="${FRP_INTERNAL_IP:-$FRP_PUBLIC_IP}"

  prompt "FRP control port" "${FRP_CONTROL_PORT:-443}" FRP_CONTROL_PORT
  prompt "Service port range start" "${FRP_PORT_START:-6000}" FRP_PORT_START
  prompt "Service port range end" "${FRP_PORT_END:-6098}" FRP_PORT_END
  prompt "Allocator internal listen port" "${FRP_ALLOCATOR_PORT:-6099}" FRP_ALLOCATOR_PORT

  local derived_url="http://${FRP_PUBLIC_IP}/enroll"
  if [[ -z "$FRP_ALLOCATOR_PUBLIC_URL" ]]; then
    if frp_has_tty; then
      prompt "Allocator public URL" "$derived_url" FRP_ALLOCATOR_PUBLIC_URL
    else
      FRP_ALLOCATOR_PUBLIC_URL="$derived_url"
    fi
  fi
  require_value FRP_ALLOCATOR_PUBLIC_URL "Allocator public URL (FRP_ALLOCATOR_PUBLIC_URL or FRP_ALLOCATOR_URL)"
  if ! frp_valid_http_url "$FRP_ALLOCATOR_PUBLIC_URL"; then
    echo "ERROR: Allocator public URL must be an http:// or https:// URL with a host" >&2
    exit 1
  fi

  if ! [[ "$FRP_CONTROL_PORT" =~ ^[0-9]+$ && "$FRP_PORT_START" =~ ^[0-9]+$ && "$FRP_PORT_END" =~ ^[0-9]+$ && "$FRP_ALLOCATOR_PORT" =~ ^[0-9]+$ ]]; then
    echo "ERROR: ports must be integers" >&2
    exit 1
  fi
  if (( FRP_CONTROL_PORT < 1 || FRP_CONTROL_PORT > 65535 || FRP_PORT_START < 1 || FRP_PORT_END > 65535 || FRP_PORT_START > FRP_PORT_END )); then
    echo "ERROR: invalid service port range" >&2
    exit 1
  fi
  if (( FRP_ALLOCATOR_PORT < 1 || FRP_ALLOCATOR_PORT > 65535 )); then
    echo "ERROR: invalid allocator port" >&2
    exit 1
  fi
  if (( FRP_ALLOCATOR_PORT >= FRP_PORT_START && FRP_ALLOCATOR_PORT <= FRP_PORT_END )); then
    echo "ERROR: allocator port must be outside the FRP service port range" >&2
    exit 1
  fi
}

write_server_config() {
  local path
  path="$(frp_server_config_path)"
  mkdir -p "$(dirname "$path")"
  python3 - "$path" "$FRP_PUBLIC_IP" "$FRP_CONTROL_PORT" "$FRP_PORT_START" "$FRP_PORT_END" \
    "$FRP_ALLOCATOR_PORT" "$FRP_ALLOCATOR_PUBLIC_URL" "$CLIENT_INSTALLER_URL" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
cfg = {
    'public_ip': sys.argv[2],
    'control_port': int(sys.argv[3]),
    'port_start': int(sys.argv[4]),
    'port_end': int(sys.argv[5]),
    'listen_host': '0.0.0.0',
    'listen_port': int(sys.argv[6]),
    'allocator_public_url': sys.argv[7],
    'registry_file': '/var/lib/frp-auto-deploy/registry.json',
    'enrollments_dir': '/var/lib/frp-auto-deploy/enrollments',
    'token_file': '/etc/frp/server_token',
    'client_installer_url': sys.argv[8],
}
path.write_text(json.dumps(cfg, indent=2, sort_keys=True) + '\n', encoding='utf-8')
PY
  chmod 600 "$path"
}

frp_server_main() {
  if [[ ${EUID} -ne 0 ]]; then
    echo "ERROR: run with sudo" >&2
    exit 1
  fi

  ensure_deps

  DETECTED_PUBLIC_IP="$(curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)"
  DETECTED_INTERNAL_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"

  load_existing_server_config
  resolve_server_settings

  case "$(uname -m)" in
    x86_64) FRP_ARCH=amd64; EXPECTED_SHA="$FRP_SHA256_AMD64" ;;
    aarch64|arm64) FRP_ARCH=arm64; EXPECTED_SHA="$FRP_SHA256_ARM64" ;;
    *) echo "ERROR: unsupported architecture: $(uname -m)" >&2; exit 1 ;;
  esac

  # Capture existing listeners before restarting an existing frps. On first migration,
  # this preserves ports such as 6000/6001 already used by unmanaged clients.
  ACTIVE_PORTS="$(ss -H -lnt 2>/dev/null | awk -v s="$FRP_PORT_START" -v e="$FRP_PORT_END" '{p=$4; sub(/^.*:/,"",p); if (p ~ /^[0-9]+$/ && p>=s && p<=e) print p}' | sort -nu | paste -sd, - || true)"

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
bindPort = ${FRP_CONTROL_PORT}

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
  install -m 0644 "$BASE_DIR/lib/frp-common.sh" /usr/local/lib/frp-auto-deploy/frp-common.sh
  install -m 0644 "$BASE_DIR/server/frps.service" /etc/systemd/system/frps.service
  install -m 0644 "$BASE_DIR/server/frp-port-allocator.service" /etc/systemd/system/frp-port-allocator.service
  for tool in frp-create-client frp-clients frp-client-info frp-release-client frp-release-service frp-revoke-client frp-set-client-installer-url frp-server-status frp-update frpctl; do
    install -m 0755 "$BASE_DIR/tools/$tool" "/usr/local/sbin/$tool"
  done

  systemctl daemon-reload
  systemctl enable frps frp-port-allocator >/dev/null
  systemctl restart frps
  systemctl restart frp-port-allocator

  sleep 2
  systemctl is-active --quiet frps || { journalctl -u frps -n 50 --no-pager; exit 1; }
  systemctl is-active --quiet frp-port-allocator || { journalctl -u frp-port-allocator -n 50 --no-pager; exit 1; }
  curl -fsS "http://127.0.0.1:${FRP_ALLOCATOR_PORT}/healthz" >/dev/null

  cat <<EOF2

============================================================
 FRP Auto Deploy server installation complete
============================================================

Project version   : ${PROJECT_VERSION}
FRP version       : ${FRP_VERSION}
Public IP         : ${FRP_PUBLIC_IP}
Internal FRP IP   : ${FRP_INTERNAL_IP}
FRP control       : TCP/${FRP_CONTROL_PORT}
Service range     : TCP/${FRP_PORT_START}-${FRP_PORT_END}
Allocator internal: TCP/${FRP_ALLOCATOR_PORT}
Allocator URL     : ${FRP_ALLOCATOR_PUBLIC_URL}
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
  cat <<EOF2

Firewall / DNAT example:
  ${FRP_PUBLIC_IP}:${FRP_CONTROL_PORT} -> ${FRP_INTERNAL_IP}:${FRP_CONTROL_PORT}
  ${FRP_PUBLIC_IP}:${FRP_PORT_START}-${FRP_PORT_END} -> ${FRP_INTERNAL_IP}:${FRP_PORT_START}-${FRP_PORT_END}
  ${FRP_PUBLIC_IP}:80 -> ${FRP_INTERNAL_IP}:${FRP_ALLOCATOR_PORT}

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
