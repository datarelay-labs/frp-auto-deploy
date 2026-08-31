#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
enroll="$WORKDIR/enrollments"
boot="$WORKDIR/bootstrap"
mkdir -p "$enroll" "$boot"
echo '{}' >"$enroll/deadbeefdeadbeef.json.purging"
echo '{}' >"$enroll/alivealivealive01.json"
echo '{}' >"$enroll/alivealivealive01.json.purging"
echo 'nope' >"$enroll/notes.txt.purging"
echo '{}' >"$WORKDIR/target.json.purging"
ln -s "$WORKDIR/target.json.purging" "$enroll/symlink01symlink01.json.purging"

python3 - "$ROOT" "$enroll" "$boot" <<'PY' || fail "reaper"
import importlib.util, sys
from pathlib import Path
root, enroll, boot = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
spec = importlib.util.spec_from_file_location("elc", root / "lib/frp_enrollment_lifecycle.py")
elc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(elc)
n = elc.reap_purging_tombstones(enroll, boot)
assert n == 1, n
assert not (enroll / "deadbeefdeadbeef.json.purging").exists()
assert (enroll / "alivealivealive01.json.purging").exists()
assert (enroll / "notes.txt.purging").exists()
assert (enroll / "symlink01symlink01.json.purging").is_symlink()
print("ok")
PY
pass "TOMBSTONE_REAPER"
