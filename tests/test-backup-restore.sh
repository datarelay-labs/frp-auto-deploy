#!/usr/bin/env bash
# Disaster-recovery backup validation, exact restore, and rollback coverage.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
TREE="$WORKDIR/root"
OUTDIR="$WORKDIR/output"
BACKUP="$OUTDIR/server.tar.gz"

seed_state() {
  local tree="$1" marker="$2"
  mkdir -p \
    "$tree/etc/frp-auto-deploy/pki" \
    "$tree/etc/frp" \
    "$tree/var/lib/frp-auto-deploy/enrollments" \
    "$tree/var/lib/frp-auto-deploy/bootstrap"
  printf '{"deployment_mode":"direct","marker":"%s"}\n' "$marker" \
    >"$tree/etc/frp-auto-deploy/config.json"
  cat >"$tree/etc/frp-auto-deploy/version" <<EOF
PROJECT_VERSION=2.1.0
FRP_VERSION=0.70.1
RELEASE_CHANNEL=dev
SOURCE_REF=main
BUNDLE_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF
  printf 'bindPort = 443\n# %s\n' "$marker" >"$tree/etc/frp/frps.toml"
  printf 'token-%s-super-secret\n' "$marker" >"$tree/etc/frp/server_token"
  printf '{"schema_version":2,"clients":{"client-a":{"label":"%s","notes":"private note","services":{"ssh":{"remote_port":6001}}}},"reserved":[6002]}\n' \
    "$marker" >"$tree/var/lib/frp-auto-deploy/registry.json"
  printf 'nonce-%s\n' "$marker" >"$tree/var/lib/frp-auto-deploy/mgmt-nonces.json"
  printf 'ca-key-%s\n' "$marker" >"$tree/etc/frp-auto-deploy/pki/ca.key"
  printf 'ca-cert-%s\n' "$marker" >"$tree/etc/frp-auto-deploy/pki/ca.crt"
  printf 'server-key-%s\n' "$marker" >"$tree/etc/frp-auto-deploy/pki/server.key"
  printf 'server-cert-%s\n' "$marker" >"$tree/etc/frp-auto-deploy/pki/server.crt"
  printf 'serial-%s\n' "$marker" >"$tree/etc/frp-auto-deploy/pki/ca.srl"
  printf '{"ticket":"%s-enrollment"}\n' "$marker" \
    >"$tree/var/lib/frp-auto-deploy/enrollments/ticket.json"
  printf '{"ticket":"%s-bootstrap"}\n' "$marker" \
    >"$tree/var/lib/frp-auto-deploy/bootstrap/ticket.json"
  chmod 700 \
    "$tree/etc/frp-auto-deploy" "$tree/etc/frp-auto-deploy/pki" \
    "$tree/etc/frp" "$tree/var/lib/frp-auto-deploy" \
    "$tree/var/lib/frp-auto-deploy/enrollments" \
    "$tree/var/lib/frp-auto-deploy/bootstrap"
  find "$tree/etc/frp-auto-deploy" "$tree/etc/frp" "$tree/var/lib/frp-auto-deploy" \
    -type f -exec chmod 600 {} +
}

mode_of() {
  python3 - "$1" <<'PY'
import os, stat, sys
print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))
PY
}

archive_variant() {
  local source="$1" output="$2" operation="$3"
  python3 - "$source" "$output" "$operation" <<'PY'
import hashlib, json, sys, tarfile, tempfile
from pathlib import Path

source, output, operation = map(Path, sys.argv[1:])
with tempfile.TemporaryDirectory() as name:
    root = Path(name)
    with tarfile.open(source, "r:gz") as archive:
        archive.extractall(root)
    manifest_path = root / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    if operation.name == "checksum":
        target = root / "payload/etc/frp/server_token"
        target.write_text("tampered-secret\n")
    elif operation.name == "missing":
        rel = "etc/frp/server_token"
        (root / "payload" / rel).unlink()
        manifest["files"] = [item for item in manifest["files"] if item["path"] != rel]
        manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
        lines = [
            line for line in (root / "checksums.sha256").read_text().splitlines()
            if not line.endswith("payload/" + rel)
        ]
        (root / "checksums.sha256").write_text("\n".join(lines) + "\n")
    with tarfile.open(output, "w:gz") as archive:
        archive.add(root / "manifest.json", arcname="manifest.json")
        archive.add(root / "checksums.sha256", arcname="checksums.sha256")
        archive.add(root / "payload", arcname="payload")
PY
}

seed_state "$TREE" original
mkdir -p "$OUTDIR"
chmod 755 "$OUTDIR"
export FRP_DEPLOY_TEST_ROOT="$TREE"

BACKUP_STDOUT="$WORKDIR/backup.stdout"
python3 "$ROOT/tools/frp-backup" "$BACKUP" >"$BACKUP_STDOUT" \
  || fail "backup creation"
[[ -f "$BACKUP" ]] || fail "backup archive missing"
[[ "$(mode_of "$OUTDIR")" == "0o700" ]] || fail "backup directory mode"
[[ "$(mode_of "$BACKUP")" == "0o600" ]] || fail "backup archive mode"
grep -q 'contains private keys' "$BACKUP_STDOUT" || fail "secret warning missing"
if grep -qE 'token-original-super-secret|private note|original-enrollment' "$BACKUP_STDOUT"; then
  fail "backup leaked a secret"
fi
pass "BACKUP_CREATE_PERMISSIONS_NO_SECRET_LEAK"

BAD_CHECKSUM="$WORKDIR/checksum.tar.gz"
archive_variant "$BACKUP" "$BAD_CHECKSUM" checksum
BEFORE="$(sha256sum "$TREE/etc/frp/server_token" | awk '{print $1}')"
if python3 "$ROOT/tools/frp-restore" "$BAD_CHECKSUM" >"$WORKDIR/bad.stdout" 2>"$WORKDIR/bad.stderr"; then
  fail "checksum corruption accepted"
fi
[[ "$(sha256sum "$TREE/etc/frp/server_token" | awk '{print $1}')" == "$BEFORE" ]] \
  || fail "checksum failure modified current state"
grep -q 'checksum verification failed' "$WORKDIR/bad.stderr" || {
  sed 's/^/DIAGNOSTIC: /' "$WORKDIR/bad.stderr" >&2
  fail "checksum diagnostic"
}
pass "RESTORE_CHECKSUM_REJECTED_WITHOUT_MUTATION"

MISSING="$WORKDIR/missing.tar.gz"
archive_variant "$BACKUP" "$MISSING" missing
if python3 "$ROOT/tools/frp-restore" "$MISSING" >/dev/null 2>"$WORKDIR/missing.stderr"; then
  fail "missing required file accepted"
fi
grep -q 'missing required file' "$WORKDIR/missing.stderr" || fail "missing-file diagnostic"
pass "RESTORE_MISSING_FILE_REJECTED"

seed_state "$TREE" mutated
printf 'stale\n' >"$TREE/etc/frp-auto-deploy/frontend.conf"
RESTORE_STDOUT="$WORKDIR/restore.stdout"
python3 "$ROOT/tools/frp-restore" "$BACKUP" >"$RESTORE_STDOUT" \
  || fail "exact restore"
grep -q '"marker":"original"' "$TREE/etc/frp-auto-deploy/config.json" || fail "config restore"
grep -q '"label":"original"' "$TREE/var/lib/frp-auto-deploy/registry.json" || fail "registry restore"
grep -q '6002' "$TREE/var/lib/frp-auto-deploy/registry.json" || fail "reservation restore"
grep -q 'token-original-super-secret' "$TREE/etc/frp/server_token" || fail "token restore"
grep -q 'ca-key-original' "$TREE/etc/frp-auto-deploy/pki/ca.key" || fail "CA restore"
grep -q 'serial-original' "$TREE/etc/frp-auto-deploy/pki/ca.srl" || fail "PKI serial restore"
grep -q 'original-enrollment' "$TREE/var/lib/frp-auto-deploy/enrollments/ticket.json" \
  || fail "enrollment restore"
grep -q 'original-bootstrap' "$TREE/var/lib/frp-auto-deploy/bootstrap/ticket.json" \
  || fail "bootstrap restore"
[[ ! -f "$TREE/etc/frp-auto-deploy/frontend.conf" ]] || fail "absent optional file not removed"
[[ "$(mode_of "$TREE/etc/frp/server_token")" == "0o600" ]] || fail "token mode"
[[ "$(mode_of "$TREE/etc/frp-auto-deploy/pki")" == "0o700" ]] || fail "PKI directory mode"
if grep -qE 'token-original-super-secret|private note|original-enrollment' "$RESTORE_STDOUT"; then
  fail "restore leaked a secret"
fi
find "$TREE/var/lib/frp-auto-deploy/backups" -name 'pre-restore-*.tar.gz' -type f \
  | grep -q . || fail "pre-restore snapshot missing"
pass "RESTORE_EXACT_STATE_PERMISSIONS_NO_SECRET_LEAK"

seed_state "$TREE" rollback-source
ROLLBACK_BEFORE="$WORKDIR/rollback.before"
cp "$TREE/var/lib/frp-auto-deploy/registry.json" "$ROLLBACK_BEFORE"
if FRP_RESTORE_HOOK_FAIL_AFTER=4 \
  python3 "$ROOT/tools/frp-restore" "$BACKUP" >/dev/null 2>"$WORKDIR/rollback.stderr"; then
  fail "injected restore failure unexpectedly succeeded"
fi
cmp -s "$TREE/var/lib/frp-auto-deploy/registry.json" "$ROLLBACK_BEFORE" \
  || fail "registry was not rolled back"
grep -q 'token-rollback-source-super-secret' "$TREE/etc/frp/server_token" \
  || fail "token was not rolled back"
grep -q 'ca-key-rollback-source' "$TREE/etc/frp-auto-deploy/pki/ca.key" \
  || fail "CA was not rolled back"
grep -q 'previous state was restored' "$WORKDIR/rollback.stderr" || fail "rollback diagnostic"
pass "RESTORE_FAILURE_ROLLBACK"

echo "BACKUP_RESTORE_TEST=PASS"
