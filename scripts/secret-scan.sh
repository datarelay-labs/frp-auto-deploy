#!/usr/bin/env bash
# Fail if tracked files look like runtime secrets or private keys.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "SECRET_SCAN=FAIL $1" >&2; exit 1; }

if git grep -nE 'BEGIN (RSA |OPENSSH |EC |DSA )?PRIVATE KEY' -- . >/dev/null; then
  fail "private key material is tracked"
fi

# Runtime artifacts must never be committed.
while IFS= read -r path; do
  case "$path" in
    */server_token|*/install_key|*/registry.json|*/access-info.txt|*/frpc.toml|*/frps.toml)
      fail "runtime secret/config is tracked: $path"
      ;;
  esac
done < <(git ls-files)

if git grep -nE 'INSTALL_KEY=' -- ':!tests/' ':!README.md' >/dev/null; then
  fail "INSTALL_KEY assignment found"
fi

echo "SECRET_SCAN=PASS"
