#!/usr/bin/env bash
# Immutable release channel: stable must not silently follow mutable main.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/frp-common.sh
. "$ROOT/lib/frp-common.sh"
# shellcheck source=lib/frp-client-common.sh
. "$ROOT/lib/frp-client-common.sh"

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }

[[ -f "$ROOT/release-manifest.json" ]] || fail "release-manifest.json missing"
grep -q '"signing": false' "$ROOT/release-manifest.json" || fail "manifest must not claim signing"
grep -q 'never mutable main' "$ROOT/release-manifest.json" || fail "manifest missing immutable note"
pass "RELEASE_MANIFEST_PRESENT"

# Stable defaults to vPROJECT_VERSION.
unset FRP_RELEASE_CHANNEL FRP_CLIENT_UPDATE_URL FRP_CLIENT_INSTALLER_URL || true
export FRP_RELEASE_CHANNEL=stable
ref="$(frp_release_git_ref)"
[[ "$ref" == "v${PROJECT_VERSION}" ]] || fail "stable ref is $ref"
url="$(frp_default_client_installer_url)"
[[ "$url" == "https://raw.githubusercontent.com/datarelay-labs/frp-auto-deploy/v${PROJECT_VERSION}/dist/bootstrap-client.sh" ]] \
  || fail "stable installer URL: $url"
upd="$(frp_default_client_update_url)"
[[ "$upd" == "$url" ]] || fail "stable update URL mismatch: $upd"
case "$url" in
  *'/main/'*) fail "stable URL still points at main: $url" ;;
esac
pass "STABLE_INSTALLER_IMMUTABLE_TAG"
pass "STABLE_UPDATE_IMMUTABLE_TAG"

# Dev/main channel is opt-in only.
export FRP_RELEASE_CHANNEL=dev
dev_url="$(frp_default_client_installer_url)"
[[ "$dev_url" == *"/main/dist/bootstrap-client.sh" ]] || fail "dev URL: $dev_url"
pass "DEV_CHANNEL_OPT_IN_MAIN"

# Server config rewrite: stored official main URL becomes immutable under stable.
unset FRP_RELEASE_CHANNEL FRP_CLIENT_INSTALLER_URL || true
export FRP_RELEASE_CHANNEL=stable
# shellcheck source=install-server.sh
# Source only the migration helpers by extracting behavior via a mini check.
MAIN_URL="https://raw.githubusercontent.com/datarelay-labs/frp-auto-deploy/main/dist/bootstrap-client.sh"
frp_is_official_main_installer_url "$MAIN_URL" || fail "main URL not recognized"
STABLE_URL="$(frp_default_client_installer_url)"
[[ "$STABLE_URL" != "$MAIN_URL" ]] || fail "stable default still main"
[[ "$STABLE_URL" == *"v${PROJECT_VERSION}"* ]] || fail "stable default missing tag"

# HTTPS transport must remain mandatory for updates.
export FRP_CLIENT_TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$FRP_CLIENT_TEST_ROOT"' EXIT
export FRP_CLIENT_UPDATE_URL="http://example.invalid/bootstrap-client.sh"
if frp_client_fetch_and_upgrade >/tmp/frp-release-channel-http.out 2>/tmp/frp-release-channel-http.err; then
  fail "HTTP update URL should be rejected"
fi
grep -qi 'HTTPS' /tmp/frp-release-channel-http.err || fail "HTTPS requirement message missing"
pass "UPDATE_HTTPS_REQUIRED"

# Artifact SHA verification rejects a tampered payload when expected hash is set.
GOOD="$FRP_CLIENT_TEST_ROOT/good.sh"
echo '#!/bin/sh' >"$GOOD"
chmod 0755 "$GOOD"
export FRP_CLIENT_UPDATE_SHA256="$(sha256sum "$GOOD" | awk '{print $1}')"
frp_verify_client_update_artifact "$GOOD" || fail "matching sha should pass"
echo '#tamper' >>"$GOOD"
if frp_verify_client_update_artifact "$GOOD"; then
  fail "tampered artifact should fail sha verify"
fi
pass "UPDATE_SHA256_VERIFIED"

echo "IMMUTABLE_RELEASE_CHANNEL_TEST=PASS"
