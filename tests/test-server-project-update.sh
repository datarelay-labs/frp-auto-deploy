#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/frp-common.sh
. "$ROOT/lib/frp-common.sh"
UPDATE="$ROOT/tools/frp-project-update"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
cat >"$WORKDIR/nginx" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 0755 "$WORKDIR/nginx"
export FRP_NGINX_BIN="$WORKDIR/nginx"

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }
sha() { sha256sum "$1" | awk '{print $1}'; }

setup_tree() {
  local tree="$1"
  rm -rf "$tree"
  mkdir -p \
    "$tree/etc/frp-auto-deploy/pki" "$tree/etc/frp" \
    "$tree/var/lib/frp-auto-deploy/enrollments/client-a" \
    "$tree/var/lib/frp-auto-deploy/bootstrap/client-a" \
    "$tree/usr/local/bin" "$tree/usr/local/lib/frp-auto-deploy" \
    "$tree/usr/local/sbin" "$tree/etc/systemd/system"
  cat >"$tree/usr/local/bin/frps" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && echo "0.70.1"
exit 0
EOF
  chmod 0755 "$tree/usr/local/bin/frps"
  printf 'server-token-preserve\n' >"$tree/etc/frp/server_token"
  printf 'ca-preserve\n' >"$tree/etc/frp-auto-deploy/pki/ca.crt"
  printf 'ca-key-preserve\n' >"$tree/etc/frp-auto-deploy/pki/ca.key"
  printf 'server-cert-preserve\n' >"$tree/etc/frp-auto-deploy/pki/server.crt"
  printf 'server-key-preserve\n' >"$tree/etc/frp-auto-deploy/pki/server.key"
  printf 'enrollment-preserve\n' >"$tree/var/lib/frp-auto-deploy/enrollments/client-a/state"
  printf 'bootstrap-preserve\n' >"$tree/var/lib/frp-auto-deploy/bootstrap/client-a/state"
  cat >"$tree/etc/frp/frps.toml" <<'EOF'
bindPort = 7000
auth.tokenSource.file.path = "/etc/frp/server_token"
allowPorts = [{ start = 6000, end = 6098 }]
EOF
  cat >"$tree/etc/frp-auto-deploy/config.json" <<'EOF'
{
  "public_host": "server.example",
  "deployment_mode": "single443",
  "frp_control_public_port": 443,
  "frp_control_listen_port": 7000,
  "allocator_public_port": 443,
  "allocator_listen_port": 6099,
  "allocator_public_url": "https://server.example/enroll",
  "port_start": 6000,
  "port_end": 6098,
  "client_installer_url": "https://updates.example/client.sh"
}
EOF
  printf 'events {}\nhttp {\n  server {\n    listen 443 ssl;\n  }\n}\n' \
    >"$tree/etc/frp-auto-deploy/frontend.conf"
  cat >"$tree/var/lib/frp-auto-deploy/registry.json" <<'EOF'
{
  "schema_version": 2,
  "reserved": [6000, 6001],
  "clients": {
    "machine-a": {
      "hostname": "host-a",
      "labels": ["production", "database"],
      "notes": "must survive update",
      "services": {
        "ssh": {"local_port": 22, "remote_port": 6002, "enabled": true}
      }
    }
  }
}
EOF
  cat >"$tree/etc/frp-auto-deploy/version" <<'EOF'
PROJECT_VERSION=2.0.0
FRP_VERSION=0.70.1
RELEASE_CHANNEL=dev
SOURCE_REF=main
BUNDLE_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF
  printf 'old allocator\n' >"$tree/usr/local/lib/frp-auto-deploy/frp-port-allocator.py"
  printf 'old unit\n' >"$tree/etc/systemd/system/frp-port-allocator.service"
  cp "$ROOT/server/frp-frontend.service" "$tree/etc/systemd/system/frp-frontend.service"
  chmod 600 "$tree/etc/frp/server_token" "$tree/var/lib/frp-auto-deploy/registry.json"
  chmod 600 "$tree/etc/frp-auto-deploy/pki/"*
}

state_digest() {
  local tree="$1"
  python3 - "$tree" <<'PY'
import hashlib, sys
from pathlib import Path
root = Path(sys.argv[1])
paths = [
    "usr/local/bin/frps", "etc/frp/frps.toml", "etc/frp/server_token",
    "etc/frp-auto-deploy/config.json", "etc/frp-auto-deploy/pki",
    "var/lib/frp-auto-deploy/registry.json",
    "var/lib/frp-auto-deploy/enrollments",
    "var/lib/frp-auto-deploy/bootstrap",
]
h = hashlib.sha256()
for rel in paths:
    p = root / rel
    if p.is_dir():
        for child in sorted(x for x in p.rglob("*") if x.is_file()):
            h.update(str(child.relative_to(root)).encode() + b"\0" + child.read_bytes())
    else:
        h.update(rel.encode() + b"\0" + p.read_bytes())
print(h.hexdigest())
PY
}

run_local() {
  local tree="$1"
  shift
  env FRP_SERVER_TEST_ROOT="$tree" "$UPDATE" --source "$ROOT" "$@"
}

# Check-only validates and reports without changing installed state or backups.
CHECK="$WORKDIR/check"
setup_tree "$CHECK"
CHECK_BEFORE="$(state_digest "$CHECK")"
VERSION_BEFORE="$(sha "$CHECK/etc/frp-auto-deploy/version")"
run_local "$CHECK" --check >"$WORKDIR/check.out"
grep -q 'State mutation             : NO' "$WORKDIR/check.out" || fail "check-only report"
[[ "$(state_digest "$CHECK")" == "$CHECK_BEFORE" ]] || fail "check-only changed protected state"
[[ "$(sha "$CHECK/etc/frp-auto-deploy/version")" == "$VERSION_BEFORE" ]] || fail "check-only changed version"
[[ ! -d "$CHECK/var/lib/frp-auto-deploy/backups" ]] || fail "check-only created backup"
pass "CHECK_ONLY_NO_MUTATION"

# Successful local update installs management files and preserves all server state.
OK="$WORKDIR/ok"
setup_tree "$OK"
OK_BEFORE="$(state_digest "$OK")"
run_local "$OK" >"$WORKDIR/ok.out"
grep -q 'Server project update completed successfully' "$WORKDIR/ok.out" || fail "success report"
grep -q 'FRP binary      : unchanged' "$WORKDIR/ok.out" || fail "FRP unchanged report"
grep -q 'Client re-enroll: NOT REQUIRED' "$WORKDIR/ok.out" || fail "re-enrollment report"
[[ "$(state_digest "$OK")" == "$OK_BEFORE" ]] || fail "server state changed"
cmp "$ROOT/tools/frp-project-update" "$OK/usr/local/sbin/frp-project-update" >/dev/null ||
  fail "project updater not installed"
grep -q "PROJECT_VERSION=${PROJECT_VERSION}" "$OK/etc/frp-auto-deploy/version" ||
  fail "project version not updated"
grep -q 'FRP_VERSION=0.70.1' "$OK/etc/frp-auto-deploy/version" || fail "FRP metadata changed"
pass "STATE_REGISTRY_TOKEN_CA_PRESERVED"
pass "NO_CLIENT_REENROLLMENT"

# A Direct deployment must not gain or start the single-443 frontend unit.
DIRECT="$WORKDIR/direct"
setup_tree "$DIRECT"
python3 - "$DIRECT/etc/frp-auto-deploy/config.json" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
d = json.loads(p.read_text())
d["deployment_mode"] = "direct"
d["frp_control_listen_port"] = 443
d["allocator_public_port"] = 6099
d["allocator_public_url"] = "https://server.example:6099/enroll"
p.write_text(json.dumps(d, indent=2, sort_keys=True) + "\n")
PY
rm -f "$DIRECT/etc/systemd/system/frp-frontend.service" \
  "$DIRECT/etc/frp-auto-deploy/frontend.conf"
run_local "$DIRECT" >"$WORKDIR/direct.out"
[[ ! -f "$DIRECT/etc/systemd/system/frp-frontend.service" ]] ||
  fail "direct mode gained frontend unit"
grep -q '"deployment_mode": "direct"' "$DIRECT/etc/frp-auto-deploy/config.json" ||
  fail "direct mode changed"
pass "DEPLOYMENT_MODE_PRESERVED"

# Failure injection must restore every replaceable file and leave protected state intact.
for phase in validate install verify; do
  tree="$WORKDIR/rollback-$phase"
  setup_tree "$tree"
  cp "$tree/usr/local/lib/frp-auto-deploy/frp-port-allocator.py" "$WORKDIR/$phase.before"
  before="$(state_digest "$tree")"
  if env FRP_SERVER_TEST_ROOT="$tree" FRP_SERVER_UPGRADE_HOOK_FAIL="$phase" \
    "$UPDATE" --source "$ROOT" >"$WORKDIR/$phase.out" 2>"$WORKDIR/$phase.err"; then
    fail "$phase failure should fail"
  fi
  grep -q 'UPGRADE_ROLLBACK=PASS' "$WORKDIR/$phase.out" ||
    fail "$phase rollback marker"
  cmp "$WORKDIR/$phase.before" "$tree/usr/local/lib/frp-auto-deploy/frp-port-allocator.py" >/dev/null ||
    fail "$phase did not restore project file"
  [[ "$(state_digest "$tree")" == "$before" ]] || fail "$phase changed protected state"
done
pass "ROLLBACK_VALIDATE_INSTALL_VERIFY"

# Local metadata must be present and internally consistent.
BADMETA="$WORKDIR/badmeta"
cp -a "$ROOT" "$BADMETA"
python3 - "$BADMETA/release-manifest.json" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
d = json.loads(p.read_text())
d["project_version"] = "9.9.9"
p.write_text(json.dumps(d) + "\n")
PY
META_TREE="$WORKDIR/meta-tree"
setup_tree "$META_TREE"
if env FRP_SERVER_TEST_ROOT="$META_TREE" "$UPDATE" --source "$BADMETA" \
  >"$WORKDIR/meta.out" 2>"$WORKDIR/meta.err"; then
  fail "wrong metadata should fail"
fi
grep -qi 'metadata project version mismatch' "$WORKDIR/meta.err" || fail "wrong metadata message"
rm -f "$BADMETA/release-manifest.json"
if env FRP_SERVER_TEST_ROOT="$META_TREE" "$UPDATE" --source "$BADMETA" \
  >"$WORKDIR/missing.out" 2>"$WORKDIR/missing.err"; then
  fail "missing metadata should fail"
fi
grep -Eqi 'missing (or invalid )?.*release-manifest|missing project file: .*release-manifest' "$WORKDIR/missing.err" ||
  fail "missing metadata message"
pass "METADATA_REQUIRED"

# Simulated HTTPS remote fetch. The curl mock serves immutable local fixtures.
FIX="$WORKDIR/fixture"
MOCKBIN="$WORKDIR/mockbin"
mkdir -p "$FIX" "$MOCKBIN"
cp "$ROOT/dist/bootstrap-server.sh" "$FIX/bootstrap-server.sh"
printf '%s  dist/bootstrap-server.sh\n' "$(sha "$FIX/bootstrap-server.sh")" >"$FIX/SHA256SUMS"
cat >"$MOCKBIN/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=""
url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  https://fixture.invalid/SHA256SUMS) cp "$FRP_TEST_FIXTURE/SHA256SUMS" "$out" ;;
  https://fixture.invalid/bootstrap-server.sh) cp "$FRP_TEST_FIXTURE/bootstrap-server.sh" "$out" ;;
  *) echo "unexpected mock URL: $url" >&2; exit 22 ;;
esac
EOF
chmod 0755 "$MOCKBIN/curl"

REMOTE="$WORKDIR/remote"
setup_tree "$REMOTE"
REMOTE_BEFORE="$(state_digest "$REMOTE")"
env PATH="$MOCKBIN:$PATH" FRP_TEST_FIXTURE="$FIX" FRP_SERVER_TEST_ROOT="$REMOTE" \
  FRP_RELEASE_CHANNEL=dev \
  FRP_SERVER_PROJECT_SHA256SUMS_URL=https://fixture.invalid/SHA256SUMS \
  FRP_SERVER_PROJECT_UPDATE_URL=https://fixture.invalid/bootstrap-server.sh \
  "$UPDATE" >"$WORKDIR/remote.out"
[[ "$(state_digest "$REMOTE")" == "$REMOTE_BEFORE" ]] || fail "remote update changed state"
grep -q 'Server project update completed successfully' "$WORKDIR/remote.out" ||
  fail "remote simulated HTTPS update"
pass "REMOTE_SIMULATED_HTTPS_SHA256"

# Tamper, HTTP, and missing checksum metadata are rejected before execution.
printf '\n# tampered\n' >>"$FIX/bootstrap-server.sh"
TAMPER="$WORKDIR/tamper"
setup_tree "$TAMPER"
if env PATH="$MOCKBIN:$PATH" FRP_TEST_FIXTURE="$FIX" FRP_SERVER_TEST_ROOT="$TAMPER" \
  FRP_RELEASE_CHANNEL=dev \
  FRP_SERVER_PROJECT_SHA256SUMS_URL=https://fixture.invalid/SHA256SUMS \
  FRP_SERVER_PROJECT_UPDATE_URL=https://fixture.invalid/bootstrap-server.sh \
  "$UPDATE" >"$WORKDIR/tamper.out" 2>"$WORKDIR/tamper.err"; then
  fail "tampered bundle should fail"
fi
grep -qi 'SHA256' "$WORKDIR/tamper.err" || fail "tamper SHA message"
pass "TAMPER_REJECTED"

HTTP="$WORKDIR/http"
setup_tree "$HTTP"
if env FRP_SERVER_TEST_ROOT="$HTTP" \
  FRP_SERVER_PROJECT_SHA256SUMS_URL=http://fixture.invalid/SHA256SUMS \
  FRP_SERVER_PROJECT_UPDATE_URL=https://fixture.invalid/bootstrap-server.sh \
  "$UPDATE" >"$WORKDIR/http.out" 2>"$WORKDIR/http.err"; then
  fail "HTTP URL should fail"
fi
grep -qi 'HTTPS' "$WORKDIR/http.err" || fail "HTTP rejection message"
pass "HTTP_REJECTED"

printf '%s  dist/other.sh\n' "$(printf other | sha256sum | awk '{print $1}')" >"$FIX/SHA256SUMS"
MISSING="$WORKDIR/missing-sha"
setup_tree "$MISSING"
if env PATH="$MOCKBIN:$PATH" FRP_TEST_FIXTURE="$FIX" FRP_SERVER_TEST_ROOT="$MISSING" \
  FRP_RELEASE_CHANNEL=dev \
  FRP_SERVER_PROJECT_SHA256SUMS_URL=https://fixture.invalid/SHA256SUMS \
  FRP_SERVER_PROJECT_UPDATE_URL=https://fixture.invalid/bootstrap-server.sh \
  "$UPDATE" >"$WORKDIR/missing-sha.out" 2>"$WORKDIR/missing-sha.err"; then
  fail "missing SHA metadata should fail"
fi
grep -qi 'missing valid metadata' "$WORKDIR/missing-sha.err" ||
  fail "missing SHA metadata message"
pass "MISSING_SHA_METADATA_REJECTED"

echo "SERVER_PROJECT_UPDATE_TESTS=PASS"
