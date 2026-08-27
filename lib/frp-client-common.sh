#!/usr/bin/env bash
# Shared client-side helpers for install-client.sh and tools/frp-client.
# Source this file; do not execute it.

if [[ -n "${FRP_CLIENT_COMMON_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
FRP_CLIENT_COMMON_LOADED=1

FRP_CLIENT_STATE_SCHEMA=1
FRP_CLIENT_BACKUP_KEEP="${FRP_CLIENT_BACKUP_KEEP:-5}"

frp_client_path() {
  local p="$1"
  if [[ -n "${FRP_CLIENT_TEST_ROOT:-}" ]]; then
    printf '%s' "${FRP_CLIENT_TEST_ROOT}${p}"
  else
    printf '%s' "$p"
  fi
}

frp_client_state_path() {
  frp_client_path /etc/frp/client-state.json
}

frp_client_toml_path() {
  frp_client_path /etc/frp/frpc.toml
}

frp_client_access_path() {
  frp_client_path /etc/frp/access-info.txt
}

frp_client_backup_dir() {
  frp_client_path /etc/frp/backups
}

frp_client_lock_dir() {
  frp_client_path /etc/frp/client-manage.lock
}

frp_client_lib_dir() {
  frp_client_path /usr/local/lib/frp-auto-deploy
}

frp_client_hook_log() {
  if [[ -n "${FRP_CLIENT_HOOK_LOG:-}" ]]; then
    printf '%s\n' "$1" >>"$FRP_CLIENT_HOOK_LOG"
  fi
}

frp_atomic_write_text() {
  local dest="$1" mode="$2"
  python3 - "$dest" "$mode" <<'PY'
import os, sys, tempfile
from pathlib import Path
dest = Path(sys.argv[1])
mode = int(sys.argv[2], 8)
text = sys.stdin.read()
dest.parent.mkdir(parents=True, exist_ok=True)
fd, tmp = tempfile.mkstemp(prefix=dest.name + '.', suffix='.tmp', dir=str(dest.parent))
try:
    with os.fdopen(fd, 'w', encoding='utf-8') as fh:
        fh.write(text)
        fh.flush()
        os.fsync(fh.fileno())
    os.chmod(tmp, mode)
    os.replace(tmp, dest)
except Exception:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
PY
}

frp_atomic_write_json_file() {
  local dest="$1" src="$2" mode="${3:-0600}"
  python3 - "$dest" "$src" "$mode" <<'PY'
import json, os, sys, tempfile
from pathlib import Path
dest = Path(sys.argv[1])
src = Path(sys.argv[2])
mode = int(sys.argv[3], 8)
data = json.loads(src.read_text(encoding='utf-8'))
dest.parent.mkdir(parents=True, exist_ok=True)
fd, tmp = tempfile.mkstemp(prefix=dest.name + '.', suffix='.tmp', dir=str(dest.parent))
try:
    with os.fdopen(fd, 'w', encoding='utf-8') as fh:
        json.dump(data, fh, indent=2, sort_keys=True)
        fh.write('\n')
        fh.flush()
        os.fsync(fh.fileno())
    os.chmod(tmp, mode)
    os.replace(tmp, dest)
except Exception:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
PY
}

frp_state_has_secrets() {
  python3 - "$1" <<'PY'
import json, sys
from pathlib import Path
forbidden = {
    'token', 'auth.token', 'token_ciphertext', 'frp_token', 'server_token',
    'enrollment_code', 'enrollment_secret', 'enroll_secret', 'secret',
    'password', 'private_key',
}
def walk(obj, path=''):
    if isinstance(obj, dict):
        for k, v in obj.items():
            key = str(k).lower()
            loc = f'{path}.{k}' if path else str(k)
            if key in forbidden or 'token' in key or 'secret' in key or 'password' in key:
                raise SystemExit(f'secret field: {loc}')
            walk(v, loc)
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            walk(v, f'{path}[{i}]')
raw = Path(sys.argv[1]).read_text(encoding='utf-8')
lower = raw.lower()
if 'begin ' in lower and 'private key' in lower:
    raise SystemExit('private key material')
walk(json.loads(raw))
PY
}

frp_services_to_list() {
  python3 - "$1" <<'PY'
import json, sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
if isinstance(data, list):
    json.dump(data, sys.stdout)
    sys.stdout.write('\n')
    raise SystemExit(0)
if not isinstance(data, dict):
    raise SystemExit('ERROR: invalid services document')
services = data.get('services', data)
if isinstance(services, list):
    json.dump(services, sys.stdout)
    sys.stdout.write('\n')
    raise SystemExit(0)
out = []
for sid, item in services.items():
    rec = dict(item)
    rec['id'] = rec.get('id') or sid
    out.append(rec)
json.dump(out, sys.stdout)
sys.stdout.write('\n')
PY
}

frp_enabled_services_list() {
  python3 - "$1" <<'PY'
import json, sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
if isinstance(data, dict) and 'services' in data:
    services = data['services']
    if isinstance(services, dict):
        items = []
        for sid, item in services.items():
            rec = dict(item)
            rec['id'] = rec.get('id') or sid
            items.append(rec)
        services = items
else:
    services = data
out = []
for item in services:
    if item.get('enabled', True) is False:
        continue
    out.append(item)
json.dump(out, sys.stdout)
sys.stdout.write('\n')
PY
}

frp_count_enabled_services() {
  python3 - "$1" <<'PY'
import json, sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
services = data.get('services', {}) if isinstance(data, dict) else data
n = 0
if isinstance(services, dict):
    for item in services.values():
        if item.get('enabled', True) is not False:
            n += 1
elif isinstance(services, list):
    for item in services:
        if item.get('enabled', True) is not False:
            n += 1
print(n)
PY
}

frp_load_client_state() {
  local path="$1"
  python3 - "$path" "$FRP_CLIENT_STATE_SCHEMA" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
want = int(sys.argv[2])
if not path.is_file():
    raise SystemExit(
        'ERROR: This client predates local management state.\n'
        'Re-enroll once with the current bootstrap installer to initialize frp-client management.'
    )
try:
    data = json.loads(path.read_text(encoding='utf-8'))
except Exception:
    raise SystemExit('ERROR: client-state.json is not valid JSON')
if not isinstance(data, dict) or data.get('schema_version') != want:
    raise SystemExit(
        f'ERROR: unsupported client-state schema version {data.get("schema_version")!r}.\n'
        'Re-enroll once with the current bootstrap installer to initialize frp-client management.'
    )
if not isinstance(data.get('services'), dict):
    raise SystemExit('ERROR: client-state.json services must be a map')
PY
}

frp_write_client_state() {
  python3 - "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$FRP_CLIENT_STATE_SCHEMA" "$8" <<'PY'
import json, os, sys, tempfile
from pathlib import Path
dest, allocator_url, server, server_port, hostname, machine_id, host_id = sys.argv[1:8]
schema = int(sys.argv[8])
services_raw = json.loads(Path(sys.argv[9]).read_text(encoding='utf-8'))
services = {}
if isinstance(services_raw, list):
    items = services_raw
elif isinstance(services_raw, dict):
    items = []
    for sid, item in services_raw.items():
        rec = dict(item)
        rec['id'] = rec.get('id') or sid
        items.append(rec)
else:
    raise SystemExit('ERROR: invalid services for client-state')
for item in items:
    rec = {
        'id': item['id'],
        'name': item.get('name') or item['id'],
        'preset': item.get('preset') or 'custom',
        'protocol': 'tcp',
        'local_ip': item['local_ip'],
        'local_port': int(item['local_port']),
        'enabled': item.get('enabled', True) is not False,
    }
    if 'remote_port' in item and item['remote_port'] is not None:
        rec['remote_port'] = int(item['remote_port'])
    if rec['preset'] == 'ssh':
        rec['ssh_user'] = item.get('ssh_user') or 'root'
    services[rec['id']] = rec
state = {
    'schema_version': schema,
    'allocator_url': allocator_url,
    'frp_server': server,
    'frp_server_port': int(server_port),
    'hostname': hostname,
    'machine_id': machine_id,
    'host_id': host_id,
    'services': services,
}
dest = Path(dest)
dest.parent.mkdir(parents=True, exist_ok=True)
fd, tmp = tempfile.mkstemp(prefix=dest.name + '.', suffix='.tmp', dir=str(dest.parent))
try:
    with os.fdopen(fd, 'w', encoding='utf-8') as fh:
        json.dump(state, fh, indent=2, sort_keys=True)
        fh.write('\n')
        fh.flush()
        os.fsync(fh.fileno())
    os.chmod(tmp, 0o600)
    os.replace(tmp, dest)
except Exception:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
PY
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
import json, sys
from pathlib import Path
dest, server, server_port, token, host_id, svc_path = sys.argv[1:7]
raw = json.loads(Path(svc_path).read_text(encoding='utf-8'))
if isinstance(raw, dict) and 'services' in raw:
    services = []
    for sid, item in raw['services'].items():
        rec = dict(item)
        rec['id'] = rec.get('id') or sid
        services.append(rec)
else:
    services = raw
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
    if item.get('enabled', True) is False:
        continue
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
path.parent.mkdir(parents=True, exist_ok=True)
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
raw = json.loads(Path(svc_path).read_text(encoding='utf-8'))
if isinstance(raw, dict) and 'services' in raw:
    services = []
    for sid, item in raw['services'].items():
        rec = dict(item)
        rec['id'] = rec.get('id') or sid
        services.append(rec)
else:
    services = raw
lines = [f'FRP Server: {server}', '', 'Services:', '']
for item in services:
    if item.get('enabled', True) is False:
        continue
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
path.parent.mkdir(parents=True, exist_ok=True)
tmp = path.with_name(path.name + '.tmp')
tmp.write_text('\n'.join(lines).rstrip()+'\n', encoding='utf-8')
tmp.chmod(0o644)
tmp.replace(path)
PY
}

proxy_names_from_services() {
  local host_id="$1"
  python3 - "$host_id" "$SERVICES_FILE" <<'PY'
import json,sys
from pathlib import Path
host_id=sys.argv[1]
raw=json.loads(Path(sys.argv[2]).read_text(encoding='utf-8'))
if isinstance(raw, dict) and 'services' in raw:
    services=[]
    for sid, item in raw['services'].items():
        rec=dict(item)
        rec['id']=rec.get('id') or sid
        services.append(rec)
else:
    services=raw
for item in services:
    if item.get('enabled', True) is False:
        continue
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

frp_enroll_services() {
  local allocator_url="$1" enroll_id="$2" enroll_secret="$3"
  local machine_id="$4" hostname_value="$5" services_file="$6"
  local allocated_file="$7" meta_file="$8"
  local request timestamp signature response curl_err
  frp_client_hook_log enroll
  if [[ "${FRP_CLIENT_HOOK_ENROLL_FAIL:-}" == "1" ]]; then
    echo "ERROR: allocator unavailable" >&2
    return 1
  fi
  if [[ -n "${FRP_CLIENT_ENROLL_COUNT_FILE:-}" ]]; then
    python3 - "$FRP_CLIENT_ENROLL_COUNT_FILE" <<'PY'
from pathlib import Path
p = Path(__import__('sys').argv[1])
n = int(p.read_text().strip() or '0') if p.is_file() else 0
p.write_text(str(n + 1) + '\n')
PY
    if [[ "${FRP_CLIENT_HOOK_COMPENSATE_FAIL:-}" == "1" ]]; then
      local enroll_n
      enroll_n="$(tr -d '\n' <"$FRP_CLIENT_ENROLL_COUNT_FILE")"
      if (( enroll_n >= 2 )); then
        echo "ERROR: compensating enrollment failed" >&2
        return 1
      fi
    fi
  fi
  request="$(python3 - "$machine_id" "$hostname_value" "$services_file" <<'PY'
import json,sys
from pathlib import Path
raw=json.loads(Path(sys.argv[3]).read_text(encoding='utf-8'))
if isinstance(raw, dict) and 'services' in raw:
    services=[]
    for sid, item in raw['services'].items():
        rec=dict(item)
        rec['id']=rec.get('id') or sid
        services.append(rec)
else:
    services=raw
enabled=[]
for item in services:
    if item.get('enabled', True) is False:
        continue
    out={
        'id': item['id'],
        'name': item.get('name') or item['id'],
        'protocol': 'tcp',
        'local_ip': item['local_ip'],
        'local_port': item['local_port'],
        'preset': item.get('preset') or 'custom',
    }
    if out['preset']=='ssh':
        out['ssh_user']=item.get('ssh_user') or 'root'
    enabled.append(out)
print(json.dumps({
  'machine_id': sys.argv[1],
  'hostname': sys.argv[2],
  'services': enabled,
}, separators=(',', ':')))
PY
)"
  timestamp="$(date +%s)"
  signature="$(ENROLL_SECRET="$enroll_secret" TS="$timestamp" BODY="$request" python3 - <<'PY'
import hashlib,hmac,os
secret=os.environ['ENROLL_SECRET'].encode()
message=(os.environ['TS']+'\n'+os.environ['BODY']).encode()
print(hmac.new(secret,message,hashlib.sha256).hexdigest())
PY
)"
  curl_err="$(mktemp)"
  if ! response="$(curl --fail --silent --show-error \
    -X POST \
    -H 'Content-Type: application/json' \
    -H "X-Enrollment-ID: ${enroll_id}" \
    -H "X-Timestamp: ${timestamp}" \
    -H "X-Signature: ${signature}" \
    --data "$request" \
    "$allocator_url" 2>"$curl_err")"; then
    echo "ERROR: allocator request failed" >&2
    cat "$curl_err" >&2 || true
    rm -f "$curl_err"
    return 1
  fi
  rm -f "$curl_err"
  ENROLL_SECRET="$enroll_secret" RESPONSE="$response" ALLOCATED_FILE="$allocated_file" META_FILE="$meta_file" python3 - <<'PY'
import hashlib,hmac,json,os
from pathlib import Path
secret=os.environ['ENROLL_SECRET']
d=json.loads(os.environ['RESPONSE'])
if isinstance(d, dict) and d.get('error'):
    raise SystemExit(f"ERROR: allocator rejected enrollment: {d.get('error')}")
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
Path(os.environ['ALLOCATED_FILE']).write_text(json.dumps(services)+'\n', encoding='utf-8')
token=str(d.get('token_ciphertext') or '')
if not token:
    raise SystemExit('ERROR: allocator response is missing token_ciphertext')
meta={
    'frp_server': str(d['frp_server']),
    'frp_server_port': str(d['frp_server_port']),
    'token_ciphertext': token,
}
Path(os.environ['META_FILE']).write_text(json.dumps(meta)+'\n', encoding='utf-8')
PY
}

frp_decrypt_token() {
  local ciphertext="$1" secret="$2"
  local token
  token="$(printf '%s' "$ciphertext" | \
    FRP_ENROLL_SECRET="$secret" openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
    -md sha256 -a -A -pass env:FRP_ENROLL_SECRET 2>/dev/null || true)"
  if [[ -z "$token" ]]; then
    echo "ERROR: failed to decrypt FRP token" >&2
    return 1
  fi
  printf '%s' "$token"
}

frp_state_diff() {
  python3 - "$1" "$2" <<'PY'
import json, sys
from pathlib import Path

def svcs(path):
    data = json.loads(Path(path).read_text(encoding='utf-8'))
    services = data.get('services', {})
    if isinstance(services, list):
        return {item['id']: item for item in services}
    return {sid: dict(item, id=item.get('id') or sid) for sid, item in services.items()}

cur = svcs(sys.argv[1])
new = svcs(sys.argv[2])
lines = []
for sid in sorted(set(cur) | set(new)):
    a, b = cur.get(sid), new.get(sid)
    if a is None:
        lines.append(f'+ {sid}')
        lines.append(f"  {b.get('local_ip')}:{b.get('local_port')}")
        continue
    if b is None:
        lines.append(f'- {sid}')
        lines.append('  removed from local configuration')
        continue
    changes = []
    if (a.get('enabled', True) is not False) and (b.get('enabled', True) is False):
        changes.append('disabled')
    elif (a.get('enabled', True) is False) and (b.get('enabled', True) is not False):
        changes.append('re-enabled')
    if a.get('local_ip') != b.get('local_ip') or int(a.get('local_port', 0) or 0) != int(b.get('local_port', 0) or 0):
        changes.append(f"{a.get('local_ip')}:{a.get('local_port')} -> {b.get('local_ip')}:{b.get('local_port')}")
    if a.get('name') != b.get('name'):
        changes.append(f"name {a.get('name')} -> {b.get('name')}")
    if a.get('ssh_user') != b.get('ssh_user') and (a.get('preset') == 'ssh' or b.get('preset') == 'ssh'):
        changes.append(f"ssh_user {a.get('ssh_user')} -> {b.get('ssh_user')}")
    if changes:
        mark = '~'
        lines.append(f'{mark} {sid}')
        for c in changes:
            lines.append(f'  {c}')
if not lines:
    raise SystemExit(0)
print('Pending changes:')
print()
print('\n'.join(lines))
PY
}

frp_state_has_diff() {
  python3 - "$1" "$2" <<'PY'
import json, sys
from pathlib import Path

def norm(path):
    data = json.loads(Path(path).read_text(encoding='utf-8'))
    services = data.get('services', {})
    out = {}
    items = services.items() if isinstance(services, dict) else [(i['id'], i) for i in services]
    for sid, item in items:
        rec = {
            'id': item.get('id') or sid,
            'name': item.get('name'),
            'preset': item.get('preset'),
            'local_ip': item.get('local_ip'),
            'local_port': int(item.get('local_port') or 0),
            'enabled': item.get('enabled', True) is not False,
            'ssh_user': item.get('ssh_user'),
        }
        out[sid] = rec
    return out
a, b = norm(sys.argv[1]), norm(sys.argv[2])
raise SystemExit(0 if a == b else 1)
PY
}

frp_merge_ports_into_state() {
  python3 - "$1" "$2" <<'PY'
import json, sys
from pathlib import Path
state_path, alloc_path = Path(sys.argv[1]), Path(sys.argv[2])
state = json.loads(state_path.read_text(encoding='utf-8'))
allocated = json.loads(alloc_path.read_text(encoding='utf-8'))
by_id = {str(item['id']): int(item['remote_port']) for item in allocated}
services = state['services']
enabled_ids = [sid for sid, rec in services.items() if rec.get('enabled', True) is not False]
if set(by_id) != set(enabled_ids):
    raise SystemExit('ERROR: allocator did not return every requested enabled service')
for sid, rec in services.items():
    if rec.get('enabled', True) is False:
        continue
    rec['remote_port'] = by_id[sid]
state_path.write_text(json.dumps(state, indent=2, sort_keys=True) + '\n', encoding='utf-8')
PY
}

frp_backup_client_files() {
  local stamp dest src
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  dest="$(frp_client_backup_dir)/${stamp}"
  mkdir -p "$dest"
  chmod 700 "$(frp_client_backup_dir)" 2>/dev/null || true
  chmod 700 "$dest"
  for src in "$(frp_client_state_path)" "$(frp_client_toml_path)" "$(frp_client_access_path)"; do
    if [[ -f "$src" ]]; then
      install -m 0600 "$src" "$dest/$(basename "$src")"
    fi
  done
  printf '%s' "$dest"
  python3 - "$(frp_client_backup_dir)" "$FRP_CLIENT_BACKUP_KEEP" <<'PY'
import shutil, sys
from pathlib import Path
root = Path(sys.argv[1])
keep = int(sys.argv[2])
if not root.is_dir():
    raise SystemExit(0)
dirs = sorted([p for p in root.iterdir() if p.is_dir()], key=lambda p: p.name)
for extra in dirs[: max(0, len(dirs) - keep)]:
    shutil.rmtree(extra, ignore_errors=True)
PY
}

frp_restore_client_files() {
  local backup="$1"
  [[ -d "$backup" ]] || return 1
  local f dest
  for f in client-state.json frpc.toml access-info.txt; do
    if [[ -f "$backup/$f" ]]; then
      case "$f" in
        client-state.json) dest="$(frp_client_state_path)" ;;
        frpc.toml) dest="$(frp_client_toml_path)" ;;
        access-info.txt) dest="$(frp_client_access_path)" ;;
      esac
      install -m 0600 "$backup/$f" "$dest"
      if [[ "$f" == access-info.txt ]]; then
        chmod 644 "$dest"
      fi
    fi
  done
}

frp_acquire_client_lock() {
  local dir
  dir="$(frp_client_lock_dir)"
  mkdir -p "$(dirname "$dir")"
  if ! mkdir "$dir" 2>/dev/null; then
    echo "ERROR: another frp-client management operation is already running." >&2
    return 1
  fi
  printf '%s\n' "$$" >"$dir/pid"
  chmod 700 "$dir" 2>/dev/null || true
}

frp_release_client_lock() {
  local dir
  dir="$(frp_client_lock_dir)"
  rm -rf "$dir"
}

frp_client_verify_config() {
  local cfg="$1"
  frp_client_hook_log verify
  if [[ "${FRP_CLIENT_HOOK_VERIFY_FAIL:-}" == "1" ]]; then
    echo "ERROR: simulated frpc verify failure" >&2
    return 1
  fi
  local frpc_bin
  frpc_bin="$(frp_client_path /usr/local/bin/frpc)"
  if [[ -x "$frpc_bin" ]]; then
    "$frpc_bin" verify -c "$cfg"
  elif command -v frpc >/dev/null 2>&1; then
    frpc verify -c "$cfg"
  else
    echo "ERROR: frpc is not available to verify the generated config" >&2
    return 1
  fi
}

frp_client_restart() {
  frp_client_hook_log restart
  if [[ "${FRP_CLIENT_HOOK_RESTART_FAIL:-}" == "1" ]]; then
    FRP_CLIENT_HOOK_RESTART_FAIL=0
    echo "ERROR: simulated systemctl restart failure" >&2
    return 1
  fi
  if [[ "${FRP_SKIP_SYSTEMD:-}" == "1" || -n "${FRP_CLIENT_TEST_ROOT:-}" ]]; then
    return 0
  fi
  systemctl restart frpc
}

frp_client_wait_proxies() {
  frp_client_hook_log proxies
  if [[ "${FRP_CLIENT_HOOK_PROXY_FAIL:-}" == "1" ]]; then
    echo "ERROR: frpc did not register every requested proxy successfully" >&2
    return 1
  fi
  if [[ "${FRP_SKIP_SYSTEMD:-}" == "1" || -n "${FRP_CLIENT_TEST_ROOT:-}" ]]; then
    return 0
  fi
  wait_for_proxies "$@"
}

frp_print_state_services() {
  python3 - "$1" <<'PY'
import json, sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
server = data.get('frp_server', '')
services = data.get('services') or {}
if not services:
    print('(none)')
    raise SystemExit(0)
n = 0
for sid, item in services.items():
    n += 1
    enabled = item.get('enabled', True) is not False
    state = 'enabled' if enabled else 'disabled'
    print(f"{n}. {item.get('id') or sid}")
    print(f"   Target : {item.get('local_ip')}:{item.get('local_port')}")
    remote = item.get('remote_port')
    if remote:
        print(f"   Public : {server}:{remote}")
    print(f"   State  : {state}")
    print()
PY
}
