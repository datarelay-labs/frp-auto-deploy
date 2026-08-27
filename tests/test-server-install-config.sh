#!/usr/bin/env bash
# Server installer config resolution without touching a live FRP install.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }

unset FRP_PUBLIC_IP FRP_PUBLIC_HOST FRP_INTERNAL_IP FRP_CONTROL_PORT \
  FRP_PORT_START FRP_PORT_END FRP_ALLOCATOR_PORT FRP_ALLOCATOR_URL \
  FRP_ALLOCATOR_PUBLIC_URL FRP_CLIENT_INSTALLER_URL FRP_SERVER_CONFIG \
  DETECTED_PUBLIC_IP DETECTED_INTERNAL_IP || true

export FRP_SERVER_SOURCED=1
# shellcheck source=../install-server.sh
. "$ROOT/install-server.sh"

# CASE B — non-interactive env vars.
export FRP_PUBLIC_HOST='203.0.113.10'
export FRP_ALLOCATOR_URL='http://203.0.113.10/enroll'
export FRP_SERVER_CONFIG="$WORKDIR/missing-config.json"
load_existing_server_config
resolve_server_settings
[[ "$FRP_PUBLIC_IP" == '203.0.113.10' ]] || fail "CASE B public host"
[[ "$FRP_ALLOCATOR_PUBLIC_URL" == 'http://203.0.113.10/enroll' ]] || fail "CASE B allocator URL"
[[ "$FRP_CONTROL_PORT" == '443' ]] || fail "CASE B control port default"
[[ "$FRP_PORT_START" == '6000' ]] || fail "CASE B port start default"
[[ "$FRP_PORT_END" == '6098' ]] || fail "CASE B port end default"
[[ "$FRP_ALLOCATOR_PORT" == '6099' ]] || fail "CASE B allocator port default"
[[ "$FRP_INTERNAL_IP" == '203.0.113.10' ]] || fail "CASE B internal defaults to public"
pass "CASE B non-interactive env config"

# Derived allocator URL when only public host is set.
unset FRP_PUBLIC_IP FRP_PUBLIC_HOST FRP_ALLOCATOR_URL FRP_ALLOCATOR_PUBLIC_URL \
  FRP_CONTROL_PORT FRP_PORT_START FRP_PORT_END FRP_ALLOCATOR_PORT FRP_INTERNAL_IP || true
export FRP_PUBLIC_IP='203.0.113.10'
load_existing_server_config
resolve_server_settings
[[ "$FRP_ALLOCATOR_PUBLIC_URL" == 'http://203.0.113.10/enroll' ]] || fail "derived allocator URL"
pass "derived allocator URL from public host"

# CASE C — missing required deployment value, no silent production fallback.
unset FRP_PUBLIC_IP FRP_PUBLIC_HOST FRP_ALLOCATOR_URL FRP_ALLOCATOR_PUBLIC_URL \
  FRP_CONTROL_PORT FRP_PORT_START FRP_PORT_END FRP_ALLOCATOR_PORT FRP_INTERNAL_IP || true
if (
  export FRP_SERVER_CONFIG="$WORKDIR/missing-config.json"
  export DETECTED_PUBLIC_IP='198.51.100.99'
  unset FRP_PUBLIC_IP FRP_PUBLIC_HOST FRP_ALLOCATOR_URL FRP_ALLOCATOR_PUBLIC_URL \
    FRP_CONTROL_PORT FRP_PORT_START FRP_PORT_END FRP_ALLOCATOR_PORT FRP_INTERNAL_IP || true
  load_existing_server_config
  resolve_server_settings
) >"$WORKDIR/case-c.out" 2>"$WORKDIR/case-c.err"; then
  fail "CASE C should fail without public host"
fi
grep -qi 'required' "$WORKDIR/case-c.err" || fail "CASE C error message"
if grep -F '198.51.100.99' "$WORKDIR/case-c.out" >/dev/null; then
  fail "CASE C used detected IP as silent fallback"
fi
pass "CASE C missing public host fails"

# CASE D — rerun reuses existing runtime config.
EXISTING="$WORKDIR/existing-config.json"
python3 - "$EXISTING" <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
  "public_ip": "203.0.113.10",
  "control_port": 443,
  "port_start": 6000,
  "port_end": 6098,
  "listen_port": 6099,
  "allocator_public_url": "http://203.0.113.10/enroll",
  "client_installer_url": "https://example.invalid/bootstrap-client.sh",
}, indent=2, sort_keys=True) + "\n")
PY
unset FRP_PUBLIC_IP FRP_PUBLIC_HOST FRP_ALLOCATOR_URL FRP_ALLOCATOR_PUBLIC_URL \
  FRP_CONTROL_PORT FRP_PORT_START FRP_PORT_END FRP_ALLOCATOR_PORT \
  FRP_CLIENT_INSTALLER_URL FRP_INTERNAL_IP DETECTED_PUBLIC_IP || true
export FRP_SERVER_CONFIG="$EXISTING"
load_existing_server_config
resolve_server_settings
[[ "$FRP_PUBLIC_IP" == '203.0.113.10' ]] || fail "CASE D public ip overwritten"
[[ "$FRP_ALLOCATOR_PUBLIC_URL" == 'http://203.0.113.10/enroll' ]] || fail "CASE D allocator URL overwritten"
[[ "$CLIENT_INSTALLER_URL" == 'https://example.invalid/bootstrap-client.sh' ]] || fail "CASE D installer URL overwritten"
pass "CASE D rerun preserves runtime config"

# Explicit env wins over existing config.
unset FRP_PUBLIC_IP FRP_ALLOCATOR_PUBLIC_URL CLIENT_INSTALLER_URL || true
export FRP_SERVER_CONFIG="$EXISTING"
export FRP_PUBLIC_HOST='192.0.2.10'
export FRP_ALLOCATOR_URL='https://frp.example.test/enroll'
load_existing_server_config
resolve_server_settings
[[ "$FRP_PUBLIC_IP" == '192.0.2.10' ]] || fail "env should override existing public host"
[[ "$FRP_ALLOCATOR_PUBLIC_URL" == 'https://frp.example.test/enroll' ]] || fail "env should override existing allocator URL"
pass "explicit env overrides existing config"

legacy_owner='RickLee-kr'
legacy_repo='frp-auto-deploy'
LEGACY_INSTALLER_URL="https://raw.githubusercontent.com/${legacy_owner}/${legacy_repo}/main/dist/bootstrap-client.sh"
CANONICAL_INSTALLER_URL='https://raw.githubusercontent.com/datarelay-labs/frp-auto-deploy/main/dist/bootstrap-client.sh'

# Known obsolete project installer URL is migrated on a safe installer rerun.
EXISTING_LEGACY="$WORKDIR/legacy-installer-url.json"
python3 - "$EXISTING_LEGACY" "$LEGACY_INSTALLER_URL" <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
  "public_ip": "203.0.113.10",
  "control_port": 443,
  "port_start": 6000,
  "port_end": 6098,
  "listen_port": 6099,
  "allocator_public_url": "http://203.0.113.10/enroll",
  "client_installer_url": sys.argv[2],
}, indent=2, sort_keys=True) + "\n")
PY
unset FRP_PUBLIC_IP FRP_PUBLIC_HOST FRP_ALLOCATOR_URL FRP_ALLOCATOR_PUBLIC_URL \
  FRP_CONTROL_PORT FRP_PORT_START FRP_PORT_END FRP_ALLOCATOR_PORT \
  FRP_CLIENT_INSTALLER_URL FRP_INTERNAL_IP CLIENT_INSTALLER_URL || true
export FRP_SERVER_CONFIG="$EXISTING_LEGACY"
load_existing_server_config
resolve_server_settings
[[ "$CLIENT_INSTALLER_URL" == "$CANONICAL_INSTALLER_URL" ]] || fail "legacy installer URL not migrated"
pass "legacy project installer URL migrated"

# Arbitrary custom installer URLs are left unchanged.
EXISTING_CUSTOM="$WORKDIR/custom-installer-url.json"
python3 - "$EXISTING_CUSTOM" <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
  "public_ip": "203.0.113.10",
  "control_port": 443,
  "port_start": 6000,
  "port_end": 6098,
  "listen_port": 6099,
  "allocator_public_url": "http://203.0.113.10/enroll",
  "client_installer_url": "https://example.org/my-custom-client.sh",
}, indent=2, sort_keys=True) + "\n")
PY
unset FRP_PUBLIC_IP FRP_PUBLIC_HOST FRP_ALLOCATOR_URL FRP_ALLOCATOR_PUBLIC_URL \
  FRP_CONTROL_PORT FRP_PORT_START FRP_PORT_END FRP_ALLOCATOR_PORT \
  FRP_CLIENT_INSTALLER_URL FRP_INTERNAL_IP CLIENT_INSTALLER_URL || true
export FRP_SERVER_CONFIG="$EXISTING_CUSTOM"
load_existing_server_config
resolve_server_settings
[[ "$CLIENT_INSTALLER_URL" == 'https://example.org/my-custom-client.sh' ]] || fail "custom installer URL rewritten"
pass "custom installer URL preserved"

# Empty installer URL uses the current canonical default.
EXISTING_EMPTY="$WORKDIR/empty-installer-url.json"
python3 - "$EXISTING_EMPTY" <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
  "public_ip": "203.0.113.10",
  "control_port": 443,
  "port_start": 6000,
  "port_end": 6098,
  "listen_port": 6099,
  "allocator_public_url": "http://203.0.113.10/enroll",
  "client_installer_url": "",
}, indent=2, sort_keys=True) + "\n")
PY
unset FRP_PUBLIC_IP FRP_PUBLIC_HOST FRP_ALLOCATOR_URL FRP_ALLOCATOR_PUBLIC_URL \
  FRP_CONTROL_PORT FRP_PORT_START FRP_PORT_END FRP_ALLOCATOR_PORT \
  FRP_CLIENT_INSTALLER_URL FRP_INTERNAL_IP CLIENT_INSTALLER_URL \
  EXISTING_CLIENT_INSTALLER_URL || true
export FRP_SERVER_CONFIG="$EXISTING_EMPTY"
load_existing_server_config
resolve_server_settings
[[ "$CLIENT_INSTALLER_URL" == "$CANONICAL_INSTALLER_URL" ]] || fail "empty installer URL did not use canonical default"
pass "empty installer URL uses canonical default"

echo
echo "SERVER_INSTALL_CONFIG_TEST=PASS"
