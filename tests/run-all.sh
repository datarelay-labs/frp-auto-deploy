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
bash -n tools/frp-server-status tools/frp-update tools/frp-client tools/frpctl

echo "=== Python compile ==="
python3 -m py_compile server/frp-port-allocator.py server/migrate_token.py scripts/build-bundles.py lib/frp_mgmt_auth.py lib/frp_pki.py lib/frp_frontend.py lib/frp_doctor.py
python3 -m py_compile tools/frp-create-client tools/frp-clients tools/frp-client-info tools/frp-release-client tools/frp-release-service tools/frp-revoke-client tools/frp-set-client-installer-url
python3 -m py_compile tests/test-allocator.py tests/test-enrollment-security.py tests/test-mgmt-identity.py tests/test-pki-https.py tests/test-bootstrap-ticket.py

echo "=== tests ==="
./tests/test-server-migration.sh
./tests/test-registry-init.sh
python3 tests/test-allocator.py
python3 tests/test-bootstrap-ticket.py
python3 tests/test-enrollment-security.py
python3 tests/test-mgmt-identity.py
./tests/test-client-config.sh
./tests/test-client-allocator-url.sh
./tests/test-client-platform.sh
./tests/test-portability.sh
./tests/test-server-install-config.sh
./tests/test-allocator-ready.sh
./tests/test-create-client.sh
./tests/test-zero-touch-bootstrap.sh
./tests/test-management-commands.sh
./tests/test-frp-client.sh
./tests/test-lifecycle.sh
./tests/test-guided-ux.sh
./tests/test-client-upgrade.sh
./tests/test-install-lifecycle.sh
./tests/test-frpctl.sh
./tests/test-frpctl-completion.sh
./tests/test-frpctl-doctor.sh
./tests/test-port-architecture.sh
./tests/test-ca-bootstrap.sh
python3 tests/test-pki-https.py
./tests/test-distro-matrix.sh
./tests/test-frp-update.sh
./tests/test-frp-server-status.sh
./tests/test-release-docs.sh

echo "=== secret scan ==="
./scripts/secret-scan.sh

echo "=== whitespace ==="
git diff --check HEAD

echo
echo "RUN_ALL=PASS"
echo "Note: Docker matrix is ./tests/run-distro-matrix.sh"
echo "Note: bundle parity is ./scripts/build-bundles.sh && git diff --exit-code dist/"
echo "Note: SHA256SUMS is ./scripts/verify-sha256sums.sh"
