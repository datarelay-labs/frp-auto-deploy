#!/usr/bin/env bash
# Permanent regression: project-managed client installer URL release-line migration.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/frp-common.sh
. "$ROOT/lib/frp-common.sh"

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }

HOST='raw.githubusercontent.com'
OWNER='datarelay-labs'
REPO='frp-auto-deploy'
ARTIFACT='dist/bootstrap-client.sh'

official() {
  printf 'https://%s/%s/%s/%s/%s' "$HOST" "$OWNER" "$REPO" "$1" "$ARTIFACT"
}

unset FRP_CLIENT_INSTALLER_URL FRP_RELEASE_CHANNEL || true

STABLE_V211="$(
  PROJECT_VERSION=2.1.1 FRP_RELEASE_CHANNEL=stable frp_default_client_installer_url
)"
[[ "$STABLE_V211" == "$(official v2.1.1)" ]] || fail "stable 2.1.1 canonical: $STABLE_V211"

DEV_CANONICAL="$(
  PROJECT_VERSION=2.1.1 FRP_RELEASE_CHANNEL=dev frp_default_client_installer_url
)"
[[ "$DEV_CANONICAL" == "$(official main)" ]] || fail "dev canonical: $DEV_CANONICAL"

# --- Official managed URL detection (strict parsing) ---
frp_is_official_managed_client_installer_url "$(official v2.1.0)" || fail "v2.1.0 not detected"
frp_is_official_managed_client_installer_url "$(official main)" || fail "main not detected"
frp_is_official_managed_client_installer_url "$(official v2.1.1)" || fail "v2.1.1 not detected"
frp_is_official_managed_client_installer_url 'https://mirror.example.com/frp/bootstrap-client.sh' \
  && fail "custom mirror wrongly official"
frp_is_official_managed_client_installer_url \
  'https://raw.githubusercontent.com/another-org/another-repo/v2.1.0/dist/bootstrap-client.sh' \
  && fail "other github repo wrongly official"
frp_is_official_managed_client_installer_url \
  'https://raw.githubusercontent.com.evil.example/datarelay-labs/frp-auto-deploy/v2.1.0/dist/bootstrap-client.sh' \
  && fail "lookalike host wrongly official"
frp_is_official_managed_client_installer_url \
  "https://${HOST}/${OWNER}/${REPO}/v2.1.0/extra/dist/bootstrap-client.sh" \
  && fail "extra path wrongly official"
frp_is_official_managed_client_installer_url \
  "https://${HOST}/${OWNER}/${REPO}/v2.1.0/dist/bootstrap-client.sh?x=1" \
  && fail "query string wrongly official"
frp_is_official_managed_client_installer_url \
  "https://user:pass@${HOST}/${OWNER}/${REPO}/v2.1.0/dist/bootstrap-client.sh" \
  && fail "userinfo wrongly official"
pass "LOOKALIKE_URL_SAFE"

# --- Stable channel migrations ---
got="$(
  PROJECT_VERSION=2.1.1 FRP_RELEASE_CHANNEL=stable \
    frp_canonicalize_managed_client_installer_url "$(official v2.1.0)"
)"
[[ "$got" == "$STABLE_V211" ]] || fail "OFFICIAL_V210_TO_STABLE_V211 got $got"
pass "OFFICIAL_V210_TO_STABLE_V211=MIGRATED"

got="$(
  PROJECT_VERSION=2.1.1 FRP_RELEASE_CHANNEL=stable \
    frp_canonicalize_managed_client_installer_url "$(official main)"
)"
[[ "$got" == "$STABLE_V211" ]] || fail "OFFICIAL_MAIN_TO_STABLE_V211 got $got"
pass "OFFICIAL_MAIN_TO_STABLE_V211=MIGRATED"

got="$(
  PROJECT_VERSION=2.1.1 FRP_RELEASE_CHANNEL=stable \
    frp_canonicalize_managed_client_installer_url "$(official v2.1.1)"
)"
[[ "$got" == "$STABLE_V211" ]] || fail "OFFICIAL_V211_TO_STABLE_V211 got $got"
pass "OFFICIAL_V211_TO_STABLE_V211=UNCHANGED"

# --- Dev channel migrations ---
got="$(
  PROJECT_VERSION=2.1.1 FRP_RELEASE_CHANNEL=dev \
    frp_canonicalize_managed_client_installer_url "$(official v2.1.0)"
)"
[[ "$got" == "$DEV_CANONICAL" ]] || fail "OFFICIAL_OLD_STABLE_TO_DEV got $got"
pass "OFFICIAL_OLD_STABLE_TO_DEV_CANONICAL=EXPECTED_BEHAVIOR"

got="$(
  PROJECT_VERSION=2.1.1 FRP_RELEASE_CHANNEL=dev \
    frp_canonicalize_managed_client_installer_url "$(official main)"
)"
[[ "$got" == "$DEV_CANONICAL" ]] || fail "OFFICIAL_MAIN_TO_DEV got $got"
pass "OFFICIAL_MAIN_TO_DEV=EXPECTED_BEHAVIOR"

# --- Preserve custom / third-party / lookalike ---
CUSTOM='https://mirror.example.com/frp/bootstrap-client.sh'
got="$(
  PROJECT_VERSION=2.1.1 FRP_RELEASE_CHANNEL=stable \
    frp_canonicalize_managed_client_installer_url "$CUSTOM"
)"
[[ "$got" == "$CUSTOM" ]] || fail "custom rewritten"
pass "CUSTOM_URL_PRESERVED"

OTHER='https://raw.githubusercontent.com/another-org/another-repo/v2.1.0/dist/bootstrap-client.sh'
got="$(
  PROJECT_VERSION=2.1.1 FRP_RELEASE_CHANNEL=stable \
    frp_canonicalize_managed_client_installer_url "$OTHER"
)"
[[ "$got" == "$OTHER" ]] || fail "other github repo rewritten"
pass "OTHER_GITHUB_REPO_PRESERVED"

LOOKALIKE='https://raw.githubusercontent.com.evil.example/datarelay-labs/frp-auto-deploy/v2.1.0/dist/bootstrap-client.sh'
got="$(
  PROJECT_VERSION=2.1.1 FRP_RELEASE_CHANNEL=stable \
    frp_canonicalize_managed_client_installer_url "$LOOKALIKE"
)"
[[ "$got" == "$LOOKALIKE" ]] || fail "lookalike rewritten"
pass "LOOKALIKE_HOST_PRESERVED"

# --- Explicit env override never rewritten ---
export FRP_CLIENT_INSTALLER_URL="$(official v2.1.0)"
got="$(
  PROJECT_VERSION=2.1.1 FRP_RELEASE_CHANNEL=stable \
    frp_canonicalize_managed_client_installer_url "$(official v2.1.0)"
)"
[[ "$got" == "$(official v2.1.0)" ]] || fail "explicit override rewritten"
unset FRP_CLIENT_INSTALLER_URL
pass "EXPLICIT_FRP_CLIENT_INSTALLER_URL_PRESERVED"

# --- Whitespace / empty / invalid URL validation still works ---
frp_validate_https_url 'https://example.test/bootstrap-client.sh' || fail "valid https rejected"
frp_validate_https_url '' && fail "empty URL accepted"
frp_validate_https_url 'http://example.test/bootstrap-client.sh' && fail "http accepted"
frp_validate_https_url 'https://' && fail "incomplete https accepted"
frp_validate_https_url 'not-a-url' && fail "garbage URL accepted"
pass "URL_VALIDATION_INTACT"

# --- Legacy historical owner URL migrates ---
LEGACY="$(frp_legacy_project_client_installer_url)"
got="$(
  PROJECT_VERSION=2.1.1 FRP_RELEASE_CHANNEL=stable \
    frp_canonicalize_managed_client_installer_url "$LEGACY"
)"
[[ "$got" == "$STABLE_V211" ]] || fail "legacy not migrated: $got"
pass "LEGACY_OWNER_MIGRATED"

echo
echo "CLIENT_INSTALLER_URL_MIGRATION_TEST=PASS"
