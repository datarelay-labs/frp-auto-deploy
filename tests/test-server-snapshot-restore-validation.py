#!/usr/bin/env python3
"""P2-3: server install snapshot restore must fail-closed on unsafe metadata."""
from __future__ import annotations

import json
import os
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))
import frp_install_txn as txn  # noqa: E402


def fail(msg):
    print("FAIL", msg, file=sys.stderr)
    raise SystemExit(1)


def write_meta(snap: Path, present=None, absent=None):
    meta = {
        "present": present or [],
        "absent": absent or [],
        "services": {"skipped": True},
        "extra": {},
    }
    (snap / "metadata.json").write_text(json.dumps(meta) + "\n", encoding="utf-8")


def expect_reject(label, root, snap):
    try:
        txn.restore(root, snap)
    except txn.SnapshotRestoreError:
        print("%s=PASS" % label)
        return
    fail("%s should reject" % label)


def main():
    with tempfile.TemporaryDirectory() as td:
        td_path = Path(td)
        root = td_path / "root"
        snap = td_path / "snap"
        (root / "usr/local/lib/frp-auto-deploy").mkdir(parents=True)
        (root / "etc/frp-auto-deploy").mkdir(parents=True)
        (snap / "files/usr/local/lib/frp-auto-deploy").mkdir(parents=True)
        (root / "usr/local/lib/frp-auto-deploy/frp-common.sh").write_text("live\n", encoding="utf-8")
        (snap / "files/usr/local/lib/frp-auto-deploy/frp-common.sh").write_text(
            "snap\n", encoding="utf-8"
        )

        # Valid restore
        write_meta(
            snap,
            present=[{"path": "usr/local/lib/frp-auto-deploy/frp-common.sh", "mode": 0o644}],
            absent=["etc/frp-auto-deploy/frontend.conf"],
        )
        (root / "etc/frp-auto-deploy/frontend.conf").write_text("gone\n", encoding="utf-8")
        os.environ["FRP_SERVER_TEST_ROOT"] = str(root)
        meta = txn.restore(root, snap)
        if meta is None:
            fail("valid restore returned None")
        if (root / "usr/local/lib/frp-auto-deploy/frp-common.sh").read_text() != "snap\n":
            fail("valid restore content")
        if (root / "etc/frp-auto-deploy/frontend.conf").exists():
            fail("valid restore should remove absent file")
        print("SERVER_SNAPSHOT_VALID_RESTORE=PASS")

        # Unknown path
        write_meta(snap, present=[{"path": "tmp/evil", "mode": 0o644}])
        (snap / "files/tmp").mkdir(parents=True, exist_ok=True)
        (snap / "files/tmp/evil").write_text("x\n", encoding="utf-8")
        expect_reject("SERVER_SNAPSHOT_UNKNOWN_PATH_REJECTED", root, snap)

        # Dotdot
        write_meta(
            snap,
            present=[{"path": "usr/local/lib/frp-auto-deploy/../frp-common.sh", "mode": 0o644}],
        )
        expect_reject("SERVER_SNAPSHOT_DOTDOT_REJECTED", root, snap)

        # Absolute
        write_meta(snap, present=[{"path": "/etc/passwd", "mode": 0o644}])
        expect_reject("SERVER_SNAPSHOT_ABSOLUTE_PATH_REJECTED", root, snap)

        # Protected
        write_meta(snap, present=[{"path": "etc/frp/server_token", "mode": 0o600}])
        (snap / "files/etc/frp").mkdir(parents=True, exist_ok=True)
        (snap / "files/etc/frp/server_token").write_text("tok\n", encoding="utf-8")
        expect_reject("SERVER_SNAPSHOT_PROTECTED_PATH_REJECTED", root, snap)

        # Symlink escape under files/
        write_meta(
            snap,
            present=[{"path": "usr/local/lib/frp-auto-deploy/frp-common.sh", "mode": 0o644}],
        )
        target = snap / "files/usr/local/lib/frp-auto-deploy/frp-common.sh"
        if target.exists() or target.is_symlink():
            target.unlink()
        escape = td_path / "outside"
        escape.write_text("escaped\n", encoding="utf-8")
        target.symlink_to(escape)
        expect_reject("SERVER_SNAPSHOT_SYMLINK_ESCAPE_REJECTED", root, snap)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
