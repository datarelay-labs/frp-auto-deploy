#!/usr/bin/env bash
# Public vs internal port model, NAT summary, and generated configs.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }

reset_env() {
  unset FRP_PUBLIC_IP FRP_PUBLIC_HOST FRP_INTERNAL_IP FRP_CONTROL_PORT \
    FRP_CONTROL_PUBLIC_PORT FRP_CONTROL_LISTEN_PORT \
    FRP_PORT_START FRP_PORT_END FRP_ALLOCATOR_PORT \
    FRP_ALLOCATOR_PUBLIC_PORT FRP_ALLOCATOR_LISTEN_PORT \
    FRP_ALLOCATOR_URL FRP_ALLOCATOR_PUBLIC_URL FRP_CLIENT_INSTALLER_URL \
    FRP_SERVER_CONFIG DETECTED_PUBLIC_IP DETECTED_INTERNAL_IP \
    CLIENT_INSTALLER_URL || true
}

export FRP_SERVER_SOURCED=1
# shellcheck source=../install-server.sh
. "$ROOT/install-server.sh"

assert_ports() {
  local label="$1"
  [[ "$FRP_CONTROL_PUBLIC_PORT" == "$2" ]] || fail "$label control public"
  [[ "$FRP_CONTROL_LISTEN_PORT" == "$3" ]] || fail "$label control listen"
  [[ "$FRP_ALLOCATOR_PUBLIC_PORT" == "$4" ]] || fail "$label allocator public"
  [[ "$FRP_ALLOCATOR_LISTEN_PORT" == "$5" ]] || fail "$label allocator listen"
}

reset_env
export FRP_PUBLIC_HOST=203.0.113.10
export FRP_CONTROL_PUBLIC_PORT=443
export FRP_CONTROL_LISTEN_PORT=443
export FRP_SERVER_CONFIG="$WORKDIR/missing.json"
load_existing_server_config
resolve_server_settings >/dev/null
assert_ports "direct FRP" 443 443 6099 6099
pass "direct FRP public 443 / listen 443"

reset_env
export FRP_PUBLIC_HOST=203.0.113.10
export FRP_CONTROL_PUBLIC_PORT=8443
export FRP_CONTROL_LISTEN_PORT=443
export FRP_SERVER_CONFIG="$WORKDIR/missing.json"
load_existing_server_config
resolve_server_settings >/dev/null
assert_ports "NAT FRP" 8443 443 6099 6099
pass "NAT FRP public 8443 / listen 443"

reset_env
export FRP_PUBLIC_HOST=203.0.113.10
export FRP_CONTROL_PUBLIC_PORT=8443
export FRP_CONTROL_LISTEN_PORT=8443
export FRP_SERVER_CONFIG="$WORKDIR/missing.json"
load_existing_server_config
resolve_server_settings >/dev/null
assert_ports "direct 8443" 8443 8443 6099 6099
pass "FRP public 8443 / listen 8443"

reset_env
export FRP_PUBLIC_HOST=203.0.113.10
export FRP_ALLOCATOR_PUBLIC_PORT=6099
export FRP_ALLOCATOR_LISTEN_PORT=6099
export FRP_SERVER_CONFIG="$WORKDIR/missing.json"
load_existing_server_config
resolve_server_settings >/dev/null
assert_ports "direct allocator" 443 443 6099 6099
[[ "$FRP_ALLOCATOR_PUBLIC_URL" == 'https://203.0.113.10:6099/enroll' ]] || fail "direct allocator URL"
pass "direct allocator public 6099 / listen 6099"

reset_env
export FRP_PUBLIC_HOST=203.0.113.10
export FRP_ALLOCATOR_PUBLIC_PORT=9443
export FRP_ALLOCATOR_LISTEN_PORT=6099
export FRP_SERVER_CONFIG="$WORKDIR/missing.json"
load_existing_server_config
resolve_server_settings >/dev/null
assert_ports "NAT allocator" 443 443 9443 6099
[[ "$FRP_ALLOCATOR_PUBLIC_URL" == 'https://203.0.113.10:9443/enroll' ]] || fail "NAT allocator URL"
pass "NAT allocator public 9443 / listen 6099"

reset_env
export FRP_PUBLIC_HOST=203.0.113.10
export FRP_CONTROL_PUBLIC_PORT=8443
export FRP_CONTROL_LISTEN_PORT=8443
export FRP_ALLOCATOR_PUBLIC_PORT=443
export FRP_ALLOCATOR_LISTEN_PORT=6099
export FRP_SERVER_CONFIG="$WORKDIR/missing.json"
load_existing_server_config
resolve_server_settings >/dev/null
assert_ports "allocator public 443" 8443 8443 443 6099
[[ "$FRP_ALLOCATOR_PUBLIC_URL" == 'https://203.0.113.10/enroll' ]] || fail "allocator public 443 URL omits port"
pass "allocator public 443 / listen 6099 with FRP elsewhere"

# write_server_config consumers
reset_env
export FRP_PUBLIC_HOST=203.0.113.10
export FRP_CONTROL_PUBLIC_PORT=8443
export FRP_CONTROL_LISTEN_PORT=443
export FRP_ALLOCATOR_PUBLIC_PORT=9443
export FRP_ALLOCATOR_LISTEN_PORT=6099
export FRP_INTERNAL_IP=192.0.2.50
export FRP_SERVER_CONFIG="$WORKDIR/written.json"
load_existing_server_config
resolve_server_settings >/dev/null
write_server_config
python3 - "$FRP_SERVER_CONFIG" <<'PY' || fail "written config fields"
import json, sys
from pathlib import Path
cfg = json.loads(Path(sys.argv[1]).read_text())
assert cfg['public_host'] == '203.0.113.10'
assert cfg['frp_control_public_port'] == 8443
assert cfg['frp_control_listen_port'] == 443
assert cfg['allocator_public_port'] == 9443
assert cfg['allocator_listen_port'] == 6099
assert cfg['listen_port'] == 6099
assert cfg['allocator_public_url'] == 'https://203.0.113.10:9443/enroll'
assert 'control_port' not in cfg
PY
pass "generated config keeps public/listen distinct"

# NAT summary uses public endpoints and internal listen ports.
reset_env
export FRP_PUBLIC_HOST=203.0.113.10
export FRP_CONTROL_PUBLIC_PORT=8443
export FRP_CONTROL_LISTEN_PORT=443
export FRP_ALLOCATOR_PUBLIC_PORT=9443
export FRP_ALLOCATOR_LISTEN_PORT=6099
export FRP_INTERNAL_IP=192.0.2.50
export FRP_PORT_START=6000
export FRP_PORT_END=6098
export FRP_ALLOCATOR_PUBLIC_URL='https://203.0.113.10:9443/enroll'
frp_print_nat_summary >"$WORKDIR/nat.out"
grep -q '203.0.113.10:8443' "$WORKDIR/nat.out" || fail "NAT summary FRP public"
grep -q '192.0.2.50:443' "$WORKDIR/nat.out" || fail "NAT summary FRP listen"
grep -q '203.0.113.10:9443' "$WORKDIR/nat.out" || fail "NAT summary allocator public"
grep -q '192.0.2.50:6099' "$WORKDIR/nat.out" || fail "NAT summary allocator listen"
grep -q '6000-6098' "$WORKDIR/nat.out" || fail "NAT summary service range"
grep -q '1:1' "$WORKDIR/nat.out" || fail "NAT summary 1:1 services"
if grep -q '192.0.2.50:8443' "$WORKDIR/nat.out"; then
  fail "NAT summary showed internal host with public FRP port"
fi
pass "installer summary shows public -> internal mapping"

# Public port collision warns, does not fail.
reset_env
export FRP_PUBLIC_HOST=203.0.113.10
export FRP_CONTROL_PUBLIC_PORT=443
export FRP_ALLOCATOR_PUBLIC_PORT=443
export FRP_CONTROL_LISTEN_PORT=8443
export FRP_ALLOCATOR_LISTEN_PORT=6099
export FRP_SERVER_CONFIG="$WORKDIR/missing.json"
load_existing_server_config
resolve_server_settings >"$WORKDIR/share.out" 2>"$WORKDIR/share.err"
grep -qi 'proxy' "$WORKDIR/share.err" || fail "public port share warning"
pass "public FRP/allocator same port warns"

# CA is not rotated when only ports change.
PKI="$WORKDIR/pki"
python3 "$ROOT/lib/frp_pki.py" ensure --pki-dir "$PKI" --public-host 203.0.113.10 >/dev/null
FP1="$(python3 "$ROOT/lib/frp_pki.py" fingerprint --cert "$PKI/ca.crt")"
python3 "$ROOT/lib/frp_pki.py" ensure --pki-dir "$PKI" --public-host 203.0.113.10 >/dev/null
FP2="$(python3 "$ROOT/lib/frp_pki.py" fingerprint --cert "$PKI/ca.crt")"
[[ "$FP1" == "$FP2" ]] || fail "ensure reused rotated CA"
pass "changing only public/listen ports does not regenerate CA"

# Allocator listen overlap with service range is rejected.
reset_env
if (
  export FRP_PUBLIC_HOST=203.0.113.10
  export FRP_ALLOCATOR_LISTEN_PORT=6002
  export FRP_PORT_START=6000
  export FRP_PORT_END=6098
  export FRP_SERVER_CONFIG="$WORKDIR/missing.json"
  load_existing_server_config
  resolve_server_settings
) >/dev/null 2>"$WORKDIR/range.err"; then
  fail "allocator listen in service range should fail"
fi
grep -qi 'outside' "$WORKDIR/range.err" || fail "range overlap message"
pass "service range collision protection preserved"

# No hard-coded product requirement that FRP owns TCP/443.
if grep -nE 'FRP must (own|use|bind).*443|require.*TCP/443|hard.?coded.*443' "$ROOT/install-server.sh"; then
  fail "installer still treats 443 as mandatory"
fi
grep -q 'Public control port' "$ROOT/install-server.sh" || fail "missing public control prompt"
grep -q 'Internal listen port' "$ROOT/install-server.sh" || fail "missing listen prompt"
pass "no fixed TCP/443 product requirement"

echo
echo "PORT_ARCHITECTURE_TEST=PASS"
