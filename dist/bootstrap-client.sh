#!/usr/bin/env bash
set -euo pipefail

PROJECT_VERSION="1.0.0"
FRP_VERSION="0.70.1"
FRP_SHA256_AMD64="333da23d1b9009d7c01638e9ba38cf4600f7d37d393f854e96ee1396adefa9a6"
FRP_SHA256_ARM64="3990f396a9a490ee7f0e5f355287750ed41520064ed999eab443b5e9a78d773d"
DEFAULT_ALLOCATOR_URL="${FRP_ALLOCATOR_URL:-http://221.139.249.110/enroll}"

frp_client_path() {
  local p="$1"
  if [[ -n "${FRP_CLIENT_TEST_ROOT:-}" ]]; then
    printf '%s' "${FRP_CLIENT_TEST_ROOT}${p}"
  else
    printf '%s' "$p"
  fi
}

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

read_tty() {
  local prompt="$1" default="${2:-}"
  local value=""
  if [[ -r /dev/tty ]]; then
    read -r -p "$prompt" value </dev/tty || true
  else
    echo "ERROR: no TTY for interactive setup; set FRP_SERVICES_JSON" >&2
    exit 1
  fi
  printf '%s' "${value:-$default}"
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

infer_ssh_user() {
  local user="${FRP_SSH_USER:-${SUDO_USER:-root}}"
  if [[ "$user" == "root" && -n "${LOGNAME:-}" && "$LOGNAME" != root ]]; then
    user="$LOGNAME"
  fi
  printf '%s' "$user"
}

probe_tcp() {
  local host="$1" port="$2"
  timeout 3 bash -c "echo >/dev/tcp/${host}/${port}" >/dev/null 2>&1
}

services_init() {
  printf '%s\n' '[]' >"$SERVICES_FILE"
}

services_count() {
  python3 - "$SERVICES_FILE" <<'PY'
import json,sys
from pathlib import Path
print(len(json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))))
PY
}

services_add_json() {
  python3 - "$SERVICES_FILE" "$1" <<'PY'
import json, re, sys
from pathlib import Path
path = Path(sys.argv[1])
raw = json.loads(sys.argv[2])
data = json.loads(path.read_text(encoding='utf-8'))
sid = str(raw.get('id', '')).strip().lower()
if not re.fullmatch(r'[a-z0-9][a-z0-9._-]{0,31}', sid or ''):
    raise SystemExit('ERROR: invalid service id; use [a-z0-9][a-z0-9._-]{0,31}')
if any(item.get('id') == sid for item in data):
    raise SystemExit(f'ERROR: duplicate service id: {sid}')
protocol = str(raw.get('protocol', 'tcp') or 'tcp').strip().lower()
if protocol != 'tcp':
    raise SystemExit('ERROR: only tcp services are supported')
preset = str(raw.get('preset', 'custom') or 'custom').strip().lower()
if preset not in ('ssh', 'http', 'https', 'custom'):
    raise SystemExit('ERROR: invalid service preset')
name = str(raw.get('name', '') or sid).strip() or sid
if len(name) > 64 or '\n' in name or '\r' in name:
    raise SystemExit('ERROR: invalid service display name')
local_ip = str(raw.get('local_ip', '')).strip()
if not local_ip or any(c in local_ip for c in ' \t\r\n/\\;|&$`\'"<>'):
    raise SystemExit('ERROR: invalid target host')
try:
    local_port = int(str(raw.get('local_port', '')).strip())
except Exception:
    raise SystemExit('ERROR: invalid local_port; must be an integer 1-65535')
if local_port < 1 or local_port > 65535:
    raise SystemExit('ERROR: invalid local_port; must be an integer 1-65535')
item = {
    'id': sid,
    'name': name,
    'protocol': 'tcp',
    'local_ip': local_ip,
    'local_port': local_port,
    'preset': preset,
}
if preset == 'ssh':
    ssh_user = str(raw.get('ssh_user', '') or 'root').strip() or 'root'
    if not re.fullmatch(r'[A-Za-z0-9._@-]{1,32}', ssh_user):
        raise SystemExit('ERROR: invalid ssh_user')
    item['ssh_user'] = ssh_user
if len(data) >= 32:
    raise SystemExit('ERROR: too many services')
data.append(item)
path.write_text(json.dumps(data, indent=2) + '\n', encoding='utf-8')
PY
}

services_load_from_env() {
  python3 - "$SERVICES_FILE" <<'PY'
import json, os, re, sys
from pathlib import Path

def add(path, raw):
    data = json.loads(path.read_text(encoding='utf-8'))
    sid = str(raw.get('id', '')).strip().lower()
    if not re.fullmatch(r'[a-z0-9][a-z0-9._-]{0,31}', sid or ''):
        raise SystemExit('ERROR: invalid service id; use [a-z0-9][a-z0-9._-]{0,31}')
    if any(item.get('id') == sid for item in data):
        raise SystemExit(f'ERROR: duplicate service id: {sid}')
    protocol = str(raw.get('protocol', 'tcp') or 'tcp').strip().lower()
    if protocol != 'tcp':
        raise SystemExit('ERROR: only tcp services are supported')
    preset = str(raw.get('preset', 'custom') or 'custom').strip().lower()
    if preset not in ('ssh', 'http', 'https', 'custom'):
        raise SystemExit('ERROR: invalid service preset')
    name = str(raw.get('name', '') or sid).strip() or sid
    if len(name) > 64 or '\n' in name or '\r' in name:
        raise SystemExit('ERROR: invalid service display name')
    local_ip = str(raw.get('local_ip', '')).strip()
    if not local_ip or any(c in local_ip for c in ' \t\r\n/\\;|&$`\'"<>'):
        raise SystemExit('ERROR: invalid target host')
    try:
        local_port = int(str(raw.get('local_port', '')).strip())
    except Exception:
        raise SystemExit('ERROR: invalid local_port; must be an integer 1-65535')
    if local_port < 1 or local_port > 65535:
        raise SystemExit('ERROR: invalid local_port; must be an integer 1-65535')
    item = {
        'id': sid,
        'name': name,
        'protocol': 'tcp',
        'local_ip': local_ip,
        'local_port': local_port,
        'preset': preset,
    }
    if preset == 'ssh':
        ssh_user = str(raw.get('ssh_user', '') or 'root').strip() or 'root'
        if not re.fullmatch(r'[A-Za-z0-9._@-]{1,32}', ssh_user):
            raise SystemExit('ERROR: invalid ssh_user')
        item['ssh_user'] = ssh_user
    if len(data) >= 32:
        raise SystemExit('ERROR: too many services')
    data.append(item)
    path.write_text(json.dumps(data, indent=2) + '\n', encoding='utf-8')

path = Path(sys.argv[1])
try:
    raw = json.loads(os.environ.get('FRP_SERVICES_JSON', ''))
except json.JSONDecodeError:
    raise SystemExit('ERROR: FRP_SERVICES_JSON is not valid JSON')
if not isinstance(raw, list):
    raise SystemExit('ERROR: FRP_SERVICES_JSON must be a list')
if not raw:
    raise SystemExit('ERROR: at least one service must be configured')
path.write_text('[]\n', encoding='utf-8')
for item in raw:
    add(path, item)
PY
}

services_list() {
  python3 - "$SERVICES_FILE" <<'PY'
import json,sys
from pathlib import Path
data=json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
if not data:
    print('(none)')
    raise SystemExit(0)
for i, item in enumerate(data, 1):
    print(f"{i}. {item.get('id')}")
    print(f"   TCP {item.get('local_ip')}:{item.get('local_port')}")
PY
}

services_remove_index() {
  python3 - "$SERVICES_FILE" "$1" <<'PY'
import json,sys
from pathlib import Path
path=Path(sys.argv[1])
data=json.loads(path.read_text(encoding='utf-8'))
try:
    idx=int(sys.argv[2])
except Exception:
    raise SystemExit('ERROR: invalid service number')
if idx < 1 or idx > len(data):
    raise SystemExit('ERROR: service number out of range')
data.pop(idx-1)
path.write_text(json.dumps(data, indent=2)+'\n', encoding='utf-8')
PY
}

maybe_warn_connectivity() {
  local host="$1" port="$2" label="$3"
  if [[ "${FRP_SKIP_CONNECTIVITY_CHECK:-}" == "1" ]]; then
    return 0
  fi
  if probe_tcp "$host" "$port"; then
    return 0
  fi
  echo "WARNING: cannot connect to ${label} ${host}:${port} (continuing; target may be remote or not yet listening)"
}

prompt_service_id() {
  local default="$1"
  local sid
  sid="$(read_tty "Service ID [${default}]: " "$default")"
  printf '%s' "$sid"
}

prompt_target_host() {
  local default="${1:-127.0.0.1}"
  read_tty "Target host [${default}]: " "$default"
}

prompt_target_port() {
  local default="$1"
  read_tty "Target port [${default}]: " "$default"
}

service_payload() {
  python3 - "$@" <<'PY'
import json, sys
preset = sys.argv[1]
sid = sys.argv[2]
name = sys.argv[3]
host = sys.argv[4]
port = sys.argv[5]
payload = {
  'id': sid,
  'name': name,
  'protocol': 'tcp',
  'local_ip': host,
  'local_port': port,
  'preset': preset,
}
if preset == 'ssh':
    payload['ssh_user'] = sys.argv[6] if len(sys.argv) > 6 else 'root'
print(json.dumps(payload))
PY
}

add_preset_ssh() {
  local sid host port user payload
  sid="$(prompt_service_id ssh)"
  host="$(prompt_target_host 127.0.0.1)"
  port="$(prompt_target_port 22)"
  user="$(read_tty "SSH user [$(infer_ssh_user)]: " "$(infer_ssh_user)")"
  maybe_warn_connectivity "$host" "$port" "SSH"
  payload="$(service_payload ssh "$sid" SSH "$host" "$port" "$user")"
  services_add_json "$payload"
}

add_preset_http() {
  local sid host port payload
  sid="$(prompt_service_id http)"
  host="$(prompt_target_host 127.0.0.1)"
  port="$(prompt_target_port 80)"
  maybe_warn_connectivity "$host" "$port" "HTTP"
  payload="$(service_payload http "$sid" HTTP "$host" "$port")"
  services_add_json "$payload"
}

add_preset_https() {
  local sid host port payload
  sid="$(prompt_service_id https)"
  host="$(prompt_target_host 127.0.0.1)"
  port="$(prompt_target_port 443)"
  maybe_warn_connectivity "$host" "$port" "HTTPS"
  payload="$(service_payload https "$sid" HTTPS "$host" "$port")"
  services_add_json "$payload"
}

add_preset_custom() {
  local sid name host port payload
  sid="$(read_tty "Service ID: " "")"
  name="$(read_tty "Display name [${sid}]: " "$sid")"
  host="$(prompt_target_host 127.0.0.1)"
  port="$(read_tty "Target port: " "")"
  maybe_warn_connectivity "$host" "$port" "TCP"
  payload="$(service_payload custom "$sid" "$name" "$host" "$port")"
  services_add_json "$payload"
}

menu_add_service() {
  local choice
  while true; do
    echo
    echo "Add service"
    echo
    echo "1) SSH"
    echo "2) HTTP"
    echo "3) HTTPS"
    echo "4) Custom TCP"
    echo "5) Back"
    echo
    choice="$(read_tty "Select: " "")"
    case "$choice" in
      1) add_preset_ssh; return 0 ;;
      2) add_preset_http; return 0 ;;
      3) add_preset_https; return 0 ;;
      4) add_preset_custom; return 0 ;;
      5) return 0 ;;
      *) echo "ERROR: select 1-5" >&2 ;;
    esac
  done
}

menu_remove_service() {
  local choice
  if [[ "$(services_count)" == "0" ]]; then
    echo "ERROR: no services to remove" >&2
    return 0
  fi
  echo
  echo "Configured services:"
  echo
  services_list
  echo
  choice="$(read_tty "Remove service number: " "")"
  services_remove_index "$choice"
}

collect_services_interactive() {
  local choice
  while true; do
    echo
    echo "Configured services:"
    echo
    services_list
    echo
    echo "1) Add service"
    echo "2) Remove service"
    echo "3) Install"
    echo "4) Cancel"
    echo
    choice="$(read_tty "Select: " "")"
    case "$choice" in
      1) menu_add_service ;;
      2) menu_remove_service ;;
      3)
        if [[ "$(services_count)" == "0" ]]; then
          echo "ERROR: at least one service must be configured" >&2
          continue
        fi
        return 0
        ;;
      4)
        echo "Cancelled."
        exit 1
        ;;
      *) echo "ERROR: select 1-4" >&2 ;;
    esac
  done
}

collect_services() {
  services_init
  if [[ -n "${FRP_SERVICES_JSON:-}" ]]; then
    services_load_from_env
    if [[ "$(services_count)" == "0" ]]; then
      echo "ERROR: at least one service must be configured" >&2
      exit 1
    fi
    return 0
  fi
  collect_services_interactive
}

merge_allocated_services() {
  python3 - "$SERVICES_FILE" "$ALLOCATED_FILE" <<'PY'
import json,sys
from pathlib import Path
local_path, alloc_path = Path(sys.argv[1]), Path(sys.argv[2])
local = json.loads(local_path.read_text(encoding='utf-8'))
allocated = json.loads(alloc_path.read_text(encoding='utf-8'))
if not isinstance(allocated, list):
    raise SystemExit('ERROR: allocator response services are invalid')
by_id = {}
for item in allocated:
    sid = str(item.get('id', '')).strip()
    if not sid:
        raise SystemExit('ERROR: allocator response is missing a service id')
    if 'remote_port' not in item:
        raise SystemExit(f'ERROR: allocator response is missing remote_port for {sid}')
    by_id[sid] = int(item['remote_port'])
if len(by_id) != len(local):
    raise SystemExit('ERROR: allocator did not return every requested service')
for item in local:
    sid = item['id']
    if sid not in by_id:
        raise SystemExit(f'ERROR: allocator did not allocate a port for {sid}')
    item['remote_port'] = by_id[sid]
local_path.write_text(json.dumps(local, indent=2)+'\n', encoding='utf-8')
PY
}

render_frpc_toml() {
  local dest="$1" server="$2" server_port="$3" token="$4" host_id="$5" services_json_file="$6"
  python3 - "$dest" "$server" "$server_port" "$token" "$host_id" "$services_json_file" <<'PY'
import sys
from pathlib import Path
dest, server, server_port, token, host_id, svc_path = sys.argv[1:7]
import json
services = json.loads(Path(svc_path).read_text(encoding='utf-8'))
lines = [
    f'serverAddr = "{server}"',
    f'serverPort = {server_port}',
    '',
    'auth.method = "token"',
    f'auth.token = "{token}"',
    '',
    'transport.tls.enable = true',
]
for item in services:
    lines.extend([
        '',
        '[[proxies]]',
        f'name = "{host_id}-{item["id"]}"',
        'type = "tcp"',
        f'localIP = "{item["local_ip"]}"',
        f'localPort = {int(item["local_port"])}',
        f'remotePort = {int(item["remote_port"])}',
    ])
text = '\n'.join(lines) + '\n'
path = Path(dest)
tmp = path.with_name(path.name + '.tmp')
tmp.write_text(text, encoding='utf-8')
tmp.chmod(0o600)
tmp.replace(path)
PY
}

render_access_info() {
  local dest="$1" server="$2" services_json_file="$3"
  python3 - "$dest" "$server" "$services_json_file" <<'PY'
import json,sys
from pathlib import Path
dest, server, svc_path = sys.argv[1:4]
services = json.loads(Path(svc_path).read_text(encoding='utf-8'))
lines = [f'FRP Server: {server}', '', 'Services:', '']
for item in services:
    sid = item['id']
    name = item.get('name') or sid
    preset = item.get('preset') or 'custom'
    local_ip = item.get('local_ip')
    local_port = item.get('local_port')
    remote_port = item.get('remote_port')
    lines.append(sid if name == sid else f'{sid} ({name})')
    lines.append(f'  Target : {local_ip}:{local_port}')
    lines.append(f'  Public : {server}:{remote_port}')
    if preset == 'ssh':
        user = item.get('ssh_user') or 'root'
        lines.append('  Connect:')
        lines.append(f'    ssh -p {remote_port} {user}@{server}')
    elif preset == 'http':
        lines.append('  URL:')
        lines.append(f'    http://{server}:{remote_port}')
    elif preset == 'https':
        lines.append('  URL:')
        lines.append(f'    https://{server}:{remote_port}')
    else:
        lines.append('  Connect:')
        lines.append(f'    {server}:{remote_port}')
    lines.append('')
path = Path(dest)
tmp = path.with_name(path.name + '.tmp')
tmp.write_text('\n'.join(lines).rstrip()+'\n', encoding='utf-8')
tmp.chmod(0o644)
tmp.replace(path)
PY
}

print_complete() {
  local server="$1" services_json_file="$2"
  python3 - "$server" "$services_json_file" <<'PY'
import json,sys
from pathlib import Path
server = sys.argv[1]
services = json.loads(Path(sys.argv[2]).read_text(encoding='utf-8'))
print()
print('=========================================')
print(' FRP Installation Complete')
print('=========================================')
print()
print('Published services:')
print()
for item in services:
    name = item.get('name') or item['id']
    preset = item.get('preset') or 'custom'
    remote_port = item.get('remote_port')
    print(name)
    if preset == 'ssh':
        user = item.get('ssh_user') or 'root'
        print(f'  ssh -p {remote_port} {user}@{server}')
    elif preset == 'http':
        print(f'  http://{server}:{remote_port}')
    elif preset == 'https':
        print(f'  https://{server}:{remote_port}')
    else:
        print(f'  {server}:{remote_port}')
    print()
print('Connection information:')
print('cat /etc/frp/access-info.txt')
print()
print('Service status:')
print('sudo systemctl status frpc --no-pager')
print()
print('=========================================')
PY
}

proxy_names_from_services() {
  local host_id="$1"
  python3 - "$host_id" "$SERVICES_FILE" <<'PY'
import json,sys
from pathlib import Path
host_id=sys.argv[1]
services=json.loads(Path(sys.argv[2]).read_text(encoding='utf-8'))
for item in services:
    print(f'{host_id}-{item["id"]}')
PY
}

wait_for_proxies() {
  local logs proxy missing
  local -a names=("$@")
  local i
  for i in {1..20}; do
    sleep 1
    logs="$(journalctl -u frpc -n 400 --no-pager 2>/dev/null || true)"
    if ! grep -q 'login to server success' <<<"$logs"; then
      continue
    fi
    missing=""
    for proxy in "${names[@]}"; do
      if ! grep -F "[${proxy}] start proxy success" <<<"$logs"; then
        missing="$proxy"
        break
      fi
    done
    if [[ -z "$missing" ]]; then
      return 0
    fi
  done
  return 1
}

frp_client_main() {
  if [[ ${EUID} -ne 0 && -z "${FRP_CLIENT_TEST_ROOT:-}" ]]; then
    echo "ERROR: run as root, e.g. curl ... | sudo bash" >&2
    exit 1
  fi

  if [[ -z "${FRP_CLIENT_TEST_ROOT:-}" ]]; then
    ensure_deps
  fi

  cat <<'EOF'

=========================================
 FRP Client Setup
=========================================

EOF

  ALLOCATOR_URL="$DEFAULT_ALLOCATOR_URL"
  prompt_secret "Enrollment Code: " FRP_ENROLLMENT_CODE

  if [[ "$FRP_ENROLLMENT_CODE" != *.* ]]; then
    echo "ERROR: invalid enrollment code format" >&2
    exit 1
  fi
  ENROLL_ID="${FRP_ENROLLMENT_CODE%%.*}"
  ENROLL_SECRET="${FRP_ENROLLMENT_CODE#*.}"

  SERVICES_FILE="$(mktemp)"
  ALLOCATED_FILE="$(mktemp)"
  TMPDIR="$(mktemp -d)"
  trap 'rm -rf "$TMPDIR" "$SERVICES_FILE" "$ALLOCATED_FILE"; unset FRP_TOKEN ENROLL_SECRET FRP_ENROLLMENT_CODE TOKEN_CIPHERTEXT' EXIT

  collect_services

  local etc_frp
  etc_frp="$(frp_client_path /etc/frp)"
  mkdir -p "$etc_frp"
  if [[ -s /etc/machine-id ]]; then
    MACHINE_ID="$(tr -d '\n' </etc/machine-id)"
  elif [[ -s "${etc_frp}/client-id" ]]; then
    MACHINE_ID="$(tr -d '\n' <"${etc_frp}/client-id")"
  else
    MACHINE_ID="$(openssl rand -hex 16)"
    printf '%s\n' "$MACHINE_ID" >"${etc_frp}/client-id"
    chmod 600 "${etc_frp}/client-id"
  fi

  HOSTNAME_VALUE="$(hostname -s)"
  REQUEST="$(python3 - "$MACHINE_ID" "$HOSTNAME_VALUE" "$SERVICES_FILE" <<'PY'
import json,sys
from pathlib import Path
services=json.loads(Path(sys.argv[3]).read_text(encoding='utf-8'))
print(json.dumps({
  'machine_id': sys.argv[1],
  'hostname': sys.argv[2],
  'services': services,
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

  echo "Requesting persistent FRP ports ..."
  RESPONSE="$(curl --fail --silent --show-error \
    -X POST \
    -H 'Content-Type: application/json' \
    -H "X-Enrollment-ID: ${ENROLL_ID}" \
    -H "X-Timestamp: ${TIMESTAMP}" \
    -H "X-Signature: ${SIGNATURE}" \
    --data "$REQUEST" \
    "$ALLOCATOR_URL")"

  EVAL_OUTPUT="$(ENROLL_SECRET="$ENROLL_SECRET" RESPONSE="$RESPONSE" ALLOCATED_FILE="$ALLOCATED_FILE" python3 - <<'PY'
import hashlib,hmac,json,os,shlex
secret=os.environ['ENROLL_SECRET']
d=json.loads(os.environ['RESPONSE'])
received=d.pop('response_hmac',None)
canonical=json.dumps(d,sort_keys=True,separators=(',',':'),ensure_ascii=False)
expected=hmac.new(secret.encode(),canonical.encode(),hashlib.sha256).hexdigest()
if not received or not hmac.compare_digest(received,expected):
    raise SystemExit('ERROR: allocator response HMAC verification failed')
if 'ssh_port' in d or 'https_port' in d:
    raise SystemExit('ERROR: allocator returned a legacy SSH/HTTPS response')
services=d.get('services')
if not isinstance(services, list) or not services:
    raise SystemExit('ERROR: allocator response is missing services')
open(os.environ['ALLOCATED_FILE'],'w',encoding='utf-8').write(json.dumps(services)+'\n')
token=str(d['token_ciphertext'])
if not token:
    raise SystemExit('ERROR: allocator response is missing token_ciphertext')
for k,v in {
    'FRP_SERVER':str(d['frp_server']),
    'FRP_SERVER_PORT':str(d['frp_server_port']),
    'TOKEN_CIPHERTEXT':token,
}.items():
    print(f'{k}={shlex.quote(v)}')
PY
)"
  eval "$EVAL_OUTPUT"
  merge_allocated_services

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

  if [[ "${FRP_SKIP_DOWNLOAD:-}" != "1" ]]; then
    ARCHIVE="$TMPDIR/frp.tar.gz"
    URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_${FRP_ARCH}.tar.gz"
    echo "Downloading FRP ${FRP_VERSION} (${FRP_ARCH}) ..."
    curl -fL --retry 3 -o "$ARCHIVE" "$URL"
    printf '%s  %s\n' "$EXPECTED_SHA" "$ARCHIVE" | sha256sum -c -
    tar xzf "$ARCHIVE" -C "$TMPDIR"
    install -m 0755 "$TMPDIR/frp_${FRP_VERSION}_linux_${FRP_ARCH}/frpc" /usr/local/bin/frpc
  fi

  HOST_SAFE="$(printf '%s' "$HOSTNAME_VALUE" | tr -cs 'A-Za-z0-9._-' '-')"
  HOST_ID="${HOST_SAFE}-${MACHINE_ID:0:8}"
  FRPC_TOML="$(frp_client_path /etc/frp/frpc.toml)"
  ACCESS_INFO="$(frp_client_path /etc/frp/access-info.txt)"
  mkdir -p "$(dirname "$FRPC_TOML")"
  render_frpc_toml "$FRPC_TOML" "$FRP_SERVER" "$FRP_SERVER_PORT" "$FRP_TOKEN" "$HOST_ID" "$SERVICES_FILE"

  local frpc_bin
  frpc_bin="$(frp_client_path /usr/local/bin/frpc)"
  if [[ "${FRP_SKIP_DOWNLOAD:-}" == "1" && -x /usr/local/bin/frpc && ! -x "$frpc_bin" ]]; then
    frpc_bin=/usr/local/bin/frpc
  fi
  if [[ -x "$frpc_bin" ]]; then
    "$frpc_bin" verify -c "$FRPC_TOML"
  elif command -v frpc >/dev/null 2>&1; then
    frpc verify -c "$FRPC_TOML"
  else
    echo "ERROR: frpc is not available to verify the generated config" >&2
    exit 1
  fi

  if [[ "${FRP_SKIP_SYSTEMD:-}" != "1" && -z "${FRP_CLIENT_TEST_ROOT:-}" ]]; then
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

    mapfile -t PROXY_NAMES < <(proxy_names_from_services "$HOST_ID")
    if ! wait_for_proxies "${PROXY_NAMES[@]}"; then
      echo "ERROR: frpc did not register every requested proxy successfully" >&2
      journalctl -u frpc -n 80 --no-pager >&2 || true
      exit 1
    fi
  fi

  render_access_info "$ACCESS_INFO" "$FRP_SERVER" "$SERVICES_FILE"
  print_complete "$FRP_SERVER" "$SERVICES_FILE"
}

if [[ "${FRP_CLIENT_SOURCED:-}" != "1" ]]; then
  frp_client_main "$@"
fi
