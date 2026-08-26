#!/usr/bin/env bash
# Fail if tracked files look like runtime secrets, private keys, or
# deployment-specific literals that must not ship in this public repository.
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

if git grep -nE 'INSTALL_KEY=' -- ':!tests/' ':!README.md' ':!scripts/secret-scan.sh' >/dev/null; then
  fail "INSTALL_KEY assignment found"
fi

# Known historical production addresses must not re-enter tracked source.
if git grep -nF '221.139.249.110' -- ':!scripts/secret-scan.sh' >/dev/null; then
  fail "forbidden production public IP 221.139.249.110 is tracked"
fi
if git grep -nF '10.10.10.50' -- ':!scripts/secret-scan.sh' >/dev/null; then
  fail "forbidden production internal IP 10.10.10.50 is tracked"
fi
if git grep -nF 'RickLee-kr/frp-auto-deploy' -- ':!scripts/secret-scan.sh' >/dev/null; then
  fail "stale repository URL RickLee-kr/frp-auto-deploy is tracked"
fi

echo "SECRET_SCAN=PASS"
