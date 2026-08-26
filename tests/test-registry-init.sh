#!/usr/bin/env bash
# Fresh v2 registry init. Does not import SSH/HTTPS-era registries.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATE=(python3 "$ROOT/server/migrate_token.py")
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }

assert_mode() {
  local path="$1" expected="$2" mode
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

# Fresh install creates schema v2 with scanned ports reserved.
A="$WORKDIR/case-a"
mkdir -p "$A"
"${MIGRATE[@]}" init-registry \
  --registry "$A/registry.json" \
  --ports '6000,6001' \
  --port-start 6000 \
  --port-end 6098 \
  --allocator-port 6099 >"$WORKDIR/case-a.out"
[[ "$(parse_kv REGISTRY_ACTION "$WORKDIR/case-a.out")" == "created" ]] || fail "CASE A action"
python3 - "$A/registry.json" <<'PY'
import json,sys
from pathlib import Path
state=json.loads(Path(sys.argv[1]).read_text())
assert state.get('schema_version') == 2
assert state.get('reserved') == [6000, 6001]
assert state.get('clients') == {}
assert 'ssh_port' not in json.dumps(state)
assert 'https_port' not in json.dumps(state)
PY
assert_mode "$A/registry.json" "0o600"
pass "REGISTRY INIT fresh v2"

# Existing v2 is left unchanged.
B="$WORKDIR/case-b"
mkdir -p "$B"
python3 - "$B/registry.json" <<'PY'
import json,sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
  'schema_version': 2,
  'reserved': [6000],
  'clients': {
    'machine-keep': {
      'hostname': 'keep-me',
      'created_at': '2026-08-26T00:00:00Z',
      'last_enrolled_at': '2026-08-26T00:00:00Z',
      'services': {
        'grafana': {
          'name': 'Grafana',
          'protocol': 'tcp',
          'local_ip': '127.0.0.1',
          'local_port': 3000,
          'remote_port': 6001,
          'preset': 'custom',
          'enabled': True,
        }
      },
    }
  },
}, indent=2, sort_keys=True)+'\n')
PY
cp "$B/registry.json" "$B/registry.before"
"${MIGRATE[@]}" init-registry \
  --registry "$B/registry.json" \
  --ports '6008,6009' \
  --port-start 6000 \
  --port-end 6098 \
  --allocator-port 6099 >"$WORKDIR/case-b.out"
[[ "$(parse_kv REGISTRY_ACTION "$WORKDIR/case-b.out")" == "unchanged" ]] || fail "CASE B action"
bytes_equal "$B/registry.before" "$B/registry.json" || fail "CASE B registry changed"
pass "REGISTRY INIT existing v2 unchanged"

# Legacy v1 registry is refused and not rewritten.
C="$WORKDIR/case-c"
mkdir -p "$C"
python3 - "$C/registry.json" <<'PY'
import json,sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
  'reserved': [6000],
  'clients': {
    'machine-old': {
      'hostname': 'old-host',
      'ssh_port': 6002,
      'https_port': 6003,
    }
  },
}, indent=2)+'\n')
PY
cp "$C/registry.json" "$C/registry.before"
if "${MIGRATE[@]}" init-registry \
  --registry "$C/registry.json" \
  --ports '6008' \
  --port-start 6000 \
  --port-end 6098 \
  --allocator-port 6099 >"$WORKDIR/case-c.out" 2>"$WORKDIR/case-c.err"; then
  fail "CASE C should reject v1 registry"
fi
grep -qi 'unsupported registry schema' "$WORKDIR/case-c.err" || fail "CASE C error message"
bytes_equal "$C/registry.before" "$C/registry.json" || fail "CASE C v1 registry rewritten"
pass "REGISTRY INIT v1 rejected"

echo
echo "REGISTRY_INIT_TEST=PASS"
