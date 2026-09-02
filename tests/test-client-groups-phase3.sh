#!/usr/bin/env bash
# Phase 3 Group completion: P3.2 enrollment assignment, P3.3 system groups,
# P3.4 dynamic groups, P3.5 filters and UX.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }

TREE="$WORKDIR/tree"
mkdir -p "$TREE/etc/frp-auto-deploy" "$TREE/var/lib/frp-auto-deploy/enrollments" "$TREE/var/log/frp-auto-deploy"
export FRP_DEPLOY_TEST_ROOT="$TREE"
export FRP_CTL_TEST_ROOT="$TREE"
export FRP_CTL_BIN_DIR="$ROOT/tools"

python3 - "$TREE/etc/frp-auto-deploy/config.json" "$TREE/var/lib/frp-auto-deploy/registry.json" <<'PY'
import json
import sys
from pathlib import Path

cfg_path, reg_path = Path(sys.argv[1]), Path(sys.argv[2])
cfg_path.write_text(json.dumps({
    'public_host': '203.0.113.10',
    'registry_file': str(reg_path),
    'enrollments_dir': str(reg_path.parent / 'enrollments'),
}, indent=2) + '\n')
reg_path.write_text(json.dumps({
    'schema_version': 2,
    'reserved': [],
    'groups': {},
    'clients': {
        'aaaaaaaa11111111aaaaaaaa11111111': {
            'hostname': 'gw01',
            'label': 'acme-gw-01',
            'mgmt_status': 'legacy',
            'tags': {'env': 'prod', 'site': 'seoul', 'customer': 'acme'},
            'services': {
                'ssh': {
                    'id': 'ssh',
                    'protocol': 'tcp',
                    'preset': 'ssh',
                    'enabled': True,
                    'local_ip': '127.0.0.1',
                    'local_port': 22,
                    'remote_port': 6001,
                    'ssh_user': 'ubuntu',
                },
            },
        },
        'bbbbbbbb22222222bbbbbbbb22222222': {
            'hostname': 'gw02',
            'label': 'pilot-gw',
            'tags': {'env': 'prod', 'site': 'busan'},
            'services': {
                'ssh': {
                    'id': 'ssh',
                    'protocol': 'tcp',
                    'preset': 'ssh',
                    'enabled': True,
                    'local_ip': '127.0.0.1',
                    'local_port': 22,
                    'remote_port': 6002,
                    'ssh_user': 'ubuntu',
                },
            },
        },
        'cccccccc33333333cccccccc33333333': {
            'hostname': 'spare',
            'tags': {'env': 'dev'},
            'services': {},
        },
    },
}, indent=2) + '\n')
PY

GSET="$ROOT/tools/frp-group-set"
FRP_GROUPS="$ROOT/tools/frp-groups"
CLIENTS="$ROOT/tools/frp-clients"
CINFO="$ROOT/tools/frp-client-info"
CREATE="$ROOT/tools/frp-create-client"
CTL="$ROOT/tools/frpctl"
REG="$TREE/var/lib/frp-auto-deploy/registry.json"
ENROLL="$TREE/var/lib/frp-auto-deploy/enrollments"

# Seed manual groups for assignment tests.
"$GSET" create customer-acme >"$WORKDIR/g1.out" || fail "create customer-acme"
"$GSET" create seoul >"$WORKDIR/g2.out" || fail "create seoul"
GID_ACME="$(python3 - "$REG" <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
for gid, group in state['groups'].items():
    if group.get('name') == 'customer-acme':
        print(gid)
        break
PY
)"
GID_SEOUL="$(python3 - "$REG" <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
for gid, group in state['groups'].items():
    if group.get('name') == 'seoul':
        print(gid)
        break
PY
)"

# Fix client a membership after groups exist
python3 - "$REG" "$GID_ACME" <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
state['clients']['aaaaaaaa11111111aaaaaaaa11111111']['group_ids'] = [sys.argv[2]]
json.dump(state, open(sys.argv[1], 'w'), indent=2)
PY

# --- P3.2 Enrollment assignment ---
"$CREATE" --group customer-acme --group seoul --group customer-acme --ttl 600 \
  >"$WORKDIR/enroll.out" || fail "create enrollment with groups"
EID="$(python3 - "$ENROLL" <<'PY'
import json, sys
from pathlib import Path
for path in sorted(Path(sys.argv[1]).glob('*.json')):
    record = json.load(path.open())
    ids = record.get('assigned_group_ids') or []
    if len(ids) == 2:
        print(record['id'])
        break
else:
    raise SystemExit('missing enrollment')
PY
)"
python3 - "$ENROLL/$EID.json" "$GID_ACME" "$GID_SEOUL" <<'PY' || fail "enrollment assigned_group_ids"
import json, sys
record = json.load(open(sys.argv[1]))
assert record['assigned_group_ids'] == [sys.argv[2], sys.argv[3]], record
PY
pass "P3_2_ENROLLMENT_RECORD"

if "$CREATE" --group all >"$WORKDIR/bad_all.out" 2>"$WORKDIR/bad_all.err"; then
  fail "all group assignment accepted"
fi
if "$GSET" create dyn-test --dynamic --match-tag env=prod >"$WORKDIR/dyn.out"; then
  DYN_GID="$(python3 - "$REG" <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
for gid, group in state['groups'].items():
    if group.get('name') == 'dyn-test':
        print(gid)
        break
PY
)"
  if "$CREATE" --group dyn-test >"$WORKDIR/bad_dyn.out" 2>"$WORKDIR/bad_dyn.err"; then
    fail "dynamic group assignment accepted"
  fi
fi
if "$CREATE" --group missing-group >"$WORKDIR/bad_miss.out" 2>"$WORKDIR/bad_miss.err"; then
  fail "missing group assignment accepted"
fi
pass "P3_2_ENROLLMENT_REJECT"

"$GSET" set customer-acme --name acme-renamed >"$WORKDIR/rename_g.out" || fail "rename group"
python3 - "$ENROLL/$EID.json" "$GID_ACME" <<'PY' || fail "rename preserves assignment id"
import json, sys
record = json.load(open(sys.argv[1]))
assert sys.argv[2] in record['assigned_group_ids']
PY
pass "P3_2_RENAME_SURVIVES"

python3 - "$ROOT/server/frp-port-allocator.py" "$REG" "$ENROLL" "$EID" "$GID_ACME" "$GID_SEOUL" <<'PY' || fail "enroll assignment apply"
import hashlib
import hmac
import importlib.util
import json
import sys
import time
from pathlib import Path

ROOT = Path(sys.argv[1]).resolve().parents[0]
spec = importlib.util.spec_from_file_location('alloc', sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

reg_path = Path(sys.argv[2])
enroll_dir = Path(sys.argv[3])
eid = sys.argv[4]
gid_acme = sys.argv[5]
gid_seoul = sys.argv[6]

cfg = {
    'public_ip': '203.0.113.10',
    'control_port': 443,
    'port_start': 6000,
    'port_end': 7000,
    'registry_file': str(reg_path),
    'enrollments_dir': str(enroll_dir),
    'token_file': str(reg_path.parent / 'token'),
}
(reg_path.parent / 'token').write_text('tok\n')
cfg_path = reg_path.parent / 'alloc-config.json'
cfg_path.write_text(json.dumps(cfg) + '\n')
mod.port_is_available = lambda port: True
alloc = mod.Allocator(str(cfg_path))

record = json.load(open(enroll_dir / (eid + '.json')))
secret = record['secret']
body = json.dumps({
    'machine_id': 'dddddddd44444444dddddddd44444444',
    'hostname': 'new-client',
    'services': [{'id': 'ssh', 'name': 'SSH', 'protocol': 'tcp', 'local_ip': '127.0.0.1', 'local_port': 22, 'preset': 'ssh', 'ssh_user': 'ubuntu'}],
}, separators=(',', ':')).encode()
ts = str(int(time.time()))
sig = hmac.new(secret.encode(), (ts + '\n' + body.decode()).encode(), hashlib.sha256).hexdigest()
code, result = alloc.enroll(eid, ts, sig, body)
assert code == 200, (code, result)
state = json.load(reg_path.open())
client = state['clients']['dddddddd44444444dddddddd44444444']
assert gid_acme in client['group_ids'] and gid_seoul in client['group_ids']

# Re-enrollment preserves existing + adds assignment
record2 = json.load(open(enroll_dir / (eid + '.json')))
record2['bound_machine_id'] = None
record2['used_at'] = None
json.dump(record2, open(enroll_dir / (eid + '.json'), 'w'))
body2 = json.dumps({
    'machine_id': 'aaaaaaaa11111111aaaaaaaa11111111',
    'hostname': 'gw01',
    'services': [{'id': 'ssh', 'name': 'SSH', 'protocol': 'tcp', 'local_ip': '127.0.0.1', 'local_port': 22, 'preset': 'ssh', 'ssh_user': 'ubuntu'}],
}, separators=(',', ':')).encode()
ts2 = str(int(time.time()))
sig2 = hmac.new(secret.encode(), (ts2 + '\n' + body2.decode()).encode(), hashlib.sha256).hexdigest()
code2, _ = alloc.enroll(eid, ts2, sig2, body2)
assert code2 == 200, code2
state = json.load(reg_path.open())
client = state['clients']['aaaaaaaa11111111aaaaaaaa11111111']
assert gid_acme in client['group_ids']
assert gid_seoul in client['group_ids']
PY
pass "P3_2_ENROLL_APPLY"

"$GSET" delete seoul >"$WORKDIR/del_seoul.out" || fail "delete seoul for fail-closed"
if python3 - "$ROOT/server/frp-port-allocator.py" "$REG" "$ENROLL" "$EID" <<'PY'
import hashlib, hmac, importlib.util, json, sys, time
from pathlib import Path
spec = importlib.util.spec_from_file_location('alloc', sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
reg_path = Path(sys.argv[2])
enroll_dir = Path(sys.argv[3])
eid = sys.argv[4]
record = json.load(open(enroll_dir / (eid + '.json')))
record['bound_machine_id'] = None
record['used_at'] = None
json.dump(record, open(enroll_dir / (eid + '.json'), 'w'))
cfg = {'public_ip': '203.0.113.10', 'control_port': 443, 'port_start': 6000, 'port_end': 7000,
       'registry_file': str(reg_path), 'enrollments_dir': str(enroll_dir),
       'token_file': str(reg_path.parent / 'token')}
cfg_path = reg_path.parent / 'alloc-config2.json'
cfg_path.write_text(json.dumps(cfg) + '\n')
mod.port_is_available = lambda port: True
alloc = mod.Allocator(str(cfg_path))
secret = record['secret']
body = json.dumps({'machine_id': 'eeeeeeee55555555eeeeeeee55555555', 'hostname': 'x', 'services': []}, separators=(',', ':')).encode()
ts = str(int(time.time()))
sig = hmac.new(secret.encode(), (ts + '\n' + body.decode()).encode(), hashlib.sha256).hexdigest()
code, result = alloc.enroll(eid, ts, sig, body)
raise SystemExit(0 if code == 403 else 1)
PY
then
  pass "P3_2_DELETED_GROUP_FAIL_CLOSED"
else
  fail "deleted group redeem should fail closed"
fi

# Never-redeemed pending enrollment referencing a deleted group must fail closed.
"$GSET" create pending-target >"$WORKDIR/pend_g.out" || fail "create pending-target"
GID_PEND="$(python3 - "$REG" <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
for gid, group in state['groups'].items():
    if group.get('name') == 'pending-target':
        print(gid)
        break
PY
)"
"$CREATE" --group pending-target --ttl 600 >"$WORKDIR/pend_enroll.out" || fail "create pending enrollment"
PEND_EID="$(python3 - "$ENROLL" "$GID_PEND" <<'PY'
import json, sys
from pathlib import Path
gid = sys.argv[2]
for path in sorted(Path(sys.argv[1]).glob('*.json')):
    record = json.load(path.open())
    if record.get('used_at') or record.get('bound_machine_id'):
        continue
    if record.get('assigned_group_ids') == [gid]:
        print(record['id'])
        break
else:
    raise SystemExit('missing never-redeemed enrollment')
PY
)"
"$GSET" delete pending-target >"$WORKDIR/pend_del.out" || fail "delete pending-target"
if python3 - "$ROOT/server/frp-port-allocator.py" "$REG" "$ENROLL" "$PEND_EID" <<'PY'
import hashlib, hmac, importlib.util, json, sys, time
from pathlib import Path
spec = importlib.util.spec_from_file_location('alloc', sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
reg_path = Path(sys.argv[2])
enroll_dir = Path(sys.argv[3])
eid = sys.argv[4]
record = json.load(open(enroll_dir / (eid + '.json')))
assert not record.get('used_at') and not record.get('bound_machine_id')
cfg = {'public_ip': '203.0.113.10', 'control_port': 443, 'port_start': 6000, 'port_end': 7000,
       'registry_file': str(reg_path), 'enrollments_dir': str(enroll_dir),
       'token_file': str(reg_path.parent / 'token')}
cfg_path = reg_path.parent / 'alloc-pend.json'
cfg_path.write_text(json.dumps(cfg) + '\n')
mod.port_is_available = lambda port: True
alloc = mod.Allocator(str(cfg_path))
secret = record['secret']
body = json.dumps({
    'machine_id': 'ffffffff66666666ffffffff66666666',
    'hostname': 'never-redeemed',
    'services': [],
}, separators=(',', ':')).encode()
ts = str(int(time.time()))
sig = hmac.new(secret.encode(), (ts + '\n' + body.decode()).encode(), hashlib.sha256).hexdigest()
code, result = alloc.enroll(eid, ts, sig, body)
raise SystemExit(0 if code == 403 else 1)
PY
then
  pass "P3_2_NEVER_REDEEMED_DELETED_GROUP"
else
  fail "never-redeemed deleted group should fail closed"
fi

# Zero-touch pending enrollment with deleted assigned group fails on redeem.
# Seed the enrollment side the same way issue_bootstrap_ticket persists groups.
"$GSET" create zt-target >"$WORKDIR/zt_g.out" || fail "create zt-target"
GID_ZT="$(python3 - "$REG" <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
for gid, group in state['groups'].items():
    if group.get('name') == 'zt-target':
        print(gid)
        break
PY
)"
python3 - "$ROOT" "$REG" "$ENROLL" "$GID_ZT" <<'PY' || fail "seed zero-touch enrollment"
import importlib.util, json, secrets, sys, time
from pathlib import Path
root = Path(sys.argv[1])
reg_path = Path(sys.argv[2])
enroll_dir = Path(sys.argv[3])
gid = sys.argv[4]
eid = 'ztdeleted000001'
secret = 'e' * 64
now = int(time.time())
(enroll_dir / (eid + '.json')).write_text(json.dumps({
    'id': eid,
    'secret': secret,
    'expires_at': now + 600,
    'bound_machine_id': None,
    'used_at': None,
    'label': 'zt-del',
    'type': 'zero-touch',
    'assigned_group_ids': [gid],
}, indent=2) + '\n')
Path(reg_path.parent / 'zt-eid').write_text(eid + '\n')
print('seeded')
PY
ZT_EID="$(cat "$TREE/var/lib/frp-auto-deploy/zt-eid")"
"$GSET" delete zt-target >"$WORKDIR/zt_del.out" || fail "delete zt-target"
if python3 - "$ROOT/server/frp-port-allocator.py" "$REG" "$ENROLL" "$ZT_EID" <<'PY'
import hashlib, hmac, importlib.util, json, sys, time
from pathlib import Path
spec = importlib.util.spec_from_file_location('alloc', sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
reg_path = Path(sys.argv[2])
enroll_dir = Path(sys.argv[3])
eid = sys.argv[4]
record = json.load(open(enroll_dir / (eid + '.json')))
assert record.get('type') == 'zero-touch'
assert not record.get('used_at')
cfg = {'public_ip': '203.0.113.10', 'control_port': 443, 'port_start': 6000, 'port_end': 7000,
       'registry_file': str(reg_path), 'enrollments_dir': str(enroll_dir),
       'token_file': str(reg_path.parent / 'token')}
cfg_path = reg_path.parent / 'alloc-zt.json'
cfg_path.write_text(json.dumps(cfg) + '\n')
mod.port_is_available = lambda port: True
alloc = mod.Allocator(str(cfg_path))
secret = record['secret']
body = json.dumps({
    'machine_id': 'abababab77777777abababab77777777',
    'hostname': 'zt-deleted-group',
    'services': [],
}, separators=(',', ':')).encode()
ts = str(int(time.time()))
sig = hmac.new(secret.encode(), (ts + '\n' + body.decode()).encode(), hashlib.sha256).hexdigest()
code, result = alloc.enroll(eid, ts, sig, body)
raise SystemExit(0 if code == 403 else 1)
PY
then
  pass "P3_2_ZERO_TOUCH_DELETED_GROUP"
else
  fail "zero-touch deleted group should fail closed"
fi

# --- P3.3 System groups ---
"$FRP_GROUPS" >"$WORKDIR/sys_list.out" || fail "show groups"
grep -q 'system' "$WORKDIR/sys_list.out" || fail "system groups missing"
grep -q 'all' "$WORKDIR/sys_list.out" || fail "all missing"
grep -q 'ungrouped' "$WORKDIR/sys_list.out" || fail "ungrouped missing"
"$FRP_GROUPS" all --clients >"$WORKDIR/all_clients.out" || fail "all clients"
grep -q 'aaaaaaaa' "$WORKDIR/all_clients.out" || fail "all missing a"
grep -q 'bbbbbbbb' "$WORKDIR/all_clients.out" || fail "all missing b"
grep -q 'cccccccc' "$WORKDIR/all_clients.out" || fail "all missing c"
if "$GSET" set all --name x >"$WORKDIR/sys_set.out" 2>"$WORKDIR/sys_set.err"; then
  fail "set all accepted"
fi
if "$GSET" delete ungrouped >"$WORKDIR/sys_del.out" 2>"$WORKDIR/sys_del.err"; then
  fail "delete ungrouped accepted"
fi
if "$GSET" add-member aaaaaaaa all >"$WORKDIR/sys_add.out" 2>"$WORKDIR/sys_add.err"; then
  fail "add to all accepted"
fi
pass "P3_3_SYSTEM_GROUPS"

# --- P3.4 Dynamic groups ---
"$GSET" create prod-seoul --dynamic --match-tag env=prod --match-tag site=seoul \
  >"$WORKDIR/dg.out" || fail "create dynamic"
"$GSET" create prod-only --dynamic --match-tag env=prod >"$WORKDIR/dg2.out" || fail "create dynamic 2"
"$FRP_GROUPS" prod-seoul >"$WORKDIR/dg_detail.out" || fail "show dynamic"
grep -q 'env=prod' "$WORKDIR/dg_detail.out" || fail "selector missing"
"$FRP_GROUPS" prod-seoul --clients >"$WORKDIR/dg_clients.out" || fail "dynamic clients"
grep -q 'aaaaaaaa' "$WORKDIR/dg_clients.out" || fail "dynamic member a"
if grep -q 'bbbbbbbb' "$WORKDIR/dg_clients.out"; then
  fail "dynamic included wrong client"
fi
if "$GSET" add-member bbbbbbbb prod-seoul >"$WORKDIR/dg_add.out" 2>"$WORKDIR/dg_add.err"; then
  fail "manual add to dynamic accepted"
fi
"$GSET" set prod-seoul --match-tag site=busan >"$WORKDIR/dg_set.out" || fail "selector update"
"$FRP_GROUPS" prod-seoul --clients >"$WORKDIR/dg_after.out" || fail "after selector"
if grep -q 'aaaaaaaa' "$WORKDIR/dg_after.out"; then
  fail "selector update should drop a"
fi
pass "P3_4_DYNAMIC_GROUPS"

# ungrouped after dynamic: dynamic membership must NOT remove ungrouped view.
# bbbbbbbb has tags env=prod (matches prod-only / updated prod-seoul) but no
# manual group_ids — must still appear. Manual member aaaaaaaa must not.
"$FRP_GROUPS" ungrouped --clients >"$WORKDIR/ung.out" || fail "ungrouped clients"
grep -q 'cccccccc' "$WORKDIR/ung.out" || fail "ungrouped should include c"
grep -q 'bbbbbbbb' "$WORKDIR/ung.out" || fail "dynamic-only client must remain ungrouped"
if grep -q 'aaaaaaaa' "$WORKDIR/ung.out"; then
  fail "manual member should not be ungrouped"
fi
"$CLIENTS" --group ungrouped >"$WORKDIR/ung_clients.out" || fail "clients --group ungrouped"
grep -q 'bbbbbbbb' "$WORKDIR/ung_clients.out" || fail "clients filter missing dynamic-only b"
grep -q 'cccccccc' "$WORKDIR/ung_clients.out" || fail "clients filter missing c"
if grep -q 'aaaaaaaa' "$WORKDIR/ung_clients.out"; then
  fail "clients filter included manual member a"
fi
python3 - "$WORKDIR/ung.out" "$WORKDIR/ung_clients.out" <<'PY' || fail "groups/clients ungrouped disagree"
import re, sys
def ids(path):
    text = open(path).read()
    found = set()
    for mid in (
        'aaaaaaaa11111111aaaaaaaa11111111',
        'bbbbbbbb22222222bbbbbbbb22222222',
        'cccccccc33333333cccccccc33333333',
    ):
        if mid in text or mid[:8] in text:
            found.add(mid[:8])
    return found
g, c = ids(sys.argv[1]), ids(sys.argv[2])
assert g == c == {'bbbbbbbb', 'cccccccc'}, (g, c)
print('ungrouped agree')
PY
"$CTL" show fleet >"$WORKDIR/fleet_ung.out" 2>/dev/null \
  || PYTHONPATH="$ROOT/lib${PYTHONPATH:+:$PYTHONPATH}" \
     python3 "$ROOT/lib/frp_fleet.py" fleet >"$WORKDIR/fleet_ung.out" \
  || fail "fleet overview"
grep -E 'Ungrouped[[:space:]]+2' "$WORKDIR/fleet_ung.out" \
  || fail "fleet ungrouped count should be 2 (b+c)"
python3 - "$ROOT" "$REG" <<'PY' || fail "fleet/clients ungrouped count disagree"
import importlib.util, json, sys
from pathlib import Path
root = Path(sys.argv[1])
state = json.loads(Path(sys.argv[2]).read_text())
spec = importlib.util.spec_from_file_location('fleet', root / 'lib/frp_fleet.py')
# Ensure CREG importable
sys.path.insert(0, str(root / 'lib'))
fleet = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fleet)
counts = fleet.group_summary_counts(state)
assert counts['ungrouped'] == 2, counts
print('fleet count ok')
PY
pass "P3_3_UNGROUPED_WITH_DYNAMIC"

# Ungrouped matrix: no manual/no dynamic, manual only, dynamic only,
# manual+dynamic, tag change drops dynamic match but stays ungrouped.
python3 - "$ROOT" "$REG" <<'PY' || fail "ungrouped matrix"
import importlib.util, json, sys
from pathlib import Path
root = Path(sys.argv[1])
reg_path = Path(sys.argv[2])
spec = importlib.util.spec_from_file_location('creg', root / 'lib/frp_client_registry.py')
creg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(creg)

def check(name, state, mid, expect_ungrouped):
    client = state['clients'][mid]
    got = creg.client_is_ungrouped(state, client)
    assert got is expect_ungrouped, (name, mid, got, expect_ungrouped)

# Fresh isolated fixtures (do not mutate live phase3 registry semantics here).
base_clients = {
    'nomanual000000000000000000000001': {'tags': {}, 'group_ids': []},
    'manualonly0000000000000000000002': {'tags': {}, 'group_ids': ['grp_aaaa0001']},
    'dynamiconly000000000000000000003': {'tags': {'env': 'prod'}, 'group_ids': []},
    'manualdyn00000000000000000000004': {
        'tags': {'env': 'prod'}, 'group_ids': ['grp_aaaa0001'],
    },
    'tagchange00000000000000000000005': {'tags': {'env': 'prod'}, 'group_ids': []},
}
state = {
    'schema_version': 2,
    'groups': {
        'grp_aaaa0001': {'name': 'manual-a', 'type': 'manual'},
        'grp_bbbb0001': {
            'name': 'dyn-prod', 'type': 'dynamic', 'match_tags': {'env': 'prod'},
        },
    },
    'clients': dict(base_clients),
}
check('no-manual-no-dyn-match', state, 'nomanual000000000000000000000001', True)
check('manual-only', state, 'manualonly0000000000000000000002', False)
check('dynamic-only', state, 'dynamiconly000000000000000000003', True)
check('manual+dynamic', state, 'manualdyn00000000000000000000004', False)
check('dynamic-match-still-ungrouped', state, 'tagchange00000000000000000000005', True)
# Tag change removes dynamic match; still ungrouped (no manual).
state['clients']['tagchange00000000000000000000005']['tags'] = {'env': 'dev'}
check('tag-change-no-manual', state, 'tagchange00000000000000000000005', True)
# Sanity: live registry still treats b as ungrouped after dynamics exist.
live = json.loads(reg_path.read_text())
check('live-b-dynamic-only', live, 'bbbbbbbb22222222bbbbbbbb22222222', True)
check('live-a-manual', live, 'aaaaaaaa11111111aaaaaaaa11111111', False)
check('live-c-plain', live, 'cccccccc33333333cccccccc33333333', True)
print('matrix ok')
PY
pass "P3_3_UNGROUPED_MATRIX"

# --- P3.5 Filters ---
"$CLIENTS" --group prod-seoul >"$WORKDIR/f1.out" || fail "filter dynamic group"
"$CLIENTS" --group all >"$WORKDIR/f2.out" || fail "filter all"
"$CLIENTS" --tag env=prod --tag site=seoul >"$WORKDIR/f3.out" || fail "multi tag"
grep -q 'aaaaaaaa' "$WORKDIR/f3.out" || fail "tag filter a"
"$CLIENTS" --group acme-renamed --tag env=prod >"$WORKDIR/f4.out" || fail "group+tag"
grep -q 'aaaaaaaa' "$WORKDIR/f4.out" || fail "group+tag a"
"$CLIENTS" --status offline >"$WORKDIR/f5.out" || fail "status filter"
grep -q 'aaaaaaaa' "$WORKDIR/f5.out" || fail "status offline includes clients with closed ports"
"$CINFO" aaaaaaaa groups >"$WORKDIR/cg.out" || fail "client groups view"
grep -q 'manual' "$WORKDIR/cg.out" || fail "manual type"
grep -q 'dynamic' "$WORKDIR/cg.out" || fail "dynamic type"
pass "P3_5_FILTERS_UX"

# Doctor: dynamic in client group_ids
cp "$REG" "$WORKDIR/registry.before-doctor.json"
python3 - "$REG" <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
for gid, group in state['groups'].items():
    if group.get('type') == 'dynamic':
        state['clients']['cccccccc33333333cccccccc33333333']['group_ids'] = [gid]
        break
json.dump(state, open(sys.argv[1], 'w'), indent=2)
PY
python3 - "$ROOT/lib/frp_doctor.py" "$REG" <<'PY' || fail "doctor dynamic ref"
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location('doc', sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
state = json.load(open(sys.argv[2]))
status, msg, issues = mod.validate_registry(state)
assert status == mod.FAIL, (status, msg, issues)
assert any(
    ('dynamic group' in i) or ('manual groups' in i) or ('canonical' in (msg or '').lower())
    for i in (issues or [msg or ''])
), (msg, issues)
PY
cp "$WORKDIR/registry.before-doctor.json" "$REG"
pass "DOCTOR_DYNAMIC_REF"

# Group membership / assigned_group_ids survive revoke+purge; registry groups survive restore
REVOKE="$ROOT/tools/frp-enrollment-revoke"
PURGE="$ROOT/tools/frp-enrollment-purge"
export FRP_ENROLLMENT_PURGE_YES=1
python3 - "$ROOT" "$TREE" "$REG" "$ENROLL" <<'PY' || fail "group retention enroll"
import hashlib, hmac, importlib.util, json, sys, time
from pathlib import Path

root = Path(sys.argv[1])
tree = Path(sys.argv[2])
reg_path = Path(sys.argv[3])
enroll_dir = Path(sys.argv[4])
spec = importlib.util.spec_from_file_location('alloc', root / 'server/frp-port-allocator.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

state = json.loads(reg_path.read_text())
gid = None
for candidate, group in (state.get('groups') or {}).items():
    if group.get('type', 'manual') == 'manual':
        gid = candidate
        break
assert gid, 'need a manual group'

eid = 'aabbccddeeff0099'
secret = 'd' * 64
now = int(time.time())
(enroll_dir / (eid + '.json')).write_text(json.dumps({
    'id': eid,
    'secret': secret,
    'expires_at': now + 600,
    'bound_machine_id': None,
    'used_at': None,
    'assigned_group_ids': [gid],
}, indent=2) + '\n')

cfg = {
    'public_ip': '203.0.113.10',
    'control_port': 443,
    'port_start': 6000,
    'port_end': 7000,
    'registry_file': str(reg_path),
    'enrollments_dir': str(enroll_dir),
    'token_file': str(reg_path.parent / 'token-ret'),
}
(reg_path.parent / 'token-ret').write_text('tok\n')
cfg_path = reg_path.parent / 'alloc-ret.json'
cfg_path.write_text(json.dumps(cfg) + '\n')
mod.port_is_available = lambda port: True
alloc = mod.Allocator(str(cfg_path))

mid = 'retgrpclient00000000000000000001'
body = json.dumps({
    'machine_id': mid,
    'hostname': 'ret-host',
    'services': [],
}, separators=(',', ':')).encode()
payload, err = alloc.issue_enroll_challenge(eid)
assert not err, err
message = '%s\n%s\n%s' % (payload['challenge_id'], payload['nonce'], body.decode())
sig = hmac.new(secret.encode(), message.encode(), hashlib.sha256).hexdigest()
headers = {
    'X-Enrollment-Challenge-ID': payload['challenge_id'],
    'X-Enrollment-Challenge-Nonce': payload['nonce'],
}
code, result = alloc.enroll(eid, '', sig, body, headers=headers)
assert code == 200, (code, result)
state = json.loads(reg_path.read_text())
assert gid in state['clients'][mid]['group_ids']
assert 'last_mgmt_seen_at' not in state['clients'][mid], 'enrollment must not set last_mgmt_seen_at'
Path(tree / 'var/lib/frp-auto-deploy' / 'retention-gid').write_text(gid + '\n')
Path(tree / 'var/lib/frp-auto-deploy' / 'retention-mid').write_text(mid + '\n')
print('ok')
PY
GID_RET="$(cat "$TREE/var/lib/frp-auto-deploy/retention-gid")"
MID_RET="$(cat "$TREE/var/lib/frp-auto-deploy/retention-mid")"
python3 "$PURGE" enrollment aabbccddeeff0099 >/dev/null || fail "purge completed enrollment with groups"
[[ ! -f "$ENROLL/aabbccddeeff0099.json" ]] || fail "enrollment file should be purged"
python3 - "$REG" "$GID_RET" "$MID_RET" <<'PY' || fail "group_ids survive purge"
import json, sys
state = json.load(open(sys.argv[1]))
assert sys.argv[2] in state['clients'][sys.argv[3]]['group_ids']
assert sys.argv[2] in state['groups']
PY
# Simulate backup/restore of registry (exact JSON round-trip)
cp "$REG" "$WORKDIR/registry.backup.json"
python3 - "$REG" <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({'schema_version': 2, 'clients': {}, 'groups': {}}) + '\n')
PY
cp "$WORKDIR/registry.backup.json" "$REG"
python3 - "$REG" "$GID_RET" "$MID_RET" <<'PY' || fail "group_ids survive restore"
import json, sys
state = json.load(open(sys.argv[1]))
assert sys.argv[2] in state['groups']
assert sys.argv[2] in state['clients'][sys.argv[3]]['group_ids']
print('restored ok')
PY
pass "GROUP_RETENTION_LIFECYCLE"

echo "ALL PHASE3 GROUP TESTS PASSED"
