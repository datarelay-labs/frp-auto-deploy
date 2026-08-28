#!/usr/bin/env bash
# Lightweight documentation / version consistency assertions.
# Does not parse prose for style. Catches stale version and HTTP-enrollment slips.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }

# shellcheck disable=SC1091
. "$ROOT/VERSION"
[[ "$PROJECT_VERSION" == "2.0.0" ]] || fail "VERSION project is $PROJECT_VERSION"
[[ "$FRP_VERSION" == "0.70.1" ]] || fail "VERSION FRP is $FRP_VERSION"
pass "VERSION_FILE"

grep -qF "Current project version: **${PROJECT_VERSION}**" README.md || fail "README project version"
grep -qF "**v${FRP_VERSION}**" README.md || fail "README FRP version"
if grep -nE 'Current project version: \*\*1\.(7|8|9)\.' README.md; then
  fail "README still shows a pre-2.0 current version"
fi
pass "README_VERSION"

[[ -f CHANGELOG.md ]] || fail "CHANGELOG.md missing"
[[ -f docs/SECURITY.md ]] || fail "docs/SECURITY.md missing"
[[ -f docs/RELEASE_CHECKLIST.md ]] || fail "docs/RELEASE_CHECKLIST.md missing"
[[ -f docs/RELEASE_VALIDATION.md ]] || fail "docs/RELEASE_VALIDATION.md missing"
pass "RELEASE_DOCS_PRESENT"

if grep -nE "FRP_ALLOCATOR_URL=['\"]http://" README.md docs/*.md examples/*.md 2>/dev/null; then
  fail "docs recommend an http:// allocator URL"
fi
pass "NO_HTTP_ENROLLMENT_DOCS"

if grep -nE 'FRP must (own|use|bind).*443|require[sd]? public TCP/443|hard-?coded.*443' README.md docs/*.md examples/*.md; then
  fail "docs treat TCP/443 as mandatory"
fi
pass "NO_FIXED_443_DOCS"

grep -q 'ssh -p <public-port>' README.md || fail "README missing public SSH example"
grep -q '\-\-one-line' README.md || fail "README missing zero-touch"
grep -q '\-\-ssh-user ubuntu' README.md || fail "README zero-touch example user"
grep -qF 'does **not**:' README.md || fail "README missing zero-touch negatives"
pass "ZERO_TOUCH_DOCS"

for cmd in frpctl frp-create-client frp-client frp-client-info frp-clients \
  frp-release-service frp-release-client frp-revoke-client frp-update \
  frp-server-status frp-set-client-installer-url; do
  [[ -e "$ROOT/tools/$cmd" ]] || fail "documented command missing: $cmd"
done
pass "DOCUMENTED_COMMANDS_EXIST"

grep -q 'ROCKY_9_SELINUX_ENFORCING=NOT_TESTED' docs/RELEASE_VALIDATION.md || fail "SELinux gate template"
if grep -nE 'fully supported on Rocky 9 SELinux Enforcing' README.md; then
  fail "README overclaims Rocky SELinux"
fi
pass "SUPPORT_CLAIM_ALIGNMENT"

echo "RELEASE_DOCS_TEST=PASS"
