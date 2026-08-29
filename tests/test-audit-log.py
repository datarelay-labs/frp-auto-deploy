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


if __name__ == "__main__":
    unittest.main()
