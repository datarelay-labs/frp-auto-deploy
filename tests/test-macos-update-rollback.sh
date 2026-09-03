#!/usr/bin/env bash
# macOS client update snapshot/restore must probe live files through
# frp_client_path (platform map + test root), not Linux FHS under the test root.
# Exercises real backup + mutation + rollback under mocked Darwin paths.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Resolve to a physical path so macOS /var -> /private/var (and /tmp ->
# /private/tmp) do not trip snapshot symlink-parent refusal under mktemp.
WORKDIR="$(mktemp -d)"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
trap 'rm -rf "$WORKDIR"' EXIT

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }

reset_env() {
  unset FRP_TEST_UNAME_S FRP_TEST_UNAME_M FRP_TEST_CMD_PATH FRP_MACOS_PREFIX || true
  unset FRP_MACOS_STATE_ROOT FRP_CLIENT_TEST_ROOT FRP_CTL_TEST_ROOT || true
  unset FRP_DEPLOY_TEST_ROOT FRP_UPDATE_ROOT FRP_CLIENT_COMMON_LOADED || true
  unset FRP_COMMON_LOADED FRP_MACOS_LOADED FRP_DOCTOR_LOADED || true
  unset FRP_CLIENT_UPGRADE_HOOK_FAIL FRP_CLIENT_UPGRADE_HOOK_ROLLBACK_FAIL || true
  unset FRP_SKIP_SYSTEMD FRP_SKIP_DOWNLOAD _FRP_CLIENT_UPGRADE_SOURCE || true
  unset _FRP_UNAME_S_CACHE || true
}

file_mode() {
  python3 - "$1" <<'PY'
import os, sys
print("%04o" % (os.stat(sys.argv[1]).st_mode & 0o7777))
PY
}

build_update_source() {
  local dest="$1"
  mkdir -p "$dest/lib" "$dest/tools" "$dest/client" "$dest/dist"
  cp -a "$ROOT/lib/frp-client-common.sh" "$ROOT/lib/frp-common.sh" \
    "$ROOT/lib/frp-macos.sh" "$ROOT/lib/frp_project_files.py" \
    "$ROOT/lib/client-project-files.manifest" \
    "$ROOT/lib/frp_mgmt_auth.py" "$ROOT/lib/frp_data_plane_auth.py" \
    "$ROOT/lib/frp_clock_sync.py" "$ROOT/lib/frp-doctor-common.sh" \
    "$ROOT/lib/frp_doctor.py" "$ROOT/lib/frp_ctl_grammar.py" \
    "$ROOT/lib/frp_ctl_repl.py" "$ROOT/lib/frp_client_lifecycle.py" \
    "$ROOT/lib/frp-client-lifecycle.sh" \
    "$dest/lib/"
  cp -a "$ROOT/uninstall-client.sh" "$dest/"
  cp -a "$ROOT/tools/frp-client" "$ROOT/tools/frpctl" "$dest/tools/"
  [[ -f "$ROOT/tools/frpcli" ]] && cp -a "$ROOT/tools/frpcli" "$dest/tools/" || true
  cp -a "$ROOT/client/frpc.service" "$dest/client/" 2>/dev/null || true
  if [[ -f "$ROOT/client/com.datarelay.frp-auto-deploy.frpc.plist" ]]; then
    cp -a "$ROOT/client/com.datarelay.frp-auto-deploy.frpc.plist" "$dest/client/"
  fi
  cp -a "$ROOT/VERSION" "$ROOT/release-manifest.json" "$dest/"
}

# ---------------------------------------------------------------------------
# Darwin: files exist only at mapped macOS destinations
# ---------------------------------------------------------------------------

reset_env
export FRP_TEST_UNAME_S=Darwin
export FRP_TEST_UNAME_M=arm64
export FRP_MACOS_STATE_ROOT="/Library/Application Support/frp-auto-deploy"
export FRP_MACOS_PREFIX="/opt/homebrew"
export FRP_CLIENT_TEST_ROOT="$WORKDIR/darwin-root"
export FRP_SKIP_SYSTEMD=1
# shellcheck source=../lib/frp-client-common.sh
. "$ROOT/lib/frp-client-common.sh"

STATE_LIVE="${FRP_CLIENT_TEST_ROOT}${FRP_MACOS_STATE_ROOT}"
BREW_LIVE="${FRP_CLIENT_TEST_ROOT}${FRP_MACOS_PREFIX}"
mkdir -p "$STATE_LIVE/lib" "$STATE_LIVE/bin" "$STATE_LIVE/logs" \
  "$BREW_LIVE/bin" "$BREW_LIVE/sbin"

# Seed only mapped live paths (Linux FHS under the test root must stay absent).
printf 'macos-frpctl-v1\n' >"$BREW_LIVE/bin/frpctl"
chmod 0755 "$BREW_LIVE/bin/frpctl"
printf 'macos-common-v1\n' >"$STATE_LIVE/lib/frp-client-common.sh"
chmod 0644 "$STATE_LIVE/lib/frp-client-common.sh"
printf 'macos-plist-template-v1\n' \
  >"$STATE_LIVE/lib/com.datarelay.frp-auto-deploy.frpc.plist"
chmod 0644 "$STATE_LIVE/lib/com.datarelay.frp-auto-deploy.frpc.plist"
printf 'PROJECT_VERSION=2.1.1\nFRP_VERSION=0.70.1\n' >"$STATE_LIVE/version"
chmod 0644 "$STATE_LIVE/version"
printf 'serverAddr = "203.0.113.10"\n' >"$STATE_LIVE/frpc.toml"
chmod 0600 "$STATE_LIVE/frpc.toml"

# Ensure Linux canonical locations do not exist under the test root.
[[ ! -e "$FRP_CLIENT_TEST_ROOT/usr/local/bin/frpctl" ]] \
  || fail "precondition: Linux frpctl path must be absent"
[[ ! -e "$FRP_CLIENT_TEST_ROOT/usr/local/lib/frp-auto-deploy/frp-client-common.sh" ]] \
  || fail "precondition: Linux lib path must be absent"
[[ ! -e "$FRP_CLIENT_TEST_ROOT/etc/frp-auto-deploy/version" ]] \
  || fail "precondition: Linux version path must be absent"
[[ ! -e "$FRP_CLIENT_TEST_ROOT/etc/frp/frpc.toml" ]] \
  || fail "precondition: Linux toml path must be absent"

SRC="$WORKDIR/source"
build_update_source "$SRC"

CTL_BEFORE="$(cat "$BREW_LIVE/bin/frpctl")"
COMMON_BEFORE="$(cat "$STATE_LIVE/lib/frp-client-common.sh")"
PLIST_BEFORE="$(cat "$STATE_LIVE/lib/com.datarelay.frp-auto-deploy.frpc.plist")"
VERSION_BEFORE="$(cat "$STATE_LIVE/version")"
TOML_BEFORE="$(cat "$STATE_LIVE/frpc.toml")"
CTL_MODE_BEFORE="$(file_mode "$BREW_LIVE/bin/frpctl")"
COMMON_MODE_BEFORE="$(file_mode "$STATE_LIVE/lib/frp-client-common.sh")"
TOML_MODE_BEFORE="$(file_mode "$STATE_LIVE/frpc.toml")"

BACKUP="$(frp_client_upgrade_backup_tools "$SRC")" || fail "darwin snapshot"
[[ -f "$BACKUP/metadata.json" ]] || fail "darwin metadata missing"
[[ -f "$BACKUP/recovery/frp_project_files.py" ]] || fail "darwin recovery parser missing"

python3 - "$BACKUP/metadata.json" <<'PY' || fail "darwin mapped files recorded present"
import json, sys
from pathlib import Path

meta = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert meta.get("kind") == "client-upgrade-snapshot", meta
assert int(meta.get("schema_version") or 0) == 1, meta
files = {item["dest"]: item for item in (meta.get("files") or [])}
extras = {item["id"]: item for item in (meta.get("extras") or [])}

def expect_present(bucket, key, label):
    item = bucket.get(key)
    assert item is not None, "%s missing from snapshot: %s" % (label, key)
    assert item.get("state") == "present", "%s state=%r want present" % (label, item.get("state"))
    assert item.get("backup"), "%s missing backup path" % label
    assert not str(item.get("dest", "")).startswith("/"), "%s dest must stay canonical" % label

expect_present(files, "usr/local/bin/frpctl", "frpctl")
expect_present(files, "usr/local/lib/frp-auto-deploy/frp-client-common.sh", "lib common")
expect_present(
    files,
    "usr/local/lib/frp-auto-deploy/com.datarelay.frp-auto-deploy.frpc.plist",
    "launchd plist template",
)
expect_present(extras, "version", "version extra")
expect_present(extras, "frpc.toml", "frpc.toml extra")
print("OK")
PY
pass "MACOS_UPDATE_SNAPSHOT_MAPPED_PRESENT"

# Mutate/delete mapped live files to simulate a failed update mid-flight.
printf 'mutated-frpctl\n' >"$BREW_LIVE/bin/frpctl"
chmod 0700 "$BREW_LIVE/bin/frpctl"
printf 'mutated-common\n' >"$STATE_LIVE/lib/frp-client-common.sh"
rm -f "$STATE_LIVE/lib/com.datarelay.frp-auto-deploy.frpc.plist"
printf 'mutated-version\n' >"$STATE_LIVE/version"
printf 'mutated-toml\n' >"$STATE_LIVE/frpc.toml"
chmod 0644 "$STATE_LIVE/frpc.toml"

# A path that was absent in the snapshot must remain absent after restore.
ABSENT_LIVE="$STATE_LIVE/lib/frp_fake_absent_only.py"
[[ ! -e "$ABSENT_LIVE" ]] || fail "precondition absent file"
# Confirm snapshot recorded some project file as absent (optional frpcli often is).
python3 - "$BACKUP/metadata.json" <<'PY' || fail "snapshot should include absent entries"
import json, sys
from pathlib import Path
meta = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
absent = [i for i in (meta.get("files") or []) if i.get("state") == "absent"]
assert absent, meta
print(absent[0]["dest"])
PY

frp_client_upgrade_restore_tools "$BACKUP" || fail "darwin restore"
frp_client_upgrade_verify_restored "$BACKUP" || fail "darwin verify restored"

[[ "$(cat "$BREW_LIVE/bin/frpctl")" == "$CTL_BEFORE" ]] || fail "frpctl content not restored"
[[ "$(cat "$STATE_LIVE/lib/frp-client-common.sh")" == "$COMMON_BEFORE" ]] \
  || fail "lib content not restored"
[[ "$(cat "$STATE_LIVE/lib/com.datarelay.frp-auto-deploy.frpc.plist")" == "$PLIST_BEFORE" ]] \
  || fail "plist template not restored"
[[ "$(cat "$STATE_LIVE/version")" == "$VERSION_BEFORE" ]] || fail "version not restored"
[[ "$(cat "$STATE_LIVE/frpc.toml")" == "$TOML_BEFORE" ]] || fail "toml not restored"
[[ "$(file_mode "$BREW_LIVE/bin/frpctl")" == "$CTL_MODE_BEFORE" ]] || fail "frpctl mode not restored"
[[ "$(file_mode "$STATE_LIVE/lib/frp-client-common.sh")" == "$COMMON_MODE_BEFORE" ]] \
  || fail "lib mode not restored"
[[ "$(file_mode "$STATE_LIVE/frpc.toml")" == "$TOML_MODE_BEFORE" ]] || fail "toml mode not restored"
[[ ! -e "$ABSENT_LIVE" ]] || fail "originally absent file appeared after restore"
[[ ! -e "$FRP_CLIENT_TEST_ROOT/usr/local/bin/frpctl" ]] \
  || fail "restore must not create Linux FHS frpctl"
pass "MACOS_UPDATE_ROLLBACK_RESTORE"

# Automatic rollback after first-file mutation during a real update.
# Re-seed mapped installation (restore already did), then fail install hook.
printf 'macos-frpctl-v1\n' >"$BREW_LIVE/bin/frpctl"
chmod 0755 "$BREW_LIVE/bin/frpctl"
printf 'macos-common-v1\n' >"$STATE_LIVE/lib/frp-client-common.sh"
chmod 0644 "$STATE_LIVE/lib/frp-client-common.sh"
# Minimal enrolled state required by update validate-existing.
mkdir -p "$STATE_LIVE"
cat >"$STATE_LIVE/client-state.json" <<'JSON'
{
  "schema_version": 1,
  "allocator_url": "https://203.0.113.10:6099/enroll",
  "frp_server": "203.0.113.10",
  "frp_server_port": 443,
  "hostname": "macos-update",
  "machine_id": "00112233445566778899aabbccddeeff",
  "host_id": "macos-update-00112233",
  "services": {}
}
JSON
chmod 0600 "$STATE_LIVE/client-state.json"
printf 'serverAddr = "203.0.113.10"\n' >"$STATE_LIVE/frpc.toml"
chmod 0600 "$STATE_LIVE/frpc.toml"
# Force an upgrade path (equal version + matching bundle short-circuits before install).
printf 'PROJECT_VERSION=2.0.0\nFRP_VERSION=0.70.1\n' >"$STATE_LIVE/version"

# Dummy frpc at the mapped Darwin runtime path (validate-existing verifies toml).
cat >"$STATE_LIVE/bin/frpc" <<'EOF'
#!/bin/sh
if [ "$1" = verify ]; then
  exit 0
fi
if [ "$1" = --version ]; then
  echo "frpc version 0.70.1"
  exit 0
fi
exit 0
EOF
chmod 0755 "$STATE_LIVE/bin/frpc"

# Install remaining project files at mapped paths so validate/install have a full tree.
while IFS=: read -r rel mode src; do
  [[ -n "$rel" ]] || continue
  live="$(frp_client_path "/${rel}")"
  mkdir -p "$(dirname "$live")"
  if [[ -f "${SRC}/${src}" ]]; then
    install -m "$mode" "${SRC}/${src}" "$live"
  else
    printf 'seed-%s\n' "$rel" >"$live"
    chmod "$mode" "$live"
  fi
done < <(frp_client_upgrade_destinations "$SRC")

CTL_BEFORE2="$(cat "$BREW_LIVE/bin/frpctl")"
COMMON_BEFORE2="$(cat "$(frp_client_path /usr/local/lib/frp-auto-deploy/frp-client-common.sh)")"

export FRP_CLIENT_UPGRADE_HOOK_FAIL=install
set +e
"$ROOT/tools/frp-client" update --source "$SRC" \
  >"$WORKDIR/darwin-roll.out" 2>"$WORKDIR/darwin-roll.err"
roll_rc=$?
set -e
unset FRP_CLIENT_UPGRADE_HOOK_FAIL
if [[ "$roll_rc" -eq 0 ]]; then
  cat "$WORKDIR/darwin-roll.out" "$WORKDIR/darwin-roll.err" >&2 || true
  fail "install hook should fail the update"
fi
if ! grep -q 'UPGRADE_ROLLBACK=PASS' "$WORKDIR/darwin-roll.out" "$WORKDIR/darwin-roll.err"; then
  cat "$WORKDIR/darwin-roll.out" "$WORKDIR/darwin-roll.err" >&2 || true
  fail "missing darwin automatic rollback marker"
fi
[[ "$(cat "$BREW_LIVE/bin/frpctl")" == "$CTL_BEFORE2" ]] \
  || fail "automatic rollback did not restore mapped frpctl"
[[ "$(cat "$(frp_client_path /usr/local/lib/frp-auto-deploy/frp-client-common.sh)")" == "$COMMON_BEFORE2" ]] \
  || fail "automatic rollback did not restore mapped lib"
pass "MACOS_UPDATE_AUTOMATIC_ROLLBACK"

# ---------------------------------------------------------------------------
# Linux fixture: snapshot/restore semantics unchanged
# ---------------------------------------------------------------------------

reset_env
export FRP_TEST_UNAME_S=Linux
export FRP_CLIENT_TEST_ROOT="$WORKDIR/linux-root"
export FRP_SKIP_SYSTEMD=1
# shellcheck source=../lib/frp-client-common.sh
. "$ROOT/lib/frp-client-common.sh"

mkdir -p \
  "$FRP_CLIENT_TEST_ROOT/usr/local/bin" \
  "$FRP_CLIENT_TEST_ROOT/usr/local/lib/frp-auto-deploy" \
  "$FRP_CLIENT_TEST_ROOT/etc/frp" \
  "$FRP_CLIENT_TEST_ROOT/etc/frp-auto-deploy"
printf 'linux-frpctl-v1\n' >"$FRP_CLIENT_TEST_ROOT/usr/local/bin/frpctl"
chmod 0755 "$FRP_CLIENT_TEST_ROOT/usr/local/bin/frpctl"
printf 'linux-common-v1\n' \
  >"$FRP_CLIENT_TEST_ROOT/usr/local/lib/frp-auto-deploy/frp-client-common.sh"
chmod 0644 "$FRP_CLIENT_TEST_ROOT/usr/local/lib/frp-auto-deploy/frp-client-common.sh"
printf 'PROJECT_VERSION=2.1.1\nFRP_VERSION=0.70.1\n' \
  >"$FRP_CLIENT_TEST_ROOT/etc/frp-auto-deploy/version"
chmod 0644 "$FRP_CLIENT_TEST_ROOT/etc/frp-auto-deploy/version"
printf 'serverAddr = "203.0.113.10"\n' >"$FRP_CLIENT_TEST_ROOT/etc/frp/frpc.toml"
chmod 0600 "$FRP_CLIENT_TEST_ROOT/etc/frp/frpc.toml"

LINUX_CTL_BEFORE="$(cat "$FRP_CLIENT_TEST_ROOT/usr/local/bin/frpctl")"
LINUX_COMMON_BEFORE="$(cat "$FRP_CLIENT_TEST_ROOT/usr/local/lib/frp-auto-deploy/frp-client-common.sh")"
LINUX_CTL_MODE="$(file_mode "$FRP_CLIENT_TEST_ROOT/usr/local/bin/frpctl")"

LINUX_BACKUP="$(frp_client_upgrade_backup_tools "$SRC")" || fail "linux snapshot"
python3 - "$LINUX_BACKUP/metadata.json" <<'PY' || fail "linux present states"
import json, sys
from pathlib import Path
meta = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
files = {i["dest"]: i for i in (meta.get("files") or [])}
extras = {i["id"]: i for i in (meta.get("extras") or [])}
assert files["usr/local/bin/frpctl"]["state"] == "present"
assert files["usr/local/lib/frp-auto-deploy/frp-client-common.sh"]["state"] == "present"
assert extras["version"]["state"] == "present"
assert extras["frpc.toml"]["state"] == "present"
print("OK")
PY

printf 'linux-mutated\n' >"$FRP_CLIENT_TEST_ROOT/usr/local/bin/frpctl"
chmod 0700 "$FRP_CLIENT_TEST_ROOT/usr/local/bin/frpctl"
printf 'linux-mutated-common\n' \
  >"$FRP_CLIENT_TEST_ROOT/usr/local/lib/frp-auto-deploy/frp-client-common.sh"
frp_client_upgrade_restore_tools "$LINUX_BACKUP" || fail "linux restore"
[[ "$(cat "$FRP_CLIENT_TEST_ROOT/usr/local/bin/frpctl")" == "$LINUX_CTL_BEFORE" ]] \
  || fail "linux frpctl not restored"
[[ "$(cat "$FRP_CLIENT_TEST_ROOT/usr/local/lib/frp-auto-deploy/frp-client-common.sh")" == "$LINUX_COMMON_BEFORE" ]] \
  || fail "linux common not restored"
[[ "$(file_mode "$FRP_CLIENT_TEST_ROOT/usr/local/bin/frpctl")" == "$LINUX_CTL_MODE" ]] \
  || fail "linux frpctl mode not restored"
pass "LINUX_UPDATE_SNAPSHOT_RESTORE_UNCHANGED"

echo "MACOS_UPDATE_ROLLBACK_TESTS=PASS"
