#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
TREE="$WORK/tree"
mkdir -p "$TREE/etc/frp-auto-deploy/pki" "$TREE/var/lib/frp-auto-deploy/enrollments" "$TREE/var/lib/frp-auto-deploy/bootstrap"
python3 "$ROOT/lib/frp_pki.py" ensure --pki-dir "$TREE/etc/frp-auto-deploy/pki" --public-host example.test >/dev/null
python3 - "$TREE" <<'PY'
import json, sys
from pathlib import Path
root=Path(sys.argv[1])
(root/'etc/frp-auto-deploy/config.json').write_text(json.dumps({
  'enrollments_dir':'/var/lib/frp-auto-deploy/enrollments',
  'bootstrap_dir':'/var/lib/frp-auto-deploy/bootstrap',
  'tls_ca_cert':'/etc/frp-auto-deploy/pki/ca.crt',
  'allocator_public_url':'https://example.test/enroll',
  'client_installer_url':'https://example.test/bootstrap-client.sh',
})+'\n')
PY
export FRP_DEPLOY_TEST_ROOT="$TREE"
python3 "$ROOT/tools/frp-create-client" --one-line --client-name pending-a >"$WORK/create.out"
TICKET="$(python3 - "$WORK/create.out" <<'PY'
import re,sys
t=open(sys.argv[1]).read()
m=re.search(r"FRP_BOOTSTRAP_TICKET='([^']+)'",t)
print(m.group(1))
PY
)"
ID="${TICKET#bt1.}"; ID="${ID%%.*}"; SECRET="${TICKET##*.}"
python3 "$ROOT/tools/frp-enrollments" >"$WORK/list.out"
grep -q 'ID.*TYPE.*LABEL.*CREATED.*EXPIRES.*STATE' "$WORK/list.out"
grep -qE "${ID}[[:space:]]+zero-touch[[:space:]]+pending-a.*pending" "$WORK/list.out"
! grep -Fq "$SECRET" "$WORK/list.out"
python3 "$ROOT/tools/frp-enrollment-revoke" "$ID" >"$WORK/revoke.out"
python3 "$ROOT/tools/frp-enrollments" >"$WORK/revoked.out"
grep -qE "${ID}[[:space:]]+zero-touch.*revoked" "$WORK/revoked.out"
! grep -Fq "$SECRET" "$WORK/revoked.out"
python3 - "$TREE/var/lib/frp-auto-deploy/bootstrap/$ID.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
assert r.get('revoked_at')
PY
echo "PENDING_ENROLLMENTS_TEST=PASS"
