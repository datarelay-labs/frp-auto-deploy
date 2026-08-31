#!/usr/bin/env bash
# Installed-artifact smoke: bootstrap-client → isolated root, no live enroll.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }

ensure_bundle() {
  local bundle="$ROOT/dist/bootstrap-client.sh"
  local need=0
  if [[ ! -x "$bundle" ]]; then
    need=1
  elif [[ "$ROOT/scripts/build-bundles.py" -nt "$bundle" ]] ||
       [[ "$ROOT/uninstall-client.sh" -nt "$bundle" ]] ||
       [[ "$ROOT/lib/frp-client-lifecycle.sh" -nt "$bundle" ]] ||
       [[ "$ROOT/tools/frpctl" -nt "$bundle" ]] ||
       [[ "$ROOT/tools/frpcli" -nt "$bundle" ]]; then
    need=1
  elif ! grep -q 'uninstall-client.sh' "$bundle"; then
    need=1
  fi
  if [[ "$need" == "1" ]]; then
    bash "$ROOT/scripts/build-bundles.sh" >/dev/null
  fi
  [[ -x "$bundle" ]] || fail "bootstrap-client.sh missing after build"
  grep -q 'uninstall-client.sh' "$bundle" || fail "bundle missing uninstall-client.sh"
  grep -q 'frpcli' "$bundle" || fail "bundle missing frpcli"
  grep -q 'frp-client-lifecycle' "$bundle" || fail "bundle missing lifecycle"
}

write_runtime_fixture() {
  local tree="$1"
  mkdir -p "$tree/etc/frp" "$tree/etc/frp-auto-deploy" "$tree/usr/local/bin" \
    "$tree/usr/local/lib/frp-auto-deploy" "$tree/var/lib/frp-auto-deploy"
  cat >"$tree/usr/local/bin/frpc" <<'EOF'
#!/bin/sh
if [ "${1:-}" = verify ]; then exit 0; fi
if [ "${1:-}" = --version ]; then echo "frpc version 0.70.1"; exit 0; fi
exit 0
EOF
  chmod 0755 "$tree/usr/local/bin/frpc"
  cat >"$tree/etc/frp/client-state.json" <<'EOF'
{
  "schema_version": 1,
  "allocator_url": "https://allocator.example.test/enroll",
  "frp_server": "203.0.113.10",
  "frp_server_port": 443,
  "host_id": "artifact-client-aabbccdd",
  "hostname": "artifact-client",
  "machine_id": "aabbccddeeff00112233445566778899",
  "services": {
    "ssh": {
      "enabled": true,
      "id": "ssh",
      "local_ip": "127.0.0.1",
      "local_port": 22,
      "name": "SSH",
      "preset": "ssh",
      "protocol": "tcp",
      "remote_port": 6003,
      "ssh_user": "aella"
    }
  },
  "transport": "wss"
}
EOF
  chmod 0600 "$tree/etc/frp/client-state.json"
  cat >"$tree/etc/frp/frpc.toml" <<'EOF'
serverAddr = "203.0.113.10"
serverPort = 443
auth.method = "token"
auth.token = "artifact-client-token-secret"
transport.protocol = "websocket"
transport.tls.enable = true

[[proxies]]
name = "artifact-client-aabbccdd-ssh"
type = "tcp"
localIP = "127.0.0.1"
localPort = 22
remotePort = 6003
EOF
  chmod 0600 "$tree/etc/frp/frpc.toml"
  printf 'Public SSH: 203.0.113.10:6003\n' >"$tree/etc/frp/access-info.txt"
  printf '%s\n' 'test allocator CA certificate bytes' >"$tree/etc/frp-auto-deploy/allocator-ca.crt"
  python3 "$ROOT/lib/frp_mgmt_auth.py" gen-key \
    "$tree/etc/frp/client-identity.key" "$tree/etc/frp/client-identity.pub"
  printf '%064d\n' 0 >"$tree/etc/frp/client-identity.mac"
  chmod 0600 "$tree/etc/frp/client-identity.key" "$tree/etc/frp/client-identity.mac"
  chmod 0644 "$tree/etc/frp/client-identity.pub" "$tree/etc/frp-auto-deploy/allocator-ca.crt"
  cat >"$tree/etc/frp-auto-deploy/version" <<'EOF'
PROJECT_VERSION=2.1.0
FRP_VERSION=0.70.1
RELEASE_CHANNEL=stable
SOURCE_REF=v2.1.0
EOF
}

scan_tree_no_home() {
  local tree="$1"
  if grep -RInF '/home/aella' \
    --include='*.sh' --include='*.py' --include='frpctl' --include='frpcli' --include='frp-client' \
    "$tree/usr/local" 2>/dev/null; then
    fail "installed tree contains /home/aella path"
  fi
}

ensure_bundle
BUNDLE_SHA="$(sha256sum "$ROOT/dist/bootstrap-client.sh" | awk '{print $1}')"
CLIENT="$WORKDIR/client"
write_runtime_fixture "$CLIENT"

FRP_CLIENT_TEST_ROOT="$CLIENT" FRP_SKIP_SYSTEMD=1 FRP_SKIP_DOWNLOAD=1 \
  FRP_BUNDLE_SHA256="$BUNDLE_SHA" \
  bash "$ROOT/dist/bootstrap-client.sh" --upgrade >"$WORKDIR/install.out" 2>"$WORKDIR/install.err" \
  || fail "bootstrap --upgrade failed: $(tail -20 "$WORKDIR/install.err" "$WORKDIR/install.out")"

[[ -x "$CLIENT/usr/local/bin/frpctl" ]] || fail "installed frpctl missing"
[[ -x "$CLIENT/usr/local/bin/frpcli" ]] || fail "installed frpcli missing"
[[ -x "$CLIENT/usr/local/lib/frp-auto-deploy/uninstall-client.sh" ]] \
  || fail "uninstall helper missing at usr/local/lib/frp-auto-deploy/uninstall-client.sh"
[[ -f "$CLIENT/usr/local/lib/frp-auto-deploy/frp-client-lifecycle.sh" ]] \
  || fail "lifecycle module missing"
pass "INSTALLED_FILES"

# Only installed bindir — no source-tree tools/ on PATH.
export PATH="$CLIENT/usr/local/bin:/usr/bin:/bin"
unset FRP_CTL_BIN_DIR FRP_CLIENT_LIB || true
export FRP_CLIENT_TEST_ROOT="$CLIENT"
export FRP_CTL_TEST_ROOT="$CLIENT"
export FRP_SKIP_SYSTEMD=1
export HOME="$WORKDIR/home"
mkdir -p "$HOME"

command -v frpctl | grep -q "$CLIENT/usr/local/bin/frpctl" || fail "frpctl not from installed bindir"
command -v frpcli | grep -q "$CLIENT/usr/local/bin/frpcli" || fail "frpcli not from installed bindir"

frpctl help >"$WORKDIR/help.out" 2>&1 || fail "frpctl help"
grep -Eqi 'pause|uninstall|support-bundle|status' "$WORKDIR/help.out" || fail "frpctl help content"
frpcli help >"$WORKDIR/cli-help.out" 2>&1 || fail "frpcli help"
pass "HELP"

frpctl show status >"$WORKDIR/status.out" 2>&1 || true
grep -Eqi 'status|version|Remote access|client|frpc|PAUSE|ACTIVE|artifact-client' \
  "$WORKDIR/status.out" "$WORKDIR/help.out" || fail "status/help signals"

export FRP_CLIENT_LIFECYCLE_AUTOSTART=enabled
frpctl pause >"$WORKDIR/pause.out" 2>&1 || fail "pause from installed tree"
[[ -f "$CLIENT/etc/frp/remote-access-paused.json" ]] || fail "pause marker"
frpctl test >"$WORKDIR/test.out" 2>&1 || true
grep -q 'RESULT=' "$WORKDIR/test.out" || fail "test RESULT"
frpctl support-bundle --output "$WORKDIR/bundle.tar.gz" >"$WORKDIR/bundle.out" 2>&1 \
  || fail "support-bundle"
[[ -f "$WORKDIR/bundle.tar.gz" ]] || fail "bundle file"
pass "LIFECYCLE_SMOKE"

scan_tree_no_home "$CLIENT"
pass "NO_HOME_AELLA_IN_INSTALLED_TREE"

frpctl uninstall --yes >"$WORKDIR/un.out" 2>&1 || fail "frpctl uninstall --yes"
[[ ! -f "$CLIENT/etc/frp/client-state.json" ]] || fail "state removed"
[[ ! -f "$CLIENT/etc/frp/client-identity.key" ]] || fail "identity removed"
pass "UNINSTALL"

FRP_UNINSTALL_TEST_ROOT="$CLIENT" FRP_CLIENT_TEST_ROOT="$CLIENT" \
  bash "$CLIENT/usr/local/lib/frp-auto-deploy/uninstall-client.sh" \
  >"$WORKDIR/un2.out" 2>&1 || {
  # Helper may already be removed by first uninstall; fall back to dist copy.
  if [[ -x "$ROOT/dist/uninstall-client.sh" ]]; then
    FRP_UNINSTALL_TEST_ROOT="$CLIENT" FRP_CLIENT_TEST_ROOT="$CLIENT" \
      bash "$ROOT/dist/uninstall-client.sh" >"$WORKDIR/un2.out" 2>&1 \
      || fail "second uninstall"
  else
    FRP_UNINSTALL_TEST_ROOT="$CLIENT" FRP_CLIENT_TEST_ROOT="$CLIENT" \
      bash "$ROOT/uninstall-client.sh" >"$WORKDIR/un2.out" 2>&1 \
      || fail "second uninstall"
  fi
}
pass "UNINSTALL_IDEMPOTENT"

echo "INSTALLED_CLIENT_ARTIFACT_TEST=PASS"
