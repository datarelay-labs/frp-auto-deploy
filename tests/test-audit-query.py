#!/usr/bin/env python3
"""Producer→consumer audit query E2E: emit → query → format (schema, rotation, limit)."""
from __future__ import annotations

import importlib.util
import json
import os
import sys
import tempfile
import time
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path


def load_audit():
    path = Path(__file__).resolve().parents[1] / "lib" / "frp_audit.py"
    spec = importlib.util.spec_from_file_location("frp_audit", str(path))
    mod = importlib.util.module_from_spec(spec)
    sys.path.insert(0, str(path.parent))
    spec.loader.exec_module(mod)
    return mod


class AuditQueryE2ETests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name
        os.environ["FRP_DEPLOY_TEST_ROOT"] = self.root
        os.environ.pop("FRP_AUDIT_LOG", None)
        os.environ["FRP_AUDIT_ROTATE_BYTES"] = "120"
        os.environ["FRP_AUDIT_ROTATE_KEEP"] = "3"
        self.audit = load_audit()

    def tearDown(self):
        self.tmp.cleanup()

    def test_producer_consumer_schema_and_filters(self):
        self.assertTrue(
            self.audit.emit(
                "client.updated",
                actor="test",
                client_id="aabb0011",
                details={"group": "grp_deadbeef", "label": "web"},
            )
        )
        time.sleep(0.01)
        self.assertTrue(
            self.audit.emit(
                "enrollment.created",
                actor="test",
                details={"client_id": "ccdd0022", "group": "grp_cafebabe"},
            )
        )
        rows = self.audit.query(limit=50)
        self.assertGreaterEqual(len(rows), 2)
        self.assertIn("timestamp", rows[0])
        self.assertNotIn("ts", rows[0])  # canonical writer
        by_event = self.audit.query(event="enrollment.created")
        self.assertTrue(all(r["event"] == "enrollment.created" for r in by_event))
        by_client = self.audit.query(client_id="aabb0011")
        self.assertTrue(by_client)
        by_group = self.audit.query(group="grp_cafebabe")
        self.assertTrue(by_group)
        table = self.audit.format_audit_table(by_client)
        self.assertIn("event=client.updated", table)
        self.assertIn("group=grp_deadbeef", table)
        csv = self.audit.format_audit_csv(by_client)
        self.assertIn("timestamp", csv.splitlines()[0])
        self.assertIn("details_json", csv.splitlines()[0])

    def test_legacy_ts_meta_and_newest_limit(self):
        path = self.audit.audit_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        now = datetime.now(timezone.utc).replace(microsecond=0)
        legacy = [
            {
                "ts": (now - timedelta(hours=3)).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "event": "legacy.old",
                "actor": "a",
                "meta": {"client_id": "legacy01", "group": "g1"},
            },
            {
                "ts": (now - timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "event": "legacy.mid",
                "actor": "a",
                "meta": {"client_id": "legacy02"},
            },
            {
                "timestamp": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
                "event": "legacy.new",
                "actor": "a",
                "details": {"client_id": "legacy03"},
            },
        ]
        path.write_text("".join(json.dumps(r) + "\n" for r in legacy), encoding="utf-8")
        os.chmod(path, 0o600)
        rows = self.audit.query(limit=2)
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]["event"], "legacy.new")
        self.assertEqual(rows[1]["event"], "legacy.mid")
        legacy_client = self.audit.query(client_id="legacy01")
        self.assertEqual(len(legacy_client), 1)
        self.assertEqual(legacy_client[0]["event"], "legacy.old")

    def test_rotation_included_and_since_filter(self):
        for index in range(25):
            self.audit.emit("backup.created", details={"n": index, "pad": "y" * 40})
        path = self.audit.audit_path()
        rotated = Path(str(path) + ".1")
        self.assertTrue(rotated.is_file())
        # Seed a distinctive event only in the rotated file.
        rotated.write_text(
            rotated.read_text(encoding="utf-8")
            + json.dumps(
                {
                    "timestamp": "2099-01-01T00:00:00Z",
                    "event": "rotated.only",
                    "actor": "test",
                    "details": {"n": -1},
                }
            )
            + "\n",
            encoding="utf-8",
        )
        all_rows = self.audit.query(limit=1000)
        events = [r["event"] for r in all_rows]
        self.assertIn("rotated.only", events)
        # Newest-first across current + rotated files
        stamps = [self.audit._row_timestamp(r) for r in all_rows]
        self.assertEqual(stamps, sorted(stamps, reverse=True))
        recent = self.audit.query(since="1h", limit=1000)
        self.assertTrue(any(r["event"] == "backup.created" for r in recent))
        none = self.audit.query(event="never.happens")
        self.assertEqual(none, [])
        with self.assertRaises(ValueError):
            self.audit.query(since="1s")


if __name__ == "__main__":
    unittest.main()
