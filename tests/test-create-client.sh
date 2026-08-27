#!/usr/bin/env bash
# frp-create-client prints a complete, safely quoted client command.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }

TREE="$WORKDIR/tree"
mkdir -p "$TREE/etc/frp-auto-deploy" "$TREE/var/lib/frp-auto-deploy/enrollments"

python3 - "$TREE/etc/frp-auto-deploy/config.json" "$TREE/var/lib/frp-auto-deploy/enrollments" <<'PY'
import json, sys
from pathlib import Path
cfg = Path(sys.argv[1])
enroll = Path(sys.argv[2])
cfg.write_text(json.dumps({
  "public_ip": "203.0.113.10",
  "control_port": 443,
  "allocator_public_url": "http://203.0.113.10/enroll",
  "client_installer_url": "https://raw.githubusercontent.com/datarelay-labs/frp-auto-deploy/main/dist/bootstrap-client.sh",
  "enrollments_dir": str(enroll),
}, indent=2) + "\n")
PY

OUT="$WORKDIR/create.out"
FRP_DEPLOY_TEST_ROOT="$TREE" python3 "$ROOT/tools/frp-create-client" >"$OUT"
grep -q 'Enrollment Code:' "$OUT" || fail "enrollment header"
grep -qE '^[0-9a-f]{16}\.[0-9a-f]{64}$' "$OUT" || fail "enrollment code format"
grep -q 'sudo env FRP_ALLOCATOR_URL=' "$OUT" || fail "sudo env allocator URL"
grep -q 'http://203.0.113.10/enroll' "$OUT" || fail "allocator URL value"
grep -q 'curl -fsSL' "$OUT" || fail "curl installer"
if grep -q 'FRP_ENROLLMENT' "$OUT"; then
  fail "enrollment secret must not appear in the env command name"
fi
# The code itself is printed once for interactive entry; the sudo env line must not include it.
code="$(awk '/^Enrollment Code:/{getline; print; exit}' "$OUT")"
sudo_line="$(grep 'sudo env FRP_ALLOCATOR_URL=' "$OUT")"
if grep -F "$code" <<<"$sudo_line" >/dev/null; then
  fail "enrollment code leaked into sudo command"
fi
grep -q 'datarelay-labs/frp-auto-deploy' "$OUT" || fail "canonical repository URL"
if grep -F 'RickLee-kr' "$OUT" >/dev/null; then
  fail "stale repository owner in frp-create-client output"
fi
pass "CASE D generated client command"

# Shell-sensitive allocator URL is quoted so bash does not execute extra commands.
python3 - "$TREE/etc/frp-auto-deploy/config.json" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
cfg = json.loads(path.read_text())
cfg['allocator_public_url'] = "http://203.0.113.10/enroll;id"
cfg['client_installer_url'] = "https://example.test/bootstrap-client.sh"
path.write_text(json.dumps(cfg, indent=2) + "\n")
PY
FRP_DEPLOY_TEST_ROOT="$TREE" python3 "$ROOT/tools/frp-create-client" >"$WORKDIR/quoted.out"
python3 - "$WORKDIR/quoted.out" <<'PY'
import re, subprocess, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text()
m = re.search(r"sudo env FRP_ALLOCATOR_URL=(.*) bash", text)
if not m:
    raise SystemExit('missing sudo env line')
assign = m.group(1)
wanted = "http://203.0.113.10/enroll;id"
script = f"FRP_ALLOCATOR_URL={assign}; printf '%s' \"${{FRP_ALLOCATOR_URL}}\""
out = subprocess.check_output(['bash', '-c', script], text=True)
if out != wanted:
    raise SystemExit(f'quoted assignment decoded to {out!r}')
# Confirm the semicolon was not executed as a command separator producing extra output.
if '\n' in out or out != wanted:
    raise SystemExit('command injection from allocator URL')
PY
pass "CASE E URL quoting"

echo
echo "CREATE_CLIENT_COMMAND_TEST=PASS"
