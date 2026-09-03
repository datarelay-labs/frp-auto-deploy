#!/usr/bin/env bash
# Regression: executing bootstrap/common must prefer its own crypto/clock helpers
# over a stale previously-installed copy under the client lib dir.
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

BUNDLE="$WORKDIR/bundle"
INSTALLED="$WORKDIR/installed"
mkdir -p "$BUNDLE/lib" "$INSTALLED/usr/local/lib/frp-auto-deploy"

# Current bundle helpers (good).
cp "$ROOT/lib/frp-client-common.sh" "$BUNDLE/lib/"
cp "$ROOT/lib/frp-common.sh" "$BUNDLE/lib/"
cp "$ROOT/lib/frp_mgmt_auth.py" "$BUNDLE/lib/"
cp "$ROOT/lib/frp_clock_sync.py" "$BUNDLE/lib/"
[[ -f "$ROOT/VERSION" ]] && cp "$ROOT/VERSION" "$BUNDLE/VERSION"

# Stale installed helpers: deliberately incompatible.
cat >"$INSTALLED/usr/local/lib/frp-auto-deploy/frp_mgmt_auth.py" <<'EOF'
#!/usr/bin/env python3
import sys
print('ERROR: stale installed frp_mgmt_auth.py must not be selected', file=sys.stderr)
sys.exit(97)
EOF

cat >"$INSTALLED/usr/local/lib/frp-auto-deploy/frp_clock_sync.py" <<'EOF'
#!/usr/bin/env python3
import sys
print('ERROR: stale installed frp_clock_sync.py must not be selected', file=sys.stderr)
sys.exit(97)
EOF

# Also plant a stale copy of common.sh under installed so libdir looks "real",
# but resolution must still come from the executing bundle tree.
cp "$ROOT/lib/frp-client-common.sh" "$INSTALLED/usr/local/lib/frp-auto-deploy/"
cp "$ROOT/lib/frp-common.sh" "$INSTALLED/usr/local/lib/frp-auto-deploy/"

# --- Resolution: bundle/common executing with stale install present ---
unset FRP_CLIENT_COMMON_LOADED FRP_COMMON_LOADED FRP_MGMT_AUTH_PY FRP_CLOCK_SYNC_PY || true
export FRP_CLIENT_TEST_ROOT="$INSTALLED"
# shellcheck source=/dev/null
. "$BUNDLE/lib/frp-client-common.sh"

SELECTED_MGMT="$(frp_mgmt_auth_py)" || fail "mgmt helper resolve"
SELECTED_CLOCK="$(frp_clock_sync_py)" || fail "clock helper resolve"
[[ "$SELECTED_MGMT" == "$BUNDLE/lib/frp_mgmt_auth.py" ]] \
  || fail "expected bundle mgmt helper, got: $SELECTED_MGMT"
[[ "$SELECTED_CLOCK" == "$BUNDLE/lib/frp_clock_sync.py" ]] \
  || fail "expected bundle clock helper, got: $SELECTED_CLOCK"
pass "STALE_INSTALLED_PREFERS_BUNDLE_MGMT"
pass "STALE_INSTALLED_PREFERS_BUNDLE_CLOCK"

SECRET='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
TOKEN='frp-token-regression-value'
CIPHERTEXT="$(printf '%s' "$TOKEN" | FRP_ENROLL_SECRET="$SECRET" python3 "$SELECTED_MGMT" encrypt-token)"
DECRYPTED="$(frp_decrypt_token "$CIPHERTEXT" "$SECRET")" || fail "decrypt with bundle helper"
[[ "$DECRYPTED" == "$TOKEN" ]] || fail "decrypt mismatch"
pass "TOKEN_DECRYPT_WITH_BUNDLE_HELPER"

# Explicit override still wins over bundle sibling.
export FRP_MGMT_AUTH_PY="$INSTALLED/usr/local/lib/frp-auto-deploy/frp_mgmt_auth.py"
OVERRIDE_SEL="$(frp_mgmt_auth_py)" || fail "override resolve"
[[ "$OVERRIDE_SEL" == "$FRP_MGMT_AUTH_PY" ]] || fail "override not preferred"
unset FRP_MGMT_AUTH_PY
pass "EXPLICIT_MGMT_OVERRIDE_HIGHEST"

# Decrypt diagnostics: malformed ciphertext
set +e
DIAG_OUT="$(frp_decrypt_token '!!!not-base64!!!' "$SECRET" 2>&1)"
DIAG_RC=$?
set -e
[[ "$DIAG_RC" -ne 0 ]] || fail "malformed ciphertext should fail"
printf '%s\n' "$DIAG_OUT" | grep -q 'TOKEN_CIPHERTEXT_INVALID' \
  || fail "missing TOKEN_CIPHERTEXT_INVALID"
printf '%s\n' "$DIAG_OUT" | grep -qi 'malformed\|invalid' \
  || fail "malformed ciphertext message"
printf '%s\n' "$DIAG_OUT" | grep -Fq "$SECRET" && fail "secret leaked in malformed diag"
pass "TOKEN_DECRYPT_DIAG_MALFORMED"

# Decrypt diagnostics: helper non-zero (forced via override to stale helper)
export FRP_MGMT_AUTH_PY="$INSTALLED/usr/local/lib/frp-auto-deploy/frp_mgmt_auth.py"
set +e
DIAG_OUT="$(frp_decrypt_token "$CIPHERTEXT" "$SECRET" 2>&1)"
DIAG_RC=$?
set -e
unset FRP_MGMT_AUTH_PY
[[ "$DIAG_RC" -ne 0 ]] || fail "stale helper decrypt should fail"
printf '%s\n' "$DIAG_OUT" | grep -q 'TOKEN_DECRYPT_FAILED' \
  || fail "missing TOKEN_DECRYPT_FAILED"
printf '%s\n' "$DIAG_OUT" | grep -qi 'exited with status' \
  || fail "missing helper exit status message"
printf '%s\n' "$DIAG_OUT" | grep -Fq "$SECRET" && fail "secret leaked in helper-fail diag"
printf '%s\n' "$DIAG_OUT" | grep -Fq "$TOKEN" && fail "token leaked in helper-fail diag"
pass "TOKEN_DECRYPT_DIAG_HELPER_EXIT"

# Decrypt diagnostics: empty result (helper that exits 0 with no stdout)
EMPTY_HELPER="$WORKDIR/empty_decrypt.py"
cat >"$EMPTY_HELPER" <<'EOF'
#!/usr/bin/env python3
import sys
if len(sys.argv) > 1 and sys.argv[1] == 'decrypt-token':
    sys.exit(0)
sys.exit(2)
EOF
export FRP_MGMT_AUTH_PY="$EMPTY_HELPER"
set +e
DIAG_OUT="$(frp_decrypt_token "$CIPHERTEXT" "$SECRET" 2>&1)"
DIAG_RC=$?
set -e
unset FRP_MGMT_AUTH_PY
[[ "$DIAG_RC" -ne 0 ]] || fail "empty decrypt should fail"
printf '%s\n' "$DIAG_OUT" | grep -q 'TOKEN_DECRYPT_EMPTY' \
  || fail "missing TOKEN_DECRYPT_EMPTY"
pass "TOKEN_DECRYPT_DIAG_EMPTY"

# --- Installed-runtime: execution originates from installed tree ---
unset FRP_CLIENT_COMMON_LOADED FRP_COMMON_LOADED FRP_MGMT_AUTH_PY FRP_CLOCK_SYNC_PY || true
# Replace stale helpers with coherent installed copies for this case.
cp "$ROOT/lib/frp_mgmt_auth.py" "$INSTALLED/usr/local/lib/frp-auto-deploy/"
cp "$ROOT/lib/frp_clock_sync.py" "$INSTALLED/usr/local/lib/frp-auto-deploy/"
export FRP_CLIENT_TEST_ROOT="$INSTALLED"
# shellcheck source=/dev/null
. "$INSTALLED/usr/local/lib/frp-auto-deploy/frp-client-common.sh"
INST_MGMT="$(frp_mgmt_auth_py)" || fail "installed mgmt resolve"
INST_CLOCK="$(frp_clock_sync_py)" || fail "installed clock resolve"
[[ "$INST_MGMT" == "$INSTALLED/usr/local/lib/frp-auto-deploy/frp_mgmt_auth.py" ]] \
  || fail "installed runtime should select sibling mgmt: $INST_MGMT"
[[ "$INST_CLOCK" == "$INSTALLED/usr/local/lib/frp-auto-deploy/frp_clock_sync.py" ]] \
  || fail "installed runtime should select sibling clock: $INST_CLOCK"
pass "INSTALLED_RUNTIME_SELECTS_SIBLING_MGMT"
pass "INSTALLED_RUNTIME_SELECTS_SIBLING_CLOCK"

# --- Recovery resume after decrypt crash window with stale installed helper ---
# Matches Real E2E: journal present, client-state absent, stale install on disk,
# new bundle must resume without re-redeem and decrypt successfully.
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
text = open(sys.argv[1], encoding='utf-8').read()
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
    'port_start': 18500,
    'port_end': 18530,
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
  --ssh-port "$LISTEN_PORT" --note stale-helper-01 >"$WORKDIR/create.out"
TICKET="$(extract_ticket "$WORKDIR/create.out")"
MACHINE='aabbccddeeff00112233445566778899'
CLIENT="$WORKDIR/client"
mkdir -p "$CLIENT/etc/frp" "$CLIENT/usr/local/bin" "$CLIENT/usr/local/lib/frp-auto-deploy" \
  "$CLIENT/var/lib/frp-auto-deploy"
cat >"$CLIENT/usr/local/lib/frp-auto-deploy/frp_mgmt_auth.py" <<'EOF'
#!/usr/bin/env python3
import sys
print('ERROR: stale installed frp_mgmt_auth.py must not be selected', file=sys.stderr)
sys.exit(97)
EOF
cp "$ROOT/lib/frp_clock_sync.py" "$CLIENT/usr/local/lib/frp-auto-deploy/"
make_frpc "$CLIENT/usr/local/bin/frpc"

run_zero_touch() {
  local tree="$1" ticket="$2" machine="$3" out="$4"
  mkdir -p "$tree/etc/frp" "$tree/usr/local/bin" "$tree/usr/local/lib/frp-auto-deploy" \
    "$tree/var/lib/frp-auto-deploy"
  make_frpc "$tree/usr/local/bin/frpc"
  unset FRP_CLIENT_COMMON_LOADED FRP_COMMON_LOADED FRP_MGMT_AUTH_PY FRP_CLOCK_SYNC_PY || true
  export FRP_CLIENT_TEST_ROOT="$tree"
  export FRP_CLIENT_LIB="$ROOT/lib/frp-client-common.sh"
  export FRP_SKIP_DOWNLOAD=1
  export FRP_SKIP_SYSTEMD=1
  export FRP_TEST_HOSTNAME='stale-helper-host'
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

# Crash after enroll (journal written; client-state absent) — same durable window as a
# Real-E2E decrypt failure after redeem/enroll. Then plant a stale installed helper and
# resume: executing tree must win so decrypt/commit succeed without re-redeem.
export FRP_CLIENT_HOOK_FAIL_AFTER_ENROLL=1
if run_zero_touch "$CLIENT" "$TICKET" "$MACHINE" "$WORKDIR/decrypt-crash.out"; then
  fail "fail-after-enroll should abort"
fi
unset FRP_CLIENT_HOOK_FAIL_AFTER_ENROLL
JOURNAL="$CLIENT/var/lib/frp-auto-deploy/client-enroll-recovery.json"
[[ -f "$JOURNAL" ]] || fail "recovery journal missing after enroll crash"
[[ ! -f "$CLIENT/etc/frp/client-state.json" ]] || fail "client-state must not exist after enroll crash"
grep -q bootstrap_redeem "$WORKDIR/decrypt-crash.out.hook" || fail "first attempt should redeem"
ID_KEY_BEFORE="$(sha256sum "$CLIENT/etc/frp/client-identity.key" | awk '{print $1}')"

# Plant stale incompatible installed helper before resume (Real E2E shape).
cat >"$CLIENT/usr/local/lib/frp-auto-deploy/frp_mgmt_auth.py" <<'EOF'
#!/usr/bin/env python3
import sys
print('ERROR: stale installed frp_mgmt_auth.py must not be selected', file=sys.stderr)
sys.exit(97)
EOF
pass "DECRYPT_CRASH_LEAVES_RECOVERY_JOURNAL"

# Resume: stale installed helper on disk; executing ROOT/lib tree must win for decrypt.
grep -q 'stale installed frp_mgmt_auth' "$CLIENT/usr/local/lib/frp-auto-deploy/frp_mgmt_auth.py" \
  || fail "stale installed helper must still be present before resume"
if ! run_zero_touch "$CLIENT" "$TICKET" "$MACHINE" "$WORKDIR/decrypt-resume.out"; then
  cat "$WORKDIR/decrypt-resume.out" "$WORKDIR/decrypt-resume.err" >&2
  fail "resume after stale-helper decrypt crash"
fi
grep -q 'FRP client setup complete' "$WORKDIR/decrypt-resume.out" || fail "resume success message"
grep -q 'Resuming incomplete zero-touch' "$WORKDIR/decrypt-resume.out" || fail "resume messaging"
if grep -q bootstrap_redeem "$WORKDIR/decrypt-resume.out.hook"; then
  fail "resume must not redeem bootstrap ticket"
fi
[[ -f "$CLIENT/etc/frp/client-state.json" ]] || fail "client-state missing after resume"
[[ ! -f "$JOURNAL" ]] || fail "recovery journal should be deleted after success"
ID_KEY_AFTER="$(sha256sum "$CLIENT/etc/frp/client-identity.key" | awk '{print $1}')"
[[ "$ID_KEY_BEFORE" == "$ID_KEY_AFTER" ]] || fail "management identity changed on resume"
pass "STALE_HELPER_DECRYPT_CRASH_RESUME"

echo "ALL PASS test-stale-helper-precedence"
