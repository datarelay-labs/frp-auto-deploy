#!/usr/bin/env python3
"""P1-O: management enroll consumes nonce before registry mutation (fail closed)."""
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
                    "token_file": str(self.token),
                },
                indent=2,
            )
            + "\n"
        )
        MOD.atomic_write_json(self.registry, MOD.empty_registry())
        self.allocator = MOD.Allocator(str(self.cfg))
        MOD.port_is_available = lambda port: True
        self.eid = "abcdef0123456789"
        self.secret = "enroll-secret-abcdef0123456789"
        now = int(time.time())
        MOD.atomic_write_json(
            self.enrollments / ("%s.json" % self.eid),
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

    def body(self, machine_id="machine-nonce", include_pub=True, services=None):
        payload = {
            "machine_id": machine_id,
            "hostname": "nonce-host",
            "services": services
            or [
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
        if include_pub:
            payload["mgmt_pubkey"] = self.pub_pem
            payload["mgmt_alg"] = MGMT.MGMT_ALG
        return json.dumps(payload, separators=(",", ":")).encode()

    def enroll_hmac(self, body=None):
        body = body if body is not None else self.body()
        ts = str(int(time.time()))
        sig = hmac_hex(self.secret, ts + "\n" + body.decode())
        return self.allocator.enroll(self.eid, ts, sig, body)

    def signed_headers(self, body, machine_id="machine-nonce", nonce=None):
        ts = int(time.time())
        nonce = nonce or MGMT.new_nonce()
        message = MGMT.signed_message(machine_id, body, ts, nonce)
        signature = MGMT.sign_message(self.key, message)
        return {
            "X-Mgmt-Auth": "1",
            "X-Timestamp": str(ts),
            "X-Mgmt-Nonce": nonce,
            "X-Mgmt-Signature": signature,
        }, ts, nonce

    def enroll_signed(self, body=None, machine_id="machine-nonce", headers=None):
        body = body if body is not None else self.body(machine_id=machine_id, include_pub=False)
        if headers is None:
            headers, _ts, _nonce = self.signed_headers(body, machine_id=machine_id)
        return self.allocator.enroll("", headers["X-Timestamp"], "", body, headers=headers), headers, body

    def nonce_present(self, machine_id, nonce):
        data = self.allocator.load_nonces()
        return ("%s:%s" % (machine_id, nonce)) in data.get("nonces", {})


def main():
    env = Env()
    try:
        code, result = env.enroll_hmac()
        if code != 200:
            fail("initial enroll", result)
        pass_("initial_hmac_enroll")

        body = env.body(include_pub=False)
        headers, _ts, nonce = env.signed_headers(body)
        before = env.registry.read_bytes()
        os.environ["FRP_ALLOCATOR_HOOK_REGISTRY_PERSIST_FAIL"] = "1"
        try:
            code, result = env.allocator.enroll(
                "", headers["X-Timestamp"], "", body, headers=headers
            )
        finally:
            os.environ.pop("FRP_ALLOCATOR_HOOK_REGISTRY_PERSIST_FAIL", None)
        if code != 500:
            fail("registry persist fail status", result)
        if env.registry.read_bytes() != before:
            fail("registry mutated despite persist hook")
        if not env.nonce_present("machine-nonce", nonce):
            fail("nonce not consumed before registry fail")
        # Same nonce must stay rejected
        code, result = env.allocator.enroll(
            "", headers["X-Timestamp"], "", body, headers=headers
        )
        if code != 403 or "replay" not in str(result.get("error", "")).lower():
            fail("replay after registry fail", result)
        pass_("NONCE_CONSUMED_BEFORE_REGISTRY_FAIL")

        # Retry with a NEW nonce succeeds
        (code, result), _, _ = env.enroll_signed(body)
        if code != 200:
            fail("new nonce retry", result)
        pass_("NEW_NONCE_RETRY_OK")

        # Nonce persist fail must not mutate registry and must not consume nonce
        body2 = env.body(
            include_pub=False,
            services=[
                {
                    "id": "ssh",
                    "name": "SSH",
                    "protocol": "tcp",
                    "local_ip": "127.0.0.1",
                    "local_port": 22,
                    "preset": "ssh",
                    "ssh_user": "aella",
                },
                {
                    "id": "web",
                    "name": "Web",
                    "protocol": "tcp",
                    "local_ip": "127.0.0.1",
                    "local_port": 80,
                    "preset": "custom",
                },
            ],
        )
        headers2, _ts2, nonce2 = env.signed_headers(body2)
        before2 = env.registry.read_bytes()
        os.environ["FRP_ALLOCATOR_HOOK_NONCE_PERSIST_FAIL"] = "1"
        try:
            code, result = env.allocator.enroll(
                "", headers2["X-Timestamp"], "", body2, headers=headers2
            )
        finally:
            os.environ.pop("FRP_ALLOCATOR_HOOK_NONCE_PERSIST_FAIL", None)
        if code != 500:
            fail("nonce persist fail status", result)
        if env.registry.read_bytes() != before2:
            fail("registry mutated on nonce persist fail")
        if env.nonce_present("machine-nonce", nonce2):
            fail("nonce consumed despite persist fail")
        # Same signed request can be retried once persist works
        code, result = env.allocator.enroll(
            "", headers2["X-Timestamp"], "", body2, headers=headers2
        )
        if code != 200:
            fail("retry after nonce persist fail", result)
        if "web" not in (env.allocator.load_registry()["clients"]["machine-nonce"]["services"]):
            fail("web service missing after retry")
        pass_("NONCE_PERSIST_FAIL_NO_CONSUME")
    finally:
        os.environ.pop("FRP_ALLOCATOR_HOOK_REGISTRY_PERSIST_FAIL", None)
        os.environ.pop("FRP_ALLOCATOR_HOOK_NONCE_PERSIST_FAIL", None)
        env.cleanup()

    print("MGMT_NONCE_ORDERING=PASS")


if __name__ == "__main__":
    main()
