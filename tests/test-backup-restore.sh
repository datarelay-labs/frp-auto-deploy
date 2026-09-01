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
  python3 - "$ROOT" "$tree" "$marker" <<'PY'
import json, sys
from pathlib import Path
root, tree, marker = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
sys.path.insert(0, str(root / "lib"))
import frp_pki
pki_dir = tree / "etc/frp-auto-deploy/pki"
result = frp_pki.ensure_pki(str(pki_dir), "203.0.113.10")
cfg = {
    "deployment_mode": "direct",
    "frp_transport": "tcp",
    "public_host": "203.0.113.10",
    "public_ip": "203.0.113.10",
    "port_start": 6100,
    "port_end": 6200,
    "frp_control_listen_port": 7000,
    "frp_control_public_port": 7000,
    "allocator_listen_port": 6099,
    "allocator_public_port": 6099,
    "client_installer_url": "https://example.test/bootstrap-client.sh",
    "marker": marker,
    "pki_fingerprint": result["fingerprint"],
}
(tree / "etc/frp-auto-deploy/config.json").write_text(json.dumps(cfg, indent=2) + "\n")
(tree / "var/lib/frp-auto-deploy/registry.json").write_text(json.dumps({
    "schema_version": 2,
    "clients": {},
    "reserved": [6100],
    "groups": {},
    "label": marker,
}, indent=2) + "\n")
PY
  cat >"$tree/etc/frp-auto-deploy/version" <<EOF
PROJECT_VERSION=2.1.0
FRP_VERSION=0.70.1
RELEASE_CHANNEL=dev
SOURCE_REF=main
BUNDLE_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
MARKER=$marker
EOF
  printf 'bindPort = 7000\n# %s\n' "$marker" >"$tree/etc/frp/frps.toml"
  printf 'token-%s-super-secret\n' "$marker" >"$tree/etc/frp/server_token"
  printf 'nonce-%s\n' "$marker" >"$tree/var/lib/frp-auto-deploy/mgmt-nonces.json"
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
  # Keys must remain 0600; ensure_pki already sets modes, re-assert after find.
  chmod 600 "$tree/etc/frp-auto-deploy/pki/ca.key" "$tree/etc/frp-auto-deploy/pki/server.key"
  chmod 644 "$tree/etc/frp-auto-deploy/pki/ca.crt" "$tree/etc/frp-auto-deploy/pki/server.crt"
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
[[ "$(mode_of "$OUTDIR")" == "0o755" ]] || fail "user-supplied backup parent mode must stay unchanged"
[[ "$(mode_of "$BACKUP")" == "0o600" ]] || fail "backup archive mode"
grep -q 'contains private keys' "$BACKUP_STDOUT" || fail "secret warning missing"
if grep -qE 'token-original-super-secret|private note|original-enrollment' "$BACKUP_STDOUT"; then
  fail "backup leaked a secret"
fi
# Regression: /tmp-style fixture parent mode/owner must remain untouched.
TMP_PARENT="$WORKDIR/tmp-style-parent"
mkdir -p "$TMP_PARENT"
chmod 1777 "$TMP_PARENT"
OWNER_BEFORE="$(stat -c '%u:%g' "$TMP_PARENT")"
MODE_BEFORE="$(mode_of "$TMP_PARENT")"
TMP_BACKUP="$TMP_PARENT/server.tar.gz"
python3 "$ROOT/tools/frp-backup" "$TMP_BACKUP" >/dev/null \
  || fail "backup into tmp-style parent"
[[ "$(mode_of "$TMP_PARENT")" == "$MODE_BEFORE" ]] || fail "tmp-style parent mode changed"
[[ "$(stat -c '%u:%g' "$TMP_PARENT")" == "$OWNER_BEFORE" ]] || fail "tmp-style parent owner changed"
[[ "$(mode_of "$TMP_BACKUP")" == "0o600" ]] || fail "tmp-style archive mode"
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
grep -q '"marker": "original"' "$TREE/etc/frp-auto-deploy/config.json" \
  || grep -q '"marker":"original"' "$TREE/etc/frp-auto-deploy/config.json" \
  || fail "config restore"
grep -q '"label": "original"' "$TREE/var/lib/frp-auto-deploy/registry.json" \
  || grep -q '"label":"original"' "$TREE/var/lib/frp-auto-deploy/registry.json" \
  || fail "registry restore"
grep -q '6100' "$TREE/var/lib/frp-auto-deploy/registry.json" || fail "reservation restore"
grep -q 'token-original-super-secret' "$TREE/etc/frp/server_token" || fail "token restore"
python3 - "$ROOT" "$TREE" <<'PY' || fail "CA restore fingerprint"
import json, sys
from pathlib import Path
root, tree = Path(sys.argv[1]), Path(sys.argv[2])
sys.path.insert(0, str(root / "lib"))
import frp_pki
cfg = json.loads((tree / "etc/frp-auto-deploy/config.json").read_text())
fp = frp_pki.fingerprint_from_cert_file(tree / "etc/frp-auto-deploy/pki/ca.crt")
assert fp == cfg["pki_fingerprint"], (fp, cfg.get("pki_fingerprint"))
frp_pki.validate_existing_materials(frp_pki.pki_paths(tree / "etc/frp-auto-deploy/pki"))
print("PKI_OK")
PY
grep -q 'MARKER=original' "$TREE/etc/frp-auto-deploy/version" || fail "version marker restore"
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
python3 - "$ROOT" "$TREE" <<'PY' || fail "CA was not rolled back"
import json, sys
from pathlib import Path
root, tree = Path(sys.argv[1]), Path(sys.argv[2])
sys.path.insert(0, str(root / "lib"))
import frp_pki
cfg = json.loads((tree / "etc/frp-auto-deploy/config.json").read_text())
assert cfg.get("marker") == "rollback-source"
fp = frp_pki.fingerprint_from_cert_file(tree / "etc/frp-auto-deploy/pki/ca.crt")
assert fp == cfg["pki_fingerprint"]
print("ROLLBACK_PKI_OK")
PY
grep -q 'previous state was restored' "$WORKDIR/rollback.stderr" || fail "rollback diagnostic"
pass "RESTORE_FAILURE_ROLLBACK"

# Concurrent registry mutation cannot interleave with a locked backup copy.
CONC="$WORKDIR/conc"
seed_state "$CONC" concurrent
export FRP_DEPLOY_TEST_ROOT="$CONC"
READY="$WORKDIR/backup.ready"
GO="$WORKDIR/backup.go"
rm -f "$READY" "$GO"
CONC_BACKUP="$WORKDIR/conc.tar.gz"
FRP_BACKUP_HOOK_READY="$READY" FRP_BACKUP_HOOK_GO="$GO" FRP_BACKUP_HOOK_WAIT=15 \
  python3 "$ROOT/tools/frp-backup" "$CONC_BACKUP" >"$WORKDIR/conc.stdout" 2>"$WORKDIR/conc.stderr" &
BACK_PID=$!
for _ in $(seq 1 80); do
  [[ -f "$READY" ]] && break
  sleep 0.05
done
[[ -f "$READY" ]] || { kill "$BACK_PID" 2>/dev/null || true; fail "backup lock hook"; }
python3 - "$CONC" "$WORKDIR/writer.started" "$WORKDIR/writer.done" <<'PY' &
import json, os, sys, time
from pathlib import Path
root = Path(sys.argv[1])
sys.path.insert(0, str(Path(os.environ.get("FRP_TEST_LOCKS_LIB", ""))))
# Non-blocking attempt: writer must not observe a half-copied registry.
lock = root / "var/lib/frp-auto-deploy/registry.lock"
import fcntl
fd = os.open(str(lock), os.O_CREAT | os.O_RDWR, 0o600)
Path(sys.argv[2]).write_text("started\n")
deadline = time.time() + 8
got = False
while time.time() < deadline:
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        got = True
        break
    except BlockingIOError:
        time.sleep(0.05)
if got:
    path = root / "var/lib/frp-auto-deploy/registry.json"
    json.loads(path.read_text())
    path.write_text(json.dumps({"schema_version":2,"clients":{"mutated":{}},"reserved":[]}) + "\n")
    fcntl.flock(fd, fcntl.LOCK_UN)
Path(sys.argv[3]).write_text("got=%s\n" % got)
os.close(fd)
PY
sleep 0.2
touch "$GO"
wait "$BACK_PID" || fail "concurrent backup"
python3 - "$CONC_BACKUP" <<'PY'
import json, tarfile, sys, tempfile
from pathlib import Path
with tempfile.TemporaryDirectory() as name:
    dest = Path(name)
    with tarfile.open(sys.argv[1], "r:gz") as archive:
        archive.extractall(dest)
    data = json.loads((dest / "payload/var/lib/frp-auto-deploy/registry.json").read_text())
    assert data.get("schema_version") == 2
    assert data.get("label") == "concurrent"
    assert 6100 in data.get("reserved", [])
print("BACKUP_JSON_OK")
PY
pass "BACKUP_CONCURRENT_REGISTRY_MUTATION"
pass "BACKUP_CONSISTENCY"

# Health-gated restore rollback.
HEALTH="$WORKDIR/health-tree"
seed_state "$HEALTH" health
export FRP_DEPLOY_TEST_ROOT="$HEALTH"
python3 "$ROOT/tools/frp-backup" "$WORKDIR/health.tar.gz" >/dev/null
seed_state "$HEALTH" mutated
if FRP_RESTORE_HOOK_HEALTH_FAIL=1 \
  python3 "$ROOT/tools/frp-restore" "$WORKDIR/health.tar.gz" \
  >"$WORKDIR/health.stdout" 2>"$WORKDIR/health.stderr"; then
  fail "health-fail restore should fail"
fi
grep -q 'token-mutated-super-secret' "$HEALTH/etc/frp/server_token" || fail "health rollback token"
grep -q 'previous state was restored' "$WORKDIR/health.stderr" || fail "health rollback message"
pass "RESTORE_HEALTH_GATE"
pass "RESTORE_HEALTH_FAILURE_ROLLBACK"

if FRP_RESTORE_HOOK_HEALTH_FAIL=1 FRP_RESTORE_HOOK_ROLLBACK_HEALTH_FAIL=1 \
  python3 "$ROOT/tools/frp-restore" "$WORKDIR/health.tar.gz" \
  >"$WORKDIR/rbhealth.stdout" 2>"$WORKDIR/rbhealth.stderr"; then
  fail "rollback health failure should fail"
fi
grep -q 'RESTORE_ROLLBACK_FAILED' "$WORKDIR/rbhealth.stderr" || fail "RESTORE_ROLLBACK_FAILED"
grep -q 'RECOVERY_REQUIRED' "$WORKDIR/rbhealth.stderr" || fail "restore recovery required"
[[ -f "$HEALTH/var/lib/frp-auto-deploy/update-pending.json" ]] || fail "restore pending missing"
pass "RESTORE_ROLLBACK_FAILURE"

# Symlink / existing-file backup output must refuse without clobbering.
SAFE_TREE="$WORKDIR/safe-tree"
seed_state "$SAFE_TREE" symlink-safe
export FRP_DEPLOY_TEST_ROOT="$SAFE_TREE"
VICTIM="$WORKDIR/victim-secret.txt"
printf 'do-not-clobber\n' >"$VICTIM"
SYMLINK_OUT="$WORKDIR/backup-as-symlink.tar.gz"
ln -s "$VICTIM" "$SYMLINK_OUT"
if python3 "$ROOT/tools/frp-backup" "$SYMLINK_OUT" \
  >"$WORKDIR/sym.stdout" 2>"$WORKDIR/sym.stderr"; then
  fail "backup through symlink output should refuse"
fi
grep -qi 'symlink\|refuse\|overwrite' "$WORKDIR/sym.stderr" "$WORKDIR/sym.stdout" \
  || fail "symlink output diagnostic"
[[ "$(cat "$VICTIM")" == "do-not-clobber" ]] || fail "symlink backup clobbered victim"
pass "BACKUP_REFUSES_SYMLINK_OUTPUT"

EXISTING_OUT="$WORKDIR/already-exists.tar.gz"
printf 'preexisting\n' >"$EXISTING_OUT"
if python3 "$ROOT/tools/frp-backup" "$EXISTING_OUT" \
  >"$WORKDIR/exist.stdout" 2>"$WORKDIR/exist.stderr"; then
  fail "backup over existing regular file should refuse"
fi
grep -qi 'refuse\|overwrite\|exist' "$WORKDIR/exist.stderr" "$WORKDIR/exist.stdout" \
  || fail "existing file diagnostic"
[[ "$(cat "$EXISTING_OUT")" == "preexisting" ]] || fail "existing backup file mutated"
pass "BACKUP_REFUSES_EXISTING_OUTPUT"

LINK_PARENT="$WORKDIR/link-parent"
REAL_PARENT="$WORKDIR/real-parent"
mkdir -p "$REAL_PARENT"
ln -s "$REAL_PARENT" "$LINK_PARENT"
if python3 "$ROOT/tools/frp-backup" "$LINK_PARENT/server.tar.gz" \
  >"$WORKDIR/lparent.stdout" 2>"$WORKDIR/lparent.stderr"; then
  fail "backup through symlink parent should refuse"
fi
grep -qi 'symlink' "$WORKDIR/lparent.stderr" "$WORKDIR/lparent.stdout" \
  || fail "symlink parent diagnostic"
[[ ! -e "$REAL_PARENT/server.tar.gz" ]] || fail "symlink parent write leaked"
pass "BACKUP_REFUSES_SYMLINK_PARENT"

# Restore refuses when control locks module is unavailable.
python3 - "$ROOT" "$BACKUP" <<'PY' || fail "restore locks-unavailable abort"
import importlib.machinery
import importlib.util
import sys
from pathlib import Path
from unittest import mock

root = Path(sys.argv[1])
archive = sys.argv[2]
restore_path = root / "tools" / "frp-restore"
loader = importlib.machinery.SourceFileLoader(
    "frp_restore_under_test", str(restore_path)
)
spec = importlib.util.spec_from_loader(loader.name, loader)
assert spec is not None and spec.loader is not None, restore_path
mod = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = mod
loader.exec_module(mod)

real_load = mod._load_module

def fake_load(name, filename):
    if filename == "frp_control_locks.py" or name == "frp_control_locks":
        return None
    return real_load(name, filename)

buf_err = []
def fake_error(msg):
    buf_err.append(str(msg))
    print(msg, file=sys.stderr)

with mock.patch.object(mod, "_load_module", side_effect=fake_load), \
     mock.patch.object(mod, "error", side_effect=fake_error), \
     mock.patch.object(sys, "argv", ["frp-restore", archive]):
    code = mod.main()
assert code == 1, code
assert any("frp_control_locks" in m for m in buf_err), buf_err
print("RESTORE_LOCKS_UNAVAILABLE_OK")
PY
pass "RESTORE_LOCKS_MODULE_REQUIRED"

# Archive input that is a symlink must be refused without following.
ARCHIVE_VICTIM="$WORKDIR/real-archive.tar.gz"
cp "$BACKUP" "$ARCHIVE_VICTIM"
ARCHIVE_LINK="$WORKDIR/archive-link.tar.gz"
ln -s "$ARCHIVE_VICTIM" "$ARCHIVE_LINK"
export FRP_DEPLOY_TEST_ROOT="$SAFE_TREE"
BEFORE_CFG="$(sha256sum "$SAFE_TREE/etc/frp-auto-deploy/config.json" | awk '{print $1}')"
if python3 "$ROOT/tools/frp-restore" "$ARCHIVE_LINK" \
  >"$WORKDIR/asyml.stdout" 2>"$WORKDIR/asyml.stderr"; then
  fail "restore of symlink archive should refuse"
fi
grep -qi 'symlink' "$WORKDIR/asyml.stderr" || fail "symlink archive diagnostic"
[[ "$(sha256sum "$SAFE_TREE/etc/frp-auto-deploy/config.json" | awk '{print $1}')" == "$BEFORE_CFG" ]] \
  || fail "symlink archive restore mutated state"
pass "RESTORE_REFUSES_SYMLINK_ARCHIVE"

# Crossed PKI in a backup must be rejected before live mutation.
PAIR_TREE="$WORKDIR/pair-tree"
seed_state "$PAIR_TREE" pair-live
export FRP_DEPLOY_TEST_ROOT="$PAIR_TREE"
PAIR_BACKUP="$WORKDIR/pair-good.tar.gz"
python3 "$ROOT/tools/frp-backup" "$PAIR_BACKUP" >/dev/null
CROSS_BACKUP="$WORKDIR/pair-crossed.tar.gz"
python3 - "$ROOT" "$PAIR_BACKUP" "$CROSS_BACKUP" <<'PY' || fail "cross PKI archive build"
import hashlib, json, sys, tarfile, tempfile
from pathlib import Path
root, src, dst = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
sys.path.insert(0, str(root / "lib"))
import frp_pki
with tempfile.TemporaryDirectory() as name:
    dest = Path(name)
    with tarfile.open(src, "r:gz") as archive:
        archive.extractall(dest)
    foreign = dest / "foreign-pki"
    foreign.mkdir()
    frp_pki.ensure_pki(str(foreign), "198.51.100.10")
    target = dest / "payload/etc/frp-auto-deploy/pki/ca.key"
    target.write_bytes((foreign / "ca.key").read_bytes())
    manifest = json.loads((dest / "manifest.json").read_text())
    files = []
    checksum_lines = []
    for item in manifest.get("files") or []:
        rel = item.get("path")
        payload = dest / "payload" / rel
        if not payload.is_file():
            continue
        digest = hashlib.sha256(payload.read_bytes()).hexdigest()
        entry = dict(item)
        entry["sha256"] = digest
        entry["size"] = payload.stat().st_size
        files.append(entry)
        checksum_lines.append("%s  payload/%s" % (digest, rel))
    manifest["files"] = files
    (dest / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    (dest / "checksums.sha256").write_text("\n".join(checksum_lines) + "\n")
    with tarfile.open(dst, "w:gz") as archive:
        archive.add(dest / "manifest.json", arcname="manifest.json")
        archive.add(dest / "checksums.sha256", arcname="checksums.sha256")
        archive.add(dest / "payload", arcname="payload")
PY
BEFORE_PAIR="$(sha256sum "$PAIR_TREE/etc/frp-auto-deploy/config.json" | awk '{print $1}')"
if python3 "$ROOT/tools/frp-restore" "$CROSS_BACKUP" \
  >"$WORKDIR/pair.stdout" 2>"$WORKDIR/pair.stderr"; then
  fail "crossed PKI restore should refuse"
fi
grep -qiE 'pair|pki|certificate|key|corrupted' "$WORKDIR/pair.stderr" \
  || fail "crossed PKI diagnostic"
[[ "$(sha256sum "$PAIR_TREE/etc/frp-auto-deploy/config.json" | awk '{print $1}')" == "$BEFORE_PAIR" ]] \
  || fail "crossed PKI restore mutated live state"
pass "RESTORE_PK_PAIR_PREVALIDATION"

echo "BACKUP_RESTORE_TEST=PASS"
