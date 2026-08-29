#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
TREE="$WORK/tree"
mkdir -p "$TREE/etc/frp-auto-deploy/pki" "$TREE/var/lib/frp-auto-deploy/enrollments" "$TREE/var/lib/frp-auto-deploy/bootstrap"
python3 "$ROOT/lib/frp_pki.py" ensure --pki-dir "$TREE/etc/frp-auto-deploy/pki" --public-host example.test >/dev/null
python3 - "$TREE" <<'PY'
import json,sys
from pathlib import Path
r=Path(sys.argv[1])
(r/'etc/frp-auto-deploy/config.json').write_text(json.dumps({
 'enrollments_dir':'/var/lib/frp-auto-deploy/enrollments',
 'bootstrap_dir':'/var/lib/frp-auto-deploy/bootstrap',
 'tls_ca_cert':'/etc/frp-auto-deploy/pki/ca.crt',
 'allocator_public_url':'https://example.test/enroll',
 'client_installer_url':'https://example.test/bootstrap-client.sh',
})+'\n')
PY
export FRP_DEPLOY_TEST_ROOT="$TREE"
python3 "$ROOT/tools/frp-enroll-bulk" --count 3 --label-prefix node >"$WORK/count.csv" 2>"$WORK/count.err"
grep -q 'redirected output contains sensitive' "$WORK/count.err"
cat >"$WORK/input.csv" <<'CSV'
label,ssh_user,note
ssh-node,aella,remote shell
inventory-only,,no service
CSV
python3 "$ROOT/tools/frp-enroll-bulk" --csv "$WORK/input.csv" >"$WORK/input.out" 2>"$WORK/input.err"
python3 - "$WORK/count.csv" "$WORK/input.out" "$TREE/var/lib/frp-auto-deploy/bootstrap" <<'PY'
import csv,json,re,sys
from pathlib import Path
rows=[]
for name in sys.argv[1:3]:
    with open(name,newline='') as f:
        batch=list(csv.DictReader(f))
        assert len({row['expires'] for row in batch})==len(batch)
        rows.extend(batch)
assert len(rows)==5
tickets=[]
for row in rows:
    m=re.search(r"FRP_BOOTSTRAP_TICKET='([^']+)'",row['bootstrap_command'])
    assert m, row
    tickets.append(m.group(1))
assert len(set(tickets))==5
records=[json.loads(p.read_text()) for p in Path(sys.argv[3]).glob('*.json')]
assert len(records)==5
assert len({r['id'] for r in records})==5
assert len({r['enrollment_id'] for r in records})==5
for ticket,record in zip(sorted(tickets), sorted(records,key=lambda r:r['id'])):
    assert ticket not in json.dumps(record)
assert any(r.get('services')==[] for r in records)
assert any((r.get('services') or [{}])[0].get('preset')=='ssh' for r in records if r.get('services'))
PY
echo "ENROLL_BULK_TEST=PASS"
