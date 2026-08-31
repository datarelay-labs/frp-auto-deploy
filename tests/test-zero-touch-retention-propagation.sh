#!/usr/bin/env bash
# Zero-touch issuance must honor configured enrollment_retention_days.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
export PYTHONPATH="$ROOT/lib:$ROOT/server"

python3 - "$ROOT" "$WORKDIR" <<'PY' || fail "retention propagation"
import importlib.util
import json
import os
import sys
import time
from pathlib import Path

root = Path(sys.argv[1])
work = Path(sys.argv[2])

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, str(path))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

alloc = load("alloc", root / "server/frp-port-allocator.py")
elc = load("elc", root / "lib/frp_enrollment_lifecycle.py")

def seed_tree(label, retention_days):
    base = work / label
    enroll = base / "enrollments"
    boot = base / "bootstrap"
    enroll.mkdir(parents=True)
    boot.mkdir(parents=True)
    (base / "registry.json").write_text(json.dumps({"schema_version": 2, "clients": {}}) + "\n")
    now = int(time.time())
    age = 31 * 86400
    eid = "aabbccdd11223344"
    completed = now - age
    enroll_rec = {
        "id": eid,
        "secret": "ab" * 32,
        "created_at": "2020-01-01T00:00:00Z",
        "expires_at": completed - 10,
        "bound_machine_id": "m1",
        "used_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(completed)),
        "note": "",
        "label": "old",
    }
    (enroll / ("%s.json" % eid)).write_text(json.dumps(enroll_rec) + "\n")
    cfg = {
        "enrollments_dir": str(enroll),
        "bootstrap_dir": str(boot),
        "registry_file": str(base / "registry.json"),
        "enrollment_retention_days": retention_days,
    }
    return cfg, enroll, boot, eid, now

# retention=90, age=31 -> must remain
cfg90, enroll90, boot90, eid90, now = seed_tree("r90", 90)
alloc.issue_bootstrap_ticket(enroll90, boot90, [], 600, "n", label="x", cfg=cfg90)
assert (enroll90 / ("%s.json" % eid90)).is_file(), "90-day policy purged 31-day record"
pass_msg = "RETENTION_90_DAY_31_DAY_RECORD_KEPT"
print(pass_msg)

# retention=30, age=31 -> purged
cfg30, enroll30, boot30, eid30, now = seed_tree("r30", 30)
# Reset module throttle
elc._last_retention_cleanup = 0.0
alloc.issue_bootstrap_ticket(enroll30, boot30, [], 600, "n", label="y", cfg=cfg30)
assert not (enroll30 / ("%s.json" % eid30)).is_file(), "30-day policy should purge 31-day record"
print("RETENTION_DEFAULT_30_PURGED")

# retention=0 fail closed
try:
    elc.retention_days_from_config({"enrollment_retention_days": 0})
    raise SystemExit("retention 0 should fail")
except elc.EnrollmentLifecycleError:
    print("RETENTION_ZERO_FAIL_CLOSED")

# Same policy across manual helper / zero-touch / maybe_run
cfg = {"enrollment_retention_days": 90, "enrollments_dir": str(enroll90), "bootstrap_dir": str(boot90), "registry_file": str(cfg90["registry_file"])}
assert elc.retention_days_from_config(cfg) == 90
assert elc.retention_days_from_config({"enrollments_dir": "/x"}) == 30
print("RETENTION_CONFIG_PROPAGATION")
PY

pass "RETENTION_90_DAY_31_DAY_RECORD_TEST"
pass "RETENTION_DEFAULT_30_TEST"
pass "RETENTION_ZERO_DISABLE_FAIL_CLOSED"
pass "RETENTION_CONFIG_PROPAGATION"
