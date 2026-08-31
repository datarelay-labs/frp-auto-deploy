#!/usr/bin/env bash
# P3.1 Manual Group Management: CRUD, membership, persistence, doctor, CLI.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }

TREE="$WORKDIR/tree"
mkdir -p "$TREE/etc/frp-auto-deploy" "$TREE/var/lib/frp-auto-deploy" "$TREE/var/log/frp-auto-deploy"
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
}, indent=2) + '\n')
reg_path.write_text(json.dumps({
    'schema_version': 2,
    'reserved': [],
    'clients': {
        'aaaaaaaa11111111aaaaaaaa11111111': {
            'hostname': 'gw01',
            'label': 'acme-gw-01',
            'mgmt_status': 'enrolled',
            'mgmt_pubkey': 'KEEP',
            'mgmt_mac_key': 'MAC',
            'mgmt_fingerprint': 'FP',
            'tags': {'env': 'prod'},
            'services': {
                'ssh': {'remote_port': 6001, 'preset': 'ssh', 'enabled': True, 'ssh_user': 'ubuntu'},
            },
        },
        'bbbbbbbb22222222bbbbbbbb22222222': {
            'hostname': 'gw02',
            'label': 'pilot-gw',
            'mgmt_status': 'enrolled',
            'services': {
                'ssh': {'remote_port': 6002, 'preset': 'ssh', 'enabled': True},
            },
        },
        'cccccccc33333333cccccccc33333333': {
            'hostname': 'spare',
            'services': {},
        },
    },
}, indent=2) + '\n')
PY
chmod 600 "$TREE/var/lib/frp-auto-deploy/registry.json"

CTL="$ROOT/tools/frpctl"
FRP_GROUPS="$ROOT/tools/frp-groups"
GSET="$ROOT/tools/frp-group-set"
CLIENTS="$ROOT/tools/frp-clients"
CINFO="$ROOT/tools/frp-client-info"
REG="$TREE/var/lib/frp-auto-deploy/registry.json"

# --- CRUD ---
"$GSET" create customer-acme --description 'ACME customer systems' >"$WORKDIR/create.out" \
  || fail "create group"
grep -q 'Created group grp_' "$WORKDIR/create.out" || fail "create output missing group id"
GID1="$(python3 - "$REG" <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
for gid, group in state['groups'].items():
    if group.get('name') == 'customer-acme':
        print(gid)
        break
else:
    raise SystemExit('missing group')
PY
)"
[[ "$GID1" == grp_* ]] || fail "group id format"

if "$GSET" create customer-acme >"$WORKDIR/dup.out" 2>"$WORKDIR/dup.err"; then
  fail "duplicate group name accepted"
fi
grep -qi 'already exists' "$WORKDIR/dup.err" || fail "duplicate error message"

if "$GSET" create all >"$WORKDIR/res.out" 2>"$WORKDIR/res.err"; then
  fail "reserved name all accepted"
fi
if "$GSET" create ungrouped >"$WORKDIR/res2.out" 2>"$WORKDIR/res2.err"; then
  fail "reserved name ungrouped accepted"
fi
if "$GSET" create 'bad name!' >"$WORKDIR/bad.out" 2>"$WORKDIR/bad.err"; then
  fail "invalid name accepted"
fi
pass "GROUP_CRUD_CREATE"

"$GSET" create pilot >"$WORKDIR/pilot.out" || fail "create pilot"
"$GSET" create seoul || fail "create seoul"
"$FRP_GROUPS" >"$WORKDIR/list.out" || fail "show groups"
grep -q 'customer-acme' "$WORKDIR/list.out" || fail "list missing customer-acme"
grep -q 'pilot' "$WORKDIR/list.out" || fail "list missing pilot"
"$FRP_GROUPS" "$GID1" >"$WORKDIR/byid.out" || fail "show by id"
grep -q "$GID1" "$WORKDIR/byid.out" || fail "detail missing id"
"$FRP_GROUPS" customer-acme >"$WORKDIR/byname.out" || fail "show by name"
grep -q 'ACME customer systems' "$WORKDIR/byname.out" || fail "description missing"
pass "GROUP_SHOW"

"$GSET" set customer-acme --description 'ACME Korea systems' >"$WORKDIR/desc.out" \
  || fail "set description"
"$GSET" set customer-acme --name acme-korea >"$WORKDIR/rename.out" || fail "rename"
grep -q 'Group ID remains' "$WORKDIR/rename.out" || fail "rename identity message"
python3 - "$REG" "$GID1" <<'PY' || fail "rename identity check"
import json, sys
state = json.load(open(sys.argv[1]))
group = state['groups'][sys.argv[2]]
assert group['name'] == 'acme-korea', group
assert group.get('description') == 'ACME Korea systems', group
PY
pass "GROUP_RENAME_DESCRIPTION"

# --- Membership ---
"$GSET" add-member aaaaaaaa "$GID1" >"$WORKDIR/add1.out" || fail "add member"
"$GSET" add-member aaaaaaaa pilot >"$WORKDIR/add2.out" || fail "add second group"
"$GSET" add-member aaaaaaaa seoul || fail "add third group"
"$GSET" add-member bbbbbbbb acme-korea || fail "add second client"
"$GSET" add-member aaaaaaaa acme-korea >"$WORKDIR/add_dup.out" || fail "duplicate add should succeed"
grep -qi 'already' "$WORKDIR/add_dup.out" || fail "duplicate add message"

"$CINFO" aaaaaaaa groups >"$WORKDIR/cgroups.out" || fail "client groups view"
grep -q "$GID1" "$WORKDIR/cgroups.out" || fail "client groups missing id"
grep -q 'acme-korea' "$WORKDIR/cgroups.out" || fail "client groups missing renamed name"
grep -q 'pilot' "$WORKDIR/cgroups.out" || fail "client multi membership"

"$FRP_GROUPS" acme-korea --clients >"$WORKDIR/gclients.out" || fail "group clients"
grep -q 'aaaaaaaa' "$WORKDIR/gclients.out" || fail "group clients missing a"
grep -q 'bbbbbbbb' "$WORKDIR/gclients.out" || fail "group clients missing b"

"$CLIENTS" --group acme-korea >"$WORKDIR/filter.out" || fail "group filter"
grep -q 'aaaaaaaa' "$WORKDIR/filter.out" || fail "filter missing a"
grep -q 'bbbbbbbb' "$WORKDIR/filter.out" || fail "filter missing b"
if grep -q 'cccccccc' "$WORKDIR/filter.out"; then
  fail "filter included ungrouped client"
fi

if "$GSET" add-member zzzzzzzz acme-korea >"$WORKDIR/nclient.out" 2>"$WORKDIR/nclient.err"; then
  fail "nonexistent client accepted"
fi
if "$GSET" add-member aaaaaaaa missing-group >"$WORKDIR/ngroup.out" 2>"$WORKDIR/ngroup.err"; then
  fail "nonexistent group accepted"
fi
pass "GROUP_MEMBERSHIP"

python3 - "$REG" "$GID1" <<'PY' || fail "membership after rename"
import json, sys
state = json.load(open(sys.argv[1]))
client = state['clients']['aaaaaaaa11111111aaaaaaaa11111111']
assert sys.argv[2] in client['group_ids']
assert len(client['group_ids']) == 3
PY
pass "GROUP_RENAME_IDENTITY"

"$GSET" remove-member aaaaaaaa pilot >"$WORKDIR/rm.out" || fail "remove member"
"$GSET" remove-member aaaaaaaa pilot >"$WORKDIR/rm_dup.out" || fail "duplicate remove"
grep -qi 'was not in group' "$WORKDIR/rm_dup.out" || fail "duplicate remove message"
python3 - "$REG" <<'PY' || fail "remove membership check"
import json, sys
state = json.load(open(sys.argv[1]))
client = state['clients']['aaaaaaaa11111111aaaaaaaa11111111']
names = [state['groups'][gid]['name'] for gid in client['group_ids']]
assert 'pilot' not in names
assert 'acme-korea' in names
assert 'seoul' in names
PY
pass "GROUP_REMOVE_MEMBER"

python3 "$ROOT/tools/frp-client-set" aaaaaaaa --label renamed-gw >"$WORKDIR/label.out" \
  || fail "label change"
python3 - "$REG" "$GID1" <<'PY' || fail "membership after label"
import json, sys
state = json.load(open(sys.argv[1]))
client = state['clients']['aaaaaaaa11111111aaaaaaaa11111111']
assert client['label'] == 'renamed-gw'
assert sys.argv[2] in client['group_ids']
assert client['hostname'] == 'gw01'
assert client['services']['ssh']['remote_port'] == 6001
assert client['mgmt_pubkey'] == 'KEEP'
PY
pass "MEMBERSHIP_SURVIVES_LABEL"

python3 - "$ROOT/lib/frp_client_registry.py" <<'PY' || fail "reenroll preserve groups"
import importlib.util
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location('creg', sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
client = {
    'hostname': 'old',
    'label': 'keep-label',
    'tags': {'env': 'prod'},
    'group_ids': ['grp_deadbeef'],
    'services': {'ssh': {'remote_port': 6001}},
}
before = list(client['group_ids'])
mod.seed_admin_metadata(client, label='ignored', note='ignored')
mod.apply_observed_fields(client, hostname='new-host', source_ip='203.0.113.50')
assert client['group_ids'] == before
assert client['tags'] == {'env': 'prod'}
assert client['label'] == 'keep-label'
assert client['hostname'] == 'new-host'
print('ok')
PY
pass "REENROLLMENT_PRESERVATION"

"$GSET" delete seoul >"$WORKDIR/del.out" || fail "delete group"
python3 - "$REG" <<'PY' || fail "delete semantics"
import json, sys
state = json.load(open(sys.argv[1]))
assert not any(g.get('name') == 'seoul' for g in state.get('groups', {}).values())
client = state['clients']['aaaaaaaa11111111aaaaaaaa11111111']
for gid in client.get('group_ids') or []:
    assert gid in state['groups']
assert client['services']['ssh']['remote_port'] == 6001
assert client['mgmt_pubkey'] == 'KEEP'
assert client['hostname'] == 'gw01'
PY
pass "GROUP_DELETE"

python3 - "$REG" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
state = json.load(path.open())
legacy = {
    'schema_version': 2,
    'reserved': state.get('reserved', []),
    'clients': {
        mid: {k: v for k, v in client.items() if k != 'group_ids'}
        for mid, client in state['clients'].items()
    },
}
path.with_suffix('.json.legacy').write_text(json.dumps(legacy, indent=2) + '\n')
PY
cp "$REG" "$WORKDIR/with-groups.json"
cp "$REG.legacy" "$REG"
"$FRP_GROUPS" >"$WORKDIR/legacy_list.out" || fail "old registry list groups"
grep -q '(none)' "$WORKDIR/legacy_list.out" || fail "legacy should show no groups"
"$CLIENTS" >"$WORKDIR/legacy_clients.out" || fail "old registry show clients"
cp "$WORKDIR/with-groups.json" "$REG"
pass "OLD_REGISTRY_COMPATIBILITY"

python3 - "$REG" <<'PY' || fail "backup payload includes groups"
import json, sys
state = json.load(open(sys.argv[1]))
assert 'groups' in state and state['groups']
assert any('group_ids' in c for c in state['clients'].values())
old = {
    'schema_version': 2,
    'reserved': [],
    'clients': {'deadbeefdeadbeefdeadbeefdeadbeef': {'hostname': 'old'}},
}
json.dump(old, open(sys.argv[1] + '.oldbackup', 'w'), indent=2)
PY
cp "$REG.oldbackup" "$REG"
"$FRP_GROUPS" >"$WORKDIR/oldbackup_groups.out" || fail "old backup show groups"
"$CLIENTS" >"$WORKDIR/oldbackup_clients.out" || fail "old backup show clients"
cp "$WORKDIR/with-groups.json" "$REG"
pass "BACKUP_RESTORE_COMPAT"

python3 - "$ROOT/lib/frp_doctor.py" "$REG" <<'PY' || fail "doctor valid"
import importlib.util
import json
import sys
spec = importlib.util.spec_from_file_location('doc', sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
state = json.load(open(sys.argv[2]))
status, msg, issues = mod.validate_registry(state)
assert status == mod.PASS, (status, msg, issues)
print(msg)
PY

python3 - "$REG" <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
state['clients']['aaaaaaaa11111111aaaaaaaa11111111']['group_ids'].append('grp_00000000')
json.dump(state, open(sys.argv[1], 'w'), indent=2)
PY
python3 - "$ROOT/lib/frp_doctor.py" "$REG" <<'PY' || fail "doctor dangling"
import importlib.util
import json
import sys
spec = importlib.util.spec_from_file_location('doc', sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
state = json.load(open(sys.argv[2]))
status, msg, issues = mod.validate_registry(state)
assert status == mod.FAIL, (status, msg)
assert any('nonexistent group' in i for i in issues), issues
print('dangling detected')
PY
cp "$WORKDIR/with-groups.json" "$REG"
pass "DOCTOR_GROUPS"

AUDIT_LOG="$TREE/var/log/frp-auto-deploy/audit.jsonl"
if [[ -f "$AUDIT_LOG" ]]; then
  grep -q 'group.created' "$AUDIT_LOG" || fail "audit group.created"
  grep -q 'group.updated' "$AUDIT_LOG" || fail "audit group.updated"
  grep -q 'group.member_added' "$AUDIT_LOG" || fail "audit member_added"
  grep -q 'group.member_removed' "$AUDIT_LOG" || fail "audit member_removed"
  grep -q 'group.deleted' "$AUDIT_LOG" || fail "audit group.deleted"
  pass "AUDIT"
else
  echo "WARN audit file missing at $AUDIT_LOG"
  fail "AUDIT file missing"
fi

"$CTL" create group safe-group --description 'value with $HOME and `id` and ; rm -rf /' \
  >"$WORKDIR/safe.out" 2>"$WORKDIR/safe.err" || fail "quoted description via frpctl"
python3 - "$REG" <<'PY' || fail "description stored literally"
import json, sys
state = json.load(open(sys.argv[1]))
group = next(g for g in state['groups'].values() if g.get('name') == 'safe-group')
assert '$HOME' in group.get('description', '')
assert '`id`' in group['description']
PY
pass "SECURITY_QUOTED_DESCRIPTION"

"$CTL" show groups >"$WORKDIR/ctl_groups.out" || fail "frpctl show groups"
"$CTL" show group acme-korea clients >"$WORKDIR/ctl_gc.out" || fail "frpctl show group clients"
"$CTL" show client aaaaaaaa groups >"$WORKDIR/ctl_cg.out" || fail "frpctl show client groups"
"$CTL" help create >"$WORKDIR/help_create.out" || fail "help create"
grep -q 'create group' "$WORKDIR/help_create.out" || fail "help create missing group"
"$CTL" help remove >"$WORKDIR/help_remove.out" || fail "help remove"
grep -q 'remove group' "$WORKDIR/help_remove.out" || fail "help remove missing group"
"$CTL" help add >"$WORKDIR/help_add.out" || fail "help add"
grep -q 'add client' "$WORKDIR/help_add.out" || fail "help add client group"
pass "CLI_DISPATCH_HELP"

python3 - "$ROOT/lib/frp_ctl_grammar.py" <<'PY' || fail "completion"
import importlib.util
import sys
spec = importlib.util.spec_from_file_location('g', sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
verbs = mod.canonical_verbs('server')
assert 'remove' in verbs and 'add' in verbs
cands = mod.completion_candidates('show ', 'server', ['aaaaaaaa'], {}, [], groups=['grp_11111111'])
assert 'groups' in cands and 'group' in cands
cands = mod.completion_candidates('show client aaaaaaaa ', 'server', ['aaaaaaaa'], {}, [], groups=['grp_11111111'])
assert 'groups' in cands
cands = mod.completion_candidates('remove ', 'server', ['aaaaaaaa'], {}, [], groups=['grp_11111111'])
assert 'client' in cands and 'group' in cands
cands = mod.completion_candidates('add client aaaaaaaa group ', 'server', ['aaaaaaaa'], {}, [], groups=['grp_11111111'])
assert 'grp_11111111' in cands
print('completion ok')
PY
pass "CLI_HELP_COMPLETION"

echo "ALL GROUP TESTS PASSED"
