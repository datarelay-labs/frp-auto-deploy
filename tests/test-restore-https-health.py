#!/usr/bin/env python3
"""P1-N: restore post-check uses verified HTTPS loopback /healthz (no plain HTTP)."""
from __future__ import annotations

import importlib.util
import json
import os
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))
import frp_pki  # noqa: E402


def load_restore():
    path = ROOT / "tools" / "frp-restore"
    from importlib.machinery import SourceFileLoader

    spec = importlib.util.spec_from_loader(
        "frp_restore", SourceFileLoader("frp_restore", str(path))
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


RESTORE = load_restore()


def pass_(name):
    print("PASS %s" % name)


def fail(name, detail=""):
    print("FAIL %s %s" % (name, detail), file=sys.stderr)
    raise SystemExit(1)


def free_port():
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


def wait_https(url, ca, timeout=5.0):
    ctx = ssl.create_default_context(cafile=str(ca))
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(url, context=ctx, timeout=1) as resp:
                return resp.read()
        except Exception as exc:
            last = exc
            time.sleep(0.05)
    raise last or RuntimeError("https wait failed")


def seed_tree(tree: Path, public_host: str, listen_port: int, pki_dir: Path):
    (tree / "etc/frp-auto-deploy/pki").mkdir(parents=True)
    (tree / "etc/frp").mkdir(parents=True)
    (tree / "var/lib/frp-auto-deploy").mkdir(parents=True)
    for name in ("ca.crt", "ca.key", "server.crt", "server.key"):
        src = pki_dir / name
        dest = tree / "etc/frp-auto-deploy/pki" / name
        dest.write_bytes(src.read_bytes())
        dest.chmod(0o600 if name.endswith(".key") else 0o644)
    cfg = {
        "deployment_mode": "direct",
        "public_host": public_host,
        "public_ip": public_host,
        "port_start": 6000,
        "port_end": 6098,
        "allocator_listen_port": listen_port,
        "allocator_public_port": listen_port,
        "frp_control_listen_port": 7000,
        "frp_control_public_port": 7000,
        "listen_port": listen_port,
        "registry_file": "/var/lib/frp-auto-deploy/registry.json",
        "enrollments_dir": "/var/lib/frp-auto-deploy/enrollments",
        "token_file": "/etc/frp/server_token",
        "tls_ca_cert": "/etc/frp-auto-deploy/pki/ca.crt",
        "tls_cert": "/etc/frp-auto-deploy/pki/server.crt",
        "tls_key": "/etc/frp-auto-deploy/pki/server.key",
    }
    (tree / "etc/frp-auto-deploy/config.json").write_text(
        json.dumps(cfg, indent=2) + "\n", encoding="utf-8"
    )
    (tree / "etc/frp-auto-deploy/version").write_text("2.1.1\n", encoding="utf-8")
    (tree / "etc/frp/frps.toml").write_text("bindPort = 7000\n", encoding="utf-8")
    (tree / "etc/frp/server_token").write_text("test-token\n", encoding="utf-8")
    (tree / "var/lib/frp-auto-deploy/registry.json").write_text(
        json.dumps({"schema_version": 2, "clients": {}, "groups": {}, "reserved": []})
        + "\n",
        encoding="utf-8",
    )
    return cfg


def write_allocator_cfg(tmp: Path, listen_port: int, pki: dict, public_host: str):
    cfg_path = tmp / "allocator.json"
    registry = tmp / "registry.json"
    enroll = tmp / "enrollments"
    enroll.mkdir(exist_ok=True)
    token = tmp / "server_token"
    token.write_text("test-token\n", encoding="utf-8")
    token.chmod(0o600)
    registry.write_text(
        json.dumps({"schema_version": 2, "clients": {}, "groups": {}, "reserved": []})
        + "\n",
        encoding="utf-8",
    )
    cfg = {
        "public_host": public_host,
        "public_ip": public_host,
        "frp_control_public_port": 8443,
        "frp_control_listen_port": 443,
        "port_start": 18300,
        "port_end": 18320,
        "listen_host": "127.0.0.1",
        "listen_port": listen_port,
        "allocator_listen_port": listen_port,
        "allocator_public_port": listen_port,
        "registry_file": str(registry),
        "enrollments_dir": str(enroll),
        "token_file": str(token),
        "tls_ca_cert": pki["ca_crt"],
        "tls_server_cert": pki["server_crt"],
        "tls_server_key": pki["server_key"],
        "data_plane_auth_strict": False,
    }
    cfg_path.write_text(json.dumps(cfg, indent=2) + "\n", encoding="utf-8")
    return cfg_path


def main():
    public_host = "203.0.113.10"
    with tempfile.TemporaryDirectory() as tmp_name:
        tmp = Path(tmp_name)
        pki = frp_pki.ensure_pki(str(tmp / "pki"), public_host)
        listen_port = free_port()
        cfg_path = write_allocator_cfg(tmp, listen_port, pki, public_host)
        proc = subprocess.Popen(
            [sys.executable, str(ROOT / "server" / "frp-port-allocator.py"), "--config", str(cfg_path)],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        try:
            wait_https("https://127.0.0.1:%s/healthz" % listen_port, pki["ca_crt"])

            # Helper: verified loopback HTTPS succeeds
            result = RESTORE.verify_allocator_https_health(
                public_host, listen_port, pki["ca_crt"], timeout=2
            )
            if not result.get("ok"):
                fail("helper health ok", result)
            pass_("HELPER_HTTPS_LOOPBACK_OK")

            # Missing public_host fails closed (no plain HTTP fallback)
            try:
                RESTORE.verify_allocator_https_health("", listen_port, pki["ca_crt"])
                fail("missing public_host should fail")
            except RESTORE.RestoreError as exc:
                if "public_host" not in str(exc):
                    fail("missing host message", exc)
            pass_("HELPER_REQUIRES_PUBLIC_HOST")

            # Source must not use insecure HTTP/curl -k/CERT_NONE for this probe
            src = (ROOT / "tools" / "frp-restore").read_text(encoding="utf-8")
            if "http://127.0.0.1" in src and "/healthz" in src:
                # Only accept https_loopback_get for allocator health
                health_fn = src[src.find("def verify_allocator_https_health") : src.find("def verify_restored_control_state")]
                if "http://" in health_fn or "CERT_NONE" in health_fn or "curl -k" in health_fn:
                    fail("helper still uses insecure probe")
            body = src[src.find("def verify_restored_control_state") : src.find("def restart_services")]
            if "urllib.request.urlopen" in body and "http://127.0.0.1" in body:
                fail("verify_restored_control_state still uses plain HTTP healthz")
            if "https_loopback_get" not in body and "verify_allocator_https_health" not in body:
                fail("production path does not call HTTPS helper")
            pass_("NO_PLAIN_HTTP_HEALTHZ")

            tree = tmp / "restore-root"
            seed_tree(tree, public_host, listen_port, Path(pki["ca_crt"]).parent)
            # Remap absolute CA path for helper via tree layout already seeded.

            os.environ["FRP_DEPLOY_TEST_ROOT"] = str(tree)
            os.environ["FRP_SKIP_SYSTEMD"] = "1"
            os.environ.pop("FRP_RESTORE_FORCE_HEALTH_PROBE", None)
            # Without force flag, test-root still skips runtime probes.
            RESTORE.verify_restored_control_state(tree)
            pass_("TEST_ROOT_SKIPS_WITHOUT_FORCE")

            os.environ["FRP_RESTORE_FORCE_HEALTH_PROBE"] = "1"
            # Force flag must run verified HTTPS even under FRP_DEPLOY_TEST_ROOT.
            # Remap config ports already point at live allocator; CA is under tree.
            ca_path = tree / "etc/frp-auto-deploy/pki/ca.crt"
            # verify_restored_control_state reads config listen_port from tree and
            # uses tree CA + public_host; allocator is listening on listen_port.
            RESTORE.verify_restored_control_state(tree)
            pass_("FORCE_HEALTH_PROBE_UNDER_TEST_ROOT")

            # Direct helper still works with tree CA
            RESTORE.verify_allocator_https_health(
                public_host, listen_port, ca_path, timeout=2
            )
            pass_("TREE_CA_HTTPS_PROBE")
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
            os.environ.pop("FRP_DEPLOY_TEST_ROOT", None)
            os.environ.pop("FRP_SKIP_SYSTEMD", None)
            os.environ.pop("FRP_RESTORE_FORCE_HEALTH_PROBE", None)

    print("RESTORE_HTTPS_HEALTH=PASS")


if __name__ == "__main__":
    main()
