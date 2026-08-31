#!/usr/bin/env bash
# Production absolute paths must not become cwd-relative when FRP_CLIENT_TEST_ROOT is unset.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
cd "$WORKDIR"

unset FRP_CLIENT_TEST_ROOT || true
export PYTHONPATH="$ROOT/lib"

python3 - "$WORKDIR" <<'PY' || fail "path resolution"
import os, sys
from pathlib import Path

workdir = Path(sys.argv[1]).resolve()
os.environ.pop("FRP_CLIENT_TEST_ROOT", None)
sys.path.insert(0, os.environ["PYTHONPATH"])
import importlib
import frp_client_lifecycle as m
importlib.reload(m)

cwd = Path.cwd().resolve()
assert cwd == workdir, (cwd, workdir)
assert m._root() is None, repr(m._root())
for rel in (
    "/etc/frp/client-state.json",
    "/etc/frp/frpc.toml",
    "/etc/frp/client-identity.key",
    "/etc/frp-auto-deploy/version",
    "/tmp/frp-support-bundle-demo.tar.gz",
):
    p = m._path(rel)
    assert p.is_absolute(), (rel, p)
    assert str(p) == rel, (rel, p)
    assert not str(p.resolve()).startswith(str(cwd) + "/etc"), (rel, p, cwd)

os.environ["FRP_CLIENT_TEST_ROOT"] = str(workdir / "root")
importlib.reload(m)
p = m._path("/etc/frp/client-state.json")
assert p == workdir / "root/etc/frp/client-state.json", p
print("ok")
PY

unset FRP_CLIENT_TEST_ROOT || true
out="$(
  PYTHONPATH="$ROOT/lib" python3 - <<'PY'
import os, sys
from datetime import datetime, timezone
os.environ.pop("FRP_CLIENT_TEST_ROOT", None)
sys.path.insert(0, os.environ["PYTHONPATH"])
import importlib
import frp_client_lifecycle as m
importlib.reload(m)
stamp = "20260101T000000Z"
print(m._path("/tmp/frp-support-bundle-%s.tar.gz" % stamp))
PY
)"
[[ "$out" == "/tmp/frp-support-bundle-20260101T000000Z.tar.gz" ]] || fail "default bundle path: $out"
pass "PRODUCTION_ROOT_ABSOLUTE"
pass "TEST_ROOT_REMAP_PRESERVED"
pass "DEFAULT_BUNDLE_PATH_ABSOLUTE"
