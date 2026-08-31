#!/usr/bin/env bash
# Support-bundle must refuse symlink outputs and keep mode 0600 / redaction.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
export PYTHONPATH="$ROOT/lib"
export FRP_CLIENT_TEST_ROOT="$WORKDIR/client-root"
export FRP_DEPLOY_TEST_ROOT="$WORKDIR/server-root"
export FRP_SKIP_SYSTEMD=1
mkdir -p \
  "$FRP_CLIENT_TEST_ROOT/etc/frp" \
  "$FRP_CLIENT_TEST_ROOT/etc/frp-auto-deploy" \
  "$FRP_DEPLOY_TEST_ROOT/etc/frp-auto-deploy" \
  "$FRP_DEPLOY_TEST_ROOT/var/lib/frp-auto-deploy" \
  "$WORKDIR/out"

echo 'PROJECT_VERSION=2.1.1' >"$FRP_CLIENT_TEST_ROOT/etc/frp-auto-deploy/version"
echo 'PROJECT_VERSION=2.1.1' >"$FRP_DEPLOY_TEST_ROOT/etc/frp-auto-deploy/version"
cat >"$FRP_CLIENT_TEST_ROOT/etc/frp/client-state.json" <<'JSON'
{"hostname":"h","token":"super-secret-token","services":{}}
JSON
cat >"$FRP_CLIENT_TEST_ROOT/etc/frp/frpc.toml" <<'TOML'
auth.token = "super-secret-token"
TOML
python3 - "$FRP_DEPLOY_TEST_ROOT" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
(root / 'etc/frp-auto-deploy/config.json').write_text(json.dumps({
    'enrollment_retention_days': 30,
    'registry_file': '/var/lib/frp-auto-deploy/registry.json',
    'enrollments_dir': '/var/lib/frp-auto-deploy/enrollments',
    'bootstrap_dir': '/var/lib/frp-auto-deploy/bootstrap',
    'allocator_public_url': 'https://example.test/enroll',
}) + '\n')
(root / 'var/lib/frp-auto-deploy/registry.json').write_text(json.dumps({
    'schema_version': 2,
    'clients': {},
    'groups': {},
}) + '\n')
PY

victim="$WORKDIR/out/victim.txt"
echo 'do-not-clobber' >"$victim"
link="$WORKDIR/out/bundle-link.tar.gz"
ln -s "$victim" "$link"

if python3 -m frp_client_lifecycle support-bundle --output "$link" >/tmp/frp-sb-client.out 2>/tmp/frp-sb-client.err; then
  fail "client support-bundle should refuse symlink output"
fi
grep -qi 'symlink\|refuse\|unsafe\|exists' /tmp/frp-sb-client.err /tmp/frp-sb-client.out || fail "client symlink error missing"
[[ "$(cat "$victim")" == "do-not-clobber" ]] || fail "client symlink attack clobbered victim"
pass "CLIENT_SUPPORT_BUNDLE_SYMLINK_REFUSED"

if python3 -m frp_server_lifecycle support-bundle --output "$link" >/tmp/frp-sb-server.out 2>/tmp/frp-sb-server.err; then
  fail "server support-bundle should refuse symlink output"
fi
grep -qi 'symlink\|refuse\|unsafe\|exists' /tmp/frp-sb-server.err /tmp/frp-sb-server.out || fail "server symlink error missing"
[[ "$(cat "$victim")" == "do-not-clobber" ]] || fail "server symlink attack clobbered victim"
pass "SERVER_SUPPORT_BUNDLE_SYMLINK_REFUSED"

existing="$WORKDIR/out/existing.tar.gz"
echo 'preexisting' >"$existing"
if python3 -m frp_client_lifecycle support-bundle --output "$existing" >/dev/null 2>&1; then
  fail "client should refuse existing output file"
fi
[[ "$(cat "$existing")" == "preexisting" ]] || fail "existing file was overwritten"
pass "CLIENT_SUPPORT_BUNDLE_EXISTING_REFUSED"

good="$WORKDIR/out/good-client.tar.gz"
python3 -m frp_client_lifecycle support-bundle --output "$good" >/dev/null
mode="$(stat -c '%a' "$good")"
[[ "$mode" == "600" ]] || fail "client bundle mode $mode"
leftovers="$(find "$WORKDIR/out" \( -name '.frp-support.*' -o -name '.frp-server-support.*' \) | wc -l)"
[[ "$leftovers" == "0" ]] || fail "temp leftovers remain"
tmpdir="$WORKDIR/extract"
mkdir -p "$tmpdir"
tar -xzf "$good" -C "$tmpdir"
if grep -RInE 'super-secret-token|BEGIN .*PRIVATE KEY|Enrollment Code:|bt1\.' "$tmpdir"; then
  fail "client bundle leaked secrets"
fi
pass "CLIENT_SUPPORT_BUNDLE_MODE_0600_REDACTED"

good_s="$WORKDIR/out/good-server.tar.gz"
python3 -m frp_server_lifecycle support-bundle --output "$good_s" >/dev/null
mode="$(stat -c '%a' "$good_s")"
[[ "$mode" == "600" ]] || fail "server bundle mode $mode"
pass "SERVER_SUPPORT_BUNDLE_MODE_0600"
