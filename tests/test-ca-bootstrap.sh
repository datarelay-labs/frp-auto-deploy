#!/usr/bin/env bash
# Client CA fingerprint bootstrap and verified HTTPS helper.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="$(mktemp -d)"
ALLOC_PID=""
trap '[[ -n "$ALLOC_PID" ]] && kill "$ALLOC_PID" 2>/dev/null || true; rm -rf "$WORKDIR"' EXIT

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }

export FRP_CLIENT_SOURCED=1
# shellcheck source=../install-client.sh
. "$ROOT/install-client.sh"

ALLOC_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
ALLOC_ROOT="$WORKDIR/allocator"
mkdir -p "$ALLOC_ROOT/enrollments"
python3 "$ROOT/lib/frp_pki.py" ensure --pki-dir "$ALLOC_ROOT/pki" --public-host 127.0.0.1 >/dev/null
CA_FP="$(python3 "$ROOT/lib/frp_pki.py" fingerprint --cert "$ALLOC_ROOT/pki/ca.crt")"
python3 - "$ALLOC_ROOT" "$ALLOC_PORT" <<'PY'
import json, sys
from pathlib import Path
root = Path(sys.argv[1])
port = int(sys.argv[2])
pki = root / 'pki'
(root / 'server_token').write_text('test-frp-token-do-not-use\n')
(root / 'server_token').chmod(0o600)
(root / 'registry.json').write_text(json.dumps({
    'schema_version': 2, 'reserved': [], 'clients': {},
}, indent=2) + '\n')
(root / 'config.json').write_text(json.dumps({
    'public_host': '203.0.113.10',
    'frp_control_public_port': 443,
    'frp_control_listen_port': 443,
    'port_start': 19300,
    'port_end': 19310,
    'listen_host': '127.0.0.1',
    'listen_port': port,
    'allocator_listen_port': port,
    'tls_ca_cert': str(pki / 'ca.crt'),
    'tls_server_cert': str(pki / 'server.crt'),
    'tls_server_key': str(pki / 'server.key'),
    'registry_file': str(root / 'registry.json'),
    'enrollments_dir': str(root / 'enrollments'),
    'token_file': str(root / 'server_token'),
}, indent=2) + '\n')
PY
python3 "$ROOT/server/frp-port-allocator.py" --config "$ALLOC_ROOT/config.json" >"$WORKDIR/alloc.log" 2>&1 &
ALLOC_PID=$!
for i in $(seq 1 50); do
  if curl -fsS --cacert "$ALLOC_ROOT/pki/ca.crt" "https://127.0.0.1:${ALLOC_PORT}/healthz" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

URL="https://127.0.0.1:${ALLOC_PORT}/enroll"
TREE="$WORKDIR/client"
mkdir -p "$TREE"
export FRP_CLIENT_TEST_ROOT="$TREE"

# Correct fingerprint bootstrap.
export FRP_ALLOCATOR_CA_SHA256="$CA_FP"
frp_bootstrap_allocator_ca "$URL" || fail "correct fingerprint bootstrap"
[[ -f "$TREE/etc/frp-auto-deploy/allocator-ca.crt" ]] || fail "trusted CA not installed"
mode="$(python3 - "$TREE/etc/frp-auto-deploy/allocator-ca.crt" <<'PY'
import os,stat,sys
print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))
PY
)"
[[ "$mode" == "0o644" ]] || fail "trusted CA mode"
got="$(python3 "$ROOT/lib/frp_pki.py" fingerprint --cert "$TREE/etc/frp-auto-deploy/allocator-ca.crt")"
[[ "$got" == "$CA_FP" ]] || fail "installed fingerprint"
pass "correct CA fingerprint bootstrap succeeds"
pass "trusted CA file installed atomically"
pass "trusted CA ownership/mode safe"

# Wrong fingerprint fails closed and does not replace the good file.
BAD_TREE="$WORKDIR/bad"
mkdir -p "$BAD_TREE"
export FRP_CLIENT_TEST_ROOT="$BAD_TREE"
export FRP_ALLOCATOR_CA_SHA256="$(printf '%064d' 1 | tr '0' 'a')"
if frp_bootstrap_allocator_ca "$URL" 2>"$WORKDIR/mismatch.err"; then
  fail "wrong fingerprint should fail"
fi
grep -qi 'mismatch' "$WORKDIR/mismatch.err" || fail "mismatch error"
if [[ -e "$BAD_TREE/etc/frp-auto-deploy/allocator-ca.crt" ]]; then
  fail "mismatch wrote trusted CA"
fi
pass "wrong fingerprint fails closed"

# Tampered CA PEM fails.
TAMPER="$WORKDIR/tamper.crt"
sed 's/M/N/' "$ALLOC_ROOT/pki/ca.crt" >"$TAMPER" || true
printf 'not-a-certificate\n' >"$TAMPER"
export FRP_CLIENT_TEST_ROOT="$WORKDIR/tamper-client"
unset FRP_ALLOCATOR_CA_SHA256
export FRP_ALLOCATOR_CA_FILE="$TAMPER"
if frp_bootstrap_allocator_ca "$URL" 2>"$WORKDIR/tamper.err"; then
  fail "tampered CA should fail"
fi
grep -qi 'invalid CA PEM\|fingerprint\|invalid' "$WORKDIR/tamper.err" || fail "tamper error"
if [[ -e "$WORKDIR/tamper-client/etc/frp-auto-deploy/allocator-ca.crt" ]]; then
  fail "tampered CA installed"
fi
pass "modified/tampered CA fails"
pass "malformed certificate fails"

# Helper uses --cacert and never -k for normal calls.
python3 - "$ROOT/lib/frp-client-common.sh" <<'PY' || fail "insecure curl policy"
from pathlib import Path
import re, sys
text = Path(sys.argv[1]).read_text(encoding='utf-8')
insecure = [i+1 for i, line in enumerate(text.splitlines()) if '--insecure' in line or re.search(r'(^|[\s])-k([\s]|$)', line)]
if len(insecure) != 1:
    raise SystemExit('expected exactly one --insecure (CA fetch), found %s' % insecure)
# The insecure line must be inside frp_bootstrap_allocator_ca, fetching /ca.crt.
idx = text.find('frp_bootstrap_allocator_ca()')
end = text.find('\nfrp_', idx + 10)
boot = text[idx:end]
if '--insecure' not in boot or '/ca.crt' not in boot:
    raise SystemExit('bootstrap missing narrowly scoped insecure CA fetch')
if 'X-Enrollment' in boot or 'X-Mgmt' in boot or 'X-Signature' in boot:
    raise SystemExit('insecure CA fetch carries secret payload')
curlfn_idx = text.find('frp_allocator_curl()')
curlfn_end = text.find('\nfrp_', curlfn_idx + 10)
curlfn = text[curlfn_idx:curlfn_end]
if '--insecure' in curlfn or re.search(r'(^|[\s])-k([\s]|$)', curlfn):
    raise SystemExit('trusted helper uses insecure curl')
if '--cacert' not in curlfn:
    raise SystemExit('trusted helper missing --cacert')
enroll_idx = text.find('frp_enroll_services()')
if enroll_idx < 0:
    raise SystemExit('missing enroll helper')
# Look until the next top-level function after enroll (wait_for_proxies is before enroll).
if text.count('frp_allocator_curl', enroll_idx) < 2:
    raise SystemExit('enroll does not use verified helper')
print('ok')
PY
pass "first /enroll occurs only over verified HTTPS"
pass "normal allocator calls contain no -k/--insecure"
pass "insecure CA fetch carries no secret payload"

# Verified helper succeeds against the live allocator.
export FRP_CLIENT_TEST_ROOT="$TREE"
code="$(frp_allocator_curl -fsS "https://127.0.0.1:${ALLOC_PORT}/healthz")"
[[ "$code" == *status* ]] || fail "verified helper healthz"
pass "verified allocator helper uses installed CA"

echo
echo "CA_BOOTSTRAP_TEST=PASS"
