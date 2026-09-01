#!/usr/bin/env bash
# Candidate operator guidance must not reference nonexistent v2.1.1.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/lib/frp-common.sh"

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1 ${2:-}" >&2; exit 1; }

SHA="$(git -C "$ROOT" rev-parse HEAD)"
export FRP_RELEASE_CHANNEL=candidate
export FRP_SOURCE_REF="$SHA"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/etc/frp-auto-deploy"
cat >"$tmpdir/etc/frp-auto-deploy/version" <<EOF
PROJECT_VERSION=2.1.1
FRP_VERSION=0.70.1
RELEASE_CHANNEL=candidate
SOURCE_REF=$SHA
EOF
export FRP_DEPLOY_TEST_ROOT="$tmpdir"

ref="$(frp_release_git_ref)"
[[ "$ref" == "$SHA" ]] || fail CANDIDATE_OPERATOR_GUIDANCE_EXACT_SHA "ref=$ref"
pass CANDIDATE_OPERATOR_GUIDANCE_EXACT_SHA

# Extract the existing-install helper body without executing install-client main.
helper="$(mktemp)"
python3 - "$ROOT/install-client.sh" "$helper" <<'PY'
import pathlib, sys
src = pathlib.Path(sys.argv[1]).read_text()
start = src.index('frp_client_existing_install_message() {')
# Grab through the matching closing brace at column 0 after the function.
depth = 0
end = None
for i, ch in enumerate(src[start:], start):
    if ch == '{':
        depth += 1
    elif ch == '}':
        depth -= 1
        if depth == 0:
            end = i + 1
            break
pathlib.Path(sys.argv[2]).write_text(src[start:end] + '\n')
PY
# shellcheck source=/dev/null
source "$helper"
msg="$(frp_client_existing_install_message 2>&1 || true)"
echo "$msg" | grep -q 'sudo frpctl update' || fail GUIDANCE_PREFERS_FRPCTL "$msg"
if echo "$msg" | grep -q 'bootstrap-client.sh'; then
  echo "$msg" | grep -q "/${SHA}/dist/bootstrap-client.sh" \
    || fail CANDIDATE_BOOTSTRAP_USES_SHA "$msg"
fi
if echo "$msg" | grep -E 'v2\.1\.1' >/dev/null; then
  fail NONEXISTENT_V211_GUIDANCE "$msg"
fi
# Also scan operator-facing install-client source for hardcoded nonexistent tag URLs.
if grep -nE 'v2\.1\.1/dist/bootstrap' "$ROOT/install-client.sh" >/dev/null; then
  fail NONEXISTENT_V211_GUIDANCE 'hardcoded v2.1.1 bootstrap URL'
fi
pass NONEXISTENT_V211_GUIDANCE
pass CANDIDATE_OPERATOR_GUIDANCE_EXACT_SHA_MSG
echo "ALL PASS"
