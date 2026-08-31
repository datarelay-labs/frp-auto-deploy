#!/usr/bin/env bash
# Enrollment retention, purge, auto cleanup, and pair-aware lifecycle tests.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
TREE="$WORK/tree"
mkdir -p \
  "$TREE/etc/frp-auto-deploy/pki" \
  "$TREE/var/lib/frp-auto-deploy/enrollments" \
  "$TREE/var/lib/frp-auto-deploy/bootstrap"

python3 "$ROOT/lib/frp_pki.py" ensure --pki-dir "$TREE/etc/frp-auto-deploy/pki" --public-host example.test >/dev/null
python3 - "$TREE" <<'PY'
import json, sys
from pathlib import Path
root = Path(sys.argv[1])
(root / 'etc/frp-auto-deploy/config.json').write_text(json.dumps({
  'enrollments_dir': '/var/lib/frp-auto-deploy/enrollments',
  'bootstrap_dir': '/var/lib/frp-auto-deploy/bootstrap',
  'registry_file': '/var/lib/frp-auto-deploy/registry.json',
  'enrollment_retention_days': 30,
  'tls_ca_cert': '/etc/frp-auto-deploy/pki/ca.crt',
  'allocator_public_url': 'https://example.test/enroll',
  'client_installer_url': 'https://example.test/bootstrap-client.sh',
}) + '\n')
(root / 'var/lib/frp-auto-deploy/registry.json').write_text(json.dumps({'schema_version': 2, 'clients': {}}) + '\n')
PY

export FRP_DEPLOY_TEST_ROOT="$TREE"
export FRP_ENROLLMENT_PURGE_YES=1
CREATE="$ROOT/tools/frp-create-client"
REVOKE="$ROOT/tools/frp-enrollment-revoke"
PURGE="$ROOT/tools/frp-enrollment-purge"
LIFECYCLE="$ROOT/lib/frp_enrollment_lifecycle.py"

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }

seed_manual() {
  local eid="$1" state="$2" terminal_iso="$3"
  python3 - "$TREE" "$eid" "$state" "$terminal_iso" <<'PY'
import json, sys, time
from pathlib import Path
root, eid, state, terminal_iso = sys.argv[1:5]
now = int(time.time())
rec = {
  'id': eid,
  'secret': 'a' * 64,
  'created_at': '2026-07-01T00:00:00Z',
  'expires_at': now + 600,
  'expires_at_iso': '2099-01-01T00:00:00Z',
  'bound_machine_id': None,
  'used_at': None,
  'label': state,
}
if state == 'expired':
    if terminal_iso:
        try:
            from datetime import datetime, timezone
            text = terminal_iso.replace('Z', '+00:00')
            rec['expires_at'] = int(datetime.fromisoformat(text).timestamp())
        except (ValueError, OverflowError, OSError):
            rec['expires_at'] = int(time.time()) - 86400
    else:
        rec['expires_at'] = int(time.time()) - 86400
    rec['expires_at_iso'] = terminal_iso or '2026-01-01T00:00:00Z'
elif state == 'completed':
    rec['used_at'] = terminal_iso
    rec['bound_machine_id'] = 'machine00000001'
elif state == 'revoked':
    rec['revoked_at'] = terminal_iso
elif state == 'bound':
    rec['bound_machine_id'] = 'machine00000001'
path = Path(root) / 'var/lib/frp-auto-deploy/enrollments' / (eid + '.json')
path.write_text(json.dumps(rec, indent=2) + '\n')
PY
}

seed_zero_touch() {
  local tid="$1" eid="$2" state="$3" terminal_iso="$4"
  python3 - "$TREE" "$tid" "$eid" "$state" "$terminal_iso" <<'PY'
import json, sys, time
from pathlib import Path
root, tid, eid, state, terminal_iso = sys.argv[1:6]
now = int(time.time())
expires = now + 600
ticket = {
  'schema': 1,
  'id': tid,
  'secret_hash': 'b' * 64,
  'enrollment_id': eid,
  'created_at': '2026-07-01T00:00:00Z',
  'expires_at': expires,
  'bound_machine_id': None,
  'completed_at': None,
  'label': state,
  'note': '',
  'services': [],
}
enroll = {
  'id': eid,
  'secret': 'c' * 64,
  'created_at': '2026-07-01T00:00:00Z',
  'expires_at': expires,
  'expires_at_iso': '2099-01-01T00:00:00Z',
  'bound_machine_id': None,
  'used_at': None,
  'label': state,
}
if state == 'expired':
    ts = int(time.time()) - 86400
    ticket['expires_at'] = ts
    enroll['expires_at'] = ts
elif state == 'completed':
    ticket['completed_at'] = terminal_iso
    ticket['bound_machine_id'] = 'machine00000001'
    enroll['used_at'] = terminal_iso
    enroll['bound_machine_id'] = 'machine00000001'
elif state == 'revoked':
    ticket['revoked_at'] = terminal_iso
    enroll['revoked_at'] = terminal_iso
elif state == 'bound':
    ticket['bound_machine_id'] = 'machine00000001'
root = Path(root)
(root / 'var/lib/frp-auto-deploy/bootstrap' / (tid + '.json')).write_text(json.dumps(ticket, indent=2) + '\n')
(root / 'var/lib/frp-auto-deploy/enrollments' / (eid + '.json')).write_text(json.dumps(enroll, indent=2) + '\n')
PY
}

python3 "$CREATE" --client-name pending-block >"$WORK/pending.out"
PENDING_ID="$(awk '/^Enrollment ID:/{print $3; exit}' "$WORK/pending.out")"
if python3 "$PURGE" enrollment "$PENDING_ID" >/dev/null 2>"$WORK/pending-purge.err"; then
  fail "PENDING_PURGE_BLOCKED"
fi
grep -q 'active enrollment cannot be purged' "$WORK/pending-purge.err" || fail "PENDING_PURGE_BLOCKED message"
pass "PENDING_PURGE_BLOCKED"

seed_manual bbbbbbbbbbbbbbbb bound ''
if python3 "$PURGE" enrollment bbbbbbbbbbbbbbbb >/dev/null 2>"$WORK/bound-purge.err"; then
  fail "BOUND_PURGE_BLOCKED"
fi
grep -q 'active enrollment cannot be purged' "$WORK/bound-purge.err" || fail "BOUND_PURGE_BLOCKED message"
pass "BOUND_PURGE_BLOCKED"

python3 "$CREATE" --client-name rev-pending >"$WORK/rev-p.out"
REV_P="$(awk '/^Enrollment ID:/{print $3; exit}' "$WORK/rev-p.out")"
python3 "$REVOKE" "$REV_P" >/dev/null
pass "PENDING_REVOKE"

seed_manual cccccccccccccccc bound ''
python3 "$REVOKE" cccccccccccccccc >/dev/null 2>"$WORK/rev-bound.err" || true
pass "BOUND_REVOKE"

seed_manual dddddddddddddddd expired '2026-07-01T00:00:00Z'
if python3 "$REVOKE" dddddddddddddddd >/dev/null 2>"$WORK/rev-exp.err"; then
  fail "EXPIRED_REVOKE_REFUSAL"
fi
grep -q 'expired enrollment' "$WORK/rev-exp.err" || fail "EXPIRED_REVOKE_REFUSAL message"
pass "EXPIRED_REVOKE_REFUSAL"

seed_manual eeeeeeeeeeeeeeee completed '2026-08-30T01:00:00Z'
if python3 "$REVOKE" eeeeeeeeeeeeeeee >/dev/null 2>"$WORK/rev-comp.err"; then
  fail "COMPLETED_REVOKE_REFUSAL"
fi
grep -q 'completed enrollment' "$WORK/rev-comp.err" || fail "COMPLETED_REVOKE_REFUSAL message"
pass "COMPLETED_REVOKE_REFUSAL"

seed_manual ffffffffffffffff revoked '2026-08-30T00:05:00Z'
if python3 "$REVOKE" ffffffffffffffff >/dev/null 2>"$WORK/rev-rev.err"; then
  fail "ALREADY_REVOKED_BEHAVIOR"
fi
grep -q 'already revoked' "$WORK/rev-rev.err" || fail "ALREADY_REVOKED_BEHAVIOR message"
pass "ALREADY_REVOKED_BEHAVIOR"

seed_manual 1111111111111111 expired '2026-07-01T00:00:00Z'
python3 "$PURGE" enrollment 1111111111111111 >/dev/null
[[ ! -f "$TREE/var/lib/frp-auto-deploy/enrollments/1111111111111111.json" ]] || fail "MANUAL_EXPIRED_PURGE"
pass "MANUAL_EXPIRED_PURGE"

seed_manual 2222222222222222 completed '2026-08-30T01:00:00Z'
python3 "$PURGE" enrollment 2222222222222222 >/dev/null
[[ ! -f "$TREE/var/lib/frp-auto-deploy/enrollments/2222222222222222.json" ]] || fail "MANUAL_COMPLETED_PURGE"
pass "MANUAL_COMPLETED_PURGE"

seed_manual 3333333333333333 revoked '2026-08-30T00:05:00Z'
python3 "$PURGE" enrollment 3333333333333333 >/dev/null
[[ ! -f "$TREE/var/lib/frp-auto-deploy/enrollments/3333333333333333.json" ]] || fail "MANUAL_REVOKED_PURGE"
pass "MANUAL_REVOKED_PURGE"

seed_zero_touch 4444444444444444 5555555555555555 expired '2026-07-01T00:00:00Z'
python3 "$PURGE" enrollment 4444444444444444 >/dev/null
[[ ! -f "$TREE/var/lib/frp-auto-deploy/bootstrap/4444444444444444.json" ]] || fail "ZERO_TOUCH_EXPIRED ticket"
[[ ! -f "$TREE/var/lib/frp-auto-deploy/enrollments/5555555555555555.json" ]] || fail "ZERO_TOUCH_EXPIRED enroll"
pass "ZERO_TOUCH_EXPIRED_PURGE"

seed_zero_touch 6666666666666666 7777777777777777 completed '2026-08-30T02:00:00Z'
python3 "$PURGE" enrollment 6666666666666666 >/dev/null
[[ ! -f "$TREE/var/lib/frp-auto-deploy/bootstrap/6666666666666666.json" ]] || fail "ZERO_TOUCH_COMPLETED ticket"
[[ ! -f "$TREE/var/lib/frp-auto-deploy/enrollments/7777777777777777.json" ]] || fail "ZERO_TOUCH_COMPLETED enroll"
pass "ZERO_TOUCH_COMPLETED_PURGE"

seed_zero_touch 8888888888888888 9999999999999999 revoked '2026-08-30T00:10:00Z'
python3 "$PURGE" enrollment 8888888888888888 >/dev/null
[[ ! -f "$TREE/var/lib/frp-auto-deploy/bootstrap/8888888888888888.json" ]] || fail "ZERO_TOUCH_REVOKED ticket"
[[ ! -f "$TREE/var/lib/frp-auto-deploy/enrollments/9999999999999999.json" ]] || fail "ZERO_TOUCH_REVOKED enroll"
pass "ZERO_TOUCH_REVOKED_PURGE"
pass "ZERO_TOUCH_PAIR_PURGE"

python3 - "$LIFECYCLE" <<'PY'
import importlib.util, sys, time
spec = importlib.util.spec_from_file_location('elc', sys.argv[1])
elc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(elc)
now = int(time.time())
retention = 30
cutoff = now - retention * 86400

def row(state, terminal_at):
    return {'state': state, 'terminal_at': terminal_at, 'pair_error': None}

assert not elc.is_retention_eligible(row('expired', cutoff + 86400), now, retention)
print('PASS RETENTION_29D')
assert elc.is_retention_eligible(row('expired', cutoff), now, retention)
print('PASS RETENTION_30D_BOUNDARY')
assert elc.is_retention_eligible(row('expired', cutoff - 86400), now, retention)
print('PASS RETENTION_31D')
PY

OLD_ID=aaaaaaaaaaaaaaaa
seed_manual "$OLD_ID" expired '2026-01-01T00:00:00Z'
RECENT_ID=bbbbbbbbbbbbbbbb
seed_manual "$RECENT_ID" expired ''
python3 - "$TREE" "$RECENT_ID" <<'PY'
import json, sys, time
from pathlib import Path
root, eid = sys.argv[1:3]
path = Path(root) / 'var/lib/frp-auto-deploy/enrollments' / (eid + '.json')
rec = json.loads(path.read_text())
rec['expires_at'] = int(time.time()) - 5 * 86400
path.write_text(json.dumps(rec, indent=2) + '\n')
PY
python3 "$CREATE" --client-name retention-trigger >"$WORK/auto.out"
[[ ! -f "$TREE/var/lib/frp-auto-deploy/enrollments/${OLD_ID}.json" ]] || fail "AUTO_CLEANUP old terminal"
[[ -f "$TREE/var/lib/frp-auto-deploy/enrollments/${RECENT_ID}.json" ]] || fail "AUTO_CLEANUP recent terminal"
NEW_ID="$(awk '/^Enrollment ID:/{print $3; exit}' "$WORK/auto.out")"
[[ -f "$TREE/var/lib/frp-auto-deploy/enrollments/${NEW_ID}.json" ]] || fail "AUTO_CLEANUP active pending"
pass "AUTO_CLEANUP"

python3 - "$TREE" <<'PY'
import json, sys, time
from pathlib import Path
root = Path(sys.argv[1])
tid = 'aaaabbbbccccdddd'
path = root / 'var/lib/frp-auto-deploy/bootstrap' / (tid + '.json')
rec = {
  'schema': 1,
  'id': tid,
  'secret_hash': 'd' * 64,
  'enrollment_id': 'eeeeffffaaaabbbb',
  'created_at': '2026-01-01T00:00:00Z',
  'expires_at': int(time.time()) - 86400 * 60,
  'completed_at': '2026-08-30T01:00:00Z',
  'label': 'mismatch',
  'services': [],
}
path.write_text(json.dumps(rec, indent=2) + '\n')
ep = root / 'var/lib/frp-auto-deploy/enrollments' / 'eeeeffffaaaabbbb.json'
ep.write_text(json.dumps({
  'id': 'eeeeffffaaaabbbb',
  'secret': 'e' * 64,
  'created_at': '2026-01-01T00:00:00Z',
  'expires_at': int(time.time()) - 86400 * 60,
  'used_at': None,
  'label': 'mismatch',
}, indent=2) + '\n')
PY
if python3 "$PURGE" enrollment aaaabbbbccccdddd >/dev/null 2>"$WORK/pair-fail.err"; then
  fail "PAIR_MISMATCH_PURGE_BLOCKED"
fi
grep -q 'ERROR' "$WORK/pair-fail.err" || fail "PAIR_MISMATCH_PURGE_BLOCKED message"
pass "PAIR_MISMATCH_PURGE_BLOCKED"

python3 - "$TREE" "$LIFECYCLE" <<'PY'
import importlib.util, json, sys
from pathlib import Path
root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('elc', sys.argv[2])
elc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(elc)
cfg = json.loads((root / 'etc/frp-auto-deploy/config.json').read_text())
assert elc.retention_days_from_config(cfg) == 30
del cfg['enrollment_retention_days']
assert elc.retention_days_from_config(cfg) == 30
print('PASS OLD_CONFIG_COMPATIBILITY')
PY

seed_manual 1212121212121212 expired '2026-01-01T00:00:00Z'
seed_manual 1313131313131313 completed '2026-01-01T00:00:00Z'
python3 "$PURGE" enrollments --older-than 30 | grep -q 'Matched records' || fail "BULK_PURGE_PREVIEW"
python3 "$PURGE" enrollments --older-than 30 >/dev/null
[[ ! -f "$TREE/var/lib/frp-auto-deploy/enrollments/1212121212121212.json" ]] || fail "BULK_PURGE"
pass "BULK_PURGE"

# Pair purge atomicity: before-commit failure restores both; after-commit
# leftover .purging is OK when both absent from active namespace.
python3 - "$TREE" "$LIFECYCLE" <<'PY'
import importlib.util, json, os, sys, time
from pathlib import Path

root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('elc', sys.argv[2])
elc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(elc)

enroll_dir = root / 'var/lib/frp-auto-deploy/enrollments'
boot_dir = root / 'var/lib/frp-auto-deploy/bootstrap'
tid = 'feedfacecafebeef'
eid = 'deadbeefcafef00d'
now = int(time.time())
ticket = {
    'schema': 1,
    'id': tid,
    'secret_hash': 'a' * 64,
    'enrollment_id': eid,
    'created_at': '2026-01-01T00:00:00Z',
    'expires_at': now - 86400 * 90,
    'completed_at': '2026-01-02T00:00:00Z',
    'label': 'pair-atom',
    'services': [],
}
enroll = {
    'id': eid,
    'secret': 'b' * 64,
    'created_at': '2026-01-01T00:00:00Z',
    'expires_at': now - 86400 * 90,
    'used_at': '2026-01-02T00:00:00Z',
    'label': 'pair-atom',
}
tpath = boot_dir / (tid + '.json')
epath = enroll_dir / (eid + '.json')
tpath.write_text(json.dumps(ticket, indent=2) + '\n')
epath.write_text(json.dumps(enroll, indent=2) + '\n')

# Inject stage failure on second rename; first must roll back.
real_stage = elc._stage_delete
calls = {'n': 0}

def flaky_stage(path):
    calls['n'] += 1
    if calls['n'] >= 2:
        raise OSError('simulated stage failure')
    return real_stage(path)

elc._stage_delete = flaky_stage
row = {
    'id': eid,
    'state': 'completed',
    'type': 'zero-touch',
    'enroll_path': str(epath),
    'ticket_path': str(tpath),
    'pair_error': None,
}
try:
    try:
        elc.purge_enrollment_row(row, reason='test')
        raise SystemExit('FAIL: purge should have failed mid-stage')
    except Exception:
        pass
    # Both must be restored to the active namespace — never ticket-only or enroll-only.
    if not tpath.is_file() or not epath.is_file():
        raise SystemExit('FAIL: pair not fully restored after pre-commit failure')
    if list(boot_dir.glob('*.purging')) or list(enroll_dir.glob('*.purging')):
        raise SystemExit('FAIL: leftover tombstones after rollback')
finally:
    elc._stage_delete = real_stage

# Happy path: both removed from active; leftover .purging after commit is tolerated.
tpath.write_text(json.dumps(ticket, indent=2) + '\n')
epath.write_text(json.dumps(enroll, indent=2) + '\n')
committed = []
real_commit = elc._commit_staged_deletes

def sticky_commit(staged_paths):
    errors = real_commit(staged_paths)
    # Leave one tombstone behind to simulate cleanup failure after rename commit.
    for staged in staged_paths:
        if staged is None:
            continue
        p = Path(staged)
        if not p.exists():
            p.write_text('tombstone-retry')
            committed.append(p)
            break
    return errors

elc._commit_staged_deletes = sticky_commit
try:
    elc.purge_enrollment_row(row, reason='test')
finally:
    elc._commit_staged_deletes = real_commit
if tpath.is_file() or epath.is_file():
    raise SystemExit('FAIL: active pair files still present after successful purge')
print('PASS PAIR_PURGE_ATOMICITY')
PY
pass "PAIR_PURGE_ATOMICITY"

# Malformed JSON must surface as malformed_bootstrap / malformed_enrollment
# (not orphan_bootstrap_ticket) and doctor must WARN on them.
python3 - "$TREE" "$LIFECYCLE" <<'PY'
import importlib.util
import os
import sys
from pathlib import Path

root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('elc', sys.argv[2])
elc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(elc)

enroll_dir = root / 'var/lib/frp-auto-deploy/enrollments'
boot_dir = root / 'var/lib/frp-auto-deploy/bootstrap'
(enroll_dir / 'bad-enroll.json').write_text('{not-json\n')
(boot_dir / 'bad-boot.json').write_text('[]\n')

# collect still skips corrupt files (housekeeping must not abort).
rows = elc.collect_logical_enrollments(enroll_dir, boot_dir)
for row in rows:
    if row.get('id') in ('bad-enroll', 'bad-boot'):
        raise SystemExit('FAIL: collect should skip malformed JSON rows')

findings = elc.scan_malformed_enrollment_files(enroll_dir, boot_dir)
kinds = {k for k, _name, _d in findings}
if 'malformed_enrollment' not in kinds:
    raise SystemExit('FAIL: missing malformed_enrollment finding: %r' % (findings,))
if 'malformed_bootstrap' not in kinds:
    raise SystemExit('FAIL: missing malformed_bootstrap finding: %r' % (findings,))
if any(k == 'orphan_bootstrap_ticket' for k, _n, _d in findings):
    raise SystemExit('FAIL: malformed bootstrap must not be named orphan_bootstrap_ticket')

scan = elc.doctor_scan_enrollment_lifecycle(enroll_dir, boot_dir, retention_days=30)
scan_kinds = {k for k, _n, _d in scan}
if 'malformed_enrollment' not in scan_kinds or 'malformed_bootstrap' not in scan_kinds:
    raise SystemExit('FAIL: doctor_scan missing malformed kinds: %r' % (scan,))
if any(k == 'orphan_bootstrap_ticket' for k, _n, _d in scan):
    raise SystemExit('FAIL: doctor_scan still emits orphan_bootstrap_ticket for corrupt JSON')

# Doctor WARN surface (state checks) must classify these as WARN.
# FRP_DEPLOY_TEST_ROOT remaps /var/lib/... into the isolated tree.
os.environ['FRP_DEPLOY_TEST_ROOT'] = str(root)
sys.path.insert(0, str(Path(sys.argv[2]).resolve().parent))
import frp_doctor

facts = {
    'expect_root_owner': False,
    'systemd_usable': False,
    'skip_network': True,
    'units': {},
    'network': {},
    'platform': {},
    'disk': {},
    'clock': {'status': 'ok', 'detail': ''},
}
_text, _code, report = frp_doctor.run_doctor(str(root), facts, fmt='json', skip_network=True)
statuses = {c['id']: c['status'] for c in report.checks}
matched = [
    (cid, st) for cid, st in statuses.items()
    if 'malformed_bootstrap' in cid or 'malformed_enrollment' in cid
]
if not matched:
    raise SystemExit('FAIL: doctor report missing malformed checks: %r' % (sorted(statuses),))
for cid, st in matched:
    if st != 'WARN':
        raise SystemExit('FAIL: doctor %s status=%s (want WARN)' % (cid, st))
print('PASS MALFORMED_ENROLLMENT_VISIBILITY')
PY
pass "MALFORMED_ENROLLMENT_VISIBILITY"

echo "ENROLLMENT_RETENTION_TESTS=PASS"
