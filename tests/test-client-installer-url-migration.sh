#!/usr/bin/env bash
# Permanent regression: project-managed client installer URL release-line migration.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
# shellcheck source=../lib/frp-common.sh
. "$ROOT/lib/frp-common.sh"

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }

HOST='raw.githubusercontent.com'
OWNER='datarelay-labs'
REPO='frp-auto-deploy'
ARTIFACT='dist/bootstrap-client.sh'

official() {
  printf 'https://%s/%s/%s/%s/%s' "$HOST" "$OWNER" "$REPO" "$1" "$ARTIFACT"
}

unset FRP_CLIENT_INSTALLER_URL FRP_RELEASE_CHANNEL || true

STABLE_V211="$(
  PROJECT_VERSION=2.1.1 FRP_RELEASE_CHANNEL=stable frp_default_client_installer_url
)"
[[ "$STABLE_V211" == "$(official v2.1.1)" ]] || fail "stable 2.1.1 canonical: $STABLE_V211"

DEV_CANONICAL="$(
  PROJECT_VERSION=2.1.1 FRP_RELEASE_CHANNEL=dev frp_default_client_installer_url
)"
[[ "$DEV_CANONICAL" == "$(official main)" ]] || fail "dev canonical: $DEV_CANONICAL"

# --- Official managed URL detection (strict parsing) ---
frp_is_official_managed_client_installer_url "$(official v2.1.0)" || fail "v2.1.0 not detected"
frp_is_official_managed_client_installer_url "$(official main)" || fail "main not detected"
frp_is_official_managed_client_installer_url "$(official v2.1.1)" || fail "v2.1.1 not detected"
frp_is_official_managed_client_installer_url 'https://mirror.example.com/frp/bootstrap-client.sh' \
  && fail "custom mirror wrongly official"
frp_is_official_managed_client_installer_url \
  'https://raw.githubusercontent.com/another-org/another-repo/v2.1.0/dist/bootstrap-client.sh' \
  && fail "other github repo wrongly official"
frp_is_official_managed_client_installer_url \
  'https://raw.githubusercontent.com.evil.example/datarelay-labs/frp-auto-deploy/v2.1.0/dist/bootstrap-client.sh' \
  && fail "lookalike host wrongly official"
frp_is_official_managed_client_installer_url \
  "https://${HOST}/${OWNER}/${REPO}/v2.1.0/extra/dist/bootstrap-client.sh" \
  && fail "extra path wrongly official"
frp_is_official_managed_client_installer_url \
  "https://${HOST}/${OWNER}/${REPO}/v2.1.0/dist/bootstrap-client.sh?x=1" \
  && fail "query string wrongly official"
frp_is_official_managed_client_installer_url \
  "https://user:pass@${HOST}/${OWNER}/${REPO}/v2.1.0/dist/bootstrap-client.sh" \
  && fail "userinfo wrongly official"
pass "LOOKALIKE_URL_SAFE"

# --- Stable channel migrations ---
got="$(
  PROJECT_VERSION=2.1.1 FRP_RELEASE_CHANNEL=stable \
    frp_canonicalize_managed_client_installer_url "$(official v2.1.0)"
)"
[[ "$got" == "$STABLE_V211" ]] || fail "OFFICIAL_V210_TO_STABLE_V211 got $got"
pass "OFFICIAL_V210_TO_STABLE_V211=MIGRATED"

got="$(
  PROJECT_VERSION=2.1.1 FRP_RELEASE_CHANNEL=stable \
    frp_canonicalize_managed_client_installer_url "$(official main)"
)"
[[ "$got" == "$STABLE_V211" ]] || fail "OFFICIAL_MAIN_TO_STABLE_V211 got $got"
pass "OFFICIAL_MAIN_TO_STABLE_V211=MIGRATED"

got="$(
  PROJECT_VERSION=2.1.1 FRP_RELEASE_CHANNEL=stable \
    frp_canonicalize_managed_client_installer_url "$(official v2.1.1)"
)"
[[ "$got" == "$STABLE_V211" ]] || fail "OFFICIAL_V211_TO_STABLE_V211 got $got"
pass "OFFICIAL_V211_TO_STABLE_V211=UNCHANGED"

# --- Dev channel migrations ---
got="$(
  PROJECT_VERSION=2.1.1 FRP_RELEASE_CHANNEL=dev \
    frp_canonicalize_managed_client_installer_url "$(official v2.1.0)"
)"
[[ "$got" == "$DEV_CANONICAL" ]] || fail "OFFICIAL_OLD_STABLE_TO_DEV got $got"
pass "OFFICIAL_OLD_STABLE_TO_DEV_CANONICAL=EXPECTED_BEHAVIOR"

got="$(
  PROJECT_VERSION=2.1.1 FRP_RELEASE_CHANNEL=dev \
    frp_canonicalize_managed_client_installer_url "$(official main)"
)"
[[ "$got" == "$DEV_CANONICAL" ]] || fail "OFFICIAL_MAIN_TO_DEV got $got"
pass "OFFICIAL_MAIN_TO_DEV=EXPECTED_BEHAVIOR"

# --- Preserve custom / third-party / lookalike ---
CUSTOM='https://mirror.example.com/frp/bootstrap-client.sh'
got="$(
  PROJECT_VERSION=2.1.1 FRP_RELEASE_CHANNEL=stable \
    frp_canonicalize_managed_client_installer_url "$CUSTOM"
)"
[[ "$got" == "$CUSTOM" ]] || fail "custom rewritten"
pass "CUSTOM_URL_PRESERVED"

OTHER='https://raw.githubusercontent.com/another-org/another-repo/v2.1.0/dist/bootstrap-client.sh'
got="$(
  PROJECT_VERSION=2.1.1 FRP_RELEASE_CHANNEL=stable \
    frp_canonicalize_managed_client_installer_url "$OTHER"
)"
[[ "$got" == "$OTHER" ]] || fail "other github repo rewritten"
pass "OTHER_GITHUB_REPO_PRESERVED"

LOOKALIKE='https://raw.githubusercontent.com.evil.example/datarelay-labs/frp-auto-deploy/v2.1.0/dist/bootstrap-client.sh'
got="$(
  PROJECT_VERSION=2.1.1 FRP_RELEASE_CHANNEL=stable \
    frp_canonicalize_managed_client_installer_url "$LOOKALIKE"
)"
[[ "$got" == "$LOOKALIKE" ]] || fail "lookalike rewritten"
pass "LOOKALIKE_HOST_PRESERVED"

# --- Explicit env override never rewritten ---
export FRP_CLIENT_INSTALLER_URL="$(official v2.1.0)"
got="$(
  PROJECT_VERSION=2.1.1 FRP_RELEASE_CHANNEL=stable \
    frp_canonicalize_managed_client_installer_url "$(official v2.1.0)"
)"
[[ "$got" == "$(official v2.1.0)" ]] || fail "explicit override rewritten"
unset FRP_CLIENT_INSTALLER_URL
pass "EXPLICIT_FRP_CLIENT_INSTALLER_URL_PRESERVED"

# --- Whitespace / empty / invalid URL validation still works ---
frp_validate_https_url 'https://example.test/bootstrap-client.sh' || fail "valid https rejected"
frp_validate_https_url '' && fail "empty URL accepted"
frp_validate_https_url 'http://example.test/bootstrap-client.sh' && fail "http accepted"
frp_validate_https_url 'https://' && fail "incomplete https accepted"
frp_validate_https_url 'not-a-url' && fail "garbage URL accepted"
frp_validate_https_url 'file:///etc/passwd' && fail "file URL accepted"
frp_validate_https_url 'ftp://example.test/x' && fail "ftp URL accepted"
frp_validate_https_url 'javascript:alert(1)' && fail "javascript URL accepted"
frp_validate_https_url $'https://example.test/x\ny' && fail "newline URL accepted"
frp_validate_https_url $'https://example.test/\x01path' && fail "control char URL accepted"
frp_validate_https_url 'https://user:pass@example.test/x' && fail "userinfo URL accepted"
pass "URL_VALIDATION_INTACT"

# --- frp-set-client-installer-url enforces https ---
mkdir -p "$WORKDIR/set-url/etc/frp-auto-deploy" "$WORKDIR/set-url/var/lib/frp-auto-deploy"
python3 - "$WORKDIR/set-url/etc/frp-auto-deploy/config.json" <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
  "public_ip": "203.0.113.10",
  "public_host": "203.0.113.10",
  "deployment_mode": "direct",
  "frp_transport": "tcp",
  "port_start": 6000,
  "port_end": 6099,
  "frp_control_listen_port": 7000,
  "frp_control_public_port": 7000,
  "allocator_listen_port": 6099,
  "allocator_public_port": 6099,
  "client_installer_url": "https://example.test/old.sh",
}, indent=2) + "\n")
PY
export FRP_DEPLOY_TEST_ROOT="$WORKDIR/set-url"
python3 "$ROOT/tools/frp-set-client-installer-url" \
  'https://mirror.example/bootstrap-client.sh' \
  >"$WORKDIR/set-ok.out" || fail "https set failed"
got="$(python3 -c 'import json; print(json.load(open("'"$WORKDIR/set-url/etc/frp-auto-deploy/config.json"'"))["client_installer_url"])')"
[[ "$got" == 'https://mirror.example/bootstrap-client.sh' ]] || fail "https not stored"
set +e
python3 "$ROOT/tools/frp-set-client-installer-url" \
  'http://mirror.example/bootstrap-client.sh' \
  >"$WORKDIR/set-http.out" 2>"$WORKDIR/set-http.err"
http_rc=$?
set -e
[[ "$http_rc" -ne 0 ]] || fail "http set accepted"
grep -qi 'https' "$WORKDIR/set-http.err" || fail "http set error message"
set +e
python3 "$ROOT/tools/frp-set-client-installer-url" \
  $'https://mirror.example/x\ny' \
  >"$WORKDIR/set-nl.out" 2>"$WORKDIR/set-nl.err"
nl_rc=$?
set -e
[[ "$nl_rc" -ne 0 ]] || fail "newline set accepted"
pass "SET_CLIENT_INSTALLER_URL_HTTPS_ONLY"

# Setter shares control locks with restore / project-update (lifecycle + registry).
python3 - "$ROOT" "$WORKDIR/set-url" <<'PY' || fail "CONFIG_SETTER_CONTROL_LOCK"
import os, sys, time
from pathlib import Path
root_repo, tree = Path(sys.argv[1]), Path(sys.argv[2])
sys.path.insert(0, str(root_repo / "lib"))
import frp_control_locks as locks

os.environ["FRP_DEPLOY_TEST_ROOT"] = str(tree)
os.environ["FRP_CONTROL_LOCK_TIMEOUT"] = "1"
setter = root_repo / "tools" / "frp-set-client-installer-url"

with locks.acquire_control_locks(tree, timeout=5):
    import subprocess
    started = time.monotonic()
    proc = subprocess.run(
        [sys.executable, str(setter), "https://mirror.example/other.sh"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        universal_newlines=True,
        env=dict(os.environ),
    )
    elapsed = time.monotonic() - started
    assert proc.returncode != 0, proc.stdout + proc.stderr
    assert "lock" in (proc.stderr or "").lower(), proc.stderr
    assert elapsed < 8, elapsed
print("CONFIG_SETTER_CONTROL_LOCK_OK")
PY
pass "CONFIG_SETTER_CONTROL_LOCK"
unset FRP_DEPLOY_TEST_ROOT
unset FRP_CONTROL_LOCK_TIMEOUT

# --- Legacy historical owner URL migrates ---
LEGACY="$(frp_legacy_project_client_installer_url)"
got="$(
  PROJECT_VERSION=2.1.1 FRP_RELEASE_CHANNEL=stable \
    frp_canonicalize_managed_client_installer_url "$LEGACY"
)"
[[ "$got" == "$STABLE_V211" ]] || fail "legacy not migrated: $got"
pass "LEGACY_OWNER_MIGRATED"

echo
echo "CLIENT_INSTALLER_URL_MIGRATION_TEST=PASS"
