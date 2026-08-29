#!/usr/bin/env bash
# Regression: client connectivity probes must not shell-interpolate host/port.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/frp-client-common.sh
. "$ROOT/lib/frp-client-common.sh"

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }

# Source must not use bash /dev/tcp with interpolated host/port.
if grep -nE 'bash -c .*\/dev\/tcp\/\$\{|bash -c .*\/dev\/tcp\/\"\$\{|timeout .* bash -c \"echo >/dev/tcp' \
  "$ROOT/lib/frp-client-common.sh"; then
  fail "probe_tcp still interpolates into bash -c /dev/tcp"
fi
grep -q 'socket.create_connection' "$ROOT/lib/frp-client-common.sh" \
  || fail "probe_tcp missing socket.create_connection"
pass "PROBE_TCP_NO_BASH_C"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
MARKER="$WORKDIR/PWNED"

# Malicious host/port strings that would create MARKER if evaluated by a shell.
cases=(
  "127.0.0.1; touch ${MARKER}"
  "127.0.0.1\$(touch ${MARKER})"
  "127.0.0.1\`touch ${MARKER}\`"
  "127.0.0.1|touch ${MARKER}"
  "127.0.0.1&touch ${MARKER}"
  "127.0.0.1
touch ${MARKER}"
)

for host in "${cases[@]}"; do
  # probe must fail closed without executing the payload
  if probe_tcp "$host" "22"; then
    : # rare: somehow connected; still must not have executed payload
  fi
  if [[ -e "$MARKER" ]]; then
    fail "malicious host executed payload: $host"
  fi
done

# Malicious port values
for port in '22; touch '"$MARKER" '22$(touch '"$MARKER"')' '22|touch '"$MARKER" 'notaport' '0' '65536' '-1'; do
  if probe_tcp "127.0.0.1" "$port"; then
    :
  fi
  if [[ -e "$MARKER" ]]; then
    fail "malicious port executed payload: $port"
  fi
done

# Empty / control-char host
for host in '' $'127.0.0.1\r' $'127.0.0.1\n'; do
  if probe_tcp "$host" "22"; then
    fail "control/empty host should not succeed: $(printf %q "$host")"
  fi
done

[[ ! -e "$MARKER" ]] || fail "marker file was created"
pass "PROBE_TCP_METACHAR_NO_EXEC"
pass "PROBE_TCP_NO_FILE_CREATE"

# Positive control: a free local listener should be reachable with argv-safe host/port.
python3 - "$WORKDIR" <<'PY' &
import socket, time, sys
from pathlib import Path
path = Path(sys.argv[1]) / 'port'
sock = socket.socket()
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind(('127.0.0.1', 0))
port = sock.getsockname()[1]
path.write_text(str(port))
sock.listen(1)
conn, _ = sock.accept()
conn.close()
sock.close()
PY
for _ in $(seq 1 50); do
  [[ -f "$WORKDIR/port" ]] && break
  sleep 0.05
done
[[ -f "$WORKDIR/port" ]] || fail "listener port file missing"
LISTEN_PORT="$(cat "$WORKDIR/port")"
probe_tcp "127.0.0.1" "$LISTEN_PORT" || fail "benign probe_tcp should succeed"
wait || true
pass "PROBE_TCP_BENIGN_OK"

echo "PROBE_TCP_INJECTION_TEST=PASS"
