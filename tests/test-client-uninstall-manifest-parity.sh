#!/usr/bin/env bash
# Client uninstall removes client-owned bins/libs; dual-role preserves shared/server files.
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

client = set(frp_project_files.client_managed_dests(source_root=root))
uninstall = set(frp_project_files.client_uninstall_rels(source_root=root))
if client != uninstall:
    raise SystemExit(
        "client managed vs uninstall drift: missing=%s extra=%s"
        % (sorted(client - uninstall), sorted(uninstall - client))
    )
required = {
    "usr/local/lib/frp-auto-deploy/frp_clock_sync.py",
    "usr/local/lib/frp-auto-deploy/frp-doctor-common.sh",
    "usr/local/lib/frp-auto-deploy/frp_doctor.py",
    "usr/local/lib/frp-auto-deploy/frp_ctl_grammar.py",
    "usr/local/lib/frp-auto-deploy/frp_ctl_repl.py",
    "usr/local/lib/frp-auto-deploy/frp-client-lifecycle.sh",
    "usr/local/lib/frp-auto-deploy/frp_client_lifecycle.py",
}
missing = sorted(required - client)
if missing:
    raise SystemExit("client manifest missing %s" % missing)
shared = set(frp_project_files.dual_role_shared_lib_basenames())
for name in ("frp-common.sh", "frp_mgmt_auth.py", "frp_clock_sync.py", "frp_doctor.py"):
    if name not in shared:
        raise SystemExit("shared set missing %s" % name)
text = (root / "uninstall-client.sh").read_text(encoding="utf-8")
if "client-uninstall-rels" not in text:
    raise SystemExit("uninstall-client.sh does not use client-uninstall-rels")
print("PARITY_OK")
PY
pass "CLIENT_UNINSTALL_MANIFEST_PARITY"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# Client-only tree
CL="$WORKDIR/client-only"
mkdir -p "$CL/usr/local/lib/frp-auto-deploy" "$CL/usr/local/bin" \
  "$CL/etc/systemd/system" "$CL/etc/frp" "$CL/etc/frp-auto-deploy"
cp "$ROOT/lib/frp_project_files.py" "$CL/usr/local/lib/frp-auto-deploy/"
cp "$ROOT/lib/client-project-files.manifest" "$CL/usr/local/lib/frp-auto-deploy/"
while IFS= read -r rel; do
  [[ -n "$rel" ]] || continue
  mkdir -p "$CL/$(dirname "$rel")"
  echo x >"$CL/$rel"
done < <(python3 "$ROOT/lib/frp_project_files.py" client-uninstall-rels)
echo bin >"$CL/usr/local/bin/frpc"
echo state >"$CL/etc/frp/client-state.json"

export FRP_UNINSTALL_TEST_ROOT="$CL"
export FRP_PROJECT_FILES_PY="$ROOT/lib/frp_project_files.py"
"$ROOT/uninstall-client.sh" >"$WORKDIR/cl.out" 2>"$WORKDIR/cl.err" || fail "client-only uninstall"

for rel in \
  usr/local/bin/frp-client \
  usr/local/bin/frpctl \
  usr/local/bin/frpc \
  usr/local/lib/frp-auto-deploy/frp_clock_sync.py \
  usr/local/lib/frp-auto-deploy/frp_doctor.py \
  usr/local/lib/frp-auto-deploy/frp-client-lifecycle.sh \
  etc/systemd/system/frpc.service; do
  [[ ! -e "$CL/$rel" ]] || fail "client-only left $rel"
done
[[ ! -d "$CL/usr/local/lib/frp-auto-deploy" ]] || fail "client-only left libdir"
pass "CLIENT_ONLY_UNINSTALL_CLEARS_PROJECT_FILES"

# Dual-role: preserve shared + server state
DUAL="$WORKDIR/dual"
mkdir -p "$DUAL/usr/local/lib/frp-auto-deploy" "$DUAL/usr/local/bin" \
  "$DUAL/usr/local/sbin" "$DUAL/etc/systemd/system" "$DUAL/etc/frp" "$DUAL/etc/frp-auto-deploy"
cp "$ROOT/lib/frp_project_files.py" "$DUAL/usr/local/lib/frp-auto-deploy/"
cp "$ROOT/lib/client-project-files.manifest" "$DUAL/usr/local/lib/frp-auto-deploy/"
cp "$ROOT/lib/server-project-files.manifest" "$DUAL/usr/local/lib/frp-auto-deploy/"
while IFS= read -r rel; do
  [[ -n "$rel" ]] || continue
  mkdir -p "$DUAL/$(dirname "$rel")"
  echo client >"$DUAL/$rel"
done < <(python3 "$ROOT/lib/frp_project_files.py" client-uninstall-rels)
echo server >"$DUAL/usr/local/lib/frp-auto-deploy/frp-port-allocator.py"
echo server >"$DUAL/usr/local/sbin/frp-clients"
echo '{"public_host":"203.0.113.10"}' >"$DUAL/etc/frp-auto-deploy/config.json"
echo token >"$DUAL/etc/frp/server_token"
echo state >"$DUAL/etc/frp/client-state.json"

export FRP_UNINSTALL_TEST_ROOT="$DUAL"
"$ROOT/uninstall-client.sh" >"$WORKDIR/dual.out" 2>"$WORKDIR/dual.err" || fail "dual uninstall"

[[ ! -f "$DUAL/usr/local/bin/frp-client" ]] || fail "dual left frp-client"
[[ ! -f "$DUAL/usr/local/lib/frp-auto-deploy/frp-client-lifecycle.sh" ]] || fail "dual left client lifecycle"
[[ ! -f "$DUAL/etc/frp/client-state.json" ]] || fail "dual left client state"
[[ -f "$DUAL/etc/frp-auto-deploy/config.json" ]] || fail "dual deleted server config"
[[ -f "$DUAL/etc/frp/server_token" ]] || fail "dual deleted server token"
[[ -f "$DUAL/usr/local/lib/frp-auto-deploy/frp-common.sh" ]] || fail "dual deleted shared frp-common.sh"
[[ -f "$DUAL/usr/local/lib/frp-auto-deploy/frp_mgmt_auth.py" ]] || fail "dual deleted shared frp_mgmt_auth.py"
[[ -f "$DUAL/usr/local/lib/frp-auto-deploy/frp_doctor.py" ]] || fail "dual deleted shared doctor"
[[ -f "$DUAL/usr/local/lib/frp-auto-deploy/frp_clock_sync.py" ]] || fail "dual deleted shared clock sync"
[[ -f "$DUAL/usr/local/lib/frp-auto-deploy/frp-port-allocator.py" ]] || fail "dual deleted server allocator"
[[ -f "$DUAL/usr/local/sbin/frp-clients" ]] || fail "dual deleted server tool"
pass "CLIENT_DUAL_ROLE_PRESERVES_SHARED_AND_SERVER"

# Fallback path when project_files helper is already gone (idempotent re-run).
FB="$WORKDIR/dual-fallback"
mkdir -p "$FB/usr/local/lib/frp-auto-deploy" "$FB/usr/local/bin" \
  "$FB/usr/local/sbin" "$FB/etc/systemd/system" "$FB/etc/frp" "$FB/etc/frp-auto-deploy"
# No frp_project_files.py → uninstall uses fallback list.
echo shared >"$FB/usr/local/lib/frp-auto-deploy/frp-common.sh"
echo shared >"$FB/usr/local/lib/frp-auto-deploy/frp_mgmt_auth.py"
echo shared >"$FB/usr/local/lib/frp-auto-deploy/frp_clock_sync.py"
echo shared >"$FB/usr/local/lib/frp-auto-deploy/frp_doctor.py"
echo shared >"$FB/usr/local/lib/frp-auto-deploy/frp-doctor-common.sh"
echo shared >"$FB/usr/local/lib/frp-auto-deploy/frp_ctl_grammar.py"
echo shared >"$FB/usr/local/lib/frp-auto-deploy/frp_ctl_repl.py"
echo client >"$FB/usr/local/lib/frp-auto-deploy/frp-client-common.sh"
echo client >"$FB/usr/local/bin/frp-client"
echo server >"$FB/usr/local/lib/frp-auto-deploy/frp-port-allocator.py"
echo '{"public_host":"203.0.113.10"}' >"$FB/etc/frp-auto-deploy/config.json"
echo token >"$FB/etc/frp/server_token"
echo state >"$FB/etc/frp/client-state.json"
export FRP_UNINSTALL_TEST_ROOT="$FB"
unset FRP_PROJECT_FILES_PY || true
"$ROOT/uninstall-client.sh" >"$WORKDIR/fb.out" 2>"$WORKDIR/fb.err" || fail "fallback dual uninstall"
[[ ! -f "$FB/usr/local/lib/frp-auto-deploy/frp-client-common.sh" ]] || fail "fallback left client lib"
[[ -f "$FB/usr/local/lib/frp-auto-deploy/frp_clock_sync.py" ]] || fail "fallback deleted shared clock"
[[ -f "$FB/usr/local/lib/frp-auto-deploy/frp_doctor.py" ]] || fail "fallback deleted shared doctor"
[[ -f "$FB/usr/local/lib/frp-auto-deploy/frp-common.sh" ]] || fail "fallback deleted shared common"
[[ -f "$FB/usr/local/lib/frp-auto-deploy/frp_ctl_grammar.py" ]] || fail "fallback deleted shared frp_ctl_grammar.py"
[[ -f "$FB/usr/local/lib/frp-auto-deploy/frp_ctl_repl.py" ]] || fail "fallback deleted shared frp_ctl_repl.py"
[[ -f "$FB/etc/frp-auto-deploy/config.json" ]] || fail "fallback deleted server config"
pass "CLIENT_DUAL_ROLE_FALLBACK_PRESERVES_SHARED"

echo "CLIENT_UNINSTALL_MANIFEST_PARITY_TEST=PASS"
