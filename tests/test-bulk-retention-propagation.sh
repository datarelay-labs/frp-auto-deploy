#!/usr/bin/env bash
# P1-Q: frp-enroll-bulk must pass authoritative cfg so retention policy applies.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
export PYTHONPATH="$ROOT/lib:$ROOT/server"

# Source-level: bulk issuance must pass cfg=
if ! grep -q 'issue_bootstrap_ticket(' "$ROOT/tools/frp-enroll-bulk"; then
  fail "bulk missing issue_bootstrap_ticket call"
fi
if ! grep -E 'issue_bootstrap_ticket\(' -A6 "$ROOT/tools/frp-enroll-bulk" | grep -q 'cfg=cfg'; then
  fail "bulk issue_bootstrap_ticket missing cfg=cfg"
fi
pass "BULK_CALLSITE_PASSES_CFG"

# All module-level / CLI call sites that take retention-sensitive cfg
while IFS= read -r file; do
  [[ -f "$file" ]] || continue
  # Skip tests and the allocator definition itself
  case "$file" in
    */tests/*|*/frp-port-allocator.py) continue ;;
  esac
  if grep -n 'issue_bootstrap_ticket(' "$file" >/dev/null 2>&1; then
    # Method wrappers that forward cfg=self.cfg are OK; module calls need cfg=
    if grep -E 'issue_bootstrap_ticket\(' -A8 "$file" | grep -q 'cfg=self\.cfg\|cfg=cfg\|cfg=cleanup'; then
      continue
    fi
    # Instance method definition on Allocator forwards below — check body
    if grep -A12 'def issue_bootstrap_ticket(self' "$file" | grep -q 'cfg=self.cfg'; then
      continue
    fi
    # Pure test helpers calling allocator method without cfg use Allocator.cfg
    if grep -q 'self\.allocator\.issue_bootstrap_ticket\|a\.issue_bootstrap_ticket' "$file"; then
      continue
    fi
    fail "issue_bootstrap_ticket call without cfg in $file"
  fi
done < <(git -C "$ROOT" ls-files 'tools/*' 'server/*' 2>/dev/null; printf '%s\n' "$ROOT/tools/frp-enroll-bulk" "$ROOT/tools/frp-create-client")
pass "ALL_ISSUANCE_CALLSITES_CFG"

python3 - "$ROOT" "$WORKDIR" <<'PY' || fail "bulk retention propagation"
import importlib.util
import json
import os
import subprocess
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

elc = load("elc", root / "lib/frp_enrollment_lifecycle.py")

def seed_tree(label, retention_days):
    base = work / label
    tree = base / "tree"
    enroll = tree / "var/lib/frp-auto-deploy/enrollments"
    boot = tree / "var/lib/frp-auto-deploy/bootstrap"
    pki = tree / "etc/frp-auto-deploy/pki"
    enroll.mkdir(parents=True)
    boot.mkdir(parents=True)
    pki.mkdir(parents=True)
    # Minimal CA for fingerprint; reuse pki helper
    sys.path.insert(0, str(root / "lib"))
    import frp_pki
    frp_pki.ensure_pki(str(pki), "example.test")
    (tree / "var/lib/frp-auto-deploy/registry.json").write_text(
        json.dumps({"schema_version": 2, "clients": {}}) + "\n"
    )
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
        "enrollments_dir": "/var/lib/frp-auto-deploy/enrollments",
        "bootstrap_dir": "/var/lib/frp-auto-deploy/bootstrap",
        "registry_file": "/var/lib/frp-auto-deploy/registry.json",
        "tls_ca_cert": "/etc/frp-auto-deploy/pki/ca.crt",
        "allocator_public_url": "https://example.test/enroll",
        "client_installer_url": "https://example.test/bootstrap-client.sh",
        "enrollment_retention_days": retention_days,
    }
    (tree / "etc/frp-auto-deploy/config.json").write_text(json.dumps(cfg) + "\n")
    return tree, enroll, eid

# retention=90, age=31 -> must remain after bulk issue
tree90, enroll90, eid90 = seed_tree("r90", 90)
elc._last_retention_cleanup = 0.0
env = os.environ.copy()
env["FRP_DEPLOY_TEST_ROOT"] = str(tree90)
subprocess.run(
    [sys.executable, str(root / "tools/frp-enroll-bulk"), "--count", "1", "--label-prefix", "keep"],
    check=True,
    env=env,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
)
assert (enroll90 / ("%s.json" % eid90)).is_file(), "90-day policy purged 31-day record via bulk"
print("RETENTION_90_DAY_31_DAY_RECORD_KEPT")

# retention=30, age=31 -> purged
tree30, enroll30, eid30 = seed_tree("r30", 30)
elc._last_retention_cleanup = 0.0
env["FRP_DEPLOY_TEST_ROOT"] = str(tree30)
subprocess.run(
    [sys.executable, str(root / "tools/frp-enroll-bulk"), "--count", "1", "--label-prefix", "purge"],
    check=True,
    env=env,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
)
assert not (enroll30 / ("%s.json" % eid30)).is_file(), "30-day policy should purge 31-day record via bulk"
print("RETENTION_DEFAULT_30_PURGED")

# retention=0 fail closed
try:
    elc.retention_days_from_config({"enrollment_retention_days": 0})
    raise SystemExit("retention 0 should fail")
except elc.EnrollmentLifecycleError:
    print("RETENTION_ZERO_FAIL_CLOSED")
PY

pass "RETENTION_90_DAY_31_DAY_RECORD_TEST"
pass "RETENTION_DEFAULT_30_TEST"
pass "RETENTION_ZERO_DISABLE_FAIL_CLOSED"
echo "BULK_RETENTION_PROPAGATION=PASS"
