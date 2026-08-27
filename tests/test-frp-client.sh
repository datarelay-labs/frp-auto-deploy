#!/usr/bin/env bash
# Post-install frp-client management: state, read-only CLI, apply, rollback.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="$(mktemp -d)"
ALLOC_PID=""
trap '[[ -n "$ALLOC_PID" ]] && kill "$ALLOC_PID" 2>/dev/null || true; rm -rf "$WORKDIR"' EXIT

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }

chmod +x "$ROOT/tools/frp-client"

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

start_allocator() {
  local cfg="$1"
  python3 "$ROOT/server/frp-port-allocator.py" --config "$cfg" >"$WORKDIR/alloc.log" 2>&1 &
  ALLOC_PID=$!
  local i
  for i in $(seq 1 50); do
    if curl -fsS "http://127.0.0.1:${ALLOC_PORT}/healthz" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  cat "$WORKDIR/alloc.log" >&2 || true
  fail "allocator did not start"
}

write_enrollment() {
  local dir="$1" eid="$2" secret="$3"
  python3 - "$dir" "$eid" "$secret" <<'PY'
import json, sys, time
from pathlib import Path
d, eid, secret = sys.argv[1], sys.argv[2], sys.argv[3]
now = int(time.time())
Path(d).mkdir(parents=True, exist_ok=True)
Path(d, f'{eid}.json').write_text(json.dumps({
    'id': eid,
    'secret': secret,
    'expires_at': now + 600,
    'bound_machine_id': None,
    'used_at': None,
}, indent=2) + '\n')
PY
}

ALLOC_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
ALLOC_ROOT="$WORKDIR/allocator"
mkdir -p "$ALLOC_ROOT/enrollments"
python3 - "$ALLOC_ROOT" "$ALLOC_PORT" <<'PY'
import json, sys
from pathlib import Path
root = Path(sys.argv[1])
port = int(sys.argv[2])
(root / 'server_token').write_text('test-enroll-token-do-not-use\n')
(root / 'server_token').chmod(0o600)
(root / 'registry.json').write_text(json.dumps({
    'schema_version': 2, 'reserved': [], 'clients': {},
}, indent=2) + '\n')
(root / 'config.json').write_text(json.dumps({
    'public_ip': '203.0.113.10',
    'control_port': 443,
    'port_start': 18200,
    'port_end': 18230,
    'listen_host': '127.0.0.1',
    'listen_port': port,
    'registry_file': str(root / 'registry.json'),
    'enrollments_dir': str(root / 'enrollments'),
    'token_file': str(root / 'server_token'),
}, indent=2) + '\n')
PY
start_allocator "$ALLOC_ROOT/config.json"

EID='abcdef0123456789'
SECRET='enroll-secret-abcdef0123456789abcdef0123456789ab'
write_enrollment "$ALLOC_ROOT/enrollments" "$EID" "$SECRET"

TREE="$WORKDIR/client"
mkdir -p "$TREE/etc/frp" "$TREE/usr/local/bin" "$TREE/usr/local/lib/frp-auto-deploy"
make_frpc "$TREE/usr/local/bin/frpc"

export FRP_CLIENT_TEST_ROOT="$TREE"
export FRP_CLIENT_LIB="$ROOT/lib/frp-client-common.sh"
export FRP_SKIP_DOWNLOAD=1
export FRP_SKIP_SYSTEMD=1
export FRP_SKIP_CONNECTIVITY_CHECK=1
export FRP_TEST_HOSTNAME='dp-example'
export FRP_TEST_MACHINE_ID='aabbccddeeff00112233445566778899'
export FRP_ALLOCATOR_URL="http://127.0.0.1:${ALLOC_PORT}/enroll"
export FRP_ENROLLMENT_CODE="${EID}.${SECRET}"
export FRP_SERVICES_JSON='[{"id":"ssh","name":"SSH","protocol":"tcp","local_ip":"127.0.0.1","local_port":22,"preset":"ssh","ssh_user":"aella"}]'
export FRP_CLIENT_SOURCED=1
# shellcheck source=../install-client.sh
. "$ROOT/install-client.sh"
frp_client_main >"$WORKDIR/install.out"

STATE="$TREE/etc/frp/client-state.json"
[[ -f "$STATE" ]] || fail "client-state.json missing after install"
mode="$(python3 - "$STATE" <<'PY'
import os,stat,sys
print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))
PY
)"
[[ "$mode" == "0o600" ]] || fail "client-state mode $mode"
python3 - "$STATE" <<'PY' || fail "client-state schema"
import json,sys
from pathlib import Path
d=json.loads(Path(sys.argv[1]).read_text())
assert d['schema_version']==1
assert d['allocator_url'].startswith('http://127.0.0.1:')
assert d['frp_server']=='203.0.113.10'
assert d['hostname']=='dp-example'
assert 'ssh' in d['services']
assert d['services']['ssh']['remote_port']==18200
assert d['services']['ssh']['enabled'] is True
assert 'token' not in json.dumps(d).lower() or 'frp_server' in d
for bad in ('token_ciphertext','enrollment_code','enrollment_secret','server_token','auth.token'):
    assert bad not in json.dumps(d)
PY
frp_state_has_secrets "$STATE" || fail "secrets in client-state"
[[ -x "$TREE/usr/local/bin/frp-client" ]] || fail "frp-client not installed"
[[ -f "$TREE/usr/local/lib/frp-auto-deploy/frp-client-common.sh" ]] || fail "client lib not installed"
pass "fresh install writes client-state"

HOOK="$WORKDIR/hook.log"
: >"$HOOK"
export FRP_CLIENT_HOOK_LOG="$HOOK"
before="$(python3 - "$TREE" <<'PY'
import hashlib, os, sys
from pathlib import Path
root=Path(sys.argv[1])
h=hashlib.sha256()
for p in sorted(root.rglob('*')):
    if p.is_file():
        h.update(p.read_bytes())
print(h.hexdigest())
PY
)"
"$ROOT/tools/frp-client" status >"$WORKDIR/status.out"
"$ROOT/tools/frp-client" info >"$WORKDIR/info.out"
"$ROOT/tools/frp-client" list >"$WORKDIR/list.out"
after="$(python3 - "$TREE" <<'PY'
import hashlib, sys
from pathlib import Path
root=Path(sys.argv[1])
h=hashlib.sha256()
for p in sorted(root.rglob('*')):
    if p.is_file():
        h.update(p.read_bytes())
print(h.hexdigest())
PY
)"
[[ "$before" == "$after" ]] || fail "read-only CLI modified files"
if grep -qx enroll "$HOOK"; then fail "read-only contacted allocator"; fi
if grep -qx restart "$HOOK"; then fail "read-only restarted frpc"; fi
grep -q 'Hostname        : dp-example' "$WORKDIR/status.out" || fail "status hostname"
grep -q 'ssh' "$WORKDIR/status.out" || fail "status ssh"
grep -q 'FRP Server: 203.0.113.10' "$WORKDIR/info.out" || fail "info server"
grep -q 'ssh -p 18200 aella@203.0.113.10' "$WORKDIR/info.out" || fail "info ssh connect"
: >"$HOOK"
FRP_CLIENT_TEST_MENU=1 "$ROOT/tools/frp-client" >"$WORKDIR/menu.out"
grep -q 'FRP Client Management' "$WORKDIR/menu.out" || fail "menu header"
grep -q '1) Add service' "$WORKDIR/menu.out" || fail "menu add"
if grep -qx enroll "$HOOK"; then fail "menu contacted allocator"; fi
if grep -qx restart "$HOOK"; then fail "menu restarted frpc"; fi
after_menu="$(python3 - "$TREE" <<'PY'
import hashlib, sys
from pathlib import Path
root=Path(sys.argv[1])
h=hashlib.sha256()
for p in sorted(root.rglob('*')):
    if p.is_file():
        h.update(p.read_bytes())
print(h.hexdigest())
PY
)"
[[ "$before" == "$after_menu" ]] || fail "menu modified files"
pass "read-only status/info do not mutate"

# No pending changes
: >"$HOOK"
export FRP_CLIENT_CANDIDATE="$STATE"
if ! "$ROOT/tools/frp-client" apply >"$WORKDIR/noop.out" 2>"$WORKDIR/noop.err"; then
  fail "no-change apply should succeed"
fi
grep -q 'No pending changes.' "$WORKDIR/noop.out" || fail "noop message"
if grep -qx enroll "$HOOK"; then fail "noop enrolled"; fi
if grep -qx restart "$HOOK"; then fail "noop restart"; fi
pass "no-change apply is a no-op"

# Name-only local metadata
CAND="$WORKDIR/cand-name.json"
python3 - "$STATE" "$CAND" <<'PY'
import json,sys
from pathlib import Path
d=json.loads(Path(sys.argv[1]).read_text())
d['services']['ssh']['name']='ssh'
Path(sys.argv[2]).write_text(json.dumps(d, indent=2, sort_keys=True)+'\n')
PY
toml_before="$(sha256sum "$TREE/etc/frp/frpc.toml" | awk '{print $1}')"
: >"$HOOK"
unset FRP_ENROLLMENT_CODE || true
export FRP_CLIENT_CANDIDATE="$CAND"
frp_state_diff "$STATE" "$CAND" >"$WORKDIR/name-pending.out"
frp_ux_print_apply_summary "$STATE" "$CAND" >"$WORKDIR/name-summary.out"
grep -q 'Display name: SSH -> ssh' "$WORKDIR/name-pending.out" || fail "pending missing name"
grep -q 'Display name: SSH -> ssh' "$WORKDIR/name-summary.out" || fail "apply summary missing name"
if grep -A2 '^Changes:' "$WORKDIR/name-summary.out" | grep -q '(none)'; then
  fail "apply summary Changes=(none) while pending name exists"
fi
grep -q 'local connection information only' "$WORKDIR/name-summary.out" || fail "local-only apply help"
if ! "$ROOT/tools/frp-client" apply >"$WORKDIR/name.out" 2>"$WORKDIR/name.err"; then
  fail "name-only apply should succeed"
fi
grep -q 'Applied local changes.' "$WORKDIR/name.out" || fail "local apply success"
grep -q 'Allocator contacted : NO' "$WORKDIR/name.out" || fail "local apply allocator line"
grep -q 'frpc restarted      : NO' "$WORKDIR/name.out" || fail "local apply restart line"
if grep -q 'Enrollment Code' "$WORKDIR/name.out" "$WORKDIR/name.err"; then
  fail "name-only asked for Enrollment Code"
fi
if grep -qx enroll "$HOOK"; then fail "name-only enrolled"; fi
if grep -qx restart "$HOOK"; then fail "name-only restarted"; fi
toml_after="$(sha256sum "$TREE/etc/frp/frpc.toml" | awk '{print $1}')"
[[ "$toml_before" == "$toml_after" ]] || fail "name-only rewrote frpc.toml"
python3 - "$STATE" <<'PY' || fail "name-only state"
import json,sys
from pathlib import Path
d=json.loads(Path(sys.argv[1]).read_text())
assert d['services']['ssh']['name']=='ssh'
assert d['services']['ssh']['remote_port']==18200
PY
grep -q 'ssh -p 18200 aella@203.0.113.10' "$TREE/etc/frp/access-info.txt" || fail "access-info after name"
pass "name-only is local metadata apply"

# ssh_user-only local metadata
CAND="$WORKDIR/cand-user.json"
python3 - "$STATE" "$CAND" <<'PY'
import json,sys
from pathlib import Path
d=json.loads(Path(sys.argv[1]).read_text())
d['services']['ssh']['ssh_user']='tester'
Path(sys.argv[2]).write_text(json.dumps(d, indent=2, sort_keys=True)+'\n')
PY
toml_before="$(sha256sum "$TREE/etc/frp/frpc.toml" | awk '{print $1}')"
: >"$HOOK"
unset FRP_ENROLLMENT_CODE || true
export FRP_CLIENT_CANDIDATE="$CAND"
frp_state_diff "$STATE" "$CAND" >"$WORKDIR/user-pending.out"
frp_ux_print_apply_summary "$STATE" "$CAND" >"$WORKDIR/user-summary.out"
grep -q 'SSH user: aella -> tester' "$WORKDIR/user-pending.out" || fail "pending missing ssh_user"
grep -q 'SSH user: aella -> tester' "$WORKDIR/user-summary.out" || fail "apply summary missing ssh_user"
if ! "$ROOT/tools/frp-client" apply >"$WORKDIR/user.out" 2>"$WORKDIR/user.err"; then
  fail "ssh_user-only apply should succeed"
fi
grep -q 'Applied local changes.' "$WORKDIR/user.out" || fail "ssh_user local apply"
if grep -qx enroll "$HOOK"; then fail "ssh_user enrolled"; fi
if grep -qx restart "$HOOK"; then fail "ssh_user restarted"; fi
toml_after="$(sha256sum "$TREE/etc/frp/frpc.toml" | awk '{print $1}')"
[[ "$toml_before" == "$toml_after" ]] || fail "ssh_user-only rewrote frpc.toml"
grep -q 'ssh -p 18200 tester@203.0.113.10' "$TREE/etc/frp/access-info.txt" || fail "access-info ssh_user"
python3 - "$STATE" <<'PY' || fail "ssh_user state"
import json,sys
from pathlib import Path
d=json.loads(Path(sys.argv[1]).read_text())
assert d['services']['ssh']['ssh_user']=='tester'
assert d['services']['ssh']['remote_port']==18200
PY
pass "ssh_user-only is local metadata apply"

# Add grafana
CAND="$WORKDIR/cand-add.json"
python3 - "$STATE" "$CAND" <<'PY'
import json,sys
from pathlib import Path
d=json.loads(Path(sys.argv[1]).read_text())
d['services']['grafana']={
  'id':'grafana','name':'Grafana','preset':'custom','protocol':'tcp',
  'local_ip':'127.0.0.1','local_port':3000,'enabled':True,
}
Path(sys.argv[2]).write_text(json.dumps(d, indent=2, sort_keys=True)+'\n')
PY
: >"$HOOK"
export FRP_CLIENT_CANDIDATE="$CAND"
export FRP_ENROLLMENT_CODE="${EID}.${SECRET}"
"$ROOT/tools/frp-client" apply >"$WORKDIR/add.out"
python3 - "$STATE" <<'PY' || fail "add service ports"
import json,sys
from pathlib import Path
d=json.loads(Path(sys.argv[1]).read_text())
assert d['services']['ssh']['remote_port']==18200
assert d['services']['grafana']['remote_port']==18201
assert d['services']['grafana']['enabled'] is True
PY
grep -q 'grafana' "$TREE/etc/frp/frpc.toml" || fail "frpc.toml missing grafana"
grep -q 'name = "dp-example-aabbccdd-grafana"' "$TREE/etc/frp/frpc.toml" || fail "grafana proxy name"
grep -q 'remotePort = 18200' "$TREE/etc/frp/frpc.toml" || fail "ssh port in toml"
grep -q '203.0.113.10:18201' "$TREE/etc/frp/access-info.txt" || fail "access-info grafana"
pass "add service preserves ssh port"

# Edit grafana target
CAND="$WORKDIR/cand-edit.json"
python3 - "$STATE" "$CAND" <<'PY'
import json,sys
from pathlib import Path
d=json.loads(Path(sys.argv[1]).read_text())
d['services']['grafana']['local_ip']='10.10.20.30'
Path(sys.argv[2]).write_text(json.dumps(d, indent=2, sort_keys=True)+'\n')
PY
export FRP_CLIENT_CANDIDATE="$CAND"
export FRP_ENROLLMENT_CODE="${EID}.${SECRET}"
"$ROOT/tools/frp-client" apply >"$WORKDIR/edit.out"
python3 - "$STATE" <<'PY' || fail "edit kept remote port"
import json,sys
from pathlib import Path
d=json.loads(Path(sys.argv[1]).read_text())
assert d['services']['grafana']['local_ip']=='10.10.20.30'
assert d['services']['grafana']['remote_port']==18201
PY
grep -q 'localIP = "10.10.20.30"' "$TREE/etc/frp/frpc.toml" || fail "toml local ip"
grep -q 'Target: 127.0.0.1:3000 -> 10.10.20.30:3000' "$WORKDIR/edit.out" || fail "edit summary missing target"
grep -q 'An Enrollment Code is required' "$WORKDIR/edit.out" || fail "target change requires enrollment"
pass "edit target preserves remote port"

# Mixed name + target is runtime
CAND="$WORKDIR/cand-mixed.json"
python3 - "$STATE" "$CAND" <<'PY'
import json,sys
from pathlib import Path
d=json.loads(Path(sys.argv[1]).read_text())
d['services']['grafana']['name']='Dash'
d['services']['grafana']['local_ip']='10.10.20.31'
Path(sys.argv[2]).write_text(json.dumps(d, indent=2, sort_keys=True)+'\n')
PY
: >"$HOOK"
export FRP_CLIENT_CANDIDATE="$CAND"
export FRP_ENROLLMENT_CODE="${EID}.${SECRET}"
frp_state_diff "$STATE" "$CAND" >"$WORKDIR/mixed-pending.out"
frp_ux_print_apply_summary "$STATE" "$CAND" >"$WORKDIR/mixed-summary.out"
grep -q 'Display name: Grafana -> Dash' "$WORKDIR/mixed-pending.out" || fail "mixed pending name"
grep -q 'Target: 10.10.20.30:3000 -> 10.10.20.31:3000' "$WORKDIR/mixed-pending.out" || fail "mixed pending target"
grep -q 'Display name: Grafana -> Dash' "$WORKDIR/mixed-summary.out" || fail "mixed summary name"
grep -q 'Target: 10.10.20.30:3000 -> 10.10.20.31:3000' "$WORKDIR/mixed-summary.out" || fail "mixed summary target"
grep -q 'will restart the FRP client' "$WORKDIR/mixed-summary.out" || fail "mixed is runtime"
"$ROOT/tools/frp-client" apply >"$WORKDIR/mixed.out"
if ! grep -qx enroll "$HOOK"; then fail "mixed did not enroll"; fi
if ! grep -qx restart "$HOOK"; then fail "mixed did not restart"; fi
python3 - "$STATE" <<'PY' || fail "mixed kept remote port"
import json,sys
from pathlib import Path
d=json.loads(Path(sys.argv[1]).read_text())
assert d['services']['grafana']['name']=='Dash'
assert d['services']['grafana']['local_ip']=='10.10.20.31'
assert d['services']['grafana']['remote_port']==18201
PY
grep -q 'localIP = "10.10.20.31"' "$TREE/etc/frp/frpc.toml" || fail "mixed toml ip"
pass "mixed name+target uses secured apply"

# Disable grafana
CAND="$WORKDIR/cand-disable.json"
python3 - "$STATE" "$CAND" <<'PY'
import json,sys
from pathlib import Path
d=json.loads(Path(sys.argv[1]).read_text())
d['services']['grafana']['enabled']=False
Path(sys.argv[2]).write_text(json.dumps(d, indent=2, sort_keys=True)+'\n')
PY
export FRP_CLIENT_CANDIDATE="$CAND"
export FRP_ENROLLMENT_CODE="${EID}.${SECRET}"
"$ROOT/tools/frp-client" apply >"$WORKDIR/disable.out"
python3 - "$STATE" "$TREE/etc/frp/frpc.toml" "$ALLOC_ROOT/registry.json" <<'PY' || fail "disable semantics"
import json,sys
from pathlib import Path
d=json.loads(Path(sys.argv[1]).read_text())
toml=Path(sys.argv[2]).read_text()
reg=json.loads(Path(sys.argv[3]).read_text())
assert d['services']['grafana']['enabled'] is False
assert d['services']['grafana']['remote_port']==18201
assert 'grafana' not in toml
mid=d['machine_id']
assert reg['clients'][mid]['services']['grafana']['enabled'] is False
assert reg['clients'][mid]['services']['grafana']['remote_port']==18201
PY
pass "disable keeps reservation and omits proxy"

# Re-enable grafana
CAND="$WORKDIR/cand-enable.json"
python3 - "$STATE" "$CAND" <<'PY'
import json,sys
from pathlib import Path
d=json.loads(Path(sys.argv[1]).read_text())
d['services']['grafana']['enabled']=True
Path(sys.argv[2]).write_text(json.dumps(d, indent=2, sort_keys=True)+'\n')
PY
export FRP_CLIENT_CANDIDATE="$CAND"
export FRP_ENROLLMENT_CODE="${EID}.${SECRET}"
"$ROOT/tools/frp-client" apply >"$WORKDIR/enable.out"
python3 - "$STATE" <<'PY' || fail "re-enable port"
import json,sys
from pathlib import Path
d=json.loads(Path(sys.argv[1]).read_text())
assert d['services']['grafana']['enabled'] is True
assert d['services']['grafana']['remote_port']==18201
PY
grep -q 'grafana' "$TREE/etc/frp/frpc.toml" || fail "re-enabled proxy missing"
pass "re-enable reuses the same public port"

# Last enabled service cannot be disabled
CAND="$WORKDIR/cand-last.json"
python3 - "$STATE" "$CAND" <<'PY'
import json,sys
from pathlib import Path
d=json.loads(Path(sys.argv[1]).read_text())
d['services']['ssh']['enabled']=False
d['services']['grafana']['enabled']=False
Path(sys.argv[2]).write_text(json.dumps(d, indent=2, sort_keys=True)+'\n')
PY
export FRP_CLIENT_CANDIDATE="$CAND"
if "$ROOT/tools/frp-client" apply >"$WORKDIR/last.out" 2>"$WORKDIR/last.err"; then
  fail "disabling last services should fail"
fi
grep -q 'at least one enabled service is required' "$WORKDIR/last.err" || fail "last-service error"
python3 - "$STATE" <<'PY' || fail "last disable mutated state"
import json,sys
from pathlib import Path
d=json.loads(Path(sys.argv[1]).read_text())
assert d['services']['ssh']['enabled'] is True
PY
pass "last enabled service cannot be disabled"

# Invalid enrollment
CAND="$WORKDIR/cand-bad.json"
python3 - "$STATE" "$CAND" <<'PY'
import json,sys
from pathlib import Path
d=json.loads(Path(sys.argv[1]).read_text())
d['services']['grafana']['local_ip']='10.10.20.99'
Path(sys.argv[2]).write_text(json.dumps(d, indent=2, sort_keys=True)+'\n')
PY
cp "$STATE" "$WORKDIR/state.before"
cp "$TREE/etc/frp/frpc.toml" "$WORKDIR/toml.before"
cp "$TREE/etc/frp/access-info.txt" "$WORKDIR/access.before"
export FRP_CLIENT_CANDIDATE="$CAND"
export FRP_ENROLLMENT_CODE='deadbeefdeadbeef.0000000000000000000000000000000000000000000000000000000000000000'
: >"$HOOK"
if "$ROOT/tools/frp-client" apply >"$WORKDIR/bad.out" 2>"$WORKDIR/bad.err"; then
  fail "invalid enrollment should fail"
fi
cmp -s "$STATE" "$WORKDIR/state.before" || fail "invalid enroll changed state"
cmp -s "$TREE/etc/frp/frpc.toml" "$WORKDIR/toml.before" || fail "invalid enroll changed toml"
cmp -s "$TREE/etc/frp/access-info.txt" "$WORKDIR/access.before" || fail "invalid enroll changed access"
if grep -qx restart "$HOOK"; then fail "invalid enroll restarted"; fi
pass "invalid enrollment leaves local config unchanged"

# Allocator unreachable
export FRP_CLIENT_HOOK_ENROLL_FAIL=1
if "$ROOT/tools/frp-client" apply >"$WORKDIR/unreach.out" 2>"$WORKDIR/unreach.err"; then
  fail "unreachable allocator should fail"
fi
unset FRP_CLIENT_HOOK_ENROLL_FAIL
cmp -s "$STATE" "$WORKDIR/state.before" || fail "unreachable allocator changed state"
pass "allocator unreachable leaves local config unchanged"

# Verify failure + compensation
python3 - "$STATE" "$CAND" <<'PY'
import json,sys
from pathlib import Path
d=json.loads(Path(sys.argv[1]).read_text())
d['services']['grafana']['local_ip']='10.10.20.98'
Path(sys.argv[2]).write_text(json.dumps(d, indent=2, sort_keys=True)+'\n')
PY
export FRP_CLIENT_CANDIDATE="$CAND"
export FRP_ENROLLMENT_CODE="${EID}.${SECRET}"
export FRP_CLIENT_HOOK_VERIFY_FAIL=1
export FRP_CLIENT_ENROLL_COUNT_FILE="$WORKDIR/enroll.count"
echo 0 >"$FRP_CLIENT_ENROLL_COUNT_FILE"
if "$ROOT/tools/frp-client" apply >"$WORKDIR/verify.out" 2>"$WORKDIR/verify.err"; then
  fail "verify failure should fail apply"
fi
unset FRP_CLIENT_HOOK_VERIFY_FAIL
grep -q 'LOCAL_ROLLBACK=PASS' "$WORKDIR/verify.out" "$WORKDIR/verify.err" || fail "verify local rollback"
grep -q 'SERVER_ROLLBACK=PASS' "$WORKDIR/verify.out" "$WORKDIR/verify.err" || fail "verify server compensation"
cmp -s "$STATE" "$WORKDIR/state.before" || fail "verify failure changed state"
pass "verify failure preserves config and compensates server"

# Restart failure + local rollback
python3 - "$STATE" "$CAND" <<'PY'
import json,sys
from pathlib import Path
d=json.loads(Path(sys.argv[1]).read_text())
d['services']['grafana']['local_ip']='10.10.20.97'
Path(sys.argv[2]).write_text(json.dumps(d, indent=2, sort_keys=True)+'\n')
PY
export FRP_CLIENT_HOOK_RESTART_FAIL=1
echo 0 >"$FRP_CLIENT_ENROLL_COUNT_FILE"
if "$ROOT/tools/frp-client" apply >"$WORKDIR/restart.out" 2>"$WORKDIR/restart.err"; then
  fail "restart failure should fail apply"
fi
unset FRP_CLIENT_HOOK_RESTART_FAIL
grep -q 'LOCAL_ROLLBACK=PASS' "$WORKDIR/restart.out" "$WORKDIR/restart.err" || fail "restart local rollback"
grep -q 'SERVER_ROLLBACK=PASS' "$WORKDIR/restart.out" "$WORKDIR/restart.err" || fail "restart server compensation"
python3 - "$STATE" <<'PY' || fail "restart left grafana target"
import json,sys
from pathlib import Path
d=json.loads(Path(sys.argv[1]).read_text())
assert d['services']['grafana']['local_ip']=='10.10.20.31'
assert d['services']['grafana']['name']=='Dash'
PY
pass "restart failure restores local files"

# Proxy health failure
python3 - "$STATE" "$CAND" <<'PY'
import json,sys
from pathlib import Path
d=json.loads(Path(sys.argv[1]).read_text())
d['services']['grafana']['local_ip']='10.10.20.96'
Path(sys.argv[2]).write_text(json.dumps(d, indent=2, sort_keys=True)+'\n')
PY
export FRP_CLIENT_HOOK_PROXY_FAIL=1
echo 0 >"$FRP_CLIENT_ENROLL_COUNT_FILE"
if "$ROOT/tools/frp-client" apply >"$WORKDIR/proxy.out" 2>"$WORKDIR/proxy.err"; then
  fail "proxy failure should fail apply"
fi
unset FRP_CLIENT_HOOK_PROXY_FAIL
grep -q 'LOCAL_ROLLBACK=PASS' "$WORKDIR/proxy.out" "$WORKDIR/proxy.err" || fail "proxy local rollback"
grep -q 'SERVER_ROLLBACK=PASS' "$WORKDIR/proxy.out" "$WORKDIR/proxy.err" || fail "proxy server compensation"
pass "proxy health failure restores local files"

# Compensation failure is reported
python3 - "$STATE" "$CAND" <<'PY'
import json,sys
from pathlib import Path
d=json.loads(Path(sys.argv[1]).read_text())
d['services']['grafana']['local_ip']='10.10.20.95'
Path(sys.argv[2]).write_text(json.dumps(d, indent=2, sort_keys=True)+'\n')
PY
export FRP_CLIENT_HOOK_VERIFY_FAIL=1
export FRP_CLIENT_HOOK_COMPENSATE_FAIL=1
echo 0 >"$FRP_CLIENT_ENROLL_COUNT_FILE"
if "$ROOT/tools/frp-client" apply >"$WORKDIR/comp.out" 2>"$WORKDIR/comp.err"; then
  fail "compensation-fail path should fail apply"
fi
unset FRP_CLIENT_HOOK_VERIFY_FAIL FRP_CLIENT_HOOK_COMPENSATE_FAIL
grep -q 'SERVER_ROLLBACK=FAIL' "$WORKDIR/comp.out" "$WORKDIR/comp.err" || fail "compensation failure not reported"
grep -qi 'reconcile' "$WORKDIR/comp.err" || fail "compensation warning"
pass "compensation failure is reported loudly"

# Missing state
rm -f "$STATE"
if "$ROOT/tools/frp-client" status >"$WORKDIR/missing.out" 2>"$WORKDIR/missing.err"; then
  fail "missing state should fail"
fi
grep -q 'predates local management state' "$WORKDIR/missing.err" || fail "missing state message"
pass "missing pre-P2 state fails closed"

# Lock
mkdir -p "$TREE/etc/frp/client-manage.lock"
export FRP_CLIENT_CANDIDATE="$CAND"
if FRP_CLIENT_TOOL_SOURCED=1; then :; fi
# restore state for lock test of apply
python3 - "$WORKDIR/state.before" "$STATE" <<'PY'
import pathlib,sys
pathlib.Path(sys.argv[2]).write_bytes(pathlib.Path(sys.argv[1]).read_bytes())
PY
if "$ROOT/tools/frp-client" apply >"$WORKDIR/lock.out" 2>"$WORKDIR/lock.err"; then
  fail "lock should block apply"
fi
grep -q 'another frp-client management operation is already running' "$WORKDIR/lock.err" || fail "lock error"
rmdir "$TREE/etc/frp/client-manage.lock" 2>/dev/null || rm -rf "$TREE/etc/frp/client-manage.lock"
pass "local management lock"

echo
echo "FRP_CLIENT_MANAGEMENT_TEST=PASS"
