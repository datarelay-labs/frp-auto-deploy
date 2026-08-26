#!/usr/bin/env bash
set -euo pipefail

PROJECT_VERSION="1.0.0"
FRP_VERSION="0.70.1"
FRP_SHA256_AMD64="333da23d1b9009d7c01638e9ba38cf4600f7d37d393f854e96ee1396adefa9a6"
FRP_SHA256_ARM64="3990f396a9a490ee7f0e5f355287750ed41520064ed999eab443b5e9a78d773d"
DEFAULT_ALLOCATOR_URL="${FRP_ALLOCATOR_URL:-http://221.139.249.110/enroll}"

if [[ ${EUID} -ne 0 ]]; then
  echo "ERROR: run as root, e.g. curl ... | sudo bash" >&2
  exit 1
fi

prompt_secret() {
  local prompt="$1" var="$2"
  if [[ -n "${!var:-}" ]]; then return 0; fi
  if [[ -r /dev/tty ]]; then
    read -r -s -p "$prompt" "$var" </dev/tty
    echo >/dev/tty
  else
    echo "ERROR: no TTY and $var is not set" >&2
    exit 1
  fi
}

prompt_value() {
  local prompt="$1" var="$2" default="${3:-}"
  if [[ -n "${!var+x}" ]]; then return 0; fi
  local value=""
  if [[ -r /dev/tty ]]; then
    read -r -p "$prompt" value </dev/tty || true
  fi
  printf -v "$var" '%s' "${value:-$default}"
}

ensure_deps() {
  local missing=()
  for c in curl openssl python3 tar sha256sum; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if ((${#missing[@]})); then
    if command -v apt-get >/dev/null 2>&1; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq
      apt-get install -y -qq curl openssl python3 ca-certificates tar coreutils iproute2
    else
      echo "ERROR: missing tools: ${missing[*]}; only Debian/Ubuntu automatic dependency installation is supported" >&2
      exit 1
    fi
  fi
}

ensure_deps

ALLOCATOR_URL="$DEFAULT_ALLOCATOR_URL"
prompt_secret "Enrollment Code: " FRP_ENROLLMENT_CODE
prompt_value "HTTPS server IP/host [Enter = SSH only]: " FRP_HTTPS_TARGET ""

if [[ "$FRP_ENROLLMENT_CODE" != *.* ]]; then
  echo "ERROR: invalid enrollment code format" >&2
  exit 1
fi
ENROLL_ID="${FRP_ENROLLMENT_CODE%%.*}"
ENROLL_SECRET="${FRP_ENROLLMENT_CODE#*.}"

if ! ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq '(^|:)22$'; then
  echo "ERROR: local SSH service is not listening on TCP/22" >&2
  exit 1
fi

WANT_HTTPS=false
if [[ -n "$FRP_HTTPS_TARGET" ]]; then
  WANT_HTTPS=true
  echo "Checking HTTPS target ${FRP_HTTPS_TARGET}:443 ..."
  if ! timeout 5 bash -c "</dev/tcp/${FRP_HTTPS_TARGET}/443" >/dev/null 2>&1; then
    echo "ERROR: cannot connect to ${FRP_HTTPS_TARGET}:443" >&2
    exit 1
  fi
fi

mkdir -p /etc/frp
if [[ -s /etc/machine-id ]]; then
  MACHINE_ID="$(tr -d '\n' </etc/machine-id)"
elif [[ -s /etc/frp/client-id ]]; then
  MACHINE_ID="$(tr -d '\n' </etc/frp/client-id)"
else
  MACHINE_ID="$(openssl rand -hex 16)"
  printf '%s\n' "$MACHINE_ID" >/etc/frp/client-id
  chmod 600 /etc/frp/client-id
fi

HOSTNAME_VALUE="$(hostname -s)"
SSH_USER="${FRP_SSH_USER:-${SUDO_USER:-root}}"
[[ "$SSH_USER" == "root" && -n "${LOGNAME:-}" && "$LOGNAME" != root ]] && SSH_USER="$LOGNAME"

REQUEST="$(python3 - "$MACHINE_ID" "$HOSTNAME_VALUE" "$SSH_USER" "$WANT_HTTPS" "$FRP_HTTPS_TARGET" <<'PY'
import json,sys
print(json.dumps({
  'machine_id': sys.argv[1],
  'hostname': sys.argv[2],
  'ssh_user': sys.argv[3],
  'want_https': sys.argv[4].lower() == 'true',
  'https_ip': sys.argv[5],
}, separators=(',', ':')))
PY
)"
TIMESTAMP="$(date +%s)"
SIGNATURE="$(ENROLL_SECRET="$ENROLL_SECRET" TS="$TIMESTAMP" BODY="$REQUEST" python3 - <<'PY'
import hashlib,hmac,os
secret=os.environ['ENROLL_SECRET'].encode()
message=(os.environ['TS']+'\n'+os.environ['BODY']).encode()
print(hmac.new(secret,message,hashlib.sha256).hexdigest())
PY
)"

echo "Requesting permanent FRP ports ..."
RESPONSE="$(curl --fail --silent --show-error \
  -X POST \
  -H 'Content-Type: application/json' \
  -H "X-Enrollment-ID: ${ENROLL_ID}" \
  -H "X-Timestamp: ${TIMESTAMP}" \
  -H "X-Signature: ${SIGNATURE}" \
  --data "$REQUEST" \
  "$ALLOCATOR_URL")"

EVAL_OUTPUT="$(ENROLL_SECRET="$ENROLL_SECRET" RESPONSE="$RESPONSE" python3 - <<'PY'
import hashlib,hmac,json,os,shlex
secret=os.environ['ENROLL_SECRET']
d=json.loads(os.environ['RESPONSE'])
received=d.pop('response_hmac',None)
canonical=json.dumps(d,sort_keys=True,separators=(',',':'),ensure_ascii=False)
expected=hmac.new(secret.encode(),canonical.encode(),hashlib.sha256).hexdigest()
if not received or not hmac.compare_digest(received,expected):
    raise SystemExit('ERROR: allocator response HMAC verification failed')
for k,v in {
    'FRP_SERVER':str(d['frp_server']),
    'FRP_SERVER_PORT':str(d['frp_server_port']),
    'SSH_REMOTE_PORT':str(d['ssh_port']),
    'HTTPS_REMOTE_PORT':'' if d.get('https_port') is None else str(d['https_port']),
    'TOKEN_CIPHERTEXT':str(d['token_ciphertext']),
}.items():
    print(f'{k}={shlex.quote(v)}')
PY
)"
eval "$EVAL_OUTPUT"

FRP_TOKEN="$(printf '%s' "$TOKEN_CIPHERTEXT" | \
  FRP_ENROLL_SECRET="$ENROLL_SECRET" openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
  -md sha256 -a -A -pass env:FRP_ENROLL_SECRET 2>/dev/null)"
if [[ -z "$FRP_TOKEN" ]]; then
  echo "ERROR: failed to decrypt FRP token" >&2
  exit 1
fi

case "$(uname -m)" in
  x86_64) FRP_ARCH=amd64; EXPECTED_SHA="$FRP_SHA256_AMD64" ;;
  aarch64|arm64) FRP_ARCH=arm64; EXPECTED_SHA="$FRP_SHA256_ARM64" ;;
  *) echo "ERROR: unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"; unset FRP_TOKEN ENROLL_SECRET FRP_ENROLLMENT_CODE TOKEN_CIPHERTEXT' EXIT
ARCHIVE="$TMPDIR/frp.tar.gz"
URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_${FRP_ARCH}.tar.gz"
echo "Downloading FRP ${FRP_VERSION} (${FRP_ARCH}) ..."
curl -fL --retry 3 -o "$ARCHIVE" "$URL"
printf '%s  %s\n' "$EXPECTED_SHA" "$ARCHIVE" | sha256sum -c -
tar xzf "$ARCHIVE" -C "$TMPDIR"
install -m 0755 "$TMPDIR/frp_${FRP_VERSION}_linux_${FRP_ARCH}/frpc" /usr/local/bin/frpc

HOST_SAFE="$(printf '%s' "$HOSTNAME_VALUE" | tr -cs 'A-Za-z0-9._-' '-')"
HOST_ID="${HOST_SAFE}-${MACHINE_ID:0:8}"

cat >/etc/frp/frpc.toml <<EOF2
serverAddr = "${FRP_SERVER}"
serverPort = ${FRP_SERVER_PORT}

auth.method = "token"
auth.token = "${FRP_TOKEN}"

transport.tls.enable = true

[[proxies]]
name = "${HOST_ID}-ssh"
type = "tcp"
localIP = "127.0.0.1"
localPort = 22
remotePort = ${SSH_REMOTE_PORT}
EOF2
if [[ -n "$HTTPS_REMOTE_PORT" ]]; then
cat >>/etc/frp/frpc.toml <<EOF2

[[proxies]]
name = "${HOST_ID}-https"
type = "tcp"
localIP = "${FRP_HTTPS_TARGET}"
localPort = 443
remotePort = ${HTTPS_REMOTE_PORT}
EOF2
fi
chmod 600 /etc/frp/frpc.toml
/usr/local/bin/frpc verify -c /etc/frp/frpc.toml

cat >/etc/systemd/system/frpc.service <<'EOF2'
[Unit]
Description=FRP Client
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/frpc -c /etc/frp/frpc.toml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF2
systemctl daemon-reload
systemctl enable frpc >/dev/null
systemctl restart frpc

OK=false
for _ in {1..12}; do
  sleep 1
  LOGS="$(journalctl -u frpc --since '-20 seconds' --no-pager 2>/dev/null || true)"
  if grep -q 'login to server success' <<<"$LOGS" && grep -q 'start proxy success' <<<"$LOGS"; then OK=true; break; fi
done
if [[ "$OK" != true ]]; then
  echo "ERROR: frpc did not register its proxy successfully" >&2
  journalctl -u frpc -n 40 --no-pager >&2 || true
  exit 1
fi

{
  echo 'SSH:'
  echo "ssh -p ${SSH_REMOTE_PORT} ${SSH_USER}@${FRP_SERVER}"
  if [[ -n "$HTTPS_REMOTE_PORT" ]]; then
    echo
    echo 'HTTPS:'
    echo "https://${FRP_SERVER}:${HTTPS_REMOTE_PORT}"
  fi
} >/etc/frp/access-info.txt
chmod 644 /etc/frp/access-info.txt

cat <<EOF2

=========================================
 FRP Installation Complete
=========================================

SSH:
ssh -p ${SSH_REMOTE_PORT} ${SSH_USER}@${FRP_SERVER}
EOF2
if [[ -n "$HTTPS_REMOTE_PORT" ]]; then
cat <<EOF2

HTTPS:
https://${FRP_SERVER}:${HTTPS_REMOTE_PORT}
EOF2
fi
cat <<'EOF2'

Connection information:
cat /etc/frp/access-info.txt

Service status:
sudo systemctl status frpc --no-pager

=========================================
EOF2
