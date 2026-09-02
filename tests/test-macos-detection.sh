#!/usr/bin/env bash
# macOS host detection, path mapping, machine identity, and Homebrew prefix
# discovery. Fully portable: runs on Linux by injecting FRP_TEST_UNAME_S /
# FRP_TEST_UNAME_M and never touching a real macOS command.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }

# shellcheck source=../lib/frp-common.sh
. "$ROOT/lib/frp-common.sh"

make_cmd() {
  local dir="$1" name="$2" body="${3:-exit 0}"
  mkdir -p "$dir"
  printf '#!/bin/sh\n%s\n' "$body" >"$dir/$name"
  chmod +x "$dir/$name"
}

reset_env() {
  unset FRP_TEST_UNAME_S FRP_TEST_UNAME_M FRP_TEST_CMD_PATH FRP_MACOS_PREFIX || true
  unset FRP_TEST_IOPLATFORM_UUID FRP_TEST_PROC_TRANSLATED FRP_ARCH EXPECTED_SHA || true
  unset FRP_MACOS_STATE_ROOT FRP_CLIENT_TEST_ROOT FRP_TEST_MACOS_PRODUCT_VERSION || true
  unset _FRP_UNAME_S_CACHE || true
}

# ---------------------------------------------------------------------------
# OS detection
# ---------------------------------------------------------------------------

reset_env
[[ "$(frp_os)" == linux ]] || fail "default host should report linux"
frp_is_darwin && fail "Linux host must not report darwin"
pass "os: linux host"

reset_env
export FRP_TEST_UNAME_S=Darwin
[[ "$(frp_os)" == darwin ]] || fail "FRP_TEST_UNAME_S=Darwin should report darwin"
frp_is_darwin || fail "frp_is_darwin under Darwin"
[[ "$(frp_detect_os)" == darwin ]] || fail "frp_detect_os under Darwin"
pass "os: darwin detection"

reset_env
export FRP_TEST_UNAME_S=Linux
[[ "$(frp_detect_os)" == linux ]] || fail "frp_detect_os under Linux"
pass "os: linux detection"

reset_env
export FRP_TEST_UNAME_S=FreeBSD
if frp_detect_os >/dev/null 2>"$WORKDIR/os.err"; then
  fail "unsupported OS should fail"
fi
grep -q 'ERROR: unsupported operating system: FreeBSD' "$WORKDIR/os.err" \
  || fail "unsupported OS message"
pass "os: unsupported kernel fails clearly"

# ---------------------------------------------------------------------------
# Architecture: Apple Silicon only
# ---------------------------------------------------------------------------

reset_env
export FRP_TEST_UNAME_S=Darwin FRP_TEST_UNAME_M=arm64
frp_detect_arch || fail "darwin arm64 must be supported"
[[ "$FRP_ARCH" == arm64 ]] || fail "darwin arm64 -> $FRP_ARCH"
[[ "$EXPECTED_SHA" == "$FRP_SHA256_DARWIN_ARM64" ]] || fail "darwin arm64 pins the darwin SHA"
pass "arch: darwin arm64 supported"

reset_env
export FRP_TEST_UNAME_S=Darwin FRP_TEST_UNAME_M=x86_64
if frp_detect_arch 2>"$WORKDIR/intel.err"; then
  fail "Intel Darwin must be rejected"
fi
grep -q 'unsupported macOS architecture: x86_64' "$WORKDIR/intel.err" \
  || fail "Intel Darwin error names the architecture"
grep -q 'Apple Silicon' "$WORKDIR/intel.err" || fail "Intel Darwin error names Apple Silicon"
grep -q 'Intel Macs are not supported' "$WORKDIR/intel.err" || fail "Intel Darwin explicit refusal"
pass "arch: Intel Darwin rejected with a clear message"

# Rosetta reports x86_64 on Apple Silicon; the message must say how to recover.
reset_env
export FRP_TEST_UNAME_S=Darwin FRP_TEST_UNAME_M=x86_64 FRP_TEST_PROC_TRANSLATED=1
if frp_detect_arch 2>"$WORKDIR/rosetta.err"; then
  fail "Rosetta x86_64 must be rejected"
fi
grep -q 'Rosetta 2' "$WORKDIR/rosetta.err" || fail "Rosetta hint missing"
grep -q 'arch -arm64' "$WORKDIR/rosetta.err" || fail "Rosetta recovery command missing"
pass "arch: Rosetta 2 detected and explained"

reset_env
export FRP_TEST_UNAME_S=Darwin FRP_TEST_UNAME_M=ppc
if frp_detect_arch 2>/dev/null; then
  fail "unknown darwin arch must be rejected"
fi
pass "arch: unknown darwin arch rejected"

# Linux must be completely unaffected.
reset_env
export FRP_TEST_UNAME_M=x86_64
frp_detect_arch || fail "linux amd64 regression"
[[ "$FRP_ARCH" == amd64 && "$EXPECTED_SHA" == "$FRP_SHA256_AMD64" ]] || fail "linux amd64 pin regression"
reset_env
export FRP_TEST_UNAME_M=aarch64
frp_detect_arch || fail "linux arm64 regression"
[[ "$FRP_ARCH" == arm64 && "$EXPECTED_SHA" == "$FRP_SHA256_ARM64" ]] || fail "linux arm64 pin regression"
pass "arch: Linux detection unchanged"

# ---------------------------------------------------------------------------
# Service manager
# ---------------------------------------------------------------------------

reset_env
export FRP_TEST_UNAME_S=Darwin
export FRP_TEST_CMD_PATH="$WORKDIR/launchd-ok"
make_cmd "$FRP_TEST_CMD_PATH" launchctl
frp_require_service_manager || fail "launchd present should satisfy the service gate"
[[ "$(frp_service_manager)" == launchd ]] || fail "service manager should report launchd"
pass "service manager: launchd accepted"

reset_env
export FRP_TEST_UNAME_S=Darwin
export FRP_TEST_CMD_PATH="$WORKDIR/launchd-missing"
mkdir -p "$FRP_TEST_CMD_PATH"
if frp_require_service_manager 2>"$WORKDIR/launchd.err"; then
  fail "missing launchctl should fail"
fi
grep -q 'requires launchd' "$WORKDIR/launchd.err" || fail "missing launchd message"
pass "service manager: missing launchctl fails clearly"

# Linux still requires systemd, with the original message.
reset_env
export FRP_TEST_CMD_PATH="$WORKDIR/sysd-ok"
export FRP_TEST_SYSTEMD_RUNTIME_DIR="$WORKDIR/run-systemd"
mkdir -p "$FRP_TEST_SYSTEMD_RUNTIME_DIR"
make_cmd "$FRP_TEST_CMD_PATH" systemctl
frp_require_service_manager || fail "linux systemd should still pass"
[[ "$(frp_service_manager)" == systemd ]] || fail "linux should report systemd"
unset FRP_TEST_SYSTEMD_RUNTIME_DIR
pass "service manager: Linux still requires systemd"

# ---------------------------------------------------------------------------
# Homebrew prefix discovery
# ---------------------------------------------------------------------------

reset_env
export FRP_TEST_UNAME_S=Darwin
export FRP_TEST_CMD_PATH="$WORKDIR/no-brew"
mkdir -p "$FRP_TEST_CMD_PATH"
[[ "$(frp_macos_brew_prefix)" == /usr/local ]] || fail "no brew should fall back to /usr/local"
pass "prefix: falls back to /usr/local without Homebrew"

# brew --prefix answers: use it verbatim, whatever it is.
reset_env
export FRP_TEST_UNAME_S=Darwin
export FRP_TEST_CMD_PATH="$WORKDIR/brew-answers"
BREW_PREFIX="$WORKDIR/fake-brew-prefix"
mkdir -p "$BREW_PREFIX"
make_cmd "$FRP_TEST_CMD_PATH" brew "printf '%s\\n' $(printf '%q' "$BREW_PREFIX")"
[[ "$(frp_macos_brew_prefix)" == "$BREW_PREFIX" ]] || fail "brew --prefix should be honored"
pass "prefix: honors brew --prefix"

# brew refuses to answer (it declines to run as root): derive from its location.
reset_env
export FRP_TEST_UNAME_S=Darwin
DERIVED="$WORKDIR/derived-prefix"
export FRP_TEST_CMD_PATH="$DERIVED/bin"
mkdir -p "$FRP_TEST_CMD_PATH"
make_cmd "$FRP_TEST_CMD_PATH" brew "exit 1"
[[ "$(frp_macos_brew_prefix)" == "$DERIVED" ]] || \
  fail "silent brew should derive prefix from its location, got $(frp_macos_brew_prefix)"
pass "prefix: derives from brew location when brew refuses"

# /opt/homebrew must never appear in executable code (prose comments are fine).
if grep -RIh --include='*.sh' --include='frpctl' --include='frp-client' -- '/opt/homebrew' \
  "$ROOT/lib" "$ROOT/tools" "$ROOT/install-client.sh" "$ROOT/uninstall-client.sh" 2>/dev/null |
  grep -v '^[[:space:]]*#' | grep -q .; then
  fail "/opt/homebrew must not be hardcoded in code"
fi
pass "prefix: /opt/homebrew is never hardcoded"

# ---------------------------------------------------------------------------
# Path mapping
# ---------------------------------------------------------------------------

reset_env
export FRP_TEST_UNAME_S=Darwin
export FRP_TEST_CMD_PATH="$WORKDIR/no-brew"
STATE='/Library/Application Support/frp-auto-deploy'

expect_map() {
  local input="$1" want="$2" got
  got="$(frp_macos_map_path "$input")"
  [[ "$got" == "$want" ]] || fail "map $input -> $got (want $want)"
}

expect_map /etc/frp "$STATE"
expect_map /etc/frp/frpc.toml "$STATE/frpc.toml"
expect_map /etc/frp/client-state.json "$STATE/client-state.json"
expect_map /etc/frp/client-identity.key "$STATE/client-identity.key"
expect_map /etc/frp-auto-deploy "$STATE"
expect_map /etc/frp-auto-deploy/allocator-ca.crt "$STATE/allocator-ca.crt"
expect_map /etc/frp-auto-deploy/version "$STATE/version"
expect_map /var/lib/frp-auto-deploy/update-pending.json "$STATE/state/update-pending.json"
expect_map /usr/local/lib/frp-auto-deploy "$STATE/lib"
expect_map /usr/local/lib/frp-auto-deploy/frp-common.sh "$STATE/lib/frp-common.sh"
expect_map /usr/local/bin/frpc "$STATE/bin/frpc"
expect_map /usr/local/bin/frpctl /usr/local/bin/frpctl
expect_map /etc/systemd/system/frpc.service \
  /Library/LaunchDaemons/com.datarelay.frp-auto-deploy.frpc.plist
expect_map /tmp/somewhere /tmp/somewhere
pass "paths: canonical paths map onto the macOS layout"

# The pinned runtime binary must stay out of an admin-writable Homebrew prefix.
reset_env
export FRP_TEST_UNAME_S=Darwin
export FRP_MACOS_PREFIX="$WORKDIR/brewish"
[[ "$(frp_macos_map_path /usr/local/bin/frpc)" == "$STATE/bin/frpc" ]] \
  || fail "frpc must not resolve into the Homebrew prefix"
[[ "$(frp_macos_map_path /usr/local/bin/frpctl)" == "$WORKDIR/brewish/bin/frpctl" ]] \
  || fail "CLI entry points should resolve into the Homebrew prefix"
[[ "$(frp_macos_map_path /usr/local/lib/frp-auto-deploy/frp_doctor.py)" == "$STATE/lib/frp_doctor.py" ]] \
  || fail "project libs must stay under the root-owned state root"
pass "paths: root-owned runtime vs Homebrew CLI split"

# Linux mapping is an identity function.
reset_env
for p in /etc/frp/frpc.toml /usr/local/bin/frpc /var/lib/frp-auto-deploy/update-pending.json \
  /etc/systemd/system/frpc.service /usr/local/lib/frp-auto-deploy/frp-common.sh; do
  [[ "$(frp_platform_map_path "$p")" == "$p" ]] || fail "Linux mapping must be identity for $p"
done
pass "paths: Linux mapping is unchanged"

# Test-root remapping still composes on macOS.
reset_env
export FRP_TEST_UNAME_S=Darwin
export FRP_MACOS_STATE_ROOT="$WORKDIR/state"
export FRP_CLIENT_TEST_ROOT="$WORKDIR/root"
[[ "$(frp_macos_fs /etc/frp/frpc.toml)" == "$WORKDIR/root$WORKDIR/state/frpc.toml" ]] \
  || fail "test root should compose with the macOS state root"
pass "paths: test-root remapping composes"

# ---------------------------------------------------------------------------
# Machine identity
# ---------------------------------------------------------------------------

reset_env
export FRP_TEST_UNAME_S=Darwin
export FRP_TEST_IOPLATFORM_UUID='2C3E4A5B-6D7F-4A1B-9C8D-0E1F2A3B4C5D'
MID="$(frp_macos_machine_id)" || fail "machine id from IOPlatformUUID"
[[ "$MID" =~ ^[0-9a-f]{32}$ ]] || fail "machine id must be 32 lowercase hex, got $MID"
pass "identity: 32 hex characters, same shape as /etc/machine-id"

# Stability: the same UUID always yields the same id.
MID2="$(frp_macos_machine_id)"
[[ "$MID" == "$MID2" ]] || fail "machine id must be deterministic"
pass "identity: deterministic"

# Case-insensitivity: ioreg casing must not change identity.
export FRP_TEST_IOPLATFORM_UUID='2c3e4a5b-6d7f-4a1b-9c8d-0e1f2a3b4c5d'
[[ "$(frp_macos_machine_id)" == "$MID" ]] || fail "machine id must normalize UUID case"
pass "identity: UUID case-normalized"

# Different hardware yields a different id.
export FRP_TEST_IOPLATFORM_UUID='AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE'
[[ "$(frp_macos_machine_id)" != "$MID" ]] || fail "different UUID must yield a different id"
pass "identity: distinct per machine"

# The raw hardware UUID must never leak into the identity.
export FRP_TEST_IOPLATFORM_UUID='2C3E4A5B-6D7F-4A1B-9C8D-0E1F2A3B4C5D'
LOWER_UUID="$(printf '%s' '2C3E4A5B6D7F4A1B9C8D0E1F2A3B4C5D' | tr 'A-Z' 'a-z')"
[[ "$(frp_macos_machine_id)" != "$LOWER_UUID" ]] || fail "identity must be hashed, not the raw UUID"
pass "identity: hashed, raw UUID never used directly"

# Hostname is not part of identity.
export FRP_TEST_HOSTNAME=mac-one
MID_A="$(frp_macos_machine_id)"
export FRP_TEST_HOSTNAME=mac-renamed
MID_B="$(frp_macos_machine_id)"
[[ "$MID_A" == "$MID_B" ]] || fail "hostname must not affect machine identity"
unset FRP_TEST_HOSTNAME
pass "identity: hostname is mutable metadata only"

# Malformed / missing UUID fails closed.
export FRP_TEST_IOPLATFORM_UUID='not-a-uuid'
if frp_macos_machine_id 2>"$WORKDIR/uuid.err" >/dev/null; then
  fail "malformed IOPlatformUUID must fail"
fi
grep -q 'IOPlatformUUID' "$WORKDIR/uuid.err" || fail "malformed UUID message"
pass "identity: malformed UUID fails closed"

reset_env
export FRP_TEST_UNAME_S=Darwin
export FRP_TEST_CMD_PATH="$WORKDIR/no-ioreg"
mkdir -p "$FRP_TEST_CMD_PATH"
if frp_macos_machine_id 2>/dev/null >/dev/null; then
  fail "missing ioreg must fail"
fi
pass "identity: missing ioreg fails closed"

# ---------------------------------------------------------------------------
# macOS release gate
# ---------------------------------------------------------------------------

reset_env
export FRP_TEST_UNAME_S=Darwin
export FRP_TEST_MACOS_PRODUCT_VERSION=14.5
frp_macos_require_supported_release || fail "macOS 14.5 should be supported"
export FRP_TEST_MACOS_PRODUCT_VERSION=11.0
frp_macos_require_supported_release || fail "macOS 11.0 should be supported"
export FRP_TEST_MACOS_PRODUCT_VERSION=10.15
if frp_macos_require_supported_release 2>"$WORKDIR/rel.err"; then
  fail "macOS 10.15 should be rejected"
fi
grep -q 'older than the supported minimum' "$WORKDIR/rel.err" || fail "old macOS message"
pass "release: minimum macOS version enforced"

# ---------------------------------------------------------------------------
# Dependencies are required, never installed
# ---------------------------------------------------------------------------

reset_env
export FRP_TEST_UNAME_S=Darwin
export FRP_TEST_CMD_PATH="$WORKDIR/deps-ok"
while IFS= read -r c; do
  [[ -n "$c" ]] || continue
  make_cmd "$FRP_TEST_CMD_PATH" "$c"
done < <(frp_macos_required_commands)
frp_macos_require_dependencies || fail "all macOS deps present should pass"
pass "deps: satisfied host proceeds"

rm -f "$FRP_TEST_CMD_PATH/python3" "$FRP_TEST_CMD_PATH/curl"
if frp_macos_require_dependencies 2>"$WORKDIR/deps.err"; then
  fail "missing macOS deps should fail"
fi
grep -q '  python3' "$WORKDIR/deps.err" || fail "missing python3 listed"
grep -q '  curl' "$WORKDIR/deps.err" || fail "missing curl listed"
grep -q 'xcode-select --install' "$WORKDIR/deps.err" || fail "recovery guidance missing"
grep -q 'does not modify system packages' "$WORKDIR/deps.err" || fail "no-mutation promise missing"
pass "deps: missing tools reported, never auto-installed"

# The installer must not reach for a Linux package manager on Darwin.
if grep -nE '(apt-get|dnf |yum )' "$ROOT/lib/frp-macos.sh" >/dev/null 2>&1; then
  fail "macOS module must not reference Linux package managers"
fi
pass "deps: no Linux package manager on the macOS path"

echo
echo "MACOS_DETECTION_TEST=PASS"
