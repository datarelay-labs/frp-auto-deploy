#!/usr/bin/env bash
# FULL_INSTALL managed == UNINSTALL project file set (excl. persistent/generated).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }

python3 - "$ROOT" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
sys.path.insert(0, str(root / "lib"))
import frp_project_files

managed = set(frp_project_files.managed_dests(single443=True, source_root=root))
uninstall = set(frp_project_files.uninstall_rels(single443=True, source_root=root))
if managed != uninstall:
    raise SystemExit(
        "managed vs uninstall-rels drift: missing=%s extra=%s"
        % (sorted(managed - uninstall), sorted(uninstall - managed))
    )

entries = frp_project_files.load_entries()
persistent = {
    e.dest
    for e in entries
    if e.cls in ("protected", "protected-prefix", "generated", "version")
}
overlap = uninstall & persistent
if overlap:
    raise SystemExit("uninstall-rels includes persistent paths: %s" % sorted(overlap))

text = (root / "uninstall-server.sh").read_text(encoding="utf-8")
for needle in ("uninstall-rels", "dual-role-shared-libs", "frp_project_files.py"):
    if needle not in text:
        raise SystemExit("uninstall-server.sh missing %s" % needle)
if "frontend.conf" in text.split("if [[ \"$PURGE\" == true ]]")[0]:
    # Default (non-purge) path must not delete generated frontend.conf.
    before_purge = text.split("if [[ \"$PURGE\" == true ]]")[0]
    if "frontend.conf" in before_purge and "frp_u_rm_file" in before_purge:
        # only flag explicit removal helpers referencing frontend.conf before purge
        for line in before_purge.splitlines():
            if "frontend.conf" in line and "frp_u_rm_file" in line:
                raise SystemExit("default uninstall deletes generated frontend.conf")

print("PARITY_OK")
PY
pass "SERVER_UNINSTALL_MANIFEST_PARITY"

# Functional: managed files removed; shared libs kept when client present.
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
TREE="$WORKDIR/tree"
mkdir -p "$TREE/usr/local/lib/frp-auto-deploy" \
  "$TREE/usr/local/sbin" "$TREE/usr/local/bin" \
  "$TREE/etc/systemd/system" "$TREE/etc/frp" "$TREE/etc/frp-auto-deploy"

while IFS= read -r rel; do
  [[ -n "$rel" ]] || continue
  mkdir -p "$TREE/$(dirname "$rel")"
  echo x >"$TREE/$rel"
done < <(python3 "$ROOT/lib/frp_project_files.py" uninstall-rels)
echo bin >"$TREE/usr/local/bin/frps"
echo state >"$TREE/etc/frp/client-state.json"
echo shared >"$TREE/usr/local/lib/frp-auto-deploy/frp-common.sh"
echo shared >"$TREE/usr/local/lib/frp-auto-deploy/frp_mgmt_auth.py"
echo client >"$TREE/usr/local/lib/frp-auto-deploy/frp-client-common.sh"
echo gen >"$TREE/etc/frp-auto-deploy/frontend.conf"
echo cfg >"$TREE/etc/frp-auto-deploy/config.json"
echo tok >"$TREE/etc/frp/server_token"

export FRP_UNINSTALL_TEST_ROOT="$TREE"
export FRP_PROJECT_FILES_PY="$ROOT/lib/frp_project_files.py"
"$ROOT/uninstall-server.sh" >"$WORKDIR/out" 2>"$WORKDIR/err" || fail "uninstall-server failed"

[[ ! -f "$TREE/usr/local/lib/frp-auto-deploy/frp-port-allocator.py" ]] \
  || fail "server lib remained"
[[ ! -f "$TREE/usr/local/sbin/frp-clients" ]] || fail "server tool remained"
[[ ! -f "$TREE/etc/systemd/system/frps.service" ]] || fail "frps unit remained"
[[ ! -f "$TREE/usr/local/bin/frps" ]] || fail "frps binary remained"
[[ -f "$TREE/usr/local/lib/frp-auto-deploy/frp-common.sh" ]] || fail "dual-role lost frp-common.sh"
[[ -f "$TREE/usr/local/lib/frp-auto-deploy/frp_mgmt_auth.py" ]] || fail "dual-role lost frp_mgmt_auth.py"
[[ -f "$TREE/usr/local/lib/frp-auto-deploy/frp-client-common.sh" ]] || fail "dual-role lost client common"
[[ -f "$TREE/etc/frp-auto-deploy/frontend.conf" ]] || fail "default uninstall deleted generated frontend.conf"
[[ -f "$TREE/etc/frp-auto-deploy/config.json" ]] || fail "default uninstall deleted config"
[[ -f "$TREE/etc/frp/server_token" ]] || fail "default uninstall deleted token"
pass "SERVER_UNINSTALL_DUAL_ROLE_AND_PERSISTENCE"

echo "SERVER_UNINSTALL_MANIFEST_PARITY_TEST=PASS"
