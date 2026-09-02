#!/usr/bin/env bash
# Guard: release-critical security/remediation tests must stay in tests/run-all.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ALL="$ROOT/tests/run-all.sh"

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }

[[ -f "$RUN_ALL" ]] || fail "run-all.sh missing"

MANDATORY=(
  tests/test-audit-followup-p1.py
  tests/test-frp-data-plane-auth.py
  tests/test-pre-e2e-remediation-five.py
  tests/test-pre-e2e-consolidated-hardening.py
  tests/test-frp-release-data-plane-auth.py
  tests/test-server-bundle-manifest-parity.py
  tests/test-allocator-runtime-restart.sh
  tests/test-server-snapshot-restore-validation.py
  tests/test-zero-touch-recovery-journal.sh
  tests/test-macos-frp-pin.sh
  tests/test-macos-zero-touch-command.sh
  tests/test-run-all-security-coverage.sh
)

BODY="$(sed -n '/^echo "=== tests ==="/,/^echo "=== secret scan ==="/p' "$RUN_ALL")"
for t in "${MANDATORY[@]}"; do
  [[ -f "$ROOT/$t" ]] || fail "missing test file $t"
  grep -Fq "$t" <<<"$BODY" || fail "run-all omits $t"
done

grep -Fq 'tests/test-frp-data-plane-auth.py' <<<"$BODY" || fail "data-plane test omitted"
grep -Fq 'tests/test-audit-followup-p1.py' <<<"$BODY" || fail "audit follow-up omitted"
grep -Fq 'tests/test-pre-e2e-remediation-five.py' <<<"$BODY" || fail "pre-e2e remediation omitted"

echo "RUN_ALL_SECURITY_REGRESSION_COVERAGE=PASS"
echo "DATA_PLANE_SECURITY_TESTS_IN_RUN_ALL=PASS"
pass "run-all-security-coverage"
