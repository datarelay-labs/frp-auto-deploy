#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/lib/frp-common.sh"

EXPECTED=cfa733b5a261c1647edee3c1fc4133d2542989b28f5602e81d47fc821d25c55f
[[ "$FRP_VERSION" == 0.70.1 ]]
[[ "$FRP_SHA256_DARWIN_ARM64" == "$EXPECTED" ]]
[[ "$(frp_checksum_for 0.70.1 arm64 darwin)" == "$EXPECTED" ]]
[[ "$(frp_release_url 0.70.1 arm64 darwin)" == \
  https://github.com/fatedier/frp/releases/download/v0.70.1/frp_0.70.1_darwin_arm64.tar.gz ]]
if frp_checksum_for 0.70.1 amd64 darwin >/dev/null 2>&1; then
  echo "FAIL: Darwin amd64 checksum resolved" >&2
  exit 1
fi
python3 - "$ROOT/release-manifest.json" "$EXPECTED" <<'PY'
import json,sys
data=json.load(open(sys.argv[1], encoding="utf-8"))
assert data["supported_frp_versions"]["0.70.1"]["darwin_arm64_sha256"] == sys.argv[2]
PY
grep -q 'shasum -a 256 -c -' "$ROOT/lib/frp-macos.sh"
echo "MACOS_FRP_PIN_TEST=PASS"
