#!/usr/bin/env bash
# Regression tests for legacy /var/lib/frp-port-allocator registry migration.
# Do not print machine IDs or token material.
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

init_reg() {
  local registry="$1" legacy="$2" ports="$3" out="$4"
  "${MIGRATE[@]}" init-registry \
    --registry "$registry" \
    --legacy-registry "$legacy" \
    --ports "$ports" \
    --port-start 6000 \
    --port-end 6098 \
    --allocator-port 6099 >"$out"
}

bytes_equal() {
  python3 - "$1" "$2" <<'PY'
import sys
from pathlib import Path
sys.exit(0 if Path(sys.argv[1]).read_bytes() == Path(sys.argv[2]).read_bytes() else 1)
PY
}

# --- CASE A: no legacy registry, fresh install ---
A="$WORKDIR/case-a"
mkdir -p "$A"
init_reg "$A/registry.json" "$A/missing-legacy.json" '6000,6001' "$WORKDIR/case-a.out"
[[ "$(parse_kv REGISTRY_ACTION "$WORKDIR/case-a.out")" == "created" ]] || fail "CASE A action"
[[ "$(parse_kv LEGACY_REGISTRY_MIGRATION "$WORKDIR/case-a.out")" == "N/A" ]] || fail "CASE A legacy"
[[ "$(parse_kv MIGRATED_CLIENTS "$WORKDIR/case-a.out")" == "0" ]] || fail "CASE A clients"
python3 - "$A/registry.json" <<'PY'
import json,sys
from pathlib import Path
state=json.loads(Path(sys.argv[1]).read_text())
assert state.get('reserved') == [6000, 6001]
assert state.get('clients') == {}
PY
assert_mode "$A/registry.json" "0o600"
pass "REGISTRY CASE A fresh install"

# --- CASE B: migrate reserved 6000/6001/6099 and client ssh 6002 ---
B="$WORKDIR/case-b"
mkdir -p "$B"
python3 - "$B/legacy.json" <<'PY'
import json,sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
  'reserved': [6000, 6001, 6099],
  'clients': {
    'machine-dp-os-upgrade': {
      'hostname': 'dp-os-upgrade',
      'ssh_port': 6002,
      'https_port': None,
    }
  },
}, indent=2)+'\n')
PY
init_reg "$B/registry.json" "$B/legacy.json" '' "$WORKDIR/case-b.out"
[[ "$(parse_kv REGISTRY_ACTION "$WORKDIR/case-b.out")" == "migrated_legacy" ]] || fail "CASE B action"
[[ "$(parse_kv LEGACY_REGISTRY_MIGRATION "$WORKDIR/case-b.out")" == "PASS" ]] || fail "CASE B migration"
[[ "$(parse_kv MIGRATED_CLIENTS "$WORKDIR/case-b.out")" == "1" ]] || fail "CASE B clients"
[[ "$(parse_kv PRESERVED_PORTS "$WORKDIR/case-b.out")" == "3" ]] || fail "CASE B preserved ports"
if grep -E 'machine-dp-os-upgrade|dp-os-upgrade' "$WORKDIR/case-b.out" >/dev/null; then
  fail "CASE B leaked client identifiers"
fi
python3 - "$B/registry.json" <<'PY'
import json,sys
from pathlib import Path
state=json.loads(Path(sys.argv[1]).read_text())
assert state['reserved'] == [6000, 6001]
assert 6099 not in state['reserved']
clients=state['clients']
assert len(clients) == 1
client=next(iter(clients.values()))
assert client['hostname'] == 'dp-os-upgrade'
assert client['ssh_port'] == 6002
assert client.get('https_port') is None
assert client.get('ssh_user') == 'root'
assert client.get('https_enabled') is False
assert 'created_at' in client
assert client['ssh_port'] not in (6099,)
PY
backup="$(python3 - "$B" <<'PY'
from pathlib import Path
import sys
matches=sorted(Path(sys.argv[1]).glob('legacy.json.pre-frp-auto-deploy-*'))
print(matches[0] if matches else '')
PY
)"
[[ -n "$backup" && -f "$backup" ]] || fail "CASE B backup missing"
assert_mode "$backup" "0o600"
pass "REGISTRY CASE B legacy reserved and client"

# --- CASE C: offline client port 6002 is kept without ACTIVE_PORTS ---
C="$WORKDIR/case-c"
mkdir -p "$C"
python3 - "$C/legacy.json" <<'PY'
import json,sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
  'reserved': [6000, 6001],
  'clients': {
    'machine-offline': {
      'hostname': 'offline-host',
      'ssh_port': 6002,
      'https_port': None,
    }
  },
})+'\n')
PY
init_reg "$C/registry.json" "$C/legacy.json" '' "$WORKDIR/case-c.out"
[[ "$(parse_kv LEGACY_REGISTRY_MIGRATION "$WORKDIR/case-c.out")" == "PASS" ]] || fail "CASE C migration"
python3 - "$C/registry.json" <<'PY'
import json,sys
from pathlib import Path
state=json.loads(Path(sys.argv[1]).read_text())
used=set(state.get('reserved') or [])
for client in state.get('clients', {}).values():
    if client.get('ssh_port'):
        used.add(int(client['ssh_port']))
    if client.get('https_port'):
        used.add(int(client['https_port']))
assert 6002 in used
assert next(iter(state['clients'].values()))['ssh_port'] == 6002
PY
pass "REGISTRY CASE C offline port preserved"

# --- CASE D: SSH + HTTPS 6002/6003 both kept ---
D="$WORKDIR/case-d"
mkdir -p "$D"
python3 - "$D/legacy.json" <<'PY'
import json,sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
  'reserved': [6000],
  'clients': {
    'machine-https': {
      'hostname': 'dual-host',
      'ssh_port': 6002,
      'https_port': 6003,
    }
  },
})+'\n')
PY
init_reg "$D/registry.json" "$D/legacy.json" '6001' "$WORKDIR/case-d.out"
[[ "$(parse_kv MIGRATED_CLIENTS "$WORKDIR/case-d.out")" == "1" ]] || fail "CASE D clients"
python3 - "$D/registry.json" <<'PY'
import json,sys
from pathlib import Path
state=json.loads(Path(sys.argv[1]).read_text())
client=next(iter(state['clients'].values()))
assert client['ssh_port'] == 6002
assert client['https_port'] == 6003
assert client.get('https_enabled') is True
assert 6000 in state['reserved']
assert 6001 in state['reserved']
used=set(state['reserved'])
used.add(client['ssh_port'])
used.add(client['https_port'])
assert used == {6000, 6001, 6002, 6003}
PY
[[ "$(parse_kv PRESERVED_PORTS "$WORKDIR/case-d.out")" == "4" ]] || fail "CASE D preserved ports"
pass "REGISTRY CASE D ssh and https ports"

# --- CASE E: existing new registry wins over legacy ---
E="$WORKDIR/case-e"
mkdir -p "$E"
python3 - "$E/registry.json" "$E/legacy.json" <<'PY'
import json,sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
  'reserved': [6010],
  'clients': {
    'machine-new': {
      'hostname': 'already-migrated',
      'ssh_user': 'aella',
      'ssh_port': 6010,
      'https_port': None,
      'https_enabled': False,
      'https_ip': '',
    }
  },
}, indent=2, sort_keys=True)+'\n')
Path(sys.argv[2]).write_text(json.dumps({
  'reserved': [6000, 6001, 6099],
  'clients': {
    'machine-legacy': {
      'hostname': 'should-not-import',
      'ssh_port': 6002,
    }
  },
})+'\n')
PY
cp "$E/registry.json" "$E/registry.before"
init_reg "$E/registry.json" "$E/legacy.json" '6008' "$WORKDIR/case-e.out"
[[ "$(parse_kv REGISTRY_ACTION "$WORKDIR/case-e.out")" == "unchanged" ]] || fail "CASE E action"
[[ "$(parse_kv LEGACY_REGISTRY_MIGRATION "$WORKDIR/case-e.out")" == "SKIP" ]] || fail "CASE E skip"
[[ "$(parse_kv MIGRATED_CLIENTS "$WORKDIR/case-e.out")" == "0" ]] || fail "CASE E clients"
bytes_equal "$E/registry.before" "$E/registry.json" || fail "CASE E new registry changed"
python3 - "$E/registry.json" <<'PY'
import json,sys
from pathlib import Path
state=json.loads(Path(sys.argv[1]).read_text())
assert 'machine-legacy' not in state['clients']
assert list(state['clients']) == ['machine-new']
assert next(iter(state['clients'].values()))['ssh_port'] == 6010
PY
pass "REGISTRY CASE E existing new registry preferred"

# --- CASE F: rerun keeps the migrated registry ---
F="$WORKDIR/case-f"
mkdir -p "$F"
python3 - "$F/legacy.json" <<'PY'
import json,sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
  'reserved': [6000, 6001, 6099],
  'clients': {
    'machine-keep': {
      'hostname': 'keep-me',
      'ssh_port': 6002,
      'https_port': 6004,
    }
  },
})+'\n')
PY
init_reg "$F/registry.json" "$F/legacy.json" '6000' "$WORKDIR/case-f.1.out"
cp "$F/registry.json" "$F/registry.after-first"
init_reg "$F/registry.json" "$F/legacy.json" '6008,6009' "$WORKDIR/case-f.2.out"
[[ "$(parse_kv REGISTRY_ACTION "$WORKDIR/case-f.2.out")" == "unchanged" ]] || fail "CASE F rerun action"
[[ "$(parse_kv LEGACY_REGISTRY_MIGRATION "$WORKDIR/case-f.2.out")" == "SKIP" ]] || fail "CASE F rerun skip"
bytes_equal "$F/registry.after-first" "$F/registry.json" || fail "CASE F registry changed on rerun"
python3 - "$F/registry.json" <<'PY'
import json,sys
from pathlib import Path
state=json.loads(Path(sys.argv[1]).read_text())
client=next(iter(state['clients'].values()))
assert client['ssh_port'] == 6002
assert client['https_port'] == 6004
assert 6008 not in state['reserved']
assert 6099 not in state['reserved']
PY
pass "REGISTRY CASE F installer rerun"

echo
echo "LEGACY_REGISTRY_MIGRATION_TEST=PASS"
echo "OFFLINE_PORT_PRESERVATION_TEST=PASS"
echo "RERUN_IDEMPOTENCY_TEST=PASS"
