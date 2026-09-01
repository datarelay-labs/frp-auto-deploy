#!/usr/bin/env bash
# E2E: three independent FRP clients behind one NAT (same source IP) on one server.
# Does not modify production code. Uses official FRP binaries and live allocator.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="$(mktemp -d)"
ALLOC_PID=""
FRPS_PID=""
declare -a IDENTITY_PIDS=()
declare -a FRPC_PIDS=()
# shellcheck source=../lib/frp-common.sh
. "$ROOT/lib/frp-common.sh"
frp_detect_arch

pass() { echo "PASS $1"; }
fail() {
  echo "FAIL $1" >&2
  if [[ -f "$WORKDIR/alloc.log" ]]; then
    echo "----- allocator log -----" >&2
    tail -n 80 "$WORKDIR/alloc.log" >&2 || true
  fi
  if [[ -f "$WORKDIR/frps.log" ]]; then
    echo "----- frps log -----" >&2
    tail -n 80 "$WORKDIR/frps.log" >&2 || true
  fi
  for letter in a b c; do
    if [[ -f "$WORKDIR/frpc-${letter}.log" ]]; then
      echo "----- frpc ${letter} log -----" >&2
      tail -n 40 "$WORKDIR/frpc-${letter}.log" >&2 || true
    fi
  done
  if [[ -f "${REGISTRY_FILE:-}" ]]; then
    echo "----- registry.json -----" >&2
    cat "$REGISTRY_FILE" >&2 || true
  fi
  exit 1
}

cleanup() {
  local pid
  for pid in "${FRPC_PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
  for pid in "${IDENTITY_PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
  [[ -n "$FRPS_PID" ]] && kill "$FRPS_PID" 2>/dev/null || true
  [[ -n "$ALLOC_PID" ]] && kill "$ALLOC_PID" 2>/dev/null || true
  sleep 0.2
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

pick_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}

find_port_range() {
  python3 - <<'PY'
import socket
need = 12
for start in range(19100, 22000):
    socks = []
    ok = True
    try:
        for port in range(start, start + need):
            s = socket.socket()
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                s.bind(('127.0.0.1', port))
            except OSError:
                ok = False
                break
            socks.append(s)
        if ok:
            print('%d %d' % (start, start + need - 1))
            raise SystemExit(0)
    finally:
        for s in socks:
            s.close()
raise SystemExit('no free port range')
PY
}

wait_tcp() {
  local host="$1" port="$2" tries="${3:-50}"
  python3 - "$host" "$port" "$tries" <<'PY'
import socket, sys, time
host, port, tries = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
for _ in range(tries):
    s = socket.socket()
    s.settimeout(0.2)
    try:
        s.connect((host, port))
        s.close()
        raise SystemExit(0)
    except Exception:
        try:
            s.close()
        except Exception:
            pass
        time.sleep(0.1)
raise SystemExit(1)
PY
}

read_marker() {
  local host="$1" port="$2"
  python3 - "$host" "$port" <<'PY'
import socket, sys
host, port = sys.argv[1], int(sys.argv[2])
s = socket.socket()
s.settimeout(3)
s.connect((host, port))
data = b''
while b'\n' not in data and len(data) < 64:
    chunk = s.recv(64)
    if not chunk:
        break
    data += chunk
s.close()
sys.stdout.write(data.decode('utf-8', 'replace').strip())
PY
}

start_identity() {
  local marker="$1" portfile="$2"
  python3 - "$marker" "$portfile" <<'PY' >/dev/null 2>&1 &
import socket, sys
from pathlib import Path
marker, portfile = sys.argv[1], sys.argv[2]
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', 0))
Path(portfile).write_text(str(s.getsockname()[1]) + '\n')
s.listen(32)
while True:
    conn, _addr = s.accept()
    try:
        conn.sendall((marker + '\n').encode())
    except Exception:
        pass
    finally:
        try:
            conn.close()
        except Exception:
            pass
PY
  IDENTITY_PIDS+=("$!")
  local i
  for i in $(seq 1 50); do
    [[ -s "$portfile" ]] && return 0
    sleep 0.05
  done
  fail "identity listener ${marker} did not publish a port"
}

download_frp() {
  local cache="/tmp/frp-auto-deploy-frp-${FRP_VERSION}-linux-${FRP_ARCH}.tar.gz"
  local archive="$WORKDIR/frp.tar.gz"
  local expected
  expected="$(frp_checksum_for "$FRP_VERSION" "$FRP_ARCH")"
  if [[ -f "$cache" ]] && frp_verify_sha256 "$expected" "$cache" >/dev/null 2>&1; then
    cp "$cache" "$archive"
  else
    local url
    url="$(frp_release_url "$FRP_VERSION" "$FRP_ARCH")"
    echo "Downloading official FRP ${FRP_VERSION} (${FRP_ARCH}) for E2E ..."
    curl -fL --retry 3 -o "$archive" "$url" || fail "FRP archive download"
    frp_verify_sha256 "$expected" "$archive" || fail "FRP archive checksum"
    cp "$archive" "$cache"
  fi
  local extracted
  extracted="$(frp_extract_frp_member "$archive" "$WORKDIR/frp-bin" frps)" || fail "extract frps"
  cp "$extracted" "$WORKDIR/frps"
  extracted="$(frp_extract_frp_member "$archive" "$WORKDIR/frp-bin" frpc)" || fail "extract frpc"
  cp "$extracted" "$WORKDIR/frpc"
  chmod 755 "$WORKDIR/frps" "$WORKDIR/frpc"
  frp_validate_frp_binary "$WORKDIR/frps" "$FRP_VERSION" "$FRP_ARCH" || fail "validate frps"
  frp_validate_frp_binary "$WORKDIR/frpc" "$FRP_VERSION" "$FRP_ARCH" || fail "validate frpc"
}

extract_ticket() {
  python3 - "$1" <<'PY'
import re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text()
m = re.search(r"FRP_BOOTSTRAP_TICKET=(?:'([^']+)'|\"([^\"]+)\"|(\S+))", text)
print(next((g for g in m.groups() if g), '') if m else '')
PY
}

install_one_client() {
  local letter="$1" tree="$2" ticket="$3" machine="$4" hostname="$5" ssh_port="$6"
  mkdir -p "$tree/etc/frp" "$tree/usr/local/bin" "$tree/usr/local/lib/frp-auto-deploy"
  cp "$WORKDIR/frpc" "$tree/usr/local/bin/frpc"
  chmod 755 "$tree/usr/local/bin/frpc"
  (
    export FRP_CLIENT_TEST_ROOT="$tree"
    export FRP_CLIENT_LIB="$ROOT/lib/frp-client-common.sh"
    export FRP_MGMT_AUTH_PY="$ROOT/lib/frp_mgmt_auth.py"
    export FRP_SKIP_DOWNLOAD=1
    export FRP_SKIP_SYSTEMD=1
    export FRP_TEST_HOSTNAME="$hostname"
    export FRP_TEST_MACHINE_ID="$machine"
    export FRP_ALLOCATOR_URL="https://127.0.0.1:${ALLOC_PORT}/enroll"
    export FRP_ALLOCATOR_CA_SHA256="$CA_FP"
    export FRP_BOOTSTRAP_TICKET="$ticket"
    export FRP_ZERO_TOUCH=1
    export FRP_SSH_USER="$SSH_USER"
    export FRP_SSH_PORT="$ssh_port"
    export FRP_CLIENT_SOURCED=1
    unset FRP_ENROLLMENT_CODE FRP_SERVICES_JSON FRP_CLIENT_TEST_INPUT FRP_DEPLOY_TEST_ROOT || true
    # shellcheck source=../install-client.sh
    . "$ROOT/install-client.sh"
    frp_client_main
  ) >"$WORKDIR/install-${letter}.out" 2>"$WORKDIR/install-${letter}.err"
}

start_frpc() {
  local letter="$1" tree="$2"
  "$WORKDIR/frpc" -c "$tree/etc/frp/frpc.toml" >"$WORKDIR/frpc-${letter}.log" 2>&1 &
  FRPC_PIDS+=("$!")
}

# ---------------------------------------------------------------------------
download_frp
read -r PORT_START PORT_END <<<"$(find_port_range)"
ALLOC_PORT="$(pick_port)"
FRPS_PORT="$(pick_port)"
SSH_USER="$(id -un)"
MID_A='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
MID_B='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
MID_C='cccccccccccccccccccccccccccccccc'

start_identity CLIENT_A "$WORKDIR/port-a.txt"
start_identity CLIENT_B "$WORKDIR/port-b.txt"
start_identity CLIENT_C "$WORKDIR/port-c.txt"
LOCAL_A="$(tr -d '\n' <"$WORKDIR/port-a.txt")"
LOCAL_B="$(tr -d '\n' <"$WORKDIR/port-b.txt")"
LOCAL_C="$(tr -d '\n' <"$WORKDIR/port-c.txt")"
wait_tcp 127.0.0.1 "$LOCAL_A" || fail "identity A listen"
wait_tcp 127.0.0.1 "$LOCAL_B" || fail "identity B listen"
wait_tcp 127.0.0.1 "$LOCAL_C" || fail "identity C listen"
[[ "$(read_marker 127.0.0.1 "$LOCAL_A")" == CLIENT_A ]] || fail "identity A local marker"
[[ "$(read_marker 127.0.0.1 "$LOCAL_B")" == CLIENT_B ]] || fail "identity B local marker"
[[ "$(read_marker 127.0.0.1 "$LOCAL_C")" == CLIENT_C ]] || fail "identity C local marker"

LIVE_TREE="$WORKDIR/live-server"
mkdir -p "$LIVE_TREE/etc/frp-auto-deploy/pki" "$LIVE_TREE/var/lib/frp-auto-deploy/enrollments" \
  "$LIVE_TREE/var/lib/frp-auto-deploy/bootstrap" "$LIVE_TREE/etc/frp" "$LIVE_TREE/usr/local/sbin"
python3 "$ROOT/lib/frp_pki.py" ensure --pki-dir "$LIVE_TREE/etc/frp-auto-deploy/pki" --public-host 127.0.0.1 >/dev/null
CA_FP="$(python3 "$ROOT/lib/frp_pki.py" fingerprint --cert "$LIVE_TREE/etc/frp-auto-deploy/pki/ca.crt")"
printf 'test-multi-client-frp-token-do-not-use\n' >"$LIVE_TREE/etc/frp/server_token"
chmod 600 "$LIVE_TREE/etc/frp/server_token"
REGISTRY_FILE="$LIVE_TREE/var/lib/frp-auto-deploy/registry.json"
BOOTSTRAP_DIR="$LIVE_TREE/var/lib/frp-auto-deploy/bootstrap"
ALLOC_CFG="$WORKDIR/allocator.json"
python3 - "$LIVE_TREE" "$ALLOC_CFG" "$ALLOC_PORT" "$FRPS_PORT" "$PORT_START" "$PORT_END" <<'PY'
import json, sys
from pathlib import Path
tree, cfg_path = Path(sys.argv[1]), Path(sys.argv[2])
alloc_port, frps_port = int(sys.argv[3]), int(sys.argv[4])
port_start, port_end = int(sys.argv[5]), int(sys.argv[6])
pki = tree / 'etc/frp-auto-deploy/pki'
registry = tree / 'var/lib/frp-auto-deploy/registry.json'
registry.write_text(json.dumps({
    'schema_version': 2, 'reserved': [], 'clients': {},
}, indent=2) + '\n')
cfg_path.write_text(json.dumps({
    'public_host': '127.0.0.1',
    'public_ip': '127.0.0.1',
    'frp_control_public_port': frps_port,
    'frp_control_listen_port': frps_port,
    'port_start': port_start,
    'port_end': port_end,
    'listen_host': '127.0.0.1',
    'listen_port': alloc_port,
    'allocator_listen_port': alloc_port,
    'allocator_public_port': alloc_port,
    'tls_ca_cert': str(pki / 'ca.crt'),
    'tls_server_cert': str(pki / 'server.crt'),
    'tls_server_key': str(pki / 'server.key'),
    'registry_file': str(registry),
    'enrollments_dir': str(tree / 'var/lib/frp-auto-deploy/enrollments'),
    'bootstrap_dir': str(tree / 'var/lib/frp-auto-deploy/bootstrap'),
    'token_file': str(tree / 'etc/frp/server_token'),
    'allocator_public_url': 'https://127.0.0.1:%s/enroll' % alloc_port,
    'client_installer_url': 'https://example.test/bootstrap-client.sh',
}, indent=2) + '\n')
PY

cat >"$WORKDIR/frps.toml" <<EOF
bindAddr = "127.0.0.1"
bindPort = ${FRPS_PORT}
proxyBindAddr = "127.0.0.1"

auth.method = "token"
auth.tokenSource.type = "file"
auth.tokenSource.file.path = "${LIVE_TREE}/etc/frp/server_token"

transport.tls.force = true

allowPorts = [
  { start = ${PORT_START}, end = ${PORT_END} }
]
EOF
chmod 600 "$WORKDIR/frps.toml"
"$WORKDIR/frps" verify -c "$WORKDIR/frps.toml" || fail "frps verify"
"$WORKDIR/frps" -c "$WORKDIR/frps.toml" >"$WORKDIR/frps.log" 2>&1 &
FRPS_PID=$!
wait_tcp 127.0.0.1 "$FRPS_PORT" 80 || fail "frps did not listen"

python3 "$ROOT/server/frp-port-allocator.py" --config "$ALLOC_CFG" \
  >"$WORKDIR/alloc.log" 2>&1 &
ALLOC_PID=$!
wait_tcp 127.0.0.1 "$ALLOC_PORT" 80 || fail "allocator did not listen"
curl -fsS --cacert "$LIVE_TREE/etc/frp-auto-deploy/pki/ca.crt" \
  "https://127.0.0.1:${ALLOC_PORT}/healthz" >/dev/null \
  || fail "allocator healthz"

cp "$ROOT/tools/frpctl" "$LIVE_TREE/usr/local/sbin/frpctl"
chmod 755 "$LIVE_TREE/usr/local/sbin/frpctl"
python3 - "$LIVE_TREE" "$ALLOC_PORT" "$FRPS_PORT" <<'PY'
import json, sys
from pathlib import Path
tree = Path(sys.argv[1])
alloc_port, frps_port = int(sys.argv[2]), int(sys.argv[3])
(tree / 'etc/frp-auto-deploy/config.json').write_text(json.dumps({
    'public_host': '127.0.0.1',
    'public_ip': '127.0.0.1',
    'frp_control_public_port': frps_port,
    'frp_control_listen_port': frps_port,
    'allocator_public_url': 'https://127.0.0.1:%s/enroll' % alloc_port,
    'tls_ca_cert': '/etc/frp-auto-deploy/pki/ca.crt',
    'client_installer_url': 'https://example.test/bootstrap-client.sh',
    'enrollments_dir': '/var/lib/frp-auto-deploy/enrollments',
    'bootstrap_dir': '/var/lib/frp-auto-deploy/bootstrap',
    'registry_file': '/var/lib/frp-auto-deploy/registry.json',
    'token_file': '/etc/frp/server_token',
}, indent=2) + '\n')
PY

issue_ticket() {
  local name="$1" ssh_port="$2" out="$3"
  FRP_DEPLOY_TEST_ROOT="$LIVE_TREE" python3 "$ROOT/tools/frp-create-client" \
    --one-line --ssh --ssh-user "$SSH_USER" --ssh-port "$ssh_port" \
    --client-name "$name" --note "nat-e2e-$name" >"$out"
}

issue_ticket client-a "$LOCAL_A" "$WORKDIR/ticket-a.out"
issue_ticket client-b "$LOCAL_B" "$WORKDIR/ticket-b.out"
issue_ticket client-c "$LOCAL_C" "$WORKDIR/ticket-c.out"
TICKET_A="$(extract_ticket "$WORKDIR/ticket-a.out")"
TICKET_B="$(extract_ticket "$WORKDIR/ticket-b.out")"
TICKET_C="$(extract_ticket "$WORKDIR/ticket-c.out")"
[[ -n "$TICKET_A" && -n "$TICKET_B" && -n "$TICKET_C" ]] || fail "bootstrap tickets missing"
python3 - "$TICKET_A" "$TICKET_B" "$TICKET_C" <<'PY' || fail "tickets not unique"
import sys
vals = sys.argv[1:]
assert len(set(vals)) == 3, vals
PY
pass "SEPARATE_BOOTSTRAP_TICKETS"

TREE_A="$WORKDIR/client-a"
TREE_B="$WORKDIR/client-b"
TREE_C="$WORKDIR/client-c"
install_one_client a "$TREE_A" "$TICKET_A" "$MID_A" host-a "$LOCAL_A" || {
  cat "$WORKDIR/install-a.err" >&2 || true
  fail "install client A"
}
install_one_client b "$TREE_B" "$TICKET_B" "$MID_B" host-b "$LOCAL_B" || {
  cat "$WORKDIR/install-b.err" >&2 || true
  fail "install client B"
}
install_one_client c "$TREE_C" "$TICKET_C" "$MID_C" host-c "$LOCAL_C" || {
  cat "$WORKDIR/install-c.err" >&2 || true
  fail "install client C"
}

eval "$(python3 - "$REGISTRY_FILE" "$TREE_A" "$TREE_B" "$TREE_C" <<'PY'
import json, sys
from pathlib import Path
reg = json.loads(Path(sys.argv[1]).read_text())
clients = reg.get('clients') or {}
assert reg.get('schema_version') == 2
mids = list(clients)
print('REG_CLIENT_COUNT=%d' % len(mids))
print('MACHINE_IDS_UNIQUE=%s' % ('YES' if len(set(mids)) == 3 else 'NO'))
ips = [clients[m].get('last_source_ip') for m in mids]
print('SOURCE_IPS=%s' % ','.join(sorted(str(i) for i in ips)))
print('SAME_SOURCE_IP=%s' % ('YES' if len(set(ips)) == 1 and ips and ips[0] else 'NO'))
ports = []
for letter, tree, expect in (
    ('A', sys.argv[2], 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'),
    ('B', sys.argv[3], 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'),
    ('C', sys.argv[4], 'cccccccccccccccccccccccccccccccc'),
):
    state = json.loads(Path(tree, 'etc/frp/client-state.json').read_text())
    mid = state['machine_id']
    print('CLIENT_%s_MACHINE_ID=%s' % (letter, mid))
    assert mid == expect, (letter, mid)
    assert mid in clients
    rec = clients[mid]
    ssh = rec['services']['ssh']
    port = int(ssh['remote_port'])
    ports.append(port)
    print('REMOTE_PORT_%s=%d' % (letter, port))
    print('LOCAL_PORT_%s=%s' % (letter, ssh.get('local_port')))
    assert rec.get('hostname') == 'host-%s' % letter.lower()
    assert rec.get('label') == 'client-%s' % letter.lower()
    assert rec.get('mgmt_status') == 'enrolled'
print('REMOTE_PORTS_UNIQUE=%s' % ('YES' if len(set(ports)) == 3 else 'NO'))
print('DUPLICATE_CLIENT_ENTRY=%s' % ('NO' if len(mids) == 3 else 'YES'))
reserved = [int(p) for p in (reg.get('reserved') or [])]
assert len(reserved) == len(set(reserved)), reserved
assert not (set(reserved) & set(ports)), (reserved, ports)
# identity collision: same machine_id mapped twice is impossible in a dict;
# check hostname/label uniqueness still holds independently of machine_id.
hosts = [clients[m].get('hostname') for m in mids]
labels = [clients[m].get('label') for m in mids]
print('HOSTNAMES_UNIQUE=%s' % ('YES' if len(set(hosts)) == 3 else 'NO'))
print('LABELS_UNIQUE=%s' % ('YES' if len(set(labels)) == 3 else 'NO'))
PY
)"

[[ "${REG_CLIENT_COUNT:-0}" == 3 ]] || fail "registry client count ${REG_CLIENT_COUNT:-missing}"
[[ "${MACHINE_IDS_UNIQUE:-}" == YES ]] || fail "machine ids not unique"
[[ "${REMOTE_PORTS_UNIQUE:-}" == YES ]] || fail "remote ports not unique"
[[ "${SAME_SOURCE_IP:-}" == YES ]] || fail "clients did not share observed source IP"
[[ "${HOSTNAMES_UNIQUE:-}" == YES ]] || fail "hostnames collided"
[[ "${LABELS_UNIQUE:-}" == YES ]] || fail "labels collided"
pass "REGISTRY_THREE_CLIENTS"
pass "SAME_NAT_SOURCE_IP"

python3 - "$BOOTSTRAP_DIR" "$MID_A" "$MID_B" "$MID_C" <<'PY' || fail "ticket binding"
import json, sys
from pathlib import Path
root = Path(sys.argv[1])
wanted = set(sys.argv[2:])
bound = set()
for path in root.glob('*.json'):
    rec = json.loads(path.read_text())
    mid = rec.get('bound_machine_id')
    if mid:
        bound.add(mid)
assert bound == wanted, (bound, wanted)
PY
pass "TICKETS_BOUND_TO_DISTINCT_MACHINES"

start_frpc a "$TREE_A"
start_frpc b "$TREE_B"
start_frpc c "$TREE_C"
wait_tcp 127.0.0.1 "$REMOTE_PORT_A" 80 || fail "remote A not listening"
wait_tcp 127.0.0.1 "$REMOTE_PORT_B" 80 || fail "remote B not listening"
wait_tcp 127.0.0.1 "$REMOTE_PORT_C" 80 || fail "remote C not listening"

SSH_A=FAIL
SSH_B=FAIL
SSH_C=FAIL
[[ "$(read_marker 127.0.0.1 "$REMOTE_PORT_A")" == CLIENT_A ]] && SSH_A=PASS
[[ "$(read_marker 127.0.0.1 "$REMOTE_PORT_B")" == CLIENT_B ]] && SSH_B=PASS
[[ "$(read_marker 127.0.0.1 "$REMOTE_PORT_C")" == CLIENT_C ]] && SSH_C=PASS
[[ "$SSH_A" == PASS ]] || fail "SSH A mapped to wrong backend: $(read_marker 127.0.0.1 "$REMOTE_PORT_A" || true)"
[[ "$SSH_B" == PASS ]] || fail "SSH B mapped to wrong backend"
[[ "$SSH_C" == PASS ]] || fail "SSH C mapped to wrong backend"
pass "SSH_ENDPOINTS"

export FRP_DEPLOY_TEST_ROOT="$LIVE_TREE"
export FRP_CTL_BIN_DIR="$ROOT/tools"
python3 "$ROOT/tools/frp-clients" >"$WORKDIR/frp-clients.out"
"$ROOT/tools/frpctl" clients >"$WORKDIR/frpctl-clients.out"
for needle in client-a client-b client-c host-a host-b host-c \
  "ssh:${REMOTE_PORT_A}" "ssh:${REMOTE_PORT_B}" "ssh:${REMOTE_PORT_C}"; do
  grep -Fq "$needle" "$WORKDIR/frp-clients.out" || fail "frp-clients missing $needle"
  grep -Fq "$needle" "$WORKDIR/frpctl-clients.out" || fail "frpctl clients missing $needle"
done
grep -c ' online ' "$WORKDIR/frp-clients.out" | grep -qx 3 \
  || fail "expected three online clients in frp-clients"
ALL_CLIENTS_SIMULTANEOUSLY_ONLINE=YES
pass "FRPCTL_AND_FRP_CLIENTS"

# Reconnect isolation: restart client A only.
kill "${FRPC_PIDS[0]}" 2>/dev/null || true
wait "${FRPC_PIDS[0]}" 2>/dev/null || true
sleep 0.4
[[ "$(read_marker 127.0.0.1 "$REMOTE_PORT_B")" == CLIENT_B ]] || fail "B broken after A stop"
[[ "$(read_marker 127.0.0.1 "$REMOTE_PORT_C")" == CLIENT_C ]] || fail "C broken after A stop"
start_frpc a "$TREE_A"
wait_tcp 127.0.0.1 "$REMOTE_PORT_A" 80 || fail "A did not return after reconnect"
[[ "$(read_marker 127.0.0.1 "$REMOTE_PORT_A")" == CLIENT_A ]] || fail "A wrong after reconnect"
[[ "$(read_marker 127.0.0.1 "$REMOTE_PORT_B")" == CLIENT_B ]] || fail "B broken after A reconnect"
[[ "$(read_marker 127.0.0.1 "$REMOTE_PORT_C")" == CLIENT_C ]] || fail "C broken after A reconnect"
python3 - "$REGISTRY_FILE" "$MID_A" "$MID_B" "$MID_C" <<'PY' || fail "ids mixed after reconnect"
import json, sys
from pathlib import Path
reg = json.loads(Path(sys.argv[1]).read_text())
clients = reg['clients']
assert set(clients) == set(sys.argv[2:])
assert clients[sys.argv[2]]['hostname'] == 'host-a'
assert clients[sys.argv[3]]['hostname'] == 'host-b'
assert clients[sys.argv[4]]['hostname'] == 'host-c'
PY
RECONNECT_ISOLATION=PASS
pass "RECONNECT_ISOLATION"

printf 'REVOKE\n' | FRP_DEPLOY_TEST_ROOT="$LIVE_TREE" python3 "$ROOT/tools/frp-revoke-client" client-a \
  >"$WORKDIR/revoke.out"
python3 - "$REGISTRY_FILE" "$MID_A" "$MID_B" "$MID_C" <<'PY' || fail "revoke isolation registry"
import json, sys
from pathlib import Path
reg = json.loads(Path(sys.argv[1]).read_text())
clients = reg['clients']
assert set(clients) == set(sys.argv[2:])
assert clients[sys.argv[2]].get('mgmt_status') == 'revoked'
assert clients[sys.argv[3]].get('mgmt_status') == 'enrolled'
assert clients[sys.argv[4]].get('mgmt_status') == 'enrolled'
assert clients[sys.argv[3]]['services']['ssh']['remote_port']
assert clients[sys.argv[4]]['services']['ssh']['remote_port']
PY
[[ "$(read_marker 127.0.0.1 "$REMOTE_PORT_B")" == CLIENT_B ]] || fail "B broken after A revoke"
[[ "$(read_marker 127.0.0.1 "$REMOTE_PORT_C")" == CLIENT_C ]] || fail "C broken after A revoke"
python3 "$ROOT/tools/frp-clients" >"$WORKDIR/frp-clients-after-revoke.out"
grep -q client-b "$WORKDIR/frp-clients-after-revoke.out" || fail "clients lost B after revoke"
grep -q client-c "$WORKDIR/frp-clients-after-revoke.out" || fail "clients lost C after revoke"
grep -q client-a "$WORKDIR/frp-clients-after-revoke.out" || fail "revoked A disappeared"
REVOKE_ISOLATION=PASS
pass "REVOKE_ISOLATION"

python3 - "$REGISTRY_FILE" <<'PY' || fail "registry integrity"
import json, sys
from pathlib import Path
reg = json.loads(Path(sys.argv[1]).read_text())
assert reg.get('schema_version') == 2
clients = reg['clients']
assert len(clients) == 3
ports = []
for mid, client in clients.items():
    ssh = client['services']['ssh']
    ports.append(int(ssh['remote_port']))
assert len(set(ports)) == 3
reserved = [int(p) for p in (reg.get('reserved') or [])]
assert len(reserved) == len(set(reserved))
assert not (set(reserved) & set(ports)), (reserved, ports)
PY
REGISTRY_INTEGRITY=PASS
pass "REGISTRY_INTEGRITY"

echo
echo "MULTI_CLIENT_NAT_E2E=PASS"
echo "CLIENT_A_MACHINE_ID=${CLIENT_A_MACHINE_ID}"
echo "CLIENT_B_MACHINE_ID=${CLIENT_B_MACHINE_ID}"
echo "CLIENT_C_MACHINE_ID=${CLIENT_C_MACHINE_ID}"
echo "MACHINE_IDS_UNIQUE=${MACHINE_IDS_UNIQUE}"
echo "ALL_CLIENTS_SIMULTANEOUSLY_ONLINE=${ALL_CLIENTS_SIMULTANEOUSLY_ONLINE}"
echo "REMOTE_PORTS_UNIQUE=${REMOTE_PORTS_UNIQUE}"
echo "SSH_A=${SSH_A}"
echo "SSH_B=${SSH_B}"
echo "SSH_C=${SSH_C}"
echo "SAME_NAT_IDENTITY_ISOLATION=PASS"
echo "RECONNECT_ISOLATION=${RECONNECT_ISOLATION}"
echo "REVOKE_ISOLATION=${REVOKE_ISOLATION}"
echo "REGISTRY_INTEGRITY=${REGISTRY_INTEGRITY}"
