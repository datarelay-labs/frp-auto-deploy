#!/usr/bin/env python3
import json
import os
import tempfile
import unittest
from pathlib import Path

import importlib.util


def load_audit():
    path = Path(__file__).resolve().parents[1] / "lib" / "frp_audit.py"
    spec = importlib.util.spec_from_file_location("frp_audit", str(path))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class AuditLogTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name
        os.environ["FRP_DEPLOY_TEST_ROOT"] = self.root
        os.environ.pop("FRP_AUDIT_LOG", None)
        self.audit = load_audit()

    def tearDown(self):
        self.tmp.cleanup()

    def test_redacts_secrets_and_appends(self):
        ok = self.audit.emit(
            "enrollment.created",
            client_id="aabbccdd",
            details={
                "ticket": "btck.0123456789abcdef.deadbeef",
                "label": "web01",
                "note": "ok",
            },
        )
        self.assertTrue(ok)
        path = self.audit.audit_path()
        self.assertEqual(oct(path.stat().st_mode & 0o777), "0o600")
        record = json.loads(path.read_text().splitlines()[-1])
        self.assertEqual(record["event"], "enrollment.created")
        self.assertEqual(record["details"]["ticket"], "[REDACTED]")
        self.assertEqual(record["details"]["label"], "web01")
        self.assertNotIn("deadbeef", path.read_text())

    def test_write_failure_warns_not_raise(self):
        blocker = Path(self.root) / "blocked"
        blocker.write_text("x")
        os.environ["FRP_AUDIT_LOG"] = "/blocked/audit.jsonl"
        ok = self.audit.emit("backup.created")
        self.assertFalse(ok)

    def test_rotation_on_emit(self):
        os.environ["FRP_AUDIT_ROTATE_BYTES"] = "80"
        os.environ["FRP_AUDIT_ROTATE_KEEP"] = "2"
        for index in range(20):
            self.audit.emit("backup.created", details={"n": index, "pad": "x" * 20})
        path = self.audit.audit_path()
        rotated = Path(str(path) + ".1")
        self.assertTrue(path.is_file())
        self.assertTrue(rotated.is_file())

    def test_installed_module_path(self):
        installed = Path(self.root) / "usr" / "local" / "lib" / "frp-auto-deploy"
        installed.mkdir(parents=True)
        src = Path(__file__).resolve().parents[1] / "lib" / "frp_audit.py"
        (installed / "frp_audit.py").write_text(src.read_text(encoding="utf-8"), encoding="utf-8")
        tool = Path(self.root) / "usr" / "local" / "sbin" / "frp-backup"
        tool.parent.mkdir(parents=True, exist_ok=True)
        path = self.audit.discover_audit_path(str(tool))
        self.assertEqual(path, installed / "frp_audit.py")


if __name__ == "__main__":
    unittest.main()
