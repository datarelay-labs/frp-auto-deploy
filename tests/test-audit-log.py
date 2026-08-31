#!/usr/bin/env python3
import json
import multiprocessing
import os
import tempfile
import time
import unittest
from pathlib import Path

import importlib.util


def load_audit():
    path = Path(__file__).resolve().parents[1] / "lib" / "frp_audit.py"
    spec = importlib.util.spec_from_file_location("frp_audit", str(path))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _concurrent_emit_worker(root, count, queue):
    os.environ["FRP_DEPLOY_TEST_ROOT"] = root
    os.environ.pop("FRP_AUDIT_LOG", None)
    audit = load_audit()
    ok = 0
    for index in range(count):
        if audit.emit("backup.created", details={"n": index, "pid": os.getpid()}):
            ok += 1
    queue.put(ok)


class AuditLogTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name
        os.environ["FRP_DEPLOY_TEST_ROOT"] = self.root
        os.environ.pop("FRP_AUDIT_LOG", None)
        os.environ.pop("FRP_AUDIT_ROTATE_BYTES", None)
        os.environ.pop("FRP_AUDIT_ROTATE_KEEP", None)
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

    def test_rotation_does_not_create_keep_plus_one(self):
        path = self.audit.audit_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        keep = 5
        for i in range(1, keep + 1):
            Path(f"{path}.{i}").write_text(f"old{i}\n", encoding="utf-8")
        path.write_text("x" * (6 * 1024 * 1024), encoding="utf-8")
        self.audit.rotate_if_needed(max_bytes=1024, keep=keep)
        self.assertFalse(Path(f"{path}.{keep + 1}").exists())
        self.assertTrue(Path(f"{path}.1").is_file())
        self.assertTrue(Path(f"{path}.{keep}").is_file())

    def test_symlink_current_log_refused(self):
        path = self.audit.audit_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        victim = Path(self.root) / "victim.jsonl"
        victim.write_text("keep\n", encoding="utf-8")
        path.symlink_to(victim)
        ok = self.audit.emit("backup.created", details={"n": 1})
        self.assertFalse(ok)
        self.assertEqual(victim.read_text(encoding="utf-8"), "keep\n")

    def test_concurrent_writers_bounded(self):
        workers = 4
        per_worker = 25
        queue = multiprocessing.Queue()
        procs = []
        for _ in range(workers):
            proc = multiprocessing.Process(
                target=_concurrent_emit_worker,
                args=(self.root, per_worker, queue),
            )
            proc.start()
            procs.append(proc)
        for proc in procs:
            proc.join(timeout=30)
            self.assertEqual(proc.exitcode, 0)
        total_ok = sum(queue.get(timeout=1) for _ in range(workers))
        self.assertEqual(total_ok, workers * per_worker)
        path = self.audit.audit_path()
        lines = [ln for ln in path.read_text(encoding="utf-8").splitlines() if ln.strip()]
        self.assertEqual(len(lines), workers * per_worker)
        for line in lines:
            json.loads(line)

    def test_rotation_with_lock(self):
        path = self.audit.audit_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        os.environ["FRP_AUDIT_ROTATE_BYTES"] = "200"
        os.environ["FRP_AUDIT_ROTATE_KEEP"] = "3"
        # Hold the audit lock while another emit must wait then succeed.
        lock_path = path.parent / (path.name + ".lock")
        import fcntl

        fd = os.open(str(lock_path), os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            started = time.time()
            result = {"ok": None}

            def delayed_emit():
                os.environ["FRP_DEPLOY_TEST_ROOT"] = self.root
                audit = load_audit()
                result["ok"] = audit.emit("backup.created", details={"pad": "y" * 40})

            import threading

            thread = threading.Thread(target=delayed_emit)
            thread.start()
            time.sleep(0.2)
            self.assertTrue(thread.is_alive())
            fcntl.flock(fd, fcntl.LOCK_UN)
            thread.join(timeout=10)
            self.assertFalse(thread.is_alive())
            self.assertTrue(result["ok"])
            self.assertGreaterEqual(time.time() - started, 0.15)
        finally:
            try:
                os.close(fd)
            except OSError:
                pass
        for index in range(30):
            self.assertTrue(
                self.audit.emit("backup.created", details={"n": index, "pad": "z" * 30})
            )
        self.assertTrue(path.is_file())
        self.assertTrue(Path(str(path) + ".1").is_file())


if __name__ == "__main__":
    unittest.main()
