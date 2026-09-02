#!/usr/bin/env bash
# P1-M: zero-touch post-enrollment recovery journal (Linux).
# Crash after /enroll success, before durable client-state; resume without re-ticket.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="$(mktemp -d)"
ALLOC_PID=""
LISTEN_PID=""
cleanup_bg() {
  if [[ -n "$ALLOC_PID" ]]; then
    kill "$ALLOC_PID" 2>/dev/null || true
    kill -9 "$ALLOC_PID" 2>/dev/null || true
  fi
  if [[ -n "$LISTEN_PID" ]]; then
    kill "$LISTEN_PID" 2>/dev/null || true
    kill -9 "$LISTEN_PID" 2>/dev/null || true
  fi
  rm -rf "$WORKDIR"
}
trap cleanup_bg EXIT

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }

chmod +x "$ROOT/tools/frp-create-client"

make_frpc() {
  local dest="$1"
  mkdir -p "$(dirname "$dest")"
  cat >"$dest" <<'EOF'
#!/bin/sh
if [ "$1" = verify ]; then
  exit 0
fi
exit 0
EOF
  chmod +x "$dest"
}

start_listener() {
  local port="$1"
  # Keep orphans from holding a `run-all | tee` stdout pipe open.
  python3 - "$port" <<'PY' >/dev/null 2>&1 &
import socket, sys
port = int(sys.argv[1])
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', port))
s.listen(5)
while True:
    conn, _addr = s.accept()
    conn.close()
PY
  LISTEN_PID=$!
  local i
  for i in $(seq 1 30); do
    python3 - "$port" <<'PY' && return 0
import socket, sys
s = socket.socket()
s.settimeout(0.2)
try:
    s.connect(('127.0.0.1', int(sys.argv[1])))
except Exception:
    raise SystemExit(1)
finally:
    s.close()
PY
    sleep 0.1
  done
  fail "test TCP listener did not start"
}

start_allocator() {
  local cfg="$1"
  python3 "$ROOT/server/frp-port-allocator.py" --config "$cfg" >"$WORKDIR/alloc.log" 2>&1 &
  ALLOC_PID=$!
  local i
  for i in $(seq 1 50); do
    if curl -fsS --cacert "$ALLOC_ROOT/pki/ca.crt" "https://127.0.0.1:${ALLOC_PORT}/healthz" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  cat "$WORKDIR/alloc.log" >&2 || true
  fail "allocator did not start"
}

pick_port() {
  python3 - <<'PY'
import socket
s = socket.socket()
s.bind(('127.0.0.1', 0))
print(s.getsockname()[1])
s.close()
PY
}

extract_ticket() {
  python3 - "$1" <<'PY'
import re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text()
m = re.search(r"FRP_BOOTSTRAP_TICKET='([^']+)'", text)
if not m:
    m = re.search(r'FRP_BOOTSTRAP_TICKET="([^"]+)"', text)
if not m:
    m = re.search(r"FRP_BOOTSTRAP_TICKET=(\S+)", text)
if not m:
    raise SystemExit("missing FRP_BOOTSTRAP_TICKET")
print(m.group(1))
PY
}

ALLOC_PORT="$(pick_port)"
PLUGIN_PORT="$(pick_port)"
LISTEN_PORT="$(pick_port)"
ALLOC_ROOT="$WORKDIR/allocator"
mkdir -p "$ALLOC_ROOT/enrollments" "$ALLOC_ROOT/bootstrap"
python3 "$ROOT/lib/frp_pki.py" ensure --pki-dir "$ALLOC_ROOT/pki" --public-host 127.0.0.1 >/dev/null
LIVE_CA_FP="$(python3 "$ROOT/lib/frp_pki.py" fingerprint --cert "$ALLOC_ROOT/pki/ca.crt")"
python3 - "$ALLOC_ROOT" "$ALLOC_PORT" "$PLUGIN_PORT" <<'PY'
import json, sys
from pathlib import Path
root = Path(sys.argv[1])
port = int(sys.argv[2])
plugin_port = int(sys.argv[3])
pki = root / 'pki'
(root / 'server_token').write_text('test-enroll-token-do-not-use\n')
(root / 'server_token').chmod(0o600)
(root / 'registry.json').write_text(json.dumps({
    'schema_version': 2, 'reserved': [], 'clients': {},
}, indent=2) + '\n')
(root / 'config.json').write_text(json.dumps({
    'public_host': '203.0.113.10',
    'public_ip': '203.0.113.10',
    'frp_control_public_port': 8443,
    'frp_control_listen_port': 443,
    'port_start': 18400,
    'port_end': 18430,
    'listen_host': '127.0.0.1',
    'listen_port': port,
    'allocator_listen_port': port,
    'allocator_public_port': port,
    'frp_plugin_listen_host': '127.0.0.1',
    'frp_plugin_listen_port': plugin_port,
    'tls_ca_cert': str(pki / 'ca.crt'),
    'tls_server_cert': str(pki / 'server.crt'),
    'tls_server_key': str(pki / 'server.key'),
    'registry_file': str(root / 'registry.json'),
    'enrollments_dir': str(root / 'enrollments'),
    'bootstrap_dir': str(root / 'bootstrap'),
    'token_file': str(root / 'server_token'),
    'data_plane_auth_strict': False,
    'client_installer_url': 'https://raw.githubusercontent.com/datarelay-labs/frp-auto-deploy/main/dist/bootstrap-client.sh',
    'allocator_public_url': 'https://127.0.0.1:%s/enroll' % port,
}, indent=2) + '\n')
PY
start_allocator "$ALLOC_ROOT/config.json"
start_listener "$LISTEN_PORT"
SSH_USER="$(id -un)"

LIVE_TREE="$WORKDIR/live-server"
mkdir -p "$LIVE_TREE/etc/frp-auto-deploy" "$LIVE_TREE/var/lib/frp-auto-deploy" "$LIVE_TREE/etc/frp"
cp -a "$ALLOC_ROOT/pki" "$LIVE_TREE/etc/frp-auto-deploy/pki"
python3 - "$LIVE_TREE" "$ALLOC_PORT" <<'PY'
import json, sys
from pathlib import Path
tree = Path(sys.argv[1])
port = int(sys.argv[2])
(tree / 'etc/frp-auto-deploy/config.json').write_text(json.dumps({
    'public_host': '203.0.113.10',
    'public_ip': '203.0.113.10',
    'frp_control_public_port': 8443,
    'frp_control_listen_port': 443,
    'allocator_public_url': 'https://127.0.0.1:%s/enroll' % port,
    'tls_ca_cert': '/etc/frp-auto-deploy/pki/ca.crt',
    'tls_server_cert': '/etc/frp-auto-deploy/pki/server.crt',
    'tls_server_key': '/etc/frp-auto-deploy/pki/server.key',
    'client_installer_url': 'https://raw.githubusercontent.com/datarelay-labs/frp-auto-deploy/main/dist/bootstrap-client.sh',
    'enrollments_dir': '/var/lib/frp-auto-deploy/enrollments',
    'bootstrap_dir': '/var/lib/frp-auto-deploy/bootstrap',
    'registry_file': '/var/lib/frp-auto-deploy/registry.json',
    'token_file': '/etc/frp/server_token',
}, indent=2) + '\n')
PY
ln -sfn "$ALLOC_ROOT/enrollments" "$LIVE_TREE/var/lib/frp-auto-deploy/enrollments"
ln -sfn "$ALLOC_ROOT/bootstrap" "$LIVE_TREE/var/lib/frp-auto-deploy/bootstrap"
ln -sfn "$ALLOC_ROOT/registry.json" "$LIVE_TREE/var/lib/frp-auto-deploy/registry.json"
ln -sfn "$ALLOC_ROOT/server_token" "$LIVE_TREE/etc/frp/server_token"

CREATE="$ROOT/tools/frp-create-client"
FRP_DEPLOY_TEST_ROOT="$LIVE_TREE" python3 "$CREATE" --one-line --ssh --ssh-user "$SSH_USER" \
  --ssh-port "$LISTEN_PORT" --note recover-01 >"$WORKDIR/create.out"
TICKET="$(extract_ticket "$WORKDIR/create.out")"

MACHINE='bbccddeeff00112233445566778899aa'
CLIENT="$WORKDIR/client"
mkdir -p "$CLIENT/etc/frp" "$CLIENT/usr/local/bin" "$CLIENT/usr/local/lib/frp-auto-deploy"
make_frpc "$CLIENT/usr/local/bin/frpc"

run_zero_touch() {
  local tree="$1" ticket="$2" machine="$3" out="$4"
  mkdir -p "$tree/etc/frp" "$tree/usr/local/bin" "$tree/usr/local/lib/frp-auto-deploy" \
    "$tree/var/lib/frp-auto-deploy"
  make_frpc "$tree/usr/local/bin/frpc"
  unset FRP_CLIENT_COMMON_LOADED FRP_COMMON_LOADED || true
  export FRP_CLIENT_TEST_ROOT="$tree"
  export FRP_CLIENT_LIB="$ROOT/lib/frp-client-common.sh"
  export FRP_SKIP_DOWNLOAD=1
  export FRP_SKIP_SYSTEMD=1
  export FRP_TEST_HOSTNAME='recover-host'
  export FRP_TEST_MACHINE_ID="$machine"
  export FRP_ALLOCATOR_URL="https://127.0.0.1:${ALLOC_PORT}/enroll"
  export FRP_ALLOCATOR_CA_SHA256="$LIVE_CA_FP"
  export FRP_BOOTSTRAP_TICKET="$ticket"
  export FRP_ZERO_TOUCH=1
  export FRP_SSH_USER="$SSH_USER"
  export FRP_SSH_PORT="$LISTEN_PORT"
  export FRP_CLIENT_SOURCED=1
  export FRP_CLIENT_HOOK_LOG="${out}.hook"
  : >"$FRP_CLIENT_HOOK_LOG"
  unset FRP_ENROLLMENT_CODE FRP_SERVICES_JSON FRP_CLIENT_TEST_INPUT || true
  # shellcheck source=../install-client.sh
  . "$ROOT/install-client.sh"
  set +e
  frp_client_main >"$out" 2>"${out%.out}.err" </dev/null
  rc=$?
  set -e
  return "$rc"
}

# --- Crash after enroll, before durable state ---
export FRP_CLIENT_HOOK_FAIL_AFTER_ENROLL=1
if run_zero_touch "$CLIENT" "$TICKET" "$MACHINE" "$WORKDIR/crash.out"; then
  fail "fail-after-enroll should abort"
fi
unset FRP_CLIENT_HOOK_FAIL_AFTER_ENROLL
grep -q 'simulated FAIL_AFTER_ENROLL failure' "$WORKDIR/crash.err" \
  || fail "fail-after-enroll message"
grep -q bootstrap_redeem "$WORKDIR/crash.out.hook" || fail "first attempt should redeem"
grep -q enroll "$WORKDIR/crash.out.hook" || fail "first attempt should enroll"
[[ ! -f "$CLIENT/etc/frp/client-state.json" ]] || fail "client-state must not exist after crash"
JOURNAL="$CLIENT/var/lib/frp-auto-deploy/client-enroll-recovery.json"
[[ -f "$JOURNAL" ]] || fail "recovery journal missing after crash"
python3 - "$JOURNAL" "$TICKET" <<'PY' || fail "journal must not contain bootstrap ticket"
import json, sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text())
ticket = sys.argv[2]
secret = ticket.split('.')[-1]
blob = Path(sys.argv[1]).read_text()
assert 'bootstrap_ticket' not in data
assert 'FRP_BOOTSTRAP_TICKET' not in data
assert ticket not in blob
assert secret not in blob
assert data.get('enrollment_id')
assert data.get('enrollment_secret')
assert data.get('machine_id') == 'bbccddeeff00112233445566778899aa'
assert data.get('schema_version') == 1
PY
ID_KEY_BEFORE="$(sha256sum "$CLIENT/etc/frp/client-identity.key" | awk '{print $1}')"
pass "FAIL_AFTER_ENROLL_LEAVES_RECOVERY_JOURNAL"

# --- Resume without re-redeem ---
if ! run_zero_touch "$CLIENT" "$TICKET" "$MACHINE" "$WORKDIR/resume.out"; then
  cat "$WORKDIR/resume.out" "$WORKDIR/resume.err" >&2
  fail "resume after crash"
fi
grep -q 'FRP client setup complete' "$WORKDIR/resume.out" || fail "resume success message"
grep -q 'Resuming incomplete zero-touch' "$WORKDIR/resume.out" || fail "resume messaging"
if grep -q bootstrap_redeem "$WORKDIR/resume.out.hook"; then
  fail "resume must not redeem bootstrap ticket"
fi
grep -q enroll "$WORKDIR/resume.out.hook" || fail "resume should re-enroll"
[[ -f "$CLIENT/etc/frp/client-state.json" ]] || fail "client-state missing after resume"
[[ ! -f "$JOURNAL" ]] || fail "recovery journal should be deleted after success"
ID_KEY_AFTER="$(sha256sum "$CLIENT/etc/frp/client-identity.key" | awk '{print $1}')"
[[ "$ID_KEY_BEFORE" == "$ID_KEY_AFTER" ]] || fail "management identity changed on resume"
python3 - "$CLIENT/etc/frp/client-state.json" "$MACHINE" <<'PY' || fail "same client id / ports"
import json, sys
from pathlib import Path
state = json.loads(Path(sys.argv[1]).read_text())
assert state['machine_id'] == sys.argv[2]
ssh = state['services']['ssh']
assert ssh['remote_port'] == 18400
assert ssh.get('enabled', True) is not False
PY
PORT_LINE="$(grep -E 'ssh -p ' "$WORKDIR/resume.out" || true)"
echo "$PORT_LINE" | grep -q 'ssh -p 18400' || fail "same public port after resume"
pass "RESUME_SAME_IDENTITY_AND_PORTS"

# --- Re-run after success refuses without redeem ---
if run_zero_touch "$CLIENT" "$TICKET" "$MACHINE" "$WORKDIR/again.out"; then
  fail "installed client should refuse re-enroll"
fi
if grep -q bootstrap_redeem "$WORKDIR/again.out.hook"; then
  fail "installed client must not redeem"
fi
pass "INSTALLED_REFUSES_RE_TICKET"

# --- Corrupt journal fail-closed ---
CLIENT2="$WORKDIR/client2"
mkdir -p "$CLIENT2/etc/frp" "$CLIENT2/var/lib/frp-auto-deploy"
make_frpc "$CLIENT2/usr/local/bin/frpc"
FRP_DEPLOY_TEST_ROOT="$LIVE_TREE" python3 "$CREATE" --one-line --ssh --ssh-user "$SSH_USER" \
  --ssh-port "$LISTEN_PORT" --note recover-02 >"$WORKDIR/create2.out"
TICKET2="$(extract_ticket "$WORKDIR/create2.out")"
MACHINE2='ccddeeff00112233445566778899aabb'
export FRP_CLIENT_HOOK_FAIL_AFTER_ENROLL=1
run_zero_touch "$CLIENT2" "$TICKET2" "$MACHINE2" "$WORKDIR/crash2.out" || true
unset FRP_CLIENT_HOOK_FAIL_AFTER_ENROLL
J2="$CLIENT2/var/lib/frp-auto-deploy/client-enroll-recovery.json"
[[ -f "$J2" ]] || fail "second journal missing"
printf 'not-json{{{{' >"$J2"
chmod 600 "$J2"
if run_zero_touch "$CLIENT2" "$TICKET2" "$MACHINE2" "$WORKDIR/corrupt.out"; then
  fail "corrupt journal must fail closed"
fi
grep -qi 'recovery journal' "$WORKDIR/corrupt.err" || fail "corrupt journal error message"
if grep -q bootstrap_redeem "$WORKDIR/corrupt.out.hook"; then
  fail "corrupt journal must not fall through to redeem"
fi
pass "CORRUPT_JOURNAL_FAIL_CLOSED"

# --- HEALTH_CHECK_FAILED: enroll ok, proxy health fails, journal retained ---
CLIENT3="$WORKDIR/client3"
MACHINE3='ddeeff00112233445566778899aabbcc'
FRP_DEPLOY_TEST_ROOT="$LIVE_TREE" python3 "$CREATE" --one-line --ssh --ssh-user "$SSH_USER" \
  --ssh-port "$LISTEN_PORT" --note recover-health >"$WORKDIR/create3.out"
TICKET3="$(extract_ticket "$WORKDIR/create3.out")"
export FRP_CLIENT_HOOK_HEALTH_CHECK_FAIL=1
if run_zero_touch "$CLIENT3" "$TICKET3" "$MACHINE3" "$WORKDIR/healthfail.out"; then
  fail "HEALTH_CHECK_FAIL should abort before client-state commit"
fi
unset FRP_CLIENT_HOOK_HEALTH_CHECK_FAIL
grep -q 'HEALTH_CHECK_FAILED' "$WORKDIR/healthfail.err" || fail "health failure class"
grep -q 'simulated HEALTH_CHECK_FAIL failure' "$WORKDIR/healthfail.err" || fail "health hook message"
grep -q bootstrap_redeem "$WORKDIR/healthfail.out.hook" || fail "health-fail attempt should redeem"
grep -q enroll "$WORKDIR/healthfail.out.hook" || fail "health-fail attempt should enroll"
[[ ! -f "$CLIENT3/etc/frp/client-state.json" ]] || fail "client-state must not exist after HEALTH_CHECK_FAILED"
J3="$CLIENT3/var/lib/frp-auto-deploy/client-enroll-recovery.json"
[[ -f "$J3" ]] || fail "recovery journal missing after HEALTH_CHECK_FAILED"
ID3_BEFORE="$(sha256sum "$CLIENT3/etc/frp/client-identity.key" | awk '{print $1}')"
if ! run_zero_touch "$CLIENT3" "$TICKET3" "$MACHINE3" "$WORKDIR/healthresume.out"; then
  cat "$WORKDIR/healthresume.out" "$WORKDIR/healthresume.err" >&2
  fail "resume after HEALTH_CHECK_FAILED"
fi
grep -q 'Resuming incomplete zero-touch' "$WORKDIR/healthresume.out" || fail "health resume messaging"
if grep -q bootstrap_redeem "$WORKDIR/healthresume.out.hook"; then
  fail "health resume must not redeem bootstrap ticket"
fi
[[ -f "$CLIENT3/etc/frp/client-state.json" ]] || fail "client-state missing after health resume"
[[ ! -f "$J3" ]] || fail "recovery journal should be deleted after health resume success"
ID3_AFTER="$(sha256sum "$CLIENT3/etc/frp/client-identity.key" | awk '{print $1}')"
[[ "$ID3_BEFORE" == "$ID3_AFTER" ]] || fail "management identity changed after health resume"
HEALTH_PORT="$(python3 - "$CLIENT3/etc/frp/client-state.json" "$MACHINE3" <<'PY' || fail "health resume state"
import json, sys
from pathlib import Path
state = json.loads(Path(sys.argv[1]).read_text())
assert state['machine_id'] == sys.argv[2]
port = state['services']['ssh']['remote_port']
assert isinstance(port, int) and 18400 <= port <= 18430
print(port)
PY
)"
PORT_LINE="$(grep -E 'ssh -p ' "$WORKDIR/healthresume.out" || true)"
echo "$PORT_LINE" | grep -q "ssh -p ${HEALTH_PORT} " || fail "same public port after health resume"
pass "HEALTH_CHECK_FAILED_RECOVERY_JOURNAL"

echo "ALL PASS test-zero-touch-recovery-journal"
