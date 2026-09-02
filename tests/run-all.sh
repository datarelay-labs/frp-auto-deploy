#!/usr/bin/env bash
# Full local non-Docker regression suite (CI lint job equivalent, minus
# bundle rebuild and Docker distro matrix).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export PYTHONDONTWRITEBYTECODE=1

echo "=== shell syntax ==="
git ls-files '*.sh' | xargs -r bash -n
git ls-files -o --exclude-standard '*.sh' | xargs -r bash -n
bash -n tools/frp-server-status tools/frp-project-update tools/frp-update tools/frp-upstream tools/frp-client tools/frpctl tools/frpcli lib/frp-client-lifecycle.sh

echo "=== Python compile ==="
mapfile -t PY_INVENTORY < <(
  git ls-files 'lib/*.py' 'server/*.py' 'scripts/*.py'
  git ls-files 'tools/*' | while read -r f; do
    [[ -f "$f" ]] || continue
    head -n 1 "$f" | grep -qE '^#!.*python' && printf '%s\n' "$f"
  done
)
# Inventory guard: refuse silent omission of fleet/lifecycle/purge modules.
printf '%s\n' "${PY_INVENTORY[@]}" | grep -qx 'lib/frp_fleet.py' \
  || { echo "FAIL missing lib/frp_fleet.py in compile inventory" >&2; exit 1; }
printf '%s\n' "${PY_INVENTORY[@]}" | grep -qx 'lib/frp_server_lifecycle.py' \
  || { echo "FAIL missing lib/frp_server_lifecycle.py in compile inventory" >&2; exit 1; }
printf '%s\n' "${PY_INVENTORY[@]}" | grep -qx 'lib/frp_server_config.py' \
  || { echo "FAIL missing lib/frp_server_config.py in compile inventory" >&2; exit 1; }
printf '%s\n' "${PY_INVENTORY[@]}" | grep -qx 'tools/frp-enrollment-purge' \
  || { echo "FAIL missing tools/frp-enrollment-purge in compile inventory" >&2; exit 1; }
python3 -m py_compile "${PY_INVENTORY[@]}"
python3 -m py_compile tests/test-allocator.py tests/test-enrollment-security.py tests/test-enrollment-id-validation.py tests/test-mgmt-identity.py tests/test-pki-https.py tests/test-bootstrap-ticket.py tests/test-frontend-proxy.py tests/test-client-registry.py tests/test-clock-skew-auth.py tests/test-deployment-mode-fail-closed.py tests/test-audit-log.py tests/test-audit-query.py tests/test-server-config-validation.py tests/test-canonical-registry-validation.py tests/test-pki-key-cert-pairs.py tests/test-config-setter-control-lock.py tests/test-restore-https-health.py tests/test-mgmt-nonce-ordering.py tests/test-enroll-bind-ordering.py tests/test-audit-followup-p1.py tests/test-frp-data-plane-auth.py tests/test-pre-e2e-remediation-five.py tests/test-frp-release-data-plane-auth.py tests/test-server-bundle-manifest-parity.py tests/test-server-snapshot-restore-validation.py

# Mandatory security/remediation regression inventory (must stay in === tests ===).
MANDATORY_SECURITY_TESTS=(
  tests/test-audit-followup-p1.py
  tests/test-frp-data-plane-auth.py
  tests/test-pre-e2e-remediation-five.py
  tests/test-frp-release-data-plane-auth.py
  tests/test-server-bundle-manifest-parity.py
  tests/test-allocator-runtime-restart.sh
  tests/test-server-snapshot-restore-validation.py
  tests/test-run-all-security-coverage.sh
)
for _sec in "${MANDATORY_SECURITY_TESTS[@]}"; do
  [[ -f "$_sec" ]] || { echo "FAIL missing mandatory security test $_sec" >&2; exit 1; }
done

echo "=== tests ==="
./tests/test-server-migration.sh
./tests/test-registry-init.sh
python3 tests/test-allocator.py
python3 tests/test-bootstrap-ticket.py
python3 tests/test-enrollment-security.py
python3 tests/test-enrollment-id-validation.py
python3 tests/test-clock-skew-auth.py
python3 tests/test-mgmt-identity.py
./tests/test-client-config.sh
./tests/test-client-allocator-url.sh
./tests/test-client-platform.sh
./tests/test-portability.sh
./tests/test-server-install-config.sh
./tests/test-allocator-ready.sh
./tests/test-create-client.sh
./tests/test-zero-touch-bootstrap.sh
./tests/test-sourced-client-errexit.sh
./tests/test-ssh-explicit-user.sh
./tests/test-passive-online.sh
./tests/test-io-hardening.sh
./tests/test-pending-enrollments.sh
./tests/test-show-enrollments.sh
./tests/test-enrollment-retention.sh
./tests/test-zero-touch-retention-propagation.sh
./tests/test-bulk-retention-propagation.sh
./tests/test-purging-tombstone-reaper.sh
./tests/test-cli-hardening.sh
./tests/test-enroll-bulk.sh
./tests/test-zero-service-client.sh
./tests/test-management-commands.sh
./tests/test-client-metadata.sh
./tests/test-client-tags.sh
./tests/test-client-groups.sh
./tests/test-client-groups-phase3.sh
python3 tests/test-client-registry.py
python3 tests/test-canonical-registry-validation.py
python3 tests/test-deployment-mode-fail-closed.py
python3 tests/test-mgmt-nonce-ordering.py
python3 tests/test-enroll-bind-ordering.py
./tests/test-frp-client.sh
./tests/test-lifecycle.sh
./tests/test-guided-ux.sh
./tests/test-client-upgrade.sh
bash ./tests/test-installed-client-update.sh
bash ./tests/test-installed-client-artifact.sh
bash ./tests/test-installed-server-artifact.sh
bash ./tests/test-bundle-source-leakage.sh
./tests/test-legacy-client-secure-bridge.sh
./tests/test-install-lifecycle.sh
./tests/test-client-uninstall-pending-marker.sh
./tests/test-frpctl.sh
./tests/test-client-lifecycle-diagnostics.sh
./tests/test-client-lifecycle-production-paths.sh
./tests/test-support-bundle-symlink-safety.sh
./tests/test-server-fleet-visibility.sh
./tests/test-frpctl-completion.sh
./tests/test-create-zero-touch.sh
./tests/test-frpctl-doctor.sh
./tests/test-systemd-units.sh
./tests/test-port-architecture.sh
./tests/test-ca-bootstrap.sh
./tests/test-pki-https.py
python3 tests/test-frontend-proxy.py
python3 tests/test-server-config-validation.py
python3 tests/test-pki-key-cert-pairs.py
python3 tests/test-config-setter-control-lock.py
./tests/test-distro-matrix.sh
./tests/test-frp-update.sh
./tests/test-server-project-update.sh
./tests/test-project-file-manifest.sh
./tests/test-server-uninstall-manifest-parity.sh
./tests/test-client-uninstall-manifest-parity.sh
python3 tests/test-allocator-url-validation.py
./tests/test-real-bundle-project-update.sh
./tests/test-frp-server-status.sh
./tests/test-release-docs.sh
./tests/test-release-service-audit.sh
./tests/test-probe-tcp-injection.sh
./tests/test-candidate-release-channel.sh
./tests/test-candidate-operator-guidance.sh
./tests/test-immutable-release-channel.sh
./tests/test-client-installer-url-migration.sh
./tests/test-install-txn-rollback.sh
python3 tests/test-audit-log.py
python3 tests/test-audit-query.py
./tests/test-frp-compatibility.sh
./tests/test-backup-restore.sh
python3 tests/test-restore-https-health.py
python3 tests/test-audit-followup-p1.py
python3 tests/test-frp-data-plane-auth.py
python3 tests/test-pre-e2e-remediation-five.py
python3 tests/test-frp-release-data-plane-auth.py
python3 tests/test-server-bundle-manifest-parity.py
./tests/test-allocator-runtime-restart.sh
python3 tests/test-server-snapshot-restore-validation.py
./tests/test-run-all-security-coverage.sh

# Inventory guard: refuse silent omission of mandatory security regressions.
RUN_ALL_BODY="$(sed -n '/^echo "=== tests ==="/,/^echo "=== secret scan ==="/p' "$0")"
for _sec in "${MANDATORY_SECURITY_TESTS[@]}"; do
  grep -Fq "$_sec" <<<"$RUN_ALL_BODY" \
    || { echo "FAIL mandatory security test not executed by run-all: $_sec" >&2; exit 1; }
done
grep -Fq 'tests/test-frp-data-plane-auth.py' <<<"$RUN_ALL_BODY" \
  || { echo "FAIL data-plane security tests missing from run-all" >&2; exit 1; }
echo "RUN_ALL_SECURITY_REGRESSION_COVERAGE=PASS"
echo "DATA_PLANE_SECURITY_TESTS_IN_RUN_ALL=PASS"

echo "=== secret scan ==="
./scripts/secret-scan.sh

echo "=== whitespace ==="
git diff --check HEAD

echo
echo "RUN_ALL=PASS"
echo "Note: Docker matrix is ./tests/run-distro-matrix.sh"
echo "Note: bundle parity is ./scripts/build-bundles.sh && git diff --exit-code dist/"
echo "Note: SHA256SUMS is ./scripts/verify-sha256sums.sh"
