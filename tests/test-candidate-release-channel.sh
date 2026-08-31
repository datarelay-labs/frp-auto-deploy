#!/usr/bin/env bash
# Candidate channel: exact commit SHA, fail-closed without SHA / with main / unknown.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/frp-common.sh
. "$ROOT/lib/frp-common.sh"
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }

SHA="ffffffffffffffffffffffffffffffffffffffff"
BAD="deadbeef"
MAINISH="main"

unset FRP_RELEASE_CHANNEL FRP_SOURCE_REF FRP_EXPECTED_SOURCE_REF || true
export FRP_RELEASE_CHANNEL=stable
ref="$(frp_release_git_ref)"
[[ "$ref" == "v${PROJECT_VERSION}" ]] || fail "stable ref $ref"
url="$(frp_default_client_installer_url)"
[[ "$url" == *"/v${PROJECT_VERSION}/dist/bootstrap-client.sh" ]] || fail "stable url $url"
pass "STABLE_TO_V_PROJECT_VERSION"

export FRP_RELEASE_CHANNEL=dev
[[ "$(frp_release_git_ref)" == "main" ]] || fail "dev ref"
[[ "$(frp_default_client_installer_url)" == *"/main/dist/bootstrap-client.sh" ]] || fail "dev url"
pass "DEV_TO_MAIN"

unset FRP_SOURCE_REF FRP_EXPECTED_SOURCE_REF || true
export FRP_RELEASE_CHANNEL=candidate
if frp_release_git_ref >/tmp/cand.out 2>/tmp/cand.err; then
  fail "candidate without SHA should fail"
fi
grep -qi 'SHA\|source ref\|FRP_SOURCE_REF' /tmp/cand.err || fail "candidate missing SHA message"
pass "CANDIDATE_WITHOUT_SHA_FAIL_CLOSED"

export FRP_SOURCE_REF="$BAD"
if frp_release_git_ref >/tmp/cand2.out 2>/tmp/cand2.err; then
  fail "malformed SHA should fail"
fi
pass "CANDIDATE_MALFORMED_SHA_FAIL_CLOSED"

export FRP_SOURCE_REF="$MAINISH"
if frp_release_git_ref >/tmp/cand3.out 2>/tmp/cand3.err; then
  fail "candidate must not accept main"
fi
pass "CANDIDATE_MUTABLE_MAIN_REJECTED"

export FRP_SOURCE_REF="$SHA"
ref="$(frp_release_git_ref)"
[[ "$ref" == "$SHA" ]] || fail "candidate ref $ref"
linux_url="$(frp_default_client_installer_url)"
win_url="$(frp_default_windows_client_installer_url)"
sums_url="$(frp_default_release_sha256sums_url)"
upd_url="$(frp_default_client_update_url)"
[[ "$linux_url" == "https://raw.githubusercontent.com/datarelay-labs/frp-auto-deploy/${SHA}/dist/bootstrap-client.sh" ]] || fail "linux $linux_url"
[[ "$win_url" == "https://raw.githubusercontent.com/datarelay-labs/frp-auto-deploy/${SHA}/dist/bootstrap-client.ps1" ]] || fail "win $win_url"
[[ "$sums_url" == "https://raw.githubusercontent.com/datarelay-labs/frp-auto-deploy/${SHA}/SHA256SUMS" ]] || fail "sums $sums_url"
[[ "$upd_url" == *"/${SHA}/"* || "$upd_url" == *"/${SHA}/"* ]] || fail "upd $upd_url"
pass "CANDIDATE_EXACT_SHA_URLS"

export FRP_RELEASE_CHANNEL=not-a-channel
if frp_release_channel >/tmp/unk.out 2>/tmp/unk.err; then
  fail "unknown channel should fail closed"
fi
pass "UNKNOWN_CHANNEL_FAIL_CLOSED"

# Stable must not accept main via official managed URL when expecting stable identity.
unset FRP_RELEASE_CHANNEL FRP_SOURCE_REF || true
export FRP_RELEASE_CHANNEL=stable
MAIN_URL="https://raw.githubusercontent.com/datarelay-labs/frp-auto-deploy/main/dist/bootstrap-client.sh"
frp_is_official_managed_client_installer_url "$MAIN_URL" || fail "main still managed for migration"
STABLE_DEFAULT="$(frp_default_client_installer_url)"
[[ "$STABLE_DEFAULT" != *"/main/"* ]] || fail "stable default followed main"
pass "STABLE_IMMUTABILITY_PRESERVED"

# Candidate SHA is recognized as official managed ref.
CAND_URL="https://raw.githubusercontent.com/datarelay-labs/frp-auto-deploy/${SHA}/dist/bootstrap-client.sh"
got="$(frp_official_managed_client_installer_ref "$CAND_URL")" || fail "candidate URL not managed"
[[ "$got" == "$SHA" ]] || fail "managed ref $got"
pass "CANDIDATE_MANAGED_URL_ACCEPTED"

# Persist candidate identity via version file write.
TREE="$(mktemp -d)"
trap 'rm -rf "$TREE"' EXIT
export FRP_DEPLOY_TEST_ROOT="$TREE"
mkdir -p "$TREE/etc/frp-auto-deploy"
export FRP_RELEASE_CHANNEL=candidate
export FRP_SOURCE_REF="$SHA"
frp_write_version_file "$TREE/etc/frp-auto-deploy/version"
grep -q 'RELEASE_CHANNEL=candidate' "$TREE/etc/frp-auto-deploy/version" || fail "persisted channel"
grep -q "SOURCE_REF=${SHA}" "$TREE/etc/frp-auto-deploy/version" || fail "persisted ref"
unset FRP_RELEASE_CHANNEL FRP_SOURCE_REF FRP_EXPECTED_SOURCE_REF || true
# URL generation from persisted candidate
[[ "$(frp_release_channel)" == "candidate" ]] || fail "persisted channel read"
[[ "$(frp_release_git_ref)" == "$SHA" ]] || fail "persisted git ref"
pass "CANDIDATE_PERSISTED_SOURCE_IDENTITY"
