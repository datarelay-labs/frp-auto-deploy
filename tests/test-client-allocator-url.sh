#!/usr/bin/env bash
# Client allocator URL: required, no production fallback, no partial install.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }

export FRP_CLIENT_SOURCED=1
# shellcheck source=../install-client.sh
. "$ROOT/install-client.sh"

if declare -p DEFAULT_ALLOCATOR_URL >/dev/null 2>&1; then
  fail "DEFAULT_ALLOCATOR_URL must not exist"
fi

# CASE A: explicit HTTPS FRP_ALLOCATOR_URL is accepted.
unset FRP_ALLOCATOR_URL ALLOCATOR_URL || true
export FRP_ALLOCATOR_URL='https://203.0.113.10:6099/enroll'
frp_require_allocator_url
[[ "$ALLOCATOR_URL" == 'https://203.0.113.10:6099/enroll' ]] || fail "CASE A ALLOCATOR_URL"
pass "CASE A FRP_ALLOCATOR_URL accepted"

# HTTP is rejected.
unset FRP_ALLOCATOR_URL ALLOCATOR_URL || true
export FRP_ALLOCATOR_URL='http://203.0.113.10/enroll'
if (
  frp_require_allocator_url
) >/dev/null 2>"$WORKDIR/http.err"; then
  fail "HTTP allocator URL should be rejected"
fi
grep -qi 'https' "$WORKDIR/http.err" || fail "HTTP rejection message"
if frp_valid_allocator_url 'http://203.0.113.10/enroll'; then
  fail "HTTP URL should be invalid"
fi
pass "HTTP allocator URL rejected"

# CASE B: missing URL fails before any client files are written.
unset FRP_ALLOCATOR_URL ALLOCATOR_URL || true
TREE_B="$WORKDIR/case-b"
if (
  export FRP_CLIENT_TEST_ROOT="$TREE_B"
  unset FRP_ALLOCATOR_URL ALLOCATOR_URL || true
  frp_client_main
) >"$WORKDIR/case-b.out" 2>"$WORKDIR/case-b.err"; then
  fail "CASE B should fail without FRP_ALLOCATOR_URL"
fi
grep -q 'FRP allocator URL is not configured' "$WORKDIR/case-b.err" || fail "CASE B error message"
if [[ -e "$TREE_B/etc/frp" ]]; then
  fail "CASE B partial install"
fi
pass "CASE B missing URL fails closed"

# CASE C: invalid URL fails before any client files are written.
TREE_C="$WORKDIR/case-c"
if (
  export FRP_CLIENT_TEST_ROOT="$TREE_C"
  export FRP_ALLOCATOR_URL='not-a-url'
  frp_client_main
) >"$WORKDIR/case-c.out" 2>"$WORKDIR/case-c.err"; then
  fail "CASE C should reject invalid URL"
fi
grep -qi 'invalid' "$WORKDIR/case-c.err" || fail "CASE C error message"
if [[ -e "$TREE_C/etc/frp" ]]; then
  fail "CASE C partial install"
fi
unset FRP_ALLOCATOR_URL
export FRP_ALLOCATOR_URL='ftp://203.0.113.10/enroll'
if frp_valid_allocator_url "$FRP_ALLOCATOR_URL"; then
  fail "CASE C ftp should be invalid"
fi
pass "CASE C invalid URL rejected"

# Whitespace / control characters are rejected.
if frp_valid_allocator_url $'https://203.0.113.10/enroll\n'; then
  fail "newline URL should be invalid"
fi
if frp_valid_allocator_url 'https://203.0.113.10/enroll extra'; then
  fail "whitespace URL should be invalid"
fi
pass "invalid whitespace rejected"

# Shell-sensitive characters in a still-valid URL are accepted as data.
if ! frp_valid_allocator_url 'https://203.0.113.10/enroll;extra'; then
  fail "semicolon path should remain a valid URL string"
fi
pass "shell-sensitive URL accepted as quoted data"

echo
echo "CLIENT_ALLOCATOR_URL_TEST=PASS"
