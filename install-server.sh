#!/usr/bin/env bash
set -euo pipefail

PROJECT_VERSION="1.0.0"
FRP_VERSION="0.70.1"
FRP_SHA256_AMD64="333da23d1b9009d7c01638e9ba38cf4600f7d37d393f854e96ee1396adefa9a6"
FRP_SHA256_ARM64="3990f396a9a490ee7f0e5f355287750ed41520064ed999eab443b5e9a78d773d"
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ${EUID} -ne 0 ]]; then
  echo "ERROR: run with sudo" >&2
  exit 1
fi

for f in \
  "$BASE_DIR/server/frp-port-allocator.py" \
  "$BASE_DIR/server/migrate_token.py" \
  "$BASE_DIR/server/frps.service" \
  "$BASE_DIR/server/frp-port-allocator.service" \
  "$BASE_DIR/tools/frp-create-client" \
  "$BASE_DIR/tools/frp-clients" \
  "$BASE_DIR/tools/frp-client-info" \
  "$BASE_DIR/tools/frp-release-client" \
  "$BASE_DIR/tools/frp-set-client-installer-url" \
  "$BASE_DIR/tools/frp-server-status"; do
  [[ -f "$f" ]] || { echo "ERROR: missing project file: $f" >&2; exit 1; }
done

prompt() {
  local label="$1" default="$2" var="$3"
  local current="${!var:-}"
  if [[ -n "$current" ]]; then return 0; fi
  local value=""
  if [[ -r /dev/tty ]]; then
    read -r -p "$label [$default]: " value </dev/tty || true
  fi
  printf -v "$var" '%s' "${value:-$default}"
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

ensure_deps

DETECTED_PUBLIC_IP="$(curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)"
DETECTED_INTERNAL_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"

prompt "Public firewall/NAT IP" "${DETECTED_PUBLIC_IP:-221.139.249.110}" FRP_PUBLIC_IP
prompt "FRP server internal IP (display only)" "${DETECTED_INTERNAL_IP:-10.10.10.50}" FRP_INTERNAL_IP
prompt "FRP control port" "443" FRP_CONTROL_PORT
prompt "Service port range start" "6000" FRP_PORT_START
prompt "Service port range end" "6098" FRP_PORT_END
prompt "Allocator internal listen port" "6099" FRP_ALLOCATOR_PORT
DEFAULT_PUBLIC_URL="http://${FRP_PUBLIC_IP}/enroll"
prompt "Allocator public URL" "$DEFAULT_PUBLIC_URL" FRP_ALLOCATOR_PUBLIC_URL

if (( FRP_PORT_START < 1 || FRP_PORT_END > 65535 || FRP_PORT_START > FRP_PORT_END )); then
  echo "ERROR: invalid service port range" >&2; exit 1
fi
if (( FRP_ALLOCATOR_PORT >= FRP_PORT_START && FRP_ALLOCATOR_PORT <= FRP_PORT_END )); then
  echo "ERROR: allocator port must be outside the FRP service port range" >&2; exit 1
fi

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

mkdir -p /etc/frp /etc/frp-auto-deploy /var/lib/frp-auto-deploy/enrollments /usr/local/lib/frp-auto-deploy
chmod 700 /etc/frp /etc/frp-auto-deploy /var/lib/frp-auto-deploy /var/lib/frp-auto-deploy/enrollments

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

CLIENT_INSTALLER_URL="${FRP_CLIENT_INSTALLER_URL:-https://raw.githubusercontent.com/RickLee-kr/frp-auto-deploy/main/dist/bootstrap-client.sh}"
python3 - "$FRP_PUBLIC_IP" "$FRP_CONTROL_PORT" "$FRP_PORT_START" "$FRP_PORT_END" \
  "$FRP_ALLOCATOR_PORT" "$FRP_ALLOCATOR_PUBLIC_URL" "$CLIENT_INSTALLER_URL" <<'PY'
import json,sys
cfg={
 'public_ip':sys.argv[1],
 'control_port':int(sys.argv[2]),
 'port_start':int(sys.argv[3]),
 'port_end':int(sys.argv[4]),
 'listen_host':'0.0.0.0',
 'listen_port':int(sys.argv[5]),
 'allocator_public_url':sys.argv[6],
 'registry_file':'/var/lib/frp-auto-deploy/registry.json',
 'enrollments_dir':'/var/lib/frp-auto-deploy/enrollments',
 'token_file':'/etc/frp/server_token',
 'client_installer_url':sys.argv[7],
}
open('/etc/frp-auto-deploy/config.json','w').write(json.dumps(cfg,indent=2,sort_keys=True)+'\n')
PY
chmod 600 /etc/frp-auto-deploy/config.json

REGISTRY_ACTION=""
LEGACY_REGISTRY_MIGRATION="N/A"
MIGRATED_CLIENTS="0"
PRESERVED_PORTS="0"
registry_out="$(python3 "$BASE_DIR/server/migrate_token.py" init-registry \
  --registry /var/lib/frp-auto-deploy/registry.json \
  --legacy-registry /var/lib/frp-port-allocator/registry.json \
  --ports "$ACTIVE_PORTS" \
  --port-start "$FRP_PORT_START" \
  --port-end "$FRP_PORT_END" \
  --allocator-port "$FRP_ALLOCATOR_PORT")"
while IFS= read -r line; do
  case "$line" in
    REGISTRY_ACTION=*|LEGACY_REGISTRY_MIGRATION=*|MIGRATED_CLIENTS=*|PRESERVED_PORTS=*)
      printf -v "${line%%=*}" '%s' "${line#*=}"
      ;;
  esac
done <<< "$registry_out"
[[ -f /var/lib/frp-auto-deploy/registry.json ]] || { echo "ERROR: registry.json is missing" >&2; exit 1; }
chmod 600 /var/lib/frp-auto-deploy/registry.json

install -m 0700 "$BASE_DIR/server/frp-port-allocator.py" /usr/local/lib/frp-auto-deploy/frp-port-allocator.py
install -m 0644 "$BASE_DIR/server/frps.service" /etc/systemd/system/frps.service
install -m 0644 "$BASE_DIR/server/frp-port-allocator.service" /etc/systemd/system/frp-port-allocator.service
for tool in frp-create-client frp-clients frp-client-info frp-release-client frp-set-client-installer-url frp-server-status; do
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
if [[ "$LEGACY_REGISTRY_MIGRATION" == "PASS" ]]; then
  echo "LEGACY_REGISTRY_MIGRATION=PASS"
  echo "MIGRATED_CLIENTS=${MIGRATED_CLIENTS}"
  echo "PRESERVED_PORTS=${PRESERVED_PORTS}"
fi
cat <<EOF2

Firewall / DNAT example:
  ${FRP_PUBLIC_IP}:${FRP_CONTROL_PORT} -> ${FRP_INTERNAL_IP}:${FRP_CONTROL_PORT}
  ${FRP_PUBLIC_IP}:${FRP_PORT_START}-${FRP_PORT_END} -> ${FRP_INTERNAL_IP}:${FRP_PORT_START}-${FRP_PORT_END}
  ${FRP_PUBLIC_IP}:80 -> ${FRP_INTERNAL_IP}:${FRP_ALLOCATOR_PORT}

Create a client enrollment:
  sudo frp-create-client

Server status:
  sudo frp-server-status

List clients:
  sudo frp-clients

Set GitHub raw client installer URL after pushing the repository:
  sudo frp-set-client-installer-url https://raw.githubusercontent.com/RickLee-kr/frp-auto-deploy/main/dist/bootstrap-client.sh

============================================================
EOF2
