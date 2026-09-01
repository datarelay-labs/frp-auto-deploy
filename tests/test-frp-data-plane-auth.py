#!/usr/bin/env python3
"""P1-L: FRP data-plane authorization (NewProxy plugin + cryptographic proofs)."""
from __future__ import annotations

import importlib.util
import json
import os
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
from copy import deepcopy
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FRPS = Path(os.environ.get("FRP_TEST_FRPS", "/usr/local/bin/frps"))
FRPC = Path(os.environ.get("FRP_TEST_FRPC", "/tmp/frp_0.70.1_linux_amd64/frpc"))


def load_mod(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


DPA = load_mod("frp_data_plane_auth", ROOT / "lib" / "frp_data_plane_auth.py")
MGMT = load_mod("frp_mgmt_auth", ROOT / "lib" / "frp_mgmt_auth.py")
LEASES = load_mod("frp_proxy_leases", ROOT / "lib" / "frp_proxy_leases.py")
PLUGIN = load_mod("frp_plugin_server", ROOT / "lib" / "frp_plugin_server.py")
CREG = load_mod("frp_client_registry", ROOT / "lib" / "frp_client_registry.py")


def pass_(name):
    print("PASS %s" % name)


def fail(name, detail=""):
    print("FAIL %s %s" % (name, detail), file=sys.stderr)
    raise SystemExit(1)


def assert_frpc_binary(path):
    if not path.is_file() or not os.access(path, os.X_OK):
        return False
    try:
        if path.read_bytes()[:2] == b"#!":
            return False
    except OSError:
        return False
    return True


def free_port():
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


def wait_listen(port, timeout=10.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.3):
                return True
        except OSError:
            time.sleep(0.1)
    return False


def wait_offline(port, timeout=8.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                time.sleep(0.1)
        except OSError:
            return True
    return False


def write(path: Path, text: str, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    path.chmod(mode)


class ProcGroup:
    def __init__(self):
        self.procs = []

    def add(self, proc):
        self.procs.append(proc)
        return proc

    def stop(self):
        for proc in self.procs:
            try:
                proc.send_signal(signal.SIGTERM)
            except OSError:
                pass
        time.sleep(0.3)
        for proc in self.procs:
            try:
                if proc.poll() is None:
                    proc.kill()
            except OSError:
                pass
        self.procs.clear()


def base_service(remote_port, **overrides):
    svc = {
        "id": "ssh",
        "name": "SSH",
        "protocol": "tcp",
        "preset": "ssh",
        "enabled": True,
        "local_ip": "127.0.0.1",
        "local_port": 22,
        "remote_port": remote_port,
        "ssh_user": "test",
    }
    svc.update(overrides)
    return svc


def base_registry(clients, reserved=None):
    return {
        "schema_version": 2,
        "clients": clients,
        "groups": {},
        "reserved": reserved or [],
    }


class Env:
    def __init__(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        os.environ["FRP_DEPLOY_TEST_ROOT"] = str(self.root)
        self.registry_path = self.root / "registry.json"
        self.control_port = free_port()
        self.remote_port = free_port()
        self.local_port = free_port()
        self.plugin_port = free_port()
        self.token = "p1l-data-plane-test-token"
        self.cfg = {
            "proxy_lease_dir": "proxy-leases",
            "data_plane_auth_strict": True,
            "port_start": 10000,
            "port_end": 65000,
            "frp_plugin_listen_port": self.plugin_port,
            "registry_file": str(self.registry_path),
        }
        self.keys = {}
        self.procs = ProcGroup()
        self.plugin_server = None
        self._write_registry(base_registry({}))

    def cleanup(self):
        self.procs.stop()
        self.stop_plugin()
        os.environ.pop("FRP_DEPLOY_TEST_ROOT", None)
        os.environ.pop("FRP_DATA_PLANE_HOOK_DELAY_AFTER_LEASE", None)
        os.environ.pop("FRP_DATA_PLANE_HOOK_FORCE_REJECT", None)
        os.environ.pop("FRP_DATA_PLANE_HOOK_AFTER_REGISTRY_AUTH_BEFORE_LEASE", None)
        os.environ.pop("FRP_DATA_PLANE_HOOK_MARKER", None)
        self.tmp.cleanup()

    def keypair(self, client_id):
        if client_id in self.keys:
            return self.keys[client_id]
        key = self.root / ("%s.key" % client_id)
        pub = self.root / ("%s.pub" % client_id)
        MGMT.generate_keypair(key, pub)
        self.keys[client_id] = (key, pub)
        return key, pub

    def proof(self, client_id):
        key, _pub = self.keypair(client_id)
        return DPA.sign_proof(key, client_id)

    def client_record(self, client_id, services, mgmt_status="enrolled"):
        _key, pub = self.keypair(client_id)
        return {
            "hostname": client_id,
            "mgmt_pubkey": pub.read_text(encoding="utf-8"),
            "mgmt_status": mgmt_status,
            "services": services,
        }

    def _write_registry(self, state):
        write(self.registry_path, json.dumps(state, indent=2) + "\n")

    def set_registry(self, state):
        self._write_registry(state)

    def load_registry(self):
        return json.loads(self.registry_path.read_text(encoding="utf-8"))

    def new_proxy_content(
        self,
        client_id,
        service_id="ssh",
        remote_port=None,
        proof=None,
        run_id="run-test",
        *,
        include_client_meta=True,
        include_proof=True,
        include_proof_schema=True,
        include_service_meta=True,
    ):
        remote_port = self.remote_port if remote_port is None else remote_port
        proof = self.proof(client_id) if proof is None else proof
        user_metas = {}
        if include_client_meta:
            user_metas[DPA.META_CLIENT_ID] = client_id
        if include_proof_schema:
            user_metas[DPA.META_PROOF_SCHEMA] = str(DPA.DATA_PLANE_SCHEMA)
        if include_proof:
            user_metas[DPA.META_PROOF] = proof
        proxy_metas = {}
        if include_service_meta:
            proxy_metas[DPA.META_SERVICE_ID] = service_id
        return {
            "proxy_type": "tcp",
            "remote_port": remote_port,
            "proxy_name": "%s-%s" % (client_id, service_id),
            "user": {
                "run_id": run_id,
                "metas": user_metas,
            },
            "metas": proxy_metas,
        }

    def authorize(self, content, registry_state=None):
        state = self.load_registry() if registry_state is None else registry_state
        return DPA.authorize_new_proxy(content, state, cfg=self.cfg, lease_mod=LEASES)

    def plugin_payload(self, content, op="NewProxy"):
        return {
            "version": "0.1.0",
            "op": op,
            "content": content,
        }

    def handle_plugin(self, content, op="NewProxy"):
        body = json.dumps(self.plugin_payload(content, op=op)).encode("utf-8")
        query = "version=0.1.0&op=%s" % op
        return DPA.handle_plugin_http(
            "POST",
            DPA.PLUGIN_PATH,
            query,
            body,
            self.load_registry,
            cfg=self.cfg,
        )

    def stop_plugin(self):
        if self.plugin_server is not None:
            try:
                self.plugin_server.shutdown()
            except Exception:
                pass
            self.plugin_server = None

    def reset_plugin_port(self):
        self.stop_plugin()
        self.plugin_port = free_port()
        self.cfg["frp_plugin_listen_port"] = self.plugin_port

    def clear_leases(self):
        lease_dir = Path(LEASES.lease_dir_from_cfg(self.cfg))
        if lease_dir.is_dir():
            for path in lease_dir.glob("lease-*.json"):
                try:
                    path.unlink()
                except OSError:
                    pass

    def start_plugin(self):
        self.stop_plugin()
        host, port = PLUGIN.plugin_listen_from_cfg(self.cfg)
        self.plugin_server, _thread = PLUGIN.start_plugin_server(
            self.load_registry,
            self.cfg,
            host=host,
            port=port,
        )

    def frps_toml(self, plugin_addr=None, allow_start=None, allow_end=None):
        plugin_addr = plugin_addr if plugin_addr is not None else "127.0.0.1:%d" % self.plugin_port
        allow_start = self.remote_port if allow_start is None else allow_start
        allow_end = self.remote_port if allow_end is None else allow_end
        return "\n".join(
            [
                'bindAddr = "127.0.0.1"',
                "bindPort = %d" % self.control_port,
                'auth.method = "token"',
                'auth.token = "%s"' % self.token,
                "transport.tls.force = false",
                "allowPorts = [",
                "  { start = %d, end = %d }" % (allow_start, allow_end),
                "]",
                "[[httpPlugins]]",
                'name = "frp-auto-deploy-port-authorizer"',
                'addr = "%s"' % plugin_addr,
                'path = "/handler"',
                'ops = ["NewProxy"]',
                "",
            ]
        )

    def frpc_toml(self, client_id, remote_port=None, service_id="ssh", proof=None, extra_lines=None):
        remote_port = self.remote_port if remote_port is None else remote_port
        proof = self.proof(client_id) if proof is None else proof
        lines = [
            'serverAddr = "127.0.0.1"',
            "serverPort = %d" % self.control_port,
            'auth.method = "token"',
            'auth.token = "%s"' % self.token,
            "transport.tls.enable = false",
            "",
        ]
        lines.extend(DPA.frpc_global_metadata_lines(client_id, proof))
        lines.extend(
            [
                "",
                "[[proxies]]",
                'name = "%s-%s"' % (client_id, service_id),
                'type = "tcp"',
                'localIP = "127.0.0.1"',
                "localPort = %d" % self.local_port,
                "remotePort = %d" % remote_port,
            ]
        )
        lines.extend(DPA.frpc_proxy_metadata_lines(service_id))
        if extra_lines:
            lines.extend(extra_lines)
        return "\n".join(lines) + "\n"

    def start_frps(self, plugin_addr=None, allow_start=None, allow_end=None):
        write(self.root / "frps.toml", self.frps_toml(plugin_addr, allow_start, allow_end))
        log_path = self.root / "frps.log"
        proc = subprocess.Popen(
            [str(FRPS), "-c", str(self.root / "frps.toml")],
            stdout=log_path.open("w"),
            stderr=subprocess.STDOUT,
            cwd=str(self.root),
        )
        self.procs.add(proc)
        if not wait_listen(self.control_port):
            detail = log_path.read_text(encoding="utf-8", errors="replace")[:800]
            fail("frps_listen", detail)
        return proc

    def start_frpc(self, toml_path, log_name="frpc.log"):
        log_path = self.root / log_name
        proc = subprocess.Popen(
            [str(FRPC), "-c", str(toml_path)],
            stdout=log_path.open("w"),
            stderr=subprocess.STDOUT,
            cwd=str(self.root),
        )
        self.procs.add(proc)
        return proc, log_path

    def frpc_error_seen(self, log_path, needle, timeout=8.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            text = log_path.read_text(encoding="utf-8", errors="replace")
            if needle in text:
                return True
            time.sleep(0.2)
        return False


def run_unit_tests(env):
    client_a = "client-a"
    client_b = "client-b"
    env.set_registry(
        base_registry(
            {
                client_a: env.client_record(
                    client_a,
                    {"ssh": base_service(env.remote_port)},
                )
            }
        )
    )
    valid = env.new_proxy_content(client_a)

    corrupt = deepcopy(env.load_registry())
    corrupt["schema_version"] = 1
    allowed, reason = env.authorize(valid, registry_state=corrupt)
    if allowed or "registry is invalid" not in (reason or ""):
        fail("unit_corrupt_registry", reason)
    pass_("UNIT_CORRUPT_REGISTRY_REJECTED")

    bad_proof = env.new_proxy_content(client_a, proof="AAAA")
    allowed, reason = env.authorize(bad_proof)
    if allowed or "invalid data-plane proof" not in (reason or ""):
        fail("unit_wrong_proof", reason)
    pass_("UNIT_WRONG_PROOF_REJECTED")

    allowed, reason = env.authorize(env.new_proxy_content("client-missing"))
    if allowed or "unknown client" not in (reason or ""):
        fail("unit_wrong_client", reason)
    pass_("UNIT_WRONG_CLIENT_REJECTED")

    allowed, reason = env.authorize(env.new_proxy_content(client_a, service_id="web"))
    if allowed or "unknown service" not in (reason or ""):
        fail("unit_wrong_service", reason)
    pass_("UNIT_WRONG_SERVICE_REJECTED")

    allowed, reason = env.authorize(
        env.new_proxy_content(client_a, remote_port=env.remote_port + 1)
    )
    if allowed or "remote_port does not match" not in (reason or ""):
        fail("unit_wrong_port", reason)
    pass_("UNIT_WRONG_PORT_REJECTED")

    disabled_reg = deepcopy(env.load_registry())
    disabled_reg["clients"][client_a]["services"]["ssh"]["enabled"] = False
    allowed, reason = env.authorize(valid, registry_state=disabled_reg)
    if allowed or "service is disabled" not in (reason or ""):
        fail("unit_disabled_service", reason)
    pass_("UNIT_DISABLED_SERVICE_REJECTED")

    for label, kwargs in (
        ("client", {"include_client_meta": False}),
        ("proof", {"include_proof": False}),
        ("service", {"include_service_meta": False}),
    ):
        allowed, reason = env.authorize(env.new_proxy_content(client_a, **kwargs))
        if allowed:
            fail("unit_missing_%s" % label, reason)
    pass_("UNIT_MISSING_METADATA_REJECTED")

    allowed, reason = env.authorize(valid)
    if not allowed:
        fail("unit_valid_authorize", reason)
    pass_("UNIT_VALID_CLIENT_SERVICE_PORT_ALLOWED")
    env.clear_leases()

    # Revoked management status must not block data-plane proof verification.
    # Management revoke invalidates enroll/API access only; existing registry
    # reservations and the stored public key remain authoritative here.
    revoked_reg = deepcopy(env.load_registry())
    revoked_reg["clients"][client_a]["mgmt_status"] = "revoked"
    LEASES.expire_stale(LEASES.lease_dir_from_cfg(env.cfg))
    allowed, reason = env.authorize(valid, registry_state=revoked_reg)
    if not allowed:
        fail("unit_revoked_mgmt_still_allows_proof", reason)
    pass_("UNIT_REVOKED_MGMT_ALLOWS_DATA_PLANE_PROOF")
    env.clear_leases()


def run_plugin_http_tests(env):
    client_a = "client-a"
    env.set_registry(
        base_registry(
            {
                client_a: env.client_record(
                    client_a,
                    {"ssh": base_service(env.remote_port)},
                )
            }
        )
    )
    content = env.new_proxy_content(client_a)

    code, payload = env.handle_plugin(content)
    if code != 200 or payload.get("reject"):
        fail("plugin_http_allow", payload)
    pass_("PLUGIN_HTTP_ALLOW_ROUNDTRIP")

    bad = env.new_proxy_content(client_a, proof="bad-proof")
    code, payload = env.handle_plugin(bad)
    if code != 200 or not payload.get("reject"):
        fail("plugin_http_reject", payload)
    if not payload.get("reject_reason"):
        fail("plugin_http_reject_reason", payload)
    pass_("PLUGIN_HTTP_REJECT_ROUNDTRIP")

    env.start_plugin()
    url = "http://127.0.0.1:%d/handler?version=0.1.0&op=NewProxy" % env.plugin_port
    req = urllib.request.Request(
        url,
        data=json.dumps(env.plugin_payload(content)).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=5) as resp:
        body = json.loads(resp.read().decode("utf-8"))
    if body.get("reject"):
        fail("plugin_server_allow", body)
    pass_("PLUGIN_SERVER_HTTP_ROUNDTRIP")
    env.stop_plugin()


def run_integration_stale_client(env):
    """Product release-service state: client A remains, service ssh is removed."""
    env.reset_plugin_port()
    env.clear_leases()
    client_a = "client-a"
    client_b = "client-b"
    env.set_registry(
        base_registry(
            {
                client_a: env.client_record(
                    client_a,
                    {"ssh": base_service(env.remote_port)},
                ),
            }
        )
    )
    # Simulate release-service: keep client A, drop only ssh.
    state = env.load_registry()
    state["clients"][client_a]["services"] = {}
    state["clients"][client_b] = env.client_record(
        client_b,
        {"ssh": base_service(env.remote_port)},
    )
    env.set_registry(state)
    if "client-a" not in env.load_registry()["clients"]:
        fail("integration_release_service_client_missing")
    if "ssh" in (env.load_registry()["clients"]["client-a"].get("services") or {}):
        fail("integration_release_service_ssh_still_present")
    pass_("RELEASE_SERVICE_STATE_TEST")

    env.start_plugin()
    env.start_frps()
    stale_toml = env.root / "frpc-stale-a.toml"
    write(
        stale_toml,
        env.frpc_toml(client_a, proof=env.proof(client_a)),
    )
    _proc, log_path = env.start_frpc(stale_toml, log_name="frpc-stale.log")
    if wait_listen(env.remote_port, timeout=6.0):
        fail("integration_stale_service_bound")
    log_text = log_path.read_text(encoding="utf-8", errors="replace")
    if "unknown service" not in log_text:
        fail("integration_stale_service_error", log_text[:800])
    pass_("STALE_RELEASED_SERVICE_REJECTED")
    pass_("INTEGRATION_STALE_RELEASED_CLIENT_REJECTED")
    try:
        _proc.send_signal(signal.SIGTERM)
    except OSError:
        pass
    time.sleep(0.5)

    valid_b_toml = env.root / "frpc-valid-b.toml"
    write(valid_b_toml, env.frpc_toml(client_b))
    _bproc, b_log = env.start_frpc(valid_b_toml, log_name="frpc-valid-b.log")
    if not wait_listen(env.remote_port, timeout=12.0):
        fail("integration_reallocated_client_bind", b_log.read_text()[:800])
    pass_("INTEGRATION_RELEASED_PORT_REALLOCATED_TO_NEW_CLIENT")
    pass_("RELEASED_PORT_REALLOCATED_TO_NEW_CLIENT")

    stale2_toml = env.root / "frpc-stale-a-again.toml"
    write(stale2_toml, env.frpc_toml(client_a, proof=env.proof(client_a)))
    _proc2, log2 = env.start_frpc(stale2_toml, log_name="frpc-stale-again.log")
    time.sleep(2.0)
    if not wait_listen(env.remote_port, timeout=2.0):
        fail("integration_reallocated_port_lost", b_log.read_text()[:800])
    rejected = False
    for needle in ("unknown service", "unknown client", "invalid data-plane proof", "proxy name"):
        if env.frpc_error_seen(log2, needle, timeout=3.0):
            rejected = True
            break
    if not rejected:
        fail("integration_old_client_reclaim", log2.read_text()[:800])
    pass_("INTEGRATION_OLD_CLIENT_CANNOT_RECLAIM_REALLOCATED_PORT")


def run_integration_release_client_state(env):
    """Product release-client state: client A remains with empty services."""
    env.reset_plugin_port()
    env.clear_leases()
    client_a = "client-a"
    env.set_registry(
        base_registry(
            {
                client_a: env.client_record(
                    client_a,
                    {
                        "ssh": base_service(env.remote_port),
                        "https": base_service(env.remote_port + 1, id="https", preset="https"),
                    },
                ),
            }
        )
    )
    state = env.load_registry()
    state["clients"][client_a]["services"] = {}
    env.set_registry(state)
    if "client-a" not in env.load_registry()["clients"]:
        fail("release_client_state_client_deleted")
    if env.load_registry()["clients"]["client-a"].get("services"):
        fail("release_client_state_services_not_empty")
    pass_("RELEASE_CLIENT_STATE_TEST")

    env.start_plugin()
    env.start_frps()
    stale_toml = env.root / "frpc-release-client.toml"
    write(stale_toml, env.frpc_toml(client_a, proof=env.proof(client_a)))
    _proc, log_path = env.start_frpc(stale_toml, log_name="frpc-release-client.log")
    if wait_listen(env.remote_port, timeout=6.0):
        fail("release_client_stale_bound")
    if "unknown service" not in log_path.read_text(encoding="utf-8", errors="replace"):
        fail("release_client_stale_error", log_path.read_text()[:800])
    pass_("STALE_RELEASED_CLIENT_REJECTED")


def run_integration_impersonation(env):
    env.reset_plugin_port()
    env.clear_leases()
    client_a = "client-a"
    client_b = "client-b"
    arbitrary_port = free_port()
    env.set_registry(
        base_registry(
            {
                client_a: env.client_record(client_a, {}),
                client_b: env.client_record(
                    client_b,
                    {"ssh": base_service(env.remote_port)},
                ),
            }
        )
    )
    env.start_plugin()
    env.start_frps(allow_start=min(env.remote_port, arbitrary_port), allow_end=max(env.remote_port, arbitrary_port))

    imp_toml = env.root / "frpc-impersonate.toml"
    write(
        imp_toml,
        env.frpc_toml(client_a, proof=env.proof(client_b)),
    )
    _proc, imp_log = env.start_frpc(imp_toml, log_name="frpc-imp.log")
    if wait_listen(env.remote_port, timeout=6.0):
        fail("integration_impersonation_bound")
    if not env.frpc_error_seen(imp_log, "invalid data-plane proof"):
        fail("integration_impersonation_error", imp_log.read_text()[:800])
    pass_("INTEGRATION_IMPERSONATION_REJECTED")

    arb_toml = env.root / "frpc-arbitrary-port.toml"
    write(arb_toml, env.frpc_toml(client_b, remote_port=arbitrary_port))
    _proc2, arb_log = env.start_frpc(arb_toml, log_name="frpc-arb.log")
    if wait_listen(arbitrary_port, timeout=6.0):
        fail("integration_arbitrary_port_bound")
    if not env.frpc_error_seen(arb_log, "remote_port does not match registry reservation"):
        fail("integration_arbitrary_port_error", arb_log.read_text()[:800])
    pass_("INTEGRATION_ARBITRARY_ALLOWPORTS_PORT_REJECTED")


def run_integration_plugin_unavailable(env):
    env.reset_plugin_port()
    env.clear_leases()
    client_a = "client-a"
    env.set_registry(
        base_registry(
            {
                client_a: env.client_record(
                    client_a,
                    {"ssh": base_service(env.remote_port)},
                )
            }
        )
    )
    dead_port = free_port()
    env.start_frps(plugin_addr="127.0.0.1:%d" % dead_port)
    toml_path = env.root / "frpc-dead-plugin.toml"
    write(toml_path, env.frpc_toml(client_a))
    _proc, log_path = env.start_frpc(toml_path, log_name="frpc-dead-plugin.log")
    if wait_listen(env.remote_port, timeout=6.0):
        fail("integration_dead_plugin_bound")
    if not env.frpc_error_seen(log_path, "send NewProxy request to plugin error"):
        fail("integration_dead_plugin_error", log_path.read_text()[:800])
    pass_("INTEGRATION_PLUGIN_UNAVAILABLE_FAIL_CLOSED")


def run_integration_release_race(env):
    env.reset_plugin_port()
    env.clear_leases()
    client_a = "client-a"
    env.set_registry(
        base_registry(
            {
                client_a: env.client_record(
                    client_a,
                    {"ssh": base_service(env.remote_port)},
                )
            }
        )
    )
    os.environ["FRP_DATA_PLANE_HOOK_DELAY_AFTER_LEASE"] = "1"
    env.start_plugin()
    env.start_frps()
    toml_path = env.root / "frpc-race.toml"
    write(toml_path, env.frpc_toml(client_a))
    proc, log_path = env.start_frpc(toml_path, log_name="frpc-race.log")
    if not wait_listen(env.remote_port, timeout=12.0):
        fail("integration_release_race_bind", log_path.read_text()[:800])

    try:
        DPA.assert_port_releasable(env.remote_port, cfg=env.cfg, lease_mod=LEASES)
    except ValueError as exc:
        if "online" not in str(exc) and "active authorization lease" not in str(exc):
            fail("integration_release_race_refuse_while_live", exc)
    else:
        fail("integration_release_race_refuse_while_live", "expected refusal")

    proc.send_signal(signal.SIGTERM)
    if not wait_offline(env.remote_port, timeout=8.0):
        fail("integration_release_race_offline")

    lease_dir = LEASES.lease_dir_from_cfg(env.cfg)
    if LEASES.has_active_lease(lease_dir, remote_port=env.remote_port):
        for path in Path(lease_dir).glob("lease-*.json"):
            data = json.loads(path.read_text(encoding="utf-8"))
            data["expires_at"] = time.time() - 1
            path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
        LEASES.expire_stale(lease_dir)

    try:
        DPA.assert_port_releasable(env.remote_port, cfg=env.cfg, lease_mod=LEASES)
    except ValueError as exc:
        fail("integration_release_race_allowed_after_stop", exc)
    pass_("INTEGRATION_RELEASE_RACE_LEASE_GUARD")


def run_integration_valid_client(env):
    env.reset_plugin_port()
    env.clear_leases()
    client_a = "client-a"
    env.set_registry(
        base_registry(
            {
                client_a: env.client_record(
                    client_a,
                    {"ssh": base_service(env.remote_port)},
                )
            }
        )
    )
    env.start_plugin()
    env.start_frps()
    toml_path = env.root / "frpc-valid.toml"
    write(toml_path, env.frpc_toml(client_a))
    _proc, log_path = env.start_frpc(toml_path, log_name="frpc-valid.log")
    if not wait_listen(env.remote_port, timeout=12.0):
        fail("integration_valid_client_bind", log_path.read_text()[:800])
    pass_("INTEGRATION_VALID_CLIENT_BINDS")


def main():
    if not FRPS.is_file():
        fail("frps_missing", str(FRPS))
    if not assert_frpc_binary(FRPC):
        fail("frpc_missing_or_stub", str(FRPC))

    env = Env()
    try:
        run_unit_tests(env)
        run_plugin_http_tests(env)
        run_integration_valid_client(env)
        env.procs.stop()
        env.stop_plugin()

        run_integration_stale_client(env)
        env.procs.stop()
        env.stop_plugin()

        run_integration_release_client_state(env)
        env.procs.stop()
        env.stop_plugin()

        run_integration_impersonation(env)
        env.procs.stop()
        env.stop_plugin()

        run_integration_plugin_unavailable(env)
        env.procs.stop()
        env.stop_plugin()

        run_integration_release_race(env)
    finally:
        env.cleanup()

    print("P1_L_INTEGRATION=PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
