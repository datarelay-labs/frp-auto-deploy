#!/usr/bin/env bash
# Fail if production source or generated dist embeds /home/aella/ developer paths.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }

# Intentional fixtures/docs/tests may mention the path; production install paths must not.
EXCLUDE=(
  ':!tests/'
  ':!docs/'
  ':!CHANGELOG.md'
  ':!README.md'
  ':!*.md'
  ':!SHA256SUMS'
)

hits="$(git grep -nF '/home/aella/' -- "${EXCLUDE[@]}" 2>/dev/null || true)"
if [[ -n "$hits" ]]; then
  echo "$hits" >&2
  fail "production source contains /home/aella/ absolute path"
fi
pass "SOURCE_NO_HOME_AELLA"

# Dist bundles are generated; scan extracted text for the literal path.
for art in dist/bootstrap-client.sh dist/bootstrap-server.sh dist/bootstrap-client.ps1 \
           dist/uninstall-client.sh dist/uninstall-server.sh; do
  [[ -f "$art" ]] || continue
  if grep -nF '/home/aella/' "$art" >/dev/null 2>&1; then
    grep -nF '/home/aella/' "$art" >&2 || true
    fail "$art embeds /home/aella/"
  fi
done
pass "DIST_NO_HOME_AELLA"

echo "BUNDLE_SOURCE_LEAKAGE_TEST=PASS"
