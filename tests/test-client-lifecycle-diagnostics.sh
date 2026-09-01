#!/usr/bin/env bash
# Client lifecycle & diagnostics (pause/resume/restart/test/logs/bundle/uninstall).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }

chmod +x "$ROOT/tools/frpctl" "$ROOT/tools/frpcli" "$ROOT/tools/frp-client" \
  "$ROOT/uninstall-client.sh" 2>/dev/null || true

export FRP_SKIP_SYSTEMD=1
export FRP_CLIENT_LIB="$ROOT/lib/frp-client-common.sh"
export FRP_CTL_BIN_DIR="$ROOT/tools"
export HOME="$WORKDIR/home"
mkdir -p "$HOME"

CLIENT="$WORKDIR/client"
mkdir -p "$CLIENT/etc/frp" "$CLIENT/etc/frp-auto-deploy" \
  "$CLIENT/usr/local/bin" "$CLIENT/usr/local/lib/frp-auto-deploy" \
  "$CLIENT/var/lib/frp-auto-deploy"

install_tree() {
  install -m 0644 "$ROOT/lib/frp-client-common.sh" "$CLIENT/usr/local/lib/frp-auto-deploy/"
  install -m 0644 "$ROOT/lib/frp-common.sh" "$CLIENT/usr/local/lib/frp-auto-deploy/"
  install -m 0644 "$ROOT/lib/frp-client-lifecycle.sh" "$CLIENT/usr/local/lib/frp-auto-deploy/"
  install -m 0644 "$ROOT/lib/frp_client_lifecycle.py" "$CLIENT/usr/local/lib/frp-auto-deploy/"
  install -m 0644 "$ROOT/lib/frp_mgmt_auth.py" "$CLIENT/usr/local/lib/frp-auto-deploy/"
  install -m 0644 "$ROOT/lib/frp_data_plane_auth.py" "$CLIENT/usr/local/lib/frp-auto-deploy/"
  install -m 0644 "$ROOT/lib/frp-doctor-common.sh" "$CLIENT/usr/local/lib/frp-auto-deploy/" 2>/dev/null || true
  install -m 0644 "$ROOT/lib/frp_doctor.py" "$CLIENT/usr/local/lib/frp-auto-deploy/" 2>/dev/null || true
  install -m 0644 "$ROOT/lib/frp_ctl_grammar.py" "$CLIENT/usr/local/lib/frp-auto-deploy/"
  install -m 0755 "$ROOT/tools/frpctl" "$CLIENT/usr/local/bin/frpctl"
  install -m 0755 "$ROOT/tools/frpcli" "$CLIENT/usr/local/bin/frpcli"
  install -m 0755 "$ROOT/tools/frp-client" "$CLIENT/usr/local/bin/frp-client"
  ln -sf "$ROOT/tools/frp-client" "$CLIENT/usr/local/bin/frp-client-bin"
}

python3 - "$CLIENT/etc/frp/client-state.json" <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
    "schema_version": 1,
    "allocator_url": "https://127.0.0.1:9/enroll",
    "frp_server": "203.0.113.10",
    "frp_server_port": 443,
    "hostname": "lc-client",
    "machine_id": "00112233445566778899aabbccddeeff",
    "host_id": "lc-client-00112233",
    "services": {
        "ssh": {
            "id": "ssh", "name": "SSH", "preset": "ssh", "protocol": "tcp",
            "local_ip": "127.0.0.1", "local_port": 22, "remote_port": 6002,
            "enabled": True, "ssh_user": "aella",
        }
    },
}, indent=2, sort_keys=True) + "\n")
PY

cat >"$CLIENT/etc/frp/frpc.toml" <<'EOF'
serverAddr = "203.0.113.10"
serverPort = 443
auth.token = "test-token-should-redact"

[[proxies]]
name = "lc-client-00112233-ssh"
type = "tcp"
localIP = "127.0.0.1"
localPort = 22
remotePort = 6002
EOF
chmod 600 "$CLIENT/etc/frp/frpc.toml"

python3 "$ROOT/lib/frp_mgmt_auth.py" gen-key \
  "$CLIENT/etc/frp/client-identity.key" "$CLIENT/etc/frp/client-identity.pub"
chmod 600 "$CLIENT/etc/frp/client-identity.key"
echo 'mac' >"$CLIENT/etc/frp/client-identity.mac"
chmod 600 "$CLIENT/etc/frp/client-identity.mac"
cat >"$CLIENT/etc/frp-auto-deploy/version" <<'EOF'
PROJECT_VERSION=2.1.1
FRP_VERSION=0.70.1
EOF

install_tree

run_ctl() {
  FRP_CLIENT_TEST_ROOT="$CLIENT" FRP_CTL_TEST_ROOT="$CLIENT" \
    "$ROOT/tools/frpctl" "$@"
}

run_cli() {
  FRP_CLIENT_TEST_ROOT="$CLIENT" FRP_CTL_TEST_ROOT="$CLIENT" \
    "$ROOT/tools/frpcli" "$@"
}

HOOK="$WORKDIR/hook.log"
: >"$HOOK"
export FRP_CLIENT_HOOK_LOG="$HOOK"

# frpcli alias parity
grep -q 'exec.*frpctl' "$ROOT/tools/frpcli" || fail "frpcli delegates to frpctl"
run_cli test >"$WORKDIR/cli-test.out" 2>&1 || true
grep -q 'RESULT=' "$WORKDIR/cli-test.out" || fail "frpcli test"

# pause
export FRP_CLIENT_LIFECYCLE_AUTOSTART=enabled
run_ctl pause >"$WORKDIR/pause.out" 2>&1 || fail "pause"
[[ -f "$CLIENT/etc/frp/remote-access-paused.json" ]] || fail "pause marker"
grep -q 'Remote access paused' "$WORKDIR/pause.out" || fail "pause message"

# persistent across simulated reboot (autostart enabled but marker remains)
run_ctl pause >"$WORKDIR/pause2.out" 2>&1 || true
[[ -f "$CLIENT/etc/frp/remote-access-paused.json" ]] || fail "pause marker after second pause"

# restart while paused fails
if run_ctl restart >"$WORKDIR/rst-paused.out" 2>"$WORKDIR/rst-paused.err"; then
  fail "restart while paused should fail"
fi
grep -q 'paused' "$WORKDIR/rst-paused.err" "$WORKDIR/rst-paused.out" || fail "restart paused message"

# test read-only; FAIL overall → non-zero exit (no CA / unreachable allocator)
before="$(cat "$CLIENT/etc/frp/client-state.json")"
set +e
run_ctl test >"$WORKDIR/test.out" 2>&1
test_rc=$?
set -e
[[ "$(cat "$CLIENT/etc/frp/client-state.json")" == "$before" ]] || fail "test mutated state"
grep -q 'NOT TESTED' "$WORKDIR/test.out" || fail "external reachability disclaimer"
grep -q 'RESULT=' "$WORKDIR/test.out" || fail "test RESULT"
if grep -q 'RESULT=FAIL' "$WORKDIR/test.out"; then
  [[ "$test_rc" -ne 0 ]] || fail "RESULT=FAIL must exit non-zero"
else
  [[ "$test_rc" -eq 0 ]] || fail "RESULT=PASS/WARN must exit 0"
fi
grep -q 'IP literal' "$WORKDIR/test.out" || fail "FRP server DNS IP literal"
grep -q 'Identity permissions' "$WORKDIR/test.out" || fail "identity permissions check"

# logs
export FRP_CLIENT_LIFECYCLE_LOG_FIXTURE="$WORKDIR/log-fixture.txt"
printf 'line1\nauth.token=secret\nline3\n' >"$FRP_CLIENT_LIFECYCLE_LOG_FIXTURE"
run_ctl logs >"$WORKDIR/logs.out" 2>&1
grep -q 'redacted' "$WORKDIR/logs.out" || fail "logs redaction"
if run_ctl logs --lines 'abc' >"$WORKDIR/logs-bad.out" 2>"$WORKDIR/logs-bad.err"; then
  fail "invalid --lines should fail"
fi

# resume
run_ctl resume >"$WORKDIR/resume.out" 2>&1 || fail "resume"
[[ ! -f "$CLIENT/etc/frp/remote-access-paused.json" ]] || fail "pause marker cleared"

# restart active
run_ctl pause >"$WORKDIR/pause3.out" 2>&1
run_ctl resume >"$WORKDIR/resume2.out" 2>&1
run_ctl restart >"$WORKDIR/restart.out" 2>&1 || fail "restart active"

# support bundle
run_ctl support-bundle --output "$WORKDIR/bundle.tar.gz" >"$WORKDIR/bundle.out" 2>&1 || fail "support-bundle"
[[ -f "$WORKDIR/bundle.tar.gz" ]] || fail "bundle file"
perm="$(stat -c '%a' "$WORKDIR/bundle.tar.gz")"
[[ "$perm" == "600" ]] || fail "bundle permission $perm"
tar -tzf "$WORKDIR/bundle.tar.gz" | grep -q client-state.redacted.json || fail "bundle contents"
if tar -xOzf "$WORKDIR/bundle.tar.gz" client-state.redacted.json 2>/dev/null | grep -qi 'test-token'; then
  fail "bundle secret leak token"
fi
if tar -xOzf "$WORKDIR/bundle.tar.gz" frpc.redacted.toml 2>/dev/null | grep -q 'test-token-should-redact'; then
  fail "bundle secret leak toml"
fi
PROOF_LEAK='FRP_AD_PROOF_TEST_DO_NOT_LEAK_LIFECYCLE'
python3 - "$CLIENT/etc/frp/frpc.toml" "$PROOF_LEAK" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
leak = sys.argv[2]
text = p.read_text()
text += '\nmetadatas.frp_ad_client_id = "00112233445566778899aabbccddeeff"\n'
text += 'metadatas.frp_ad_proof_schema = "1"\n'
text += 'metadatas.frp_ad_proof = "%s"\n' % leak
p.write_text(text)
PY
run_ctl support-bundle --output "$WORKDIR/bundle2.tar.gz" >"$WORKDIR/bundle2.out" 2>&1 || fail "support-bundle proof"
if tar -xOzf "$WORKDIR/bundle2.tar.gz" 2>/dev/null | grep -F "$PROOF_LEAK"; then
  fail "bundle secret leak proof"
fi
redacted_toml="$(tar -xOzf "$WORKDIR/bundle2.tar.gz" frpc.redacted.toml 2>/dev/null || true)"
printf '%s' "$redacted_toml" | grep -F 'frp_ad_proof = "[redacted]"' >/dev/null \
  || fail "proof redaction marker"
pass "LINUX_SUPPORT_BUNDLE_PROOF_REDACTED"

# grammar help
run_ctl help >"$WORKDIR/help.out" 2>&1
grep -q 'pause' "$WORKDIR/help.out" || fail "help pause"
run_ctl pause '?' >"$WORKDIR/pause-help.out" 2>&1 || true

# security metacharacters
for ch in ';' '|' '&' '$' '`' '>' '<' '('; do
  if run_ctl pause "$ch" >"$WORKDIR/sec-$ch.out" 2>"$WORKDIR/sec-$ch.err"; then
    fail "shell meta accepted: $ch"
  fi
done

# uninstall confirmation decline
if printf 'no\n' | run_ctl uninstall >"$WORKDIR/un-decline.out" 2>&1; then
  fail "decline should fail"
fi
grep -qi 'cancel' "$WORKDIR/un-decline.out" || fail "decline message"

# uninstall with frpctl --yes (last: destroys fixture tree)
run_ctl pause >"$WORKDIR/pause4.out" 2>&1 || true

# Regression: uninstall must not use global pkill -x frpc (unrelated frpc survives).
# With FRP_SKIP_SYSTEMD=1 the stop path is a no-op; assert source never invokes pkill -x.
if grep -nE '^[[:space:]]*pkill[[:space:]]+-x[[:space:]]+frpc' \
  "$ROOT/lib/frp-client-lifecycle.sh" "$ROOT/uninstall-client.sh"; then
  fail "global pkill -x frpc must not appear in uninstall/stop paths"
fi
# Document: an unrelated process named frpc is not killed — stop/uninstall only
# target project-owned PIDs (systemctl unit MainPID or cmdline matching
# /usr/local/bin/frpc -c /etc/frp/frpc.toml). FRP_SKIP_SYSTEMD=1 mocks systemd.
grep -q 'frp_client_project_frpc' "$ROOT/lib/frp-client-lifecycle.sh" \
  || fail "project-scoped frpc stop helper missing"
grep -q 'frp_u_project_frpc' "$ROOT/uninstall-client.sh" \
  || fail "uninstall project-scoped frpc helper missing"
# No /home/... production fallbacks
if grep -nE '/home/aella/' "$ROOT/lib/frp-client-lifecycle.sh"; then
  fail "developer /home/aella path left as uninstall fallback"
fi
install -m 0755 "$ROOT/uninstall-client.sh" \
  "$CLIENT/usr/local/lib/frp-auto-deploy/uninstall-client.sh"
[[ -f "$CLIENT/usr/local/lib/frp-auto-deploy/uninstall-client.sh" ]] \
  || fail "uninstall helper not installed to libdir"

run_ctl uninstall --yes >"$WORKDIR/un.out" 2>&1 || fail "uninstall --yes"
[[ ! -f "$CLIENT/etc/frp/client-state.json" ]] || fail "state removed"
[[ ! -f "$CLIENT/etc/frp/client-identity.key" ]] || fail "identity removed"

# idempotent uninstall
FRP_UNINSTALL_TEST_ROOT="$CLIENT" FRP_CLIENT_TEST_ROOT="$CLIENT" \
  bash "$ROOT/uninstall-client.sh" >"$WORKDIR/un2.out" 2>&1 || fail "second uninstall"

pass "test-client-lifecycle-diagnostics"
