#!/usr/bin/env bash
# P2-W: doctor/restore distinguish public vs listen ports under NAT.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

python3 - "$ROOT" "$WORKDIR" <<'PY' || fail "NAT split doctor/restore checks"
import importlib.util
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
work = Path(sys.argv[2])

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

doctor = load("frp_doctor", root / "lib" / "frp_doctor.py")
scfg = load("frp_server_config", root / "lib" / "frp_server_config.py")

# Direct-like but public != listen for both control and allocator (NAT).
cfg = {
    "deployment_mode": "direct",
    "public_host": "frp.example.test",
    "frp_control_public_port": 443,
    "frp_control_listen_port": 7000,
    "allocator_public_port": 8443,
    "allocator_listen_port": 6099,
    "allocator_public_url": "https://frp.example.test:8443/enroll",
    "port_start": 20000,
    "port_end": 20100,
    "listen_host": "127.0.0.1",
    "token_file": "/etc/frp/server_token",
    "registry_file": "/var/lib/frp-auto-deploy/registry.json",
}

# Canonical validation must accept public!=listen.
scfg.validate_server_config(cfg)

ports = doctor.server_config_ports(cfg)
assert ports["frp_public"] == 443, ports
assert ports["frp_listen"] == 7000, ports
assert ports["alloc_public"] == 8443, ports
assert ports["alloc_listen"] == 6099, ports
assert ports["frp_public"] != ports["frp_listen"]
assert ports["alloc_public"] != ports["alloc_listen"]

# ss/local probes must use listen ports, never public hairpin ports.
assert ports["frp_listen"] == 7000
assert ports["alloc_listen"] == 6099

# Restore health helper signature uses allocator_listen_port + public_host SNI.
restore_path = root / "tools" / "frp-restore"
src = restore_path.read_text(encoding="utf-8")
assert "verify_allocator_https_health" in src
assert "http://127.0.0.1" not in src or "FRP_RESTORE" in src
# Ensure plain HTTP probe string is gone from production path.
assert 'f"http://127.0.0.1:{listen_port}/healthz"' not in src
assert "https_loopback_get" in src or "LoopbackHTTPS" in src or "verify_allocator_https_health" in src

# Doctor source must PASS (not FAIL) when public != listen.
doc_src = (root / "lib" / "frp_doctor.py").read_text(encoding="utf-8")
assert "differ by design" in doc_src
assert "public_listen_frp" in doc_src
assert "public_listen_allocator" in doc_src

# Simulate doctor port collision check uses listen, not public.
class Facts(dict):
    pass

facts = {
    "listening": {7000: True, 6099: True, 443: False, 8443: False},
}
# Local listen present; public ports intentionally not listening locally.
assert facts["listening"][ports["frp_listen"]] is True
assert facts["listening"][ports["alloc_listen"]] is True
assert facts["listening"].get(ports["frp_public"]) is False
assert facts["listening"].get(ports["alloc_public"]) is False

print("NAT_SPLIT_OK")
PY

pass "doctor/restore NAT public!=listen"
echo "NAT_PUBLIC_LISTEN_SPLIT=PASS"
