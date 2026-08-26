#!/usr/bin/env bash
# Regression tests for FRP server token/registry migration.
# Fixture token values are never printed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATE=(python3 "$ROOT/server/migrate_token.py")
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }

bytes_equal() {
  python3 - "$1" "$2" <<'PY'
import sys
from pathlib import Path
a=Path(sys.argv[1]).read_bytes()
b=Path(sys.argv[2]).read_bytes()
sys.exit(0 if a==b else 1)
PY
}

semantic_equal() {
  python3 - "$1" "$2" <<'PY'
import sys
from pathlib import Path
a=Path(sys.argv[1]).read_bytes().strip()
b=Path(sys.argv[2]).read_bytes().strip()
sys.exit(0 if a==b else 1)
PY
}

assert_mode() {
  local path="$1" expected="$2"
  local mode
  mode="$(python3 - "$path" <<'PY'
import os,stat,sys
print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))
PY
)"
  [[ "$mode" == "$expected" ]] || fail "mode $path wanted $expected got $mode"
}

assert_no_leak() {
  local log="$1"
  shift
  local needle
  for needle in "$@"; do
    if grep -F -- "$needle" "$log" >/dev/null 2>&1; then
      fail "secret fixture leaked to command output"
    fi
  done
}

parse_kv() {
  local key="$1" file="$2"
  awk -F= -v k="$key" '$1==k {print substr($0, index($0,"=")+1); exit}' "$file"
}

# --- CASE A: fresh install generates a new token ---
A="$WORKDIR/case-a"
mkdir -p "$A"
A_OUT="$WORKDIR/case-a.out"
"${MIGRATE[@]}" ensure --etc-dir "$A" --backup >"$A_OUT"
assert_no_leak "$A_OUT"
[[ "$(parse_kv TOKEN_ACTION "$A_OUT")" == "generated" ]] || fail "CASE A action"
[[ "$(parse_kv TOKEN_PRESERVED "$A_OUT")" == "N/A" ]] || fail "CASE A preserved"
[[ -s "$A/server_token" ]] || fail "CASE A token missing"
assert_mode "$A/server_token" "0o600"
python3 - "$A/server_token" <<'PY'
import sys
from pathlib import Path
data=Path(sys.argv[1]).read_bytes().strip()
if len(data) < 32 or any(c not in b'0123456789abcdef' for c in data.lower()):
    raise SystemExit(1)
PY
pass "CASE A fresh install"

# --- CASE B: legacy inline auth.token migrates without changing the value ---
B="$WORKDIR/case-b"
mkdir -p "$B"
B_FIXTURE="$WORKDIR/case-b.fixture"
python3 - "$B_FIXTURE" "$B/frps.toml" <<'PY'
from pathlib import Path
import sys
fixture=b'case-b-legacy-inline-token'
Path(sys.argv[1]).write_bytes(fixture)
Path(sys.argv[2]).write_text(
    'bindPort = 443\n\n'
    'auth.method = "token"\n'
    'auth.token = "case-b-legacy-inline-token"\n'
    'allowPorts = [{ start = 6000, end = 6098 }]\n',
    encoding='utf-8',
)
PY
chmod 644 "$B/frps.toml"
B_OUT="$WORKDIR/case-b.out"
"${MIGRATE[@]}" ensure --etc-dir "$B" --backup >"$B_OUT"
assert_no_leak "$B_OUT" "case-b-legacy-inline-token"
[[ "$(parse_kv TOKEN_ACTION "$B_OUT")" == "migrated_inline" ]] || fail "CASE B action"
[[ "$(parse_kv TOKEN_PRESERVED "$B_OUT")" == "PASS" ]] || fail "CASE B preserved"
semantic_equal "$B_FIXTURE" "$B/server_token" || fail "CASE B token value changed"
assert_mode "$B/server_token" "0o600"
BACKUP="$(parse_kv TOKEN_BACKUP "$B_OUT")"
[[ -n "$BACKUP" && -f "$BACKUP" ]] || fail "CASE B backup missing"
assert_mode "$BACKUP" "0o600"
pass "CASE B legacy inline token"

# --- CASE C: existing server_token is kept byte-for-byte ---
C="$WORKDIR/case-c"
mkdir -p "$C"
C_FIXTURE="$WORKDIR/case-c.fixture"
python3 - "$C_FIXTURE" "$C/server_token" <<'PY'
from pathlib import Path
import sys
data=b'case-c-existing-server-token'
Path(sys.argv[1]).write_bytes(data)
Path(sys.argv[2]).write_bytes(data)
PY
chmod 600 "$C/server_token"
C_OUT="$WORKDIR/case-c.out"
"${MIGRATE[@]}" ensure --etc-dir "$C" --backup >"$C_OUT"
assert_no_leak "$C_OUT" "case-c-existing-server-token"
[[ "$(parse_kv TOKEN_ACTION "$C_OUT")" == "reused_server_token" ]] || fail "CASE C action"
[[ "$(parse_kv TOKEN_PRESERVED "$C_OUT")" == "PASS" ]] || fail "CASE C preserved"
bytes_equal "$C_FIXTURE" "$C/server_token" || fail "CASE C token bytes changed"
pass "CASE C existing server_token"

# --- CASE D: rerun is idempotent for token and registry ---
D="$WORKDIR/case-d"
mkdir -p "$D"
D_REG="$D/registry.json"
D_OUT1="$WORKDIR/case-d.1.out"
D_OUT2="$WORKDIR/case-d.2.out"
"${MIGRATE[@]}" ensure --etc-dir "$D" --backup >"$D_OUT1"
cp "$D/server_token" "$WORKDIR/case-d.token1"
"${MIGRATE[@]}" init-registry --registry "$D_REG" --ports '6000,6001' >"$WORKDIR/case-d.reg1.out"
cp "$D_REG" "$WORKDIR/case-d.registry1"
python3 - "$D_REG" <<'PY'
import json,sys
from pathlib import Path
state=json.loads(Path(sys.argv[1]).read_text())
state['clients']={'machine-d': {
  'hostname': 'already-there',
  'created_at': '2026-08-26T00:00:00Z',
  'last_enrolled_at': '2026-08-26T00:00:00Z',
  'services': {
    'ssh': {
      'name': 'SSH',
      'protocol': 'tcp',
      'local_ip': '127.0.0.1',
      'local_port': 22,
      'remote_port': 6000,
      'preset': 'ssh',
      'enabled': True,
    }
  },
}}
Path(sys.argv[1]).write_text(json.dumps(state, indent=2, sort_keys=True)+'\n')
PY
cp "$D_REG" "$WORKDIR/case-d.registry-with-client"
"${MIGRATE[@]}" ensure --etc-dir "$D" --backup >"$D_OUT2"
"${MIGRATE[@]}" init-registry --registry "$D_REG" --ports '6002,6003' >"$WORKDIR/case-d.reg2.out"
assert_no_leak "$D_OUT1"
assert_no_leak "$D_OUT2"
[[ "$(parse_kv TOKEN_ACTION "$D_OUT2")" == "reused_server_token" ]] || fail "CASE D rerun action"
[[ "$(parse_kv TOKEN_PRESERVED "$D_OUT2")" == "PASS" ]] || fail "CASE D rerun preserved"
bytes_equal "$WORKDIR/case-d.token1" "$D/server_token" || fail "CASE D token changed on rerun"
bytes_equal "$WORKDIR/case-d.registry-with-client" "$D_REG" || fail "CASE D registry changed on rerun"
[[ "$(parse_kv REGISTRY_ACTION "$WORKDIR/case-d.reg2.out")" == "unchanged" ]] || fail "CASE D registry action"
pass "CASE D installer rerun"

# --- CASE E: published ports 6000/6001 stay reserved ---
E="$WORKDIR/case-e"
mkdir -p "$E"
E_REG="$E/registry.json"
E_OUT="$WORKDIR/case-e.out"
"${MIGRATE[@]}" init-registry --registry "$E_REG" --ports '6000,6001' >"$E_OUT"
[[ "$(parse_kv REGISTRY_ACTION "$E_OUT")" == "created" ]] || fail "CASE E created"
python3 - "$E_REG" <<'PY'
import json,sys
from pathlib import Path
state=json.loads(Path(sys.argv[1]).read_text())
if state.get('schema_version') != 2:
    raise SystemExit(1)
if state.get('reserved') != [6000, 6001]:
    raise SystemExit(1)
if state.get('clients') != {}:
    raise SystemExit(1)
if 'ssh_port' in json.dumps(state) or 'https_port' in json.dumps(state):
    raise SystemExit(1)
PY
assert_mode "$E_REG" "0o600"
# Second init must not drop reserved ports even if a different scan is supplied.
"${MIGRATE[@]}" init-registry --registry "$E_REG" --ports '6008' >/dev/null
python3 - "$E_REG" <<'PY'
import json,sys
from pathlib import Path
state=json.loads(Path(sys.argv[1]).read_text())
if state.get('reserved') != [6000, 6001]:
    raise SystemExit(1)
PY
pass "CASE E existing published ports"

# --- tokenSource file reuse (requirement 3) ---
F="$WORKDIR/case-f"
mkdir -p "$F"
python3 - "$F/custom.token" "$F/frps.toml" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[1]).write_bytes(b'case-f-tokensource-file')
Path(sys.argv[2]).write_text(
    'auth.method = "token"\n'
    'auth.tokenSource.type = "file"\n'
    f'auth.tokenSource.file.path = "{sys.argv[1]}"\n',
    encoding='utf-8',
)
PY
F_OUT="$WORKDIR/case-f.out"
"${MIGRATE[@]}" ensure --etc-dir "$F" --backup >"$F_OUT"
assert_no_leak "$F_OUT" "case-f-tokensource-file"
[[ "$(parse_kv TOKEN_ACTION "$F_OUT")" == "migrated_token_file" ]] || fail "CASE F action"
[[ "$(parse_kv TOKEN_PRESERVED "$F_OUT")" == "PASS" ]] || fail "CASE F preserved"
semantic_equal "$F/custom.token" "$F/server_token" || fail "CASE F token file value changed"
python3 - "$F/custom.token" <<'PY'
from pathlib import Path
import sys
assert Path(sys.argv[1]).read_bytes() == b'case-f-tokensource-file'
PY
pass "CASE F tokenSource file reuse"

# --- existing config without recoverable token must not generate a replacement ---
G="$WORKDIR/case-g"
mkdir -p "$G"
printf 'bindPort = 443\n' >"$G/frps.toml"
if "${MIGRATE[@]}" ensure --etc-dir "$G" --backup >"$WORKDIR/case-g.out" 2>"$WORKDIR/case-g.err"; then
  fail "CASE G should refuse to invent a token"
fi
[[ ! -e "$G/server_token" ]] || fail "CASE G must not create a new token"
pass "CASE G refuse missing existing token"

echo
echo "TOKEN_MIGRATION_TEST=PASS"
echo "FRESH_INSTALL_TEST=PASS"
echo "RERUN_IDEMPOTENCY_TEST=PASS"
echo "EXISTING_PORT_PRESERVATION_TEST=PASS"
