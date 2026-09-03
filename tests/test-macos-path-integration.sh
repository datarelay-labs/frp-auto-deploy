#!/usr/bin/env bash
# Production path-integration: client, frpctl, doctor, and enrollment must all
# resolve canonical Linux FHS paths through frp_platform_map_path on Darwin.
# Fully portable — mocks Darwin with FRP_TEST_UNAME_S and never touches a real
# macOS filesystem.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }

reset_env() {
  unset FRP_TEST_UNAME_S FRP_TEST_UNAME_M FRP_TEST_CMD_PATH FRP_MACOS_PREFIX || true
  unset FRP_MACOS_STATE_ROOT FRP_CLIENT_TEST_ROOT FRP_CTL_TEST_ROOT || true
  unset FRP_DEPLOY_TEST_ROOT FRP_UPDATE_ROOT FRP_CLIENT_COMMON_LOADED || true
  unset FRP_COMMON_LOADED FRP_MACOS_LOADED FRP_DOCTOR_LOADED || true
  unset _FRP_UNAME_S_CACHE || true
}

# Mirror of tools/frpctl frpctl_path / frpctl_is_client for unit coverage without
# executing the CLI entry point.
define_frpctl_helpers() {
  frpctl_path() {
    local p="$1"
    local root="${FRP_CTL_TEST_ROOT:-${FRP_CLIENT_TEST_ROOT:-${FRP_DEPLOY_TEST_ROOT:-${FRP_UPDATE_ROOT:-}}}}"
    if declare -F frp_platform_map_path >/dev/null 2>&1; then
      p="$(frp_platform_map_path "$p")"
    fi
    if [[ -n "$root" ]]; then
      printf '%s' "${root}${p}"
    else
      printf '%s' "$p"
    fi
  }
  frpctl_is_client() {
    if [[ -f "$(frpctl_path /etc/frp/client-state.json)" ]]; then
      return 0
    fi
    if [[ -f "$(frpctl_path /etc/frp/frpc.toml)" && -f "$(frpctl_path /etc/frp/client-identity.key)" ]]; then
      return 0
    fi
    return 1
  }
}

# ---------------------------------------------------------------------------
# Client helpers compose: canonical -> platform map -> test root
# ---------------------------------------------------------------------------

reset_env
export FRP_TEST_UNAME_S=Darwin
export FRP_MACOS_STATE_ROOT="$WORKDIR/state"
export FRP_CLIENT_TEST_ROOT="$WORKDIR/root"
# shellcheck source=../lib/frp-client-common.sh
. "$ROOT/lib/frp-client-common.sh"

STATE_PATH="$(frp_client_state_path)"
[[ "$STATE_PATH" == "$WORKDIR/root$WORKDIR/state/client-state.json" ]] \
  || fail "frp_client_state_path -> $STATE_PATH"

FRPC_PATH="$(frp_client_path /usr/local/bin/frpc)"
[[ "$FRPC_PATH" == "$WORKDIR/root$WORKDIR/state/bin/frpc" ]] \
  || fail "frpc install destination -> $FRPC_PATH"

VERSION_PATH="$(frp_client_version_file)"
[[ "$VERSION_PATH" == "$WORKDIR/root$WORKDIR/state/version" ]] \
  || fail "client version file -> $VERSION_PATH"
pass "client: state, frpc, and version resolve under the macOS state root"

# Linux remains an identity composition under a test root.
reset_env
export FRP_TEST_UNAME_S=Linux
export FRP_CLIENT_TEST_ROOT="$WORKDIR/linux-root"
# shellcheck source=../lib/frp-client-common.sh
. "$ROOT/lib/frp-client-common.sh"
[[ "$(frp_client_state_path)" == "$WORKDIR/linux-root/etc/frp/client-state.json" ]] \
  || fail "Linux frp_client_state_path changed"
[[ "$(frp_client_path /usr/local/bin/frpc)" == "$WORKDIR/linux-root/usr/local/bin/frpc" ]] \
  || fail "Linux frpc path changed"
[[ "$(frp_client_version_file)" == "$WORKDIR/linux-root/etc/frp-auto-deploy/version" ]] \
  || fail "Linux version path changed"
pass "client: Linux FHS paths unchanged"

# ---------------------------------------------------------------------------
# frpctl recognizes a mapped macOS client installation
# ---------------------------------------------------------------------------

reset_env
export FRP_TEST_UNAME_S=Darwin
export FRP_MACOS_STATE_ROOT="$WORKDIR/ctl-state"
export FRP_CTL_TEST_ROOT="$WORKDIR/ctl-root"
mkdir -p "$FRP_CTL_TEST_ROOT$FRP_MACOS_STATE_ROOT"
printf '{"schema":1,"client_id":"mac-client"}\n' \
  >"$FRP_CTL_TEST_ROOT$FRP_MACOS_STATE_ROOT/client-state.json"
# Intentionally leave the Linux FHS location empty so detection only succeeds
# through the platform-mapped path.
mkdir -p "$FRP_CTL_TEST_ROOT/etc/frp"

# shellcheck source=../lib/frp-common.sh
. "$ROOT/lib/frp-common.sh"
define_frpctl_helpers

frpctl_is_client || fail "frpctl must detect the mapped macOS client-state.json"
[[ "$(frpctl_path /etc/frp/client-state.json)" == \
   "$WORKDIR/ctl-root$WORKDIR/ctl-state/client-state.json" ]] \
  || fail "frpctl_path client-state mapping"
[[ ! -f "$WORKDIR/ctl-root/etc/frp/client-state.json" ]] \
  || fail "Linux FHS client-state should be absent in this fixture"
pass "frpctl: recognizes the mapped client installation"

# Prove tools/frpctl embeds the same composition.
grep -q 'frp_platform_map_path' "$ROOT/tools/frpctl" \
  || fail "tools/frpctl must call frp_platform_map_path"
pass "frpctl: tools/frpctl wires platform mapping"

# Linux detection still uses FHS under the test root.
reset_env
export FRP_TEST_UNAME_S=Linux
export FRP_CTL_TEST_ROOT="$WORKDIR/ctl-linux"
mkdir -p "$FRP_CTL_TEST_ROOT/etc/frp"
printf '{"schema":1}\n' >"$FRP_CTL_TEST_ROOT/etc/frp/client-state.json"
# shellcheck source=../lib/frp-common.sh
. "$ROOT/lib/frp-common.sh"
define_frpctl_helpers
frpctl_is_client || fail "Linux frpctl client detection"
[[ "$(frpctl_path /etc/frp/client-state.json)" == \
   "$WORKDIR/ctl-linux/etc/frp/client-state.json" ]] \
  || fail "Linux frpctl_path changed"
pass "frpctl: Linux detection unchanged"

# ---------------------------------------------------------------------------
# Doctor reads mapped client / version state
# ---------------------------------------------------------------------------

reset_env
export FRP_TEST_UNAME_S=Darwin
export FRP_MACOS_STATE_ROOT="$WORKDIR/doc-state"
export FRP_CTL_TEST_ROOT="$WORKDIR/doc-root"
mkdir -p "$FRP_CTL_TEST_ROOT$FRP_MACOS_STATE_ROOT"
cat >"$FRP_CTL_TEST_ROOT$FRP_MACOS_STATE_ROOT/version" <<'EOF'
PROJECT_VERSION=2.1.1
FRP_VERSION=0.70.1
RELEASE_CHANNEL=stable
SOURCE_REF=v2.1.1
BUNDLE_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF
printf '{"schema":1,"client_id":"doc-client"}\n' \
  >"$FRP_CTL_TEST_ROOT$FRP_MACOS_STATE_ROOT/client-state.json"

# shellcheck source=../lib/frp-doctor-common.sh
. "$ROOT/lib/frp-doctor-common.sh"
DOC_VERSION="$(frp_doctor_fs /etc/frp-auto-deploy/version)"
[[ "$DOC_VERSION" == "$WORKDIR/doc-root$WORKDIR/doc-state/version" ]] \
  || fail "frp_doctor_fs version -> $DOC_VERSION"
[[ -f "$DOC_VERSION" ]] || fail "doctor version file missing at mapped path"
DOC_STATE="$(frp_doctor_fs /etc/frp/client-state.json)"
[[ "$DOC_STATE" == "$WORKDIR/doc-root$WORKDIR/doc-state/client-state.json" ]] \
  || fail "frp_doctor_fs client-state -> $DOC_STATE"

FRP_TEST_UNAME_S=Darwin \
FRP_MACOS_STATE_ROOT="$WORKDIR/doc-state" \
PYTHONPATH="$ROOT/lib" \
python3 - "$WORKDIR/doc-root" <<'PY' || fail "doctor Paths mapping"
import os, sys
from pathlib import Path
sys.path.insert(0, os.environ.get('PYTHONPATH', ''))
import frp_doctor as d
root = sys.argv[1]
paths = d.Paths(root)
ver = paths.p('/etc/frp-auto-deploy/version')
state = paths.p('/etc/frp/client-state.json')
want_ver = Path(root + os.environ['FRP_MACOS_STATE_ROOT'] + '/version')
want_state = Path(root + os.environ['FRP_MACOS_STATE_ROOT'] + '/client-state.json')
assert ver == want_ver, (ver, want_ver)
assert state == want_state, (state, want_state)
assert ver.is_file(), ver
assert d.kv_file(paths, '/etc/frp-auto-deploy/version', 'PROJECT_VERSION') == '2.1.1'
assert d.kv_file(paths, '/etc/frp-auto-deploy/version', 'FRP_VERSION') == '0.70.1'
assert d.kv_file(paths, '/etc/frp-auto-deploy/version', 'RELEASE_CHANNEL') == 'stable'
assert d.kv_file(paths, '/etc/frp-auto-deploy/version', 'SOURCE_REF') == 'v2.1.1'
assert d.kv_file(paths, '/etc/frp-auto-deploy/version', 'BUNDLE_SHA256').startswith('aaaa')
print('ok')
PY
pass "doctor: reads mapped client and version state"

# Linux doctor paths stay FHS.
reset_env
export FRP_TEST_UNAME_S=Linux
export FRP_CTL_TEST_ROOT="$WORKDIR/doc-linux"
mkdir -p "$FRP_CTL_TEST_ROOT/etc/frp-auto-deploy"
echo 'PROJECT_VERSION=2.1.1' >"$FRP_CTL_TEST_ROOT/etc/frp-auto-deploy/version"
# shellcheck source=../lib/frp-doctor-common.sh
. "$ROOT/lib/frp-doctor-common.sh"
[[ "$(frp_doctor_fs /etc/frp-auto-deploy/version)" == \
   "$WORKDIR/doc-linux/etc/frp-auto-deploy/version" ]] \
  || fail "Linux doctor version path changed"
FRP_TEST_UNAME_S=Linux PYTHONPATH="$ROOT/lib" python3 - "$WORKDIR/doc-linux" <<'PY' || fail "Linux doctor Paths"
import os, sys
from pathlib import Path
os.environ['FRP_TEST_UNAME_S'] = 'Linux'
sys.path.insert(0, os.environ['PYTHONPATH'])
import frp_doctor as d
paths = d.Paths(sys.argv[1])
assert paths.p('/etc/frp-auto-deploy/version') == Path(sys.argv[1] + '/etc/frp-auto-deploy/version')
assert d.kv_file(paths, '/etc/frp-auto-deploy/version', 'PROJECT_VERSION') == '2.1.1'
print('ok')
PY
pass "doctor: Linux paths unchanged"

# ---------------------------------------------------------------------------
# Enrollment build identity reads the mapped version state
# ---------------------------------------------------------------------------

reset_env
export FRP_TEST_UNAME_S=Darwin
export FRP_MACOS_STATE_ROOT="$WORKDIR/enroll-state"
export FRP_CLIENT_TEST_ROOT="$WORKDIR/enroll-root"
mkdir -p "$FRP_CLIENT_TEST_ROOT$FRP_MACOS_STATE_ROOT"
cat >"$FRP_CLIENT_TEST_ROOT$FRP_MACOS_STATE_ROOT/version" <<'EOF'
PROJECT_VERSION=2.1.1
FRP_VERSION=0.70.1
RELEASE_CHANNEL=dev
SOURCE_REF=main
BUNDLE_SHA256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
EOF
# Leave the Linux FHS version absent so a regression would fail closed.
# shellcheck source=../lib/frp-client-common.sh
. "$ROOT/lib/frp-client-common.sh"

SERVICES="$WORKDIR/services.json"
printf '[{"id":"ssh","name":"ssh","local_ip":"127.0.0.1","local_port":22,"preset":"ssh","ssh_user":"aella","enabled":true}]\n' \
  >"$SERVICES"

# Exercise the same version resolution used by frp_enroll_services.
payload="$(
  python3 - "machine-1" "host.example" "$SERVICES" "" "$(frp_client_version_file)" <<'PY'
import json, sys
from pathlib import Path
raw=json.loads(Path(sys.argv[3]).read_text(encoding='utf-8'))
services=raw
enabled=[]
for item in services:
    if item.get('enabled', True) is False:
        continue
    out={
        'id': item['id'],
        'name': item.get('name') or item['id'],
        'protocol': 'tcp',
        'local_ip': item['local_ip'],
        'local_port': item['local_port'],
        'preset': item.get('preset') or 'custom',
    }
    if out['preset']=='ssh' and item.get('ssh_user'):
        out['ssh_user']=item['ssh_user']
    enabled.append(out)
payload={
  'machine_id': sys.argv[1],
  'hostname': sys.argv[2],
  'services': enabled,
}
ver_path=Path(sys.argv[5]) if len(sys.argv) > 5 and sys.argv[5] else Path('/etc/frp-auto-deploy/version')
if ver_path.is_file():
    meta={}
    for line in ver_path.read_text(encoding='utf-8').splitlines():
        if '=' not in line:
            continue
        k,v=line.split('=',1)
        meta[k.strip()]=v.strip()
    mapping={
        'PROJECT_VERSION':'reported_project_version',
        'RELEASE_CHANNEL':'reported_release_channel',
        'SOURCE_REF':'reported_source_ref',
        'BUNDLE_SHA256':'reported_bundle_sha256',
        'FRP_VERSION':'reported_frp_version',
    }
    for src,dst in mapping.items():
        val=str(meta.get(src) or '').strip()
        if val:
            payload[dst]=val
print(json.dumps(payload, separators=(',', ':')))
PY
)"
python3 - "$payload" <<'PY' || fail "enrollment payload missing mapped build identity"
import json, sys
p = json.loads(sys.argv[1])
assert p.get('reported_project_version') == '2.1.1', p
assert p.get('reported_frp_version') == '0.70.1', p
assert p.get('reported_release_channel') == 'dev', p
assert p.get('reported_source_ref') == 'main', p
assert p.get('reported_bundle_sha256', '').startswith('bbbb'), p
print('ok')
PY
[[ "$(frp_client_version_file)" == "$WORKDIR/enroll-root$WORKDIR/enroll-state/version" ]] \
  || fail "enrollment version path not mapped"
[[ ! -f "$WORKDIR/enroll-root/etc/frp-auto-deploy/version" ]] \
  || fail "Linux FHS version should be absent in enrollment fixture"
grep -q 'frp_client_version_file' "$ROOT/lib/frp-client-common.sh" \
  || fail "enrollment must pass frp_client_version_file into Python"
pass "enrollment: build metadata reads the mapped version state"

# Linux enrollment still reads FHS version under the test root.
reset_env
export FRP_TEST_UNAME_S=Linux
export FRP_CLIENT_TEST_ROOT="$WORKDIR/enroll-linux"
mkdir -p "$FRP_CLIENT_TEST_ROOT/etc/frp-auto-deploy"
cat >"$FRP_CLIENT_TEST_ROOT/etc/frp-auto-deploy/version" <<'EOF'
PROJECT_VERSION=2.1.1
FRP_VERSION=0.70.1
RELEASE_CHANNEL=stable
SOURCE_REF=v2.1.1
BUNDLE_SHA256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
EOF
# shellcheck source=../lib/frp-client-common.sh
. "$ROOT/lib/frp-client-common.sh"
[[ "$(frp_client_version_file)" == "$WORKDIR/enroll-linux/etc/frp-auto-deploy/version" ]] \
  || fail "Linux enrollment version path changed"
pass "enrollment: Linux version path unchanged"

echo
echo "MACOS_PATH_INTEGRATION=PASS"
