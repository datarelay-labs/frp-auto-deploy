#!/usr/bin/env bash
# Zero-touch one-liners propagate candidate exact SHA and Windows compact join.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1 ${2:-}" >&2; exit 1; }

SHA='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
TREE="$WORKDIR/tree"
mkdir -p "$TREE/etc/frp-auto-deploy/pki" \
  "$TREE/var/lib/frp-auto-deploy/enrollments" \
  "$TREE/var/lib/frp-auto-deploy/bootstrap" \
  "$TREE/etc/frp"
python3 "$ROOT/lib/frp_pki.py" ensure \
  --pki-dir "$TREE/etc/frp-auto-deploy/pki" \
  --public-host 203.0.113.10 >/dev/null

cat >"$TREE/etc/frp-auto-deploy/version" <<EOF
PROJECT_VERSION=2.1.1
FRP_VERSION=0.70.1
RELEASE_CHANNEL=candidate
SOURCE_REF=$SHA
EOF

python3 - "$TREE" "$SHA" <<'PY'
import json, sys
from pathlib import Path
tree = Path(sys.argv[1])
sha = sys.argv[2]
(tree / 'var/lib/frp-auto-deploy/registry.json').write_text(json.dumps({
    'schema_version': 2, 'reserved': [], 'clients': {},
}, indent=2) + '\n')
(tree / 'etc/frp-auto-deploy/config.json').write_text(json.dumps({
    'public_host': '203.0.113.10',
    'public_ip': '203.0.113.10',
    'frp_control_public_port': 7000,
    'frp_control_listen_port': 7000,
    'allocator_public_url': 'https://203.0.113.10:6099/enroll',
    'tls_ca_cert': str(tree / 'etc/frp-auto-deploy/pki/ca.crt'),
    'client_installer_url': (
        'https://raw.githubusercontent.com/datarelay-labs/frp-auto-deploy/'
        + sha + '/dist/bootstrap-client.sh'
    ),
    'windows_client_installer_url': (
        'https://raw.githubusercontent.com/datarelay-labs/frp-auto-deploy/'
        + sha + '/dist/bootstrap-client.ps1'
    ),
    'enrollments_dir': str(tree / 'var/lib/frp-auto-deploy/enrollments'),
    'bootstrap_dir': str(tree / 'var/lib/frp-auto-deploy/bootstrap'),
    'registry_file': str(tree / 'var/lib/frp-auto-deploy/registry.json'),
    'token_file': str(tree / 'etc/frp/server_token'),
}, indent=2) + '\n')
PY

CREATE="$ROOT/tools/frp-create-client"
export FRP_DEPLOY_TEST_ROOT="$TREE"

FRP_DEPLOY_TEST_ROOT="$TREE" python3 "$CREATE" --one-line --ssh --ssh-user aella \
  >"$WORKDIR/linux.out" 2>"$WORKDIR/linux.err"
CMD="$(grep -E '^curl -fsSL ' "$WORKDIR/linux.out" | head -n1)"
[[ -n "$CMD" ]] || fail "missing linux curl command"
printf '%s' "$CMD" | grep -q "FRP_RELEASE_CHANNEL='candidate'" \
  || fail "linux missing candidate channel" "$CMD"
printf '%s' "$CMD" | grep -q "FRP_SOURCE_REF='$SHA'" \
  || fail "linux missing exact SHA" "$CMD"
printf '%s' "$CMD" | grep -q "/${SHA}/dist/bootstrap-client.sh" \
  || fail "linux installer URL not exact SHA"
if printf '%s' "$CMD" | grep -qE 'v2\.1\.1'; then
  fail "linux one-line used v2.1.1 tag"
fi
pass "LINUX_ONE_LINE_CANDIDATE_IDENTITY"

FRP_DEPLOY_TEST_ROOT="$TREE" python3 "$CREATE" --platform windows --one-line --rdp \
  >"$WORKDIR/win.out" 2>"$WORKDIR/win.err"
WCMD="$(grep -E '^powershell(\.exe)? ' "$WORKDIR/win.out" | head -n1)"
[[ -n "$WCMD" ]] || fail "missing windows powershell command"
printf '%s' "$WCMD" | grep -q "windows-join.ps1" || fail "missing windows-join launcher URL" "$WCMD"
printf '%s' "$WCMD" | grep -q "/${SHA}/dist/windows-join.ps1" \
  || fail "windows-join URL not exact SHA" "$WCMD"
printf '%s' "$WCMD" | grep -q " -Join " || fail "missing -Join argument" "$WCMD"
printf '%s' "$WCMD" | grep -q "frpj1\." || fail "missing frpj1 descriptor" "$WCMD"
printf '%s' "$WCMD" | grep -qi 'Invoke-Expression\|irm |' && fail "obfuscation/iex present" || true
if printf '%s' "$WCMD" | grep -qi 'EncodedCommand'; then
  fail "EncodedCommand obfuscation present"
fi
# Compactness vs legacy embedded bootstrap download+hash+env block (~1800 chars).
python3 - "$WCMD" <<'PY' || fail "windows command not compact enough"
import sys
cmd = sys.argv[1]
n = len(cmd)
# Target roughly 20-35% of prior ~1793 length.
if n > 650:
    raise SystemExit('too long: %s' % n)
print('windows_cmd_len', n)
PY
grep -q 'C:\\ProgramData\\frp-auto-deploy\\tools\\frp-client.cmd start' "$WORKDIR/win.out" \
  || fail "windows guidance missing full tools path"
grep -q 'Release channel: candidate' "$WORKDIR/win.out" || fail "windows channel label"
grep -q "Source ref: $SHA" "$WORKDIR/win.out" || fail "windows source ref label"
pass "WINDOWS_COMPACT_JOIN_CANDIDATE"

# Descriptor round-trip contains channel + SHA (opaque, not command obfuscation).
python3 - "$WORKDIR/win.out" "$SHA" <<'PY' || fail "descriptor missing identity"
import base64, re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text()
sha = sys.argv[2]
m = re.search(r"-Join (?:''|')(frpj1\.[A-Za-z0-9_\-]+)(?:''|')", text)
if not m:
    raise SystemExit('no join descriptor')
desc = m.group(1)
assert desc.startswith('frpj1.')
b64 = desc[len('frpj1.'):] + '=' * (-len(desc[len('frpj1.'):]) % 4)
raw = base64.urlsafe_b64decode(b64.encode('ascii')).decode('utf-8')
parts = raw.split('|')
assert len(parts) >= 5
assert parts[3] == 'candidate'
assert parts[4] == sha
assert parts[0].startswith('https://')
assert len(parts[1]) == 64
assert parts[2]
print('descriptor_ok')
PY
pass "WINDOWS_JOIN_DESCRIPTOR_IDENTITY"

echo "ALL PASS test-zero-touch-candidate-identity"
