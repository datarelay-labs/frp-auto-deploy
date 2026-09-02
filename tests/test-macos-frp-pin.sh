#!/usr/bin/env bash
# The macOS client must pin the same FRP release as every other platform and
# must resolve the official darwin_arm64 asset and checksum. Portable: no
# network access and no macOS-only commands.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }

# Official fatedier/frp v0.70.1 release assets, transcribed from
# frp_sha256_checksums.txt. These literals are the point of this test: they must
# be duplicated here so a silent edit to lib/frp-common.sh cannot go unnoticed.
OFFICIAL_DARWIN_ARM64=cfa733b5a261c1647edee3c1fc4133d2542989b28f5602e81d47fc821d25c55f
OFFICIAL_LINUX_AMD64=333da23d1b9009d7c01638e9ba38cf4600f7d37d393f854e96ee1396adefa9a6
OFFICIAL_LINUX_ARM64=3990f396a9a490ee7f0e5f355287750ed41520064ed999eab443b5e9a78d773d
PINNED_FRP_VERSION=0.70.1

# shellcheck source=../lib/frp-common.sh
. "$ROOT/lib/frp-common.sh"

reset_env() {
  unset FRP_TEST_UNAME_S FRP_TEST_UNAME_M FRP_ARCH EXPECTED_SHA _FRP_UNAME_S_CACHE || true
}

# ---------------------------------------------------------------------------
# Version pin
# ---------------------------------------------------------------------------

reset_env
[[ "$FRP_VERSION" == "$PINNED_FRP_VERSION" ]] \
  || fail "FRP_VERSION drifted from ${PINNED_FRP_VERSION} (got ${FRP_VERSION})"
grep -qx "FRP_VERSION=${PINNED_FRP_VERSION}" "$ROOT/VERSION" \
  || fail "VERSION file must pin FRP ${PINNED_FRP_VERSION}"
pass "version: FRP ${PINNED_FRP_VERSION} pin unchanged"

# ---------------------------------------------------------------------------
# Checksum constants
# ---------------------------------------------------------------------------

[[ "$FRP_SHA256_DARWIN_ARM64" == "$OFFICIAL_DARWIN_ARM64" ]] \
  || fail "FRP_SHA256_DARWIN_ARM64 does not match the official release asset"
[[ "$FRP_SHA256_AMD64" == "$OFFICIAL_LINUX_AMD64" ]] || fail "linux amd64 pin changed"
[[ "$FRP_SHA256_ARM64" == "$OFFICIAL_LINUX_ARM64" ]] || fail "linux arm64 pin changed"
pass "checksum: darwin_arm64 constant matches the official asset"

# The darwin pin must be distinct from every other platform pin. A copy-paste
# of the linux arm64 digest would otherwise pass a naive length check.
for other in "$FRP_SHA256_AMD64" "$FRP_SHA256_ARM64" "$FRP_SHA256_WINDOWS_AMD64"; do
  [[ "$FRP_SHA256_DARWIN_ARM64" != "$other" ]] \
    || fail "darwin pin must not reuse another platform digest"
done
[[ "$FRP_SHA256_DARWIN_ARM64" =~ ^[0-9a-f]{64}$ ]] || fail "darwin pin must be 64 lowercase hex"
pass "checksum: darwin pin is distinct and well-formed"

# ---------------------------------------------------------------------------
# Checksum resolution
# ---------------------------------------------------------------------------

[[ "$(frp_checksum_for "$PINNED_FRP_VERSION" arm64 darwin)" == "$OFFICIAL_DARWIN_ARM64" ]] \
  || fail "frp_checksum_for darwin/arm64"
[[ "$(frp_checksum_for "$PINNED_FRP_VERSION" amd64 linux)" == "$OFFICIAL_LINUX_AMD64" ]] \
  || fail "frp_checksum_for linux/amd64"
[[ "$(frp_checksum_for "$PINNED_FRP_VERSION" arm64 linux)" == "$OFFICIAL_LINUX_ARM64" ]] \
  || fail "frp_checksum_for linux/arm64"
pass "checksum: OS-aware resolution"

if frp_checksum_for "$PINNED_FRP_VERSION" amd64 darwin 2>"$WORKDIR/intel.err" >/dev/null; then
  fail "darwin/amd64 must not resolve a checksum"
fi
grep -q 'Apple Silicon (arm64) only' "$WORKDIR/intel.err" || fail "darwin amd64 refusal message"
pass "checksum: darwin/amd64 has no checksum and says why"

if frp_checksum_for 0.69.0 arm64 darwin 2>"$WORKDIR/ver.err" >/dev/null; then
  fail "an untested FRP version must be refused on darwin"
fi
grep -q 'is not the tested version' "$WORKDIR/ver.err" || fail "version refusal message"
pass "checksum: untested FRP version refused on darwin"

# Two-argument callers keep working: the OS defaults to the (mocked) host.
reset_env
export FRP_TEST_UNAME_S=Darwin
[[ "$(frp_checksum_for "$PINNED_FRP_VERSION" arm64)" == "$OFFICIAL_DARWIN_ARM64" ]] \
  || fail "implicit OS should follow the host on darwin"
reset_env
export FRP_TEST_UNAME_S=Linux
[[ "$(frp_checksum_for "$PINNED_FRP_VERSION" amd64)" == "$OFFICIAL_LINUX_AMD64" ]] \
  || fail "implicit OS should follow the host on linux"
pass "checksum: implicit OS follows the host"

# ---------------------------------------------------------------------------
# Release URL
# ---------------------------------------------------------------------------

DARWIN_URL="$(frp_release_url "$PINNED_FRP_VERSION" arm64 darwin)"
EXPECT_DARWIN="https://github.com/fatedier/frp/releases/download/v${PINNED_FRP_VERSION}/frp_${PINNED_FRP_VERSION}_darwin_arm64.tar.gz"
[[ "$DARWIN_URL" == "$EXPECT_DARWIN" ]] || fail "darwin URL: $DARWIN_URL"
[[ "$DARWIN_URL" == https://* ]] || fail "darwin URL must be HTTPS"
pass "url: official darwin_arm64 asset"

# Linux URLs are byte-identical to the previous release.
[[ "$(frp_release_url "$PINNED_FRP_VERSION" amd64 linux)" == \
  "https://github.com/fatedier/frp/releases/download/v${PINNED_FRP_VERSION}/frp_${PINNED_FRP_VERSION}_linux_amd64.tar.gz" ]] \
  || fail "linux amd64 URL regression"
[[ "$(frp_release_url "$PINNED_FRP_VERSION" arm64 linux)" == \
  "https://github.com/fatedier/frp/releases/download/v${PINNED_FRP_VERSION}/frp_${PINNED_FRP_VERSION}_linux_arm64.tar.gz" ]] \
  || fail "linux arm64 URL regression"
reset_env
export FRP_TEST_UNAME_S=Linux
[[ "$(frp_release_url "$PINNED_FRP_VERSION" amd64)" == \
  "https://github.com/fatedier/frp/releases/download/v${PINNED_FRP_VERSION}/frp_${PINNED_FRP_VERSION}_linux_amd64.tar.gz" ]] \
  || fail "implicit-OS linux URL regression"
pass "url: Linux URLs unchanged"

if frp_release_url "$PINNED_FRP_VERSION" arm64 freebsd 2>/dev/null >/dev/null; then
  fail "unknown OS must not produce a release URL"
fi
pass "url: unknown OS refused"

# ---------------------------------------------------------------------------
# Detection wires the darwin pin into EXPECTED_SHA
# ---------------------------------------------------------------------------

reset_env
export FRP_TEST_UNAME_S=Darwin FRP_TEST_UNAME_M=arm64
frp_detect_arch || fail "darwin arm64 detection"
[[ "$EXPECTED_SHA" == "$OFFICIAL_DARWIN_ARM64" ]] || fail "EXPECTED_SHA must be the darwin pin"
[[ "$(frp_release_url "$FRP_VERSION" "$FRP_ARCH")" == "$EXPECT_DARWIN" ]] \
  || fail "detected values must produce the darwin asset URL"
pass "detect: darwin arm64 selects the darwin asset and digest"

# ---------------------------------------------------------------------------
# The release manifest agrees with the code
# ---------------------------------------------------------------------------

python3 - "$ROOT/release-manifest.json" "$PINNED_FRP_VERSION" "$OFFICIAL_DARWIN_ARM64" <<'PY'
import json
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
version, expected = sys.argv[2], sys.argv[3]
if manifest.get('frp_version') != version:
    raise SystemExit('FAIL release manifest frp_version drifted')
entry = (manifest.get('supported_frp_versions') or {}).get(version) or {}
if entry.get('darwin_arm64_sha256') != expected:
    raise SystemExit('FAIL release manifest darwin_arm64_sha256 mismatch')
PY
pass "manifest: release-manifest.json records the darwin pin"

# ---------------------------------------------------------------------------
# No insecure transport anywhere on the client download path
# ---------------------------------------------------------------------------

if grep -nE 'curl[^|]*(-k|--insecure)' \
  "$ROOT/install-client.sh" "$ROOT/lib/frp-macos.sh" "$ROOT/lib/frp-common.sh" \
  "$ROOT/lib/frp-client-common.sh" >/dev/null 2>&1; then
  fail "client must never use curl -k/--insecure"
fi
if grep -nE 'http://github\.com|http://raw\.' \
  "$ROOT/install-client.sh" "$ROOT/lib/frp-macos.sh" "$ROOT/lib/frp-common.sh" >/dev/null 2>&1; then
  fail "client must never fetch release artifacts over plain HTTP"
fi
pass "security: no insecure transport on the download path"

# The macOS integrity check must verify the digest, not merely compute it.
grep -q 'shasum -a 256 -c -' "$ROOT/lib/frp-macos.sh" \
  || fail "macOS checksum helper must use shasum -c to verify"
grep -q 'frp_macos_sha256_check "\$EXPECTED_SHA"' "$ROOT/install-client.sh" \
  || fail "installer must verify the archive against EXPECTED_SHA on macOS"
pass "security: macOS archive is verified against the pinned digest"

echo
echo "MACOS_FRP_PIN_TEST=PASS"
