#!/usr/bin/env bash
# P1: sourcing install-client must not let internal `set -e` abort the harness
# when frp_client_main returns non-zero under an outer `set +e` capture.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

export FRP_CLIENT_SOURCED=1
export FRP_CLIENT_TEST_ROOT="$WORKDIR/client"
mkdir -p "$WORKDIR/client/etc/frp" "$WORKDIR/client/usr/local/bin"
cat >"$WORKDIR/client/usr/local/bin/frpc" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$WORKDIR/client/usr/local/bin/frpc"

# shellcheck source=../install-client.sh
. "$ROOT/install-client.sh"

export FRP_ALLOCATOR_URL='https://127.0.0.1:9/enroll'
export FRP_ZERO_TOUCH=1
export FRP_BOOTSTRAP_TICKET='bt1.deadbeefdeadbeef.00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff'
export FRP_SSH_USER='tester'
export FRP_SSH_PORT=22
export FRP_ALLOCATOR_CA_SHA256='ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff'

set +e
frp_client_main >"$WORKDIR/out" 2>"$WORKDIR/err" </dev/null
rc=$?
set -e

[[ "$rc" -ne 0 ]] || fail "expected non-zero from failing sourced main"
# If internal set -e leaked, we would never reach this line.
pass "SOURCED_MAIN_NONZERO_DOES_NOT_ABORT_HARNESS"

# errexit should still be controllable by the harness after return
set +e
false
set -e
pass "HARNESS_ERREXIT_STILL_CONTROLLABLE"

echo "SOURCED_CLIENT_ERREXIT_TEST=PASS"
