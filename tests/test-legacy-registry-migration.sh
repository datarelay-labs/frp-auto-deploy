#!/usr/bin/env bash
# Regression tests for legacy frp-port-allocator registry migration.
# Never print full client machine IDs from fixtures into summary lines beyond counts.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATE=(python3 "$ROOT/server/migrate_token.py")
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }

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

parse_kv() {
  local key="$1" file="$2"
  awk -F= -v k="$key" '$1==k {print substr($0, index($0,"=")+1); exit}' "$file"
}

bytes_equal() {
  python3 - "$1" "$2" <<'PY'
import sys
from pathlib import Path
sys.exit(0 if Path(sys.argv[1]).read_bytes() == Path(sys.argv[2]).read_bytes() else 1)
PY
}

write_legacy() {
  python3 - "$1" <<'PY'
import json,sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
  "reserved": [6000, 6001, 6099],
  "clients": {
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa": {
      "hostname": "dp-os-upgrade",
      "ssh_port": 6002,
      "https_port": None
    }
  }
}, indent=2) + "\n")
PY
}

# --- CASE A: no legacy registry + fresh install ---
A="$WORKDIR/case-a"
mkdir -p "$A/new" "$A/legacy"
A_REG="$A/new/registry.json"
A_OUT="$WORKDIR/case-a.out"
"${MIGRATE[@]}" init-registry \
  --registry "$A_REG" \
  --legacy-registry "$A/legacy/registry.json" \
  --ports '6000,6001' >"$A_OUT"
[[ "$(parse_kv REGISTRY_ACTION "$A_OUT")" == "created" ]] || fail "CASE A action"
[[ "$(parse_kv LEGACY_REGISTRY_MIGRATION "$A_OUT")" == "N/A" ]] || fail "CASE A legacy status"
python3 - "$A_REG" <<'PY'
import json,sys
from pathlib import Path
state=json.loads(Path(sys.argv[1]).read_text())
assert state.get('reserved') == [6000, 6001]
assert state.get('clients') == {}
PY
assert_mode "$A_REG" "0o600"
pass "CASE A fresh install without legacy"

# --- CASE B: legacy reserved 6000,6001,6099 + client ssh 6002 ---
B="$WORKDIR/case-b"
mkdir -p "$B/new" "$B/legacy"
write_legacy "$B/legacy/registry.json"
B_REG="$B/new/registry.json"
B_OUT="$WORKDIR/case-b.out"
"${MIGRATE[@]}" init-registry \
  --registry "$B_REG" \
  --legacy-registry "$B/legacy/registry.json" \
  --ports '' >"$B_OUT"
[[ "$(parse_kv REGISTRY_ACTION "$B_OUT")" == "migrated" ]] || fail "CASE B action"
[[ "$(parse_kv LEGACY_REGISTRY_MIGRATION "$B_OUT")" == "PASS" ]] || fail "CASE B migration"
[[ "$(parse_kv MIGRATED_CLIENTS "$B_OUT")" == "1" ]] || fail "CASE B clients"
[[ "$(parse_kv PRESERVED_PORTS "$B_OUT")" == "4" ]] || fail "CASE B ports"
BACKUP="$(parse_kv LEGACY_REGISTRY_BACKUP "$B_OUT")"
[[ -n "$BACKUP" && -f "$BACKUP" ]] || fail "CASE B backup missing"
assert_mode "$BACKUP" "0o600"
python3 - "$B_REG" <<'PY'
import json,sys
from pathlib import Path
state=json.loads(Path(sys.argv[1]).read_text())
assert state['reserved'] == [6000, 6001, 6099]
clients=state['clients']
assert len(clients) == 1
c=next(iter(clients.values()))
assert c['hostname'] == 'dp-os-upgrade'
assert c['ssh_port'] == 6002
assert c['https_port'] is None
assert c['ssh_user'] == 'root'
assert c['https_enabled'] is False
assert c.get('created_at')
assert c.get('last_enrolled_at')
# 6099 must remain reserved, never appear as a client service port
assert 6099 in state['reserved']
for client in clients.values():
    assert client.get('ssh_port') != 6099
    assert client.get('https_port') != 6099
PY
assert_mode "$B_REG" "0o600"
# Summary must not dump full machine ids
if grep -E 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$B_OUT" >/dev/null 2>&1; then
  fail "CASE B leaked full client id"
fi
pass "CASE B legacy reserved+client migration"

# --- CASE C: offline client; ACTIVE_PORTS omits 6002 ---
C="$WORKDIR/case-c"
mkdir -p "$C/new" "$C/legacy"
write_legacy "$C/legacy/registry.json"
C_REG="$C/new/registry.json"
C_OUT="$WORKDIR/case-c.out"
"${MIGRATE[@]}" init-registry \
  --registry "$C_REG" \
  --legacy-registry "$C/legacy/registry.json" \
  --ports '6000,6001' >"$C_OUT"
[[ "$(parse_kv LEGACY_REGISTRY_MIGRATION "$C_OUT")" == "PASS" ]] || fail "CASE C migration"
python3 - "$C_REG" <<'PY'
import json,sys
from pathlib import Path
state=json.loads(Path(sys.argv[1]).read_text())
used=set(int(x) for x in state.get('reserved', []))
for c in state.get('clients', {}).values():
    for k in ('ssh_port', 'https_port'):
        if c.get(k) is not None:
            used.add(int(c[k]))
assert 6002 in used, 'offline client port 6002 must stay reserved/used'
assert any(c.get('ssh_port') == 6002 for c in state['clients'].values())
PY
pass "CASE C offline port preservation"

# --- CASE D: SSH + HTTPS ports both preserved ---
D="$WORKDIR/case-d"
mkdir -p "$D/new" "$D/legacy"
python3 - "$D/legacy/registry.json" <<'PY'
import json
from pathlib import Path
import sys
Path(sys.argv[1]).write_text(json.dumps({
  "reserved": [6000],
  "clients": {
    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb": {
      "hostname": "dual-port-host",
      "ssh_port": 6002,
      "https_port": 6003
    }
  }
}, indent=2) + "\n")
PY
D_REG="$D/new/registry.json"
D_OUT="$WORKDIR/case-d.out"
"${MIGRATE[@]}" init-registry \
  --registry "$D_REG" \
  --legacy-registry "$D/legacy/registry.json" \
  --ports '' >"$D_OUT"
[[ "$(parse_kv LEGACY_REGISTRY_MIGRATION "$D_OUT")" == "PASS" ]] || fail "CASE D migration"
[[ "$(parse_kv MIGRATED_CLIENTS "$D_OUT")" == "1" ]] || fail "CASE D clients"
[[ "$(parse_kv PRESERVED_PORTS "$D_OUT")" == "3" ]] || fail "CASE D ports"
python3 - "$D_REG" <<'PY'
import json,sys
from pathlib import Path
state=json.loads(Path(sys.argv[1]).read_text())
c=next(iter(state['clients'].values()))
assert c['ssh_port'] == 6002
assert c['https_port'] == 6003
assert c['https_enabled'] is True
assert c['hostname'] == 'dual-port-host'
PY
pass "CASE D SSH+HTTPS preservation"

# --- CASE E: new registry already exists; prefer it over legacy ---
E="$WORKDIR/case-e"
mkdir -p "$E/new" "$E/legacy"
write_legacy "$E/legacy/registry.json"
E_REG="$E/new/registry.json"
python3 - "$E_REG" <<'PY'
import json
from pathlib import Path
import sys
Path(sys.argv[1]).write_text(json.dumps({
  "reserved": [6010],
  "clients": {
    "cccccccccccccccccccccccccccccccccccc": {
      "hostname": "already-migrated",
      "ssh_user": "root",
      "ssh_port": 6011,
      "https_port": None,
      "https_enabled": False,
      "https_ip": "",
      "created_at": "2020-01-01T00:00:00Z",
      "last_enrolled_at": "2020-01-01T00:00:00Z"
    }
  }
}, indent=2, sort_keys=True) + "\n")
PY
cp "$E_REG" "$WORKDIR/case-e.before"
E_OUT="$WORKDIR/case-e.out"
"${MIGRATE[@]}" init-registry \
  --registry "$E_REG" \
  --legacy-registry "$E/legacy/registry.json" \
  --ports '6000,6001,6002' >"$E_OUT"
[[ "$(parse_kv REGISTRY_ACTION "$E_OUT")" == "unchanged" ]] || fail "CASE E action"
[[ "$(parse_kv LEGACY_REGISTRY_MIGRATION "$E_OUT")" == "SKIP" ]] || fail "CASE E skip"
bytes_equal "$WORKDIR/case-e.before" "$E_REG" || fail "CASE E new registry changed"
python3 - "$E_REG" <<'PY'
import json,sys
from pathlib import Path
state=json.loads(Path(sys.argv[1]).read_text())
assert state['reserved'] == [6010]
assert list(state['clients'].values())[0]['ssh_port'] == 6011
assert 6002 not in state['reserved']
PY
pass "CASE E existing new registry wins"

# --- CASE F: installer rerun keeps registry completely ---
F="$WORKDIR/case-f"
mkdir -p "$F/new" "$F/legacy"
write_legacy "$F/legacy/registry.json"
F_REG="$F/new/registry.json"
F_OUT1="$WORKDIR/case-f.1.out"
F_OUT2="$WORKDIR/case-f.2.out"
"${MIGRATE[@]}" init-registry \
  --registry "$F_REG" \
  --legacy-registry "$F/legacy/registry.json" \
  --ports '6000' >"$F_OUT1"
cp "$F_REG" "$WORKDIR/case-f.after-first"
"${MIGRATE[@]}" init-registry \
  --registry "$F_REG" \
  --legacy-registry "$F/legacy/registry.json" \
  --ports '6088,6089' >"$F_OUT2"
[[ "$(parse_kv REGISTRY_ACTION "$F_OUT1")" == "migrated" ]] || fail "CASE F first action"
[[ "$(parse_kv LEGACY_REGISTRY_MIGRATION "$F_OUT1")" == "PASS" ]] || fail "CASE F first migration"
[[ "$(parse_kv REGISTRY_ACTION "$F_OUT2")" == "unchanged" ]] || fail "CASE F rerun action"
[[ "$(parse_kv LEGACY_REGISTRY_MIGRATION "$F_OUT2")" == "SKIP" ]] || fail "CASE F rerun skip"
bytes_equal "$WORKDIR/case-f.after-first" "$F_REG" || fail "CASE F registry changed on rerun"
python3 - "$F_REG" <<'PY'
import json,sys
from pathlib import Path
state=json.loads(Path(sys.argv[1]).read_text())
assert 6002 in {c.get('ssh_port') for c in state['clients'].values()}
assert 6088 not in state['reserved']
assert 6089 not in state['reserved']
PY
pass "CASE F installer rerun idempotent"

echo
echo "LEGACY_REGISTRY_MIGRATION_TEST=PASS"
echo "OFFLINE_PORT_PRESERVATION_TEST=PASS"
echo "RERUN_IDEMPOTENCY_TEST=PASS"
