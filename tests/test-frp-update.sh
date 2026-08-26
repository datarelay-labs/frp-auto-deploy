#!/usr/bin/env bash
# Regression tests for safe FRP update management.
# Uses a hermetic fixture root; never prints real secrets.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPDATE="$ROOT/tools/frp-update"
STATUS="$ROOT/tools/frp-server-status"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }

assert_mode() {
  local path="$1" expected="$2"
  local mode
  mode="$(python3 - "$path" <<'PY'
import os,stat,sys
print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))
PY
)"
  [[ "$mode" == "$expected" ]] || fail "mode $path wanted $expected got $mode"
}

bytes_equal() {
  python3 - "$1" "$2" <<'PY'
import sys
from pathlib import Path
sys.exit(0 if Path(sys.argv[1]).read_bytes() == Path(sys.argv[2]).read_bytes() else 1)
PY
}

sha_file() { sha256sum -- "$1" | awk '{print $1}'; }

make_fake_frps() {
  local dest="$1" version="$2" verify_exit="${3:-0}"
  mkdir -p "$(dirname -- "$dest")"
  cat >"$dest" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "--version" || "\${1:-}" == "-v" ]]; then
  echo "${version}"
  exit 0
fi
if [[ "\${1:-}" == "verify" ]]; then
  exit ${verify_exit}
fi
exit 0
EOF
  chmod 755 "$dest"
}

make_archive_for() {
  # Create a tar.gz that matches upstream layout enough for extraction path;
  # tests usually override with FRP_UPDATE_FAKE_FRPS after checksum.
  local dest="$1" version="$2" arch="$3"
  local staging="$WORKDIR/arch-staging-$$"
  rm -rf "$staging"
  mkdir -p "$staging/frp_${version}_linux_${arch}"
  make_fake_frps "$staging/frp_${version}_linux_${arch}/frps" "$version"
  tar -C "$staging" -czf "$dest" "frp_${version}_linux_${arch}"
  rm -rf "$staging"
}

setup_fixture() {
  local name="$1"
  local base="$WORKDIR/$name"
  rm -rf "$base"
  mkdir -p "$base"/{usr/local/bin,etc/frp,etc/frp-auto-deploy,var/lib/frp-auto-deploy,bin,state}

  # Mock systemctl
  cat >"$base/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE="$ROOT/state"
cmd=""
unit=""
for arg in "$@"; do
  case "$arg" in
    --quiet|-q) continue ;;
    is-active|restart|start|stop|status) cmd="$arg" ;;
    *)
      if [[ -z "$unit" && "$arg" != --* ]]; then
        unit="$arg"
      fi
      ;;
  esac
done
case "$cmd" in
  is-active)
    if [[ -f "$STATE/${unit}.active" ]]; then
      echo active
      exit 0
    fi
    echo inactive
    exit 3
    ;;
  restart)
    if [[ -f "$STATE/fail-restart" ]]; then
      exit 1
    fi
    touch "$STATE/${unit}.active"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod 755 "$base/bin/systemctl"

  # Mock ss: report configured control port as listening when frps.active
  cat >"$base/bin/ss" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -f "$ROOT/state/frps.active" ]]; then
  port="$(python3 - "$ROOT/etc/frp-auto-deploy/config.json" <<'PY'
import json,sys
from pathlib import Path
print(json.loads(Path(sys.argv[1]).read_text()).get("control_port",443))
PY
)"
  # Match ss -H -lnt column layout (local address in field 4).
  printf 'LISTEN 0 4096 *:%s *:*\n' "$port"
fi
exit 0
EOF
  chmod 755 "$base/bin/ss"

  printf 'test-token-fixture-do-not-use\n' >"$base/etc/frp/server_token"
  chmod 600 "$base/etc/frp/server_token"

  cat >"$base/etc/frp/frps.toml" <<'EOF'
bindPort = 443
auth.method = "token"
auth.tokenSource.type = "file"
auth.tokenSource.file.path = "server_token"
transport.tls.force = true
allowPorts = [
  { start = 6000, end = 6098 }
]
EOF
  chmod 600 "$base/etc/frp/frps.toml"

  python3 - "$base/etc/frp-auto-deploy/config.json" <<'PY'
import json,sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
  "public_ip": "203.0.113.10",
  "control_port": 443,
  "port_start": 6000,
  "port_end": 6098,
  "listen_host": "0.0.0.0",
  "listen_port": 6099,
  "allocator_public_url": "http://203.0.113.10/enroll",
  "registry_file": "registry.json",
  "enrollments_dir": "enrollments",
  "token_file": "server_token",
  "client_installer_url": ""
}, indent=2, sort_keys=True) + "\n")
PY
  chmod 600 "$base/etc/frp-auto-deploy/config.json"

  python3 - "$base/var/lib/frp-auto-deploy/registry.json" <<'PY'
import json,sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
  "reserved": [6000, 6001, 6099],
  "clients": {
    "online-client-aaaaaaaaaaaaaaaaaaaa": {
      "hostname": "online-host",
      "ssh_user": "root",
      "ssh_port": 6002,
      "https_port": None,
      "https_enabled": False,
      "https_ip": "",
      "created_at": "2020-01-01T00:00:00Z",
      "last_enrolled_at": "2020-01-01T00:00:00Z"
    },
    "offline-client-bbbbbbbbbbbbbbbbbbbb": {
      "hostname": "offline-host",
      "ssh_user": "root",
      "ssh_port": 6004,
      "https_port": None,
      "https_enabled": False,
      "https_ip": "",
      "created_at": "2020-01-01T00:00:00Z",
      "last_enrolled_at": "2020-01-01T00:00:00Z"
    },
    "dual-client-cccccccccccccccccccc": {
      "hostname": "dual-host",
      "ssh_user": "root",
      "ssh_port": 6005,
      "https_port": 6006,
      "https_enabled": True,
      "https_ip": "10.0.0.8",
      "created_at": "2020-01-01T00:00:00Z",
      "last_enrolled_at": "2020-01-01T00:00:00Z"
    }
  }
}, indent=2, sort_keys=True) + "\n")
PY
  chmod 600 "$base/var/lib/frp-auto-deploy/registry.json"

  cat >"$base/etc/frp-auto-deploy/version" <<'EOF'
PROJECT_VERSION=1.0.0
FRP_VERSION=0.70.0
EOF

  touch "$base/state/frps.active"
  touch "$base/state/frp-port-allocator.active"
  printf '%s\n' "$base"
}

run_update() {
  local base="$1"
  shift
  local env_vars=()
  local update_args=()
  local arg
  for arg in "$@"; do
    if [[ "$arg" == *=* && "$arg" != --* ]]; then
      env_vars+=("$arg")
    else
      update_args+=("$arg")
    fi
  done
  (
    export FRP_AUTO_DEPLOY_LIB="$ROOT/server"
    export FRP_AUTO_DEPLOY_UPDATE_TEST_DIR="$base"
    export PATH="$base/bin:$PATH"
    local item
    for item in "${env_vars[@]+"${env_vars[@]}"}"; do
      export "$item"
    done
    "$UPDATE" ${update_args[@]+"${update_args[@]}"}
  )
}

run_status() {
  local base="$1"
  env \
    FRP_AUTO_DEPLOY_LIB="$ROOT/server" \
    FRP_AUTO_DEPLOY_UPDATE_TEST_DIR="$base" \
    PATH="$base/bin:$PATH" \
    "$STATUS"
}

# --- status smoke ---
S0="$(setup_fixture status0)"
make_fake_frps "$S0/usr/local/bin/frps" "0.70.0"
STATUS_OUT="$WORKDIR/status.out"
run_status "$S0" >"$STATUS_OUT"
grep -q 'Project version : 1.0.0' "$STATUS_OUT" || fail "status project version"
grep -q 'Installed FRP   : 0.70.0' "$STATUS_OUT" || fail "status installed"
grep -q 'Tested FRP      : 0.70.1' "$STATUS_OUT" || fail "status tested"
grep -q 'Update status   : update available' "$STATUS_OUT" || fail "status update available"
grep -q 'Clients         : 3' "$STATUS_OUT" || fail "status clients"
pass "frp-server-status enhanced output"

# --- CASE A: already current ---
A="$(setup_fixture case-a)"
make_fake_frps "$A/usr/local/bin/frps" "0.70.1"
echo 'PROJECT_VERSION=1.0.0' >"$A/etc/frp-auto-deploy/version"
echo 'FRP_VERSION=0.70.1' >>"$A/etc/frp-auto-deploy/version"
cp "$A/usr/local/bin/frps" "$WORKDIR/case-a.frps.before"
cp "$A/etc/frp/server_token" "$WORKDIR/case-a.token.before"
cp "$A/var/lib/frp-auto-deploy/registry.json" "$WORKDIR/case-a.reg.before"
A_OUT="$WORKDIR/case-a.out"
run_update "$A" >"$A_OUT"
grep -q 'already installed' "$A_OUT" || fail "CASE A message"
bytes_equal "$WORKDIR/case-a.frps.before" "$A/usr/local/bin/frps" || fail "CASE A binary changed"
bytes_equal "$WORKDIR/case-a.token.before" "$A/etc/frp/server_token" || fail "CASE A token changed"
bytes_equal "$WORKDIR/case-a.reg.before" "$A/var/lib/frp-auto-deploy/registry.json" || fail "CASE A registry changed"
pass "CASE A already current"

# Shared fixtures for upgrade-path cases
make_fake_frps "$WORKDIR/new-frps" "0.70.1" 0
make_fake_frps "$WORKDIR/bad-verify-frps" "0.70.1" 1
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64) FRP_ARCH=amd64 ;;
  aarch64|arm64) FRP_ARCH=arm64 ;;
  *) fail "unsupported test arch $ARCH" ;;
esac
make_archive_for "$WORKDIR/fake-archive.tgz" "0.70.1" "$FRP_ARCH"
FAKE_SHA="$(sha_file "$WORKDIR/fake-archive.tgz")"

# --- CASE B: successful upgrade ---
B="$(setup_fixture case-b)"
make_fake_frps "$B/usr/local/bin/frps" "0.70.0"
cp "$B/etc/frp/server_token" "$WORKDIR/case-b.token.before"
cp "$B/var/lib/frp-auto-deploy/registry.json" "$WORKDIR/case-b.reg.before"
B_OUT="$WORKDIR/case-b.out"
run_update "$B" \
  FRP_UPDATE_FAKE_ARCHIVE="$WORKDIR/fake-archive.tgz" \
  FRP_UPDATE_FAKE_SHA="$FAKE_SHA" \
  FRP_UPDATE_FAKE_FRPS="$WORKDIR/new-frps" \
  >"$B_OUT"
grep -q 'FRP update completed successfully' "$B_OUT" || fail "CASE B success message"
grep -q 'TOKEN_PRESERVED=PASS' "$B_OUT" || fail "CASE B token preserved line"
grep -q 'REGISTRY_PRESERVED=PASS' "$B_OUT" || fail "CASE B registry preserved line"
[[ "$( "$B/usr/local/bin/frps" --version )" == "0.70.1" ]] || fail "CASE B version"
bytes_equal "$WORKDIR/case-b.token.before" "$B/etc/frp/server_token" || fail "CASE B token bytes"
bytes_equal "$WORKDIR/case-b.reg.before" "$B/var/lib/frp-auto-deploy/registry.json" || fail "CASE B registry bytes"
grep -q 'FRP_VERSION=0.70.1' "$B/etc/frp-auto-deploy/version" || fail "CASE B version file"
[[ -d "$B/var/lib/frp-auto-deploy/backups" ]] || fail "CASE B backup dir"
BACKUP_BIN="$(find "$B/var/lib/frp-auto-deploy/backups" -type f -name frps | head -n1)"
[[ -n "$BACKUP_BIN" ]] || fail "CASE B backup binary missing"
assert_mode "$B/etc/frp/server_token" "0o600"
pass "CASE B successful upgrade"

# --- CASE C: download failure ---
C="$(setup_fixture case-c)"
make_fake_frps "$C/usr/local/bin/frps" "0.70.0"
cp "$C/usr/local/bin/frps" "$WORKDIR/case-c.frps.before"
C_OUT="$WORKDIR/case-c.out"
C_ERR="$WORKDIR/case-c.err"
set +e
run_update "$C" FRP_UPDATE_INJECT_FAIL=download >"$C_OUT" 2>"$C_ERR"
C_RC=$?
set -e
[[ "$C_RC" -ne 0 ]] || fail "CASE C should fail"
bytes_equal "$WORKDIR/case-c.frps.before" "$C/usr/local/bin/frps" || fail "CASE C binary changed"
[[ -f "$C/state/frps.active" ]] || fail "CASE C service should remain"
pass "CASE C download failure"

# --- CASE D: checksum failure ---
D="$(setup_fixture case-d)"
make_fake_frps "$D/usr/local/bin/frps" "0.70.0"
cp "$D/usr/local/bin/frps" "$WORKDIR/case-d.frps.before"
D_OUT="$WORKDIR/case-d.out"
set +e
run_update "$D" \
  FRP_UPDATE_FAKE_ARCHIVE="$WORKDIR/fake-archive.tgz" \
  FRP_UPDATE_FAKE_SHA="0000000000000000000000000000000000000000000000000000000000000000" \
  >"$D_OUT" 2>"$WORKDIR/case-d.err"
D_RC=$?
set -e
[[ "$D_RC" -ne 0 ]] || fail "CASE D should fail"
bytes_equal "$WORKDIR/case-d.frps.before" "$D/usr/local/bin/frps" || fail "CASE D binary changed"
[[ -f "$D/state/frps.active" ]] || fail "CASE D service should remain"
pass "CASE D checksum failure"

# --- CASE E: config validation failure ---
E="$(setup_fixture case-e)"
make_fake_frps "$E/usr/local/bin/frps" "0.70.0"
cp "$E/usr/local/bin/frps" "$WORKDIR/case-e.frps.before"
set +e
run_update "$E" \
  FRP_UPDATE_FAKE_ARCHIVE="$WORKDIR/fake-archive.tgz" \
  FRP_UPDATE_FAKE_SHA="$FAKE_SHA" \
  FRP_UPDATE_FAKE_FRPS="$WORKDIR/bad-verify-frps" \
  >"$WORKDIR/case-e.out" 2>"$WORKDIR/case-e.err"
E_RC=$?
set -e
[[ "$E_RC" -ne 0 ]] || fail "CASE E should fail"
bytes_equal "$WORKDIR/case-e.frps.before" "$E/usr/local/bin/frps" || fail "CASE E binary activated"
[[ -f "$E/state/frps.active" ]] || fail "CASE E service"
pass "CASE E config validation failure"

# --- CASE F: health failure triggers rollback ---
F="$(setup_fixture case-f)"
make_fake_frps "$F/usr/local/bin/frps" "0.70.0"
cp "$F/usr/local/bin/frps" "$WORKDIR/case-f.frps.before"
cp "$F/etc/frp/server_token" "$WORKDIR/case-f.token.before"
cp "$F/var/lib/frp-auto-deploy/registry.json" "$WORKDIR/case-f.reg.before"
set +e
run_update "$F" \
  FRP_UPDATE_FAKE_ARCHIVE="$WORKDIR/fake-archive.tgz" \
  FRP_UPDATE_FAKE_SHA="$FAKE_SHA" \
  FRP_UPDATE_FAKE_FRPS="$WORKDIR/new-frps" \
  FRP_UPDATE_INJECT_FAIL=health \
  >"$WORKDIR/case-f.out" 2>"$WORKDIR/case-f.err"
F_RC=$?
set -e
[[ "$F_RC" -ne 0 ]] || fail "CASE F should fail"
grep -q 'Rollback completed successfully' "$WORKDIR/case-f.out" || fail "CASE F rollback message"
[[ "$( "$F/usr/local/bin/frps" --version )" == "0.70.0" ]] || fail "CASE F restored version"
bytes_equal "$WORKDIR/case-f.token.before" "$F/etc/frp/server_token" || fail "CASE F token"
bytes_equal "$WORKDIR/case-f.reg.before" "$F/var/lib/frp-auto-deploy/registry.json" || fail "CASE F registry"
[[ -f "$F/state/frps.active" ]] || fail "CASE F healthy after rollback"
pass "CASE F restart/health failure rollback"

# --- CASE G: rollback safety (permissions + backup metadata) ---
G="$(setup_fixture case-g)"
make_fake_frps "$G/usr/local/bin/frps" "0.70.0"
run_update "$G" \
  FRP_UPDATE_FAKE_ARCHIVE="$WORKDIR/fake-archive.tgz" \
  FRP_UPDATE_FAKE_SHA="$FAKE_SHA" \
  FRP_UPDATE_FAKE_FRPS="$WORKDIR/new-frps" \
  FRP_UPDATE_INJECT_FAIL=health \
  >"$WORKDIR/case-g.out" 2>"$WORKDIR/case-g.err" || true
META="$(find "$G/var/lib/frp-auto-deploy/backups" -name metadata.env | head -n1)"
[[ -n "$META" ]] || fail "CASE G metadata missing"
assert_mode "$META" "0o600"
CFG_BAK="$(find "$G/var/lib/frp-auto-deploy/backups" -name frps.toml | head -n1)"
[[ -n "$CFG_BAK" ]] || fail "CASE G config backup missing"
assert_mode "$CFG_BAK" "0o600"
grep -q 'PREVIOUS_VERSION=0.70.0' "$META" || fail "CASE G previous version"
grep -q 'TARGET_VERSION=0.70.1' "$META" || fail "CASE G target version"
[[ "$( "$G/usr/local/bin/frps" --version )" == "0.70.0" ]] || fail "CASE G restored binary"
pass "CASE G rollback safety"

# --- CASE H: token preservation (no leak) ---
H="$(setup_fixture case-h)"
make_fake_frps "$H/usr/local/bin/frps" "0.70.0"
TOKEN_VAL="$(cat "$H/etc/frp/server_token")"
run_update "$H" \
  FRP_UPDATE_FAKE_ARCHIVE="$WORKDIR/fake-archive.tgz" \
  FRP_UPDATE_FAKE_SHA="$FAKE_SHA" \
  FRP_UPDATE_FAKE_FRPS="$WORKDIR/new-frps" \
  >"$WORKDIR/case-h.out"
grep -q 'TOKEN_PRESERVED=PASS' "$WORKDIR/case-h.out" || fail "CASE H marker"
if grep -F -- "$TOKEN_VAL" "$WORKDIR/case-h.out" >/dev/null 2>&1; then
  fail "CASE H leaked token"
fi
[[ "$(cat "$H/etc/frp/server_token")" == "$TOKEN_VAL" ]] || fail "CASE H token changed"
pass "CASE H token preservation"

# --- CASE I: registry preservation including offline/dual ports ---
I="$(setup_fixture case-i)"
make_fake_frps "$I/usr/local/bin/frps" "0.70.0"
cp "$I/var/lib/frp-auto-deploy/registry.json" "$WORKDIR/case-i.reg.before"
run_update "$I" \
  FRP_UPDATE_FAKE_ARCHIVE="$WORKDIR/fake-archive.tgz" \
  FRP_UPDATE_FAKE_SHA="$FAKE_SHA" \
  FRP_UPDATE_FAKE_FRPS="$WORKDIR/new-frps" \
  >"$WORKDIR/case-i.out"
bytes_equal "$WORKDIR/case-i.reg.before" "$I/var/lib/frp-auto-deploy/registry.json" || fail "CASE I registry changed"
python3 - "$I/var/lib/frp-auto-deploy/registry.json" <<'PY'
import json,sys
from pathlib import Path
state=json.loads(Path(sys.argv[1]).read_text())
ports=set(state['reserved'])
clients=state['clients']
assert any(c['ssh_port']==6004 for c in clients.values()), 'offline port lost'
assert any(c.get('https_port')==6006 for c in clients.values()), 'https port lost'
assert 6000 in ports and 6001 in ports and 6099 in ports
PY
grep -q 'REGISTRY_PRESERVED=PASS' "$WORKDIR/case-i.out" || fail "CASE I marker"
pass "CASE I registry/port preservation"

# --- CASE J covered by invoking existing migration suites from the wrapper ---
# Dry-run / --check does not mutate
J="$(setup_fixture case-j)"
make_fake_frps "$J/usr/local/bin/frps" "0.70.0"
cp "$J/usr/local/bin/frps" "$WORKDIR/case-j.frps.before"
run_update "$J" --check >"$WORKDIR/case-j.out"
grep -q 'Update      : available' "$WORKDIR/case-j.out" || fail "CASE J check available"
bytes_equal "$WORKDIR/case-j.frps.before" "$J/usr/local/bin/frps" || fail "CASE J check mutated"
pass "CASE J --check dry run"

echo
echo "UPDATE_REGRESSION_TESTS=PASS"
echo "FRP_STATUS_ENHANCED=PASS"
echo "TOKEN_PRESERVATION=PASS"
echo "REGISTRY_PRESERVATION=PASS"
echo "PORT_PRESERVATION=PASS"
echo "AUTO_ROLLBACK=PASS"
