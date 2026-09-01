#!/usr/bin/env python3
"""P1-P: Enrollment Code bind is durable before registry mutation."""
from __future__ import annotations

import hashlib
import hmac
import importlib.util
import json
import os
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load_mod(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


MOD = load_mod("frp_port_allocator", ROOT / "server" / "frp-port-allocator.py")
MGMT = load_mod("frp_mgmt_auth", ROOT / "lib" / "frp_mgmt_auth.py")


def pass_(name):
    print("PASS %s" % name)


def fail(name, detail=""):
    print("FAIL %s %s" % (name, detail), file=sys.stderr)
    raise SystemExit(1)


def hmac_hex(secret, message):
    return hmac.new(secret.encode(), message.encode(), hashlib.sha256).hexdigest()


class Env:
    def __init__(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.registry = self.root / "registry.json"
        self.token = self.root / "server_token"
        self.enrollments = self.root / "enrollments"
        self.enrollments.mkdir()
        self.bootstrap = self.root / "bootstrap"
        self.bootstrap.mkdir()
        self.keys = self.root / "keys"
        self.keys.mkdir()
        self.token.write_text("test-enroll-token-do-not-use\n")
        self.token.chmod(0o600)
        self.cfg = self.root / "config.json"
        self.cfg.write_text(
            json.dumps(
                {
                    "public_ip": "203.0.113.10",
                    "control_port": 443,
                    "port_start": 18300,
                    "port_end": 18320,
                    "listen_host": "127.0.0.1",
                    "listen_port": 6099,
                    "registry_file": str(self.registry),
                    "enrollments_dir": str(self.enrollments),
                    "bootstrap_dir": str(self.bootstrap),
                    "token_file": str(self.token),
                },
                indent=2,
            )
            + "\n"
        )
        MOD.atomic_write_json(self.registry, MOD.empty_registry())
        self.allocator = MOD.Allocator(str(self.cfg))
        MOD.port_is_available = lambda port: True
        self.eid = "aabbccdd11223344"
        self.secret = "enroll-secret-aabbccdd11223344"
        self.enroll_path = self.enrollments / ("%s.json" % self.eid)
        now = int(time.time())
        MOD.atomic_write_json(
            self.enroll_path,
            {
                "id": self.eid,
                "secret": self.secret,
                "expires_at": now + 600,
                "bound_machine_id": None,
                "used_at": None,
            },
        )
        self.key = self.keys / "client-identity.key"
        self.pub = self.keys / "client-identity.pub"
        MGMT.generate_keypair(self.key, self.pub)
        self.pub_pem = self.pub.read_text(encoding="utf-8")

    def cleanup(self):
        self.tmp.cleanup()

    def body(self, machine_id, hostname="bind-host"):
        payload = {
            "machine_id": machine_id,
            "hostname": hostname,
            "mgmt_pubkey": self.pub_pem,
            "mgmt_alg": MGMT.MGMT_ALG,
            "services": [
                {
                    "id": "ssh",
                    "name": "SSH",
                    "protocol": "tcp",
                    "local_ip": "127.0.0.1",
                    "local_port": 22,
                    "preset": "ssh",
                    "ssh_user": "aella",
                }
            ],
        }
        return json.dumps(payload, separators=(",", ":")).encode()

    def enroll(self, machine_id):
        body = self.body(machine_id)
        ts = str(int(time.time()))
        sig = hmac_hex(self.secret, ts + "\n" + body.decode())
        return self.allocator.enroll(self.eid, ts, sig, body)

    def load_enrollment(self):
        return json.loads(self.enroll_path.read_text(encoding="utf-8"))


def main():
    env = Env()
    try:
        machine_a = "machine-aaaa0001"
        machine_b = "machine-bbbb0002"
        before_reg = env.registry.read_bytes()

        os.environ["FRP_ALLOCATOR_HOOK_REGISTRY_PERSIST_FAIL"] = "1"
        try:
            code, result = env.enroll(machine_a)
        finally:
            os.environ.pop("FRP_ALLOCATOR_HOOK_REGISTRY_PERSIST_FAIL", None)

        if code != 500:
            fail("registry fail status", result)
        if env.registry.read_bytes() != before_reg:
            fail("registry mutated despite hook")
        rec = env.load_enrollment()
        if rec.get("bound_machine_id") != machine_a:
            fail("enrollment not bound before registry fail", rec)
        if not rec.get("used_at"):
            fail("used_at not set on bind", rec)
        pass_("BIND_BEFORE_REGISTRY_FAIL")

        # Machine B must be rejected even though registry never accepted A
        code, result = env.enroll(machine_b)
        if code != 403 or "bound" not in str(result.get("error", "")).lower():
            fail("machine B should be rejected", result)
        pass_("MACHINE_B_REJECTED_AFTER_BIND")

        # Machine A may retry and succeed
        code, result = env.enroll(machine_a)
        if code != 200:
            fail("machine A retry", result)
        state = json.loads(env.registry.read_text(encoding="utf-8"))
        if machine_a not in state.get("clients", {}):
            fail("machine A missing from registry after retry")
        if machine_b in state.get("clients", {}):
            fail("machine B leaked into registry")
        pass_("MACHINE_A_RETRY_OK")

        # Reuse policy unchanged: same machine can re-enroll with same code
        code, result = env.enroll(machine_a)
        if code != 200:
            fail("same-machine reuse", result)
        pass_("SAME_MACHINE_REUSE_OK")
    finally:
        os.environ.pop("FRP_ALLOCATOR_HOOK_REGISTRY_PERSIST_FAIL", None)
        env.cleanup()

    print("ENROLL_BIND_ORDERING=PASS")


if __name__ == "__main__":
    main()
