#!/usr/bin/env bash
# Verify that `frpctl release service` results in local client-state cleanup.
# We simulate "release" by making the service's public port no longer accept
# TCP connections from the client host, and ensure `frp-client list` removes
# the stale disabled record from /etc/frp/client-state.json.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

TREE="$WORKDIR/client-root"
mkdir -p "$TREE/etc/frp"

write_state() {
  local server_host="$1" web_port="$2" web_enabled="$3"
  python3 - "$TREE/etc/frp/client-state.json" "$server_host" "$web_port" "$web_enabled" <<'PY'
import json, sys
from pathlib import Path

dest = Path(sys.argv[1])
server_host = sys.argv[2]
web_port = int(sys.argv[3])
web_enabled = (sys.argv[4].lower() == "true")

state = {
  "schema_version": 1,
  "allocator_url": "https://127.0.0.1:9999/enroll",
  "frp_server": server_host,
  "frp_server_port": 443,
  "hostname": "dp-example",
  "machine_id": "aabbccddeeff00112233445566778899",
  "host_id": "host-example",
  "services": {
    "ssh": {
      "id": "ssh",
      "name": "SSH",
      "protocol": "tcp",
      "local_ip": "127.0.0.1",
      "local_port": 22,
      "preset": "ssh",
      "ssh_user": "aella",
      "remote_port": 18000,
      "enabled": True,
    },
    "web": {
      "id": "web",
      "name": "Web",
      "protocol": "tcp",
      "local_ip": "127.0.0.1",
      "local_port": 18080,
      "preset": "http",
      "remote_port": web_port,
      "enabled": web_enabled,
    },
  },
}

dest.parent.mkdir(parents=True, exist_ok=True)
dest.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

pick_unused_port() {
  python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
port = s.getsockname()[1]
s.close()
print(port)
PY
}

read_has_web() {
  python3 - "$TREE/etc/frp/client-state.json" <<'PY'
import json, sys
from pathlib import Path
state = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print("web" in (state.get("services") or {}))
PY
}

run_list() {
  # Ensure reconciliation runs but keep it fast for unit test speed.
  FRP_CLIENT_TEST_ROOT="$TREE" \
    FRP_SKIP_CONNECTIVITY_CHECK=0 \
    FRP_RELEASE_RECONCILE_RETRIES=1 \
    FRP_RELEASE_RECONCILE_INTERVAL_SEC=0 \
    FRP_RELEASE_RECONCILE_CONNECT_TIMEOUT_SEC=0.2 \
    "$ROOT/tools/frp-client" list >/dev/null
}

echo "=== case: port closed => disabled web record removed ==="
WEB_PORT_CLOSED="$(pick_unused_port)"
write_state "127.0.0.1" "$WEB_PORT_CLOSED" "false"
run_list
[[ "$(read_has_web)" == "False" ]] || { echo "web record still present"; exit 1; }

echo "=== case: port open => disabled web record kept ==="
WEB_PORT_LISTEN="$(pick_unused_port)"

# Simple TCP listener: only needs to accept connections so socket.connect works.
LISTENER_PORT="$WEB_PORT_LISTEN" python3 - <<'PY' &
import socket, os, time
port = int(os.environ["LISTENER_PORT"])
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port))
s.listen(5)
end = time.time() + 5
while time.time() < end:
    try:
        conn, _ = s.accept()
        conn.close()
    except Exception:
        time.sleep(0.01)
PY
LISTENER_PID=$!

write_state "127.0.0.1" "$WEB_PORT_LISTEN" "false"
run_list
kill "$LISTENER_PID" 2>/dev/null || true

[[ "$(read_has_web)" == "True" ]] || { echo "web record removed unexpectedly"; exit 1; }

echo "PASS test-release-service-client-state-reconcile"

