#!/usr/bin/env bash
# P2-X: frp-release-service emits service.released audit (no secrets).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
TREE="$WORKDIR/tree"
mkdir -p "$TREE/etc/frp-auto-deploy" "$TREE/var/lib/frp-auto-deploy" "$TREE/var/log/frp-auto-deploy"

python3 - "$TREE" <<'PY'
import json
from pathlib import Path
tree = Path(__import__("sys").argv[1])
(tree / "etc/frp-auto-deploy/config.json").write_text(json.dumps({
    "public_host": "203.0.113.10",
    "port_start": 6000,
    "port_end": 6098,
    "allocator_listen_port": 7500,
    "frp_control_listen_port": 7000,
    "registry_file": "/var/lib/frp-auto-deploy/registry.json",
}) + "\n")
state = {
    "schema_version": 2,
    "reserved": [],
    "groups": {},
    "clients": {
        "aabbccdd00112233445566778899aabb": {
            "hostname": "edge-1",
            "label": "edge-1",
            "mgmt_status": "enrolled",
            "services": {
                "ssh": {
                    "id": "ssh",
                    "protocol": "tcp",
                    "preset": "ssh",
                    "enabled": True,
                    "local_ip": "127.0.0.1",
                    "local_port": 22,
                    "remote_port": 6001,
                    "ssh_user": "ubuntu",
                },
                "grafana": {
                    "id": "grafana",
                    "protocol": "tcp",
                    "preset": "custom",
                    "enabled": True,
                    "local_ip": "127.0.0.1",
                    "local_port": 3000,
                    "remote_port": 6002,
                },
            },
        }
    },
}
(tree / "var/lib/frp-auto-deploy/registry.json").write_text(json.dumps(state, indent=2) + "\n")
PY

export FRP_DEPLOY_TEST_ROOT="$TREE"
printf 'RELEASE\n' | python3 "$ROOT/tools/frp-release-service" aabbccdd00112233445566778899aabb grafana \
  >"$WORKDIR/out" 2>"$WORKDIR/err" || fail "release-service failed"

AUDIT="$TREE/var/log/frp-auto-deploy/audit.jsonl"
[[ -f "$AUDIT" ]] || fail "audit log missing"
python3 - "$AUDIT" <<'PY' || fail "audit record"
import json, sys
from pathlib import Path
lines = Path(sys.argv[1]).read_text().splitlines()
assert lines, "empty audit"
rec = json.loads(lines[-1])
assert rec.get("event") == "service.released", rec
assert "aabbccdd00112233445566778899aabb" in str(rec.get("client_id") or "")
details = rec.get("details") or {}
assert details.get("service_id") == "grafana"
blob = Path(sys.argv[1]).read_text()
for needle in ("server_token", "BEGIN", "PRIVATE", "mgmt_mac_key", "secret"):
    assert needle not in blob, needle
print("ok")
PY
pass "SERVICE_RELEASED_AUDIT"

# Cancel path must not audit
BEFORE="$(wc -l <"$AUDIT")"
printf 'nope\n' | python3 "$ROOT/tools/frp-release-service" aabbccdd00112233445566778899aabb ssh \
  >"$WORKDIR/cancel.out" 2>"$WORKDIR/cancel.err" && fail "cancel should fail"
AFTER="$(wc -l <"$AUDIT")"
[[ "$AFTER" -eq "$BEFORE" ]] || fail "cancel emitted audit"
pass "CANCEL_NO_AUDIT"

echo "RELEASE_SERVICE_AUDIT=PASS"
